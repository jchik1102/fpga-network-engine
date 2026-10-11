import json
from dataclasses import replace
from pathlib import Path

import pytest
from scapy.all import Ether, IP, UDP, TCP, Raw, Padding

from models.abi import Completion, Descriptor, Segment, bursts
from models.ownership import HostMemory
from models.packet import Drop, Rule, beats, classify, observe_beats
from models.policy import due_tick, eligible, lateness, loss_word, lost


def frame(payload=18):
    return bytes(Ether(src="02:00:00:00:00:01",dst="02:00:00:00:00:02") /
                 IP(src="192.0.2.1",dst="198.51.100.2",id=0x1234) /
                 UDP(sport=1234,dport=4321) / Raw(bytes(range(payload))))


def descriptor(replay=False, sequence=0, address=None):
    return Descriptor(0x0123456789ABCDEF,sequence,1,0,60,
                      (Segment(address or (0x80000 if replay else 0x40000), 60),))


@pytest.mark.parametrize("size", [60,61,62,63,64,1513,1514])
def test_bytes_lanes_and_padding(size):
    wire=frame()+bytes((i*11)&255 for i in range(size-60))
    decoded, bad, ended=observe_beats(beats(wire))
    assert decoded==wire and not bad and ended
    assert classify(wire).supported


def test_first_match_wildcard_and_unsupported():
    wire=frame()
    rules=[Rule(True,2,0xC0000200,0xFFFFFF00,src_port=1234),Rule(True,3)]
    result=classify(wire,rules,1)
    assert result.queue==2 and result.rule==0
    assert result.fields==(0xC0000201,0xC6336402,1234,4321)
    assert classify(wire,[Rule(True,0,src_port=0)],1).queue==1
    unsupported=bytearray(wire); unsupported[12:14]=b"\x86\xdd"
    result=classify(unsupported,rules,1)
    assert not result.supported and result.fields==(0,0,0,0) and result.queue==1


@pytest.mark.parametrize("offset,value,expected",[
    (14,0x44,Drop.MALFORMED),(14,0x65,Drop.MALFORMED),(16,0xFF,Drop.MALFORMED),
    (39,7,Drop.MALFORMED),(39,27,Drop.MALFORMED),(20,0x20,Drop.NONE),
    (21,1,Drop.NONE),(23,6,Drop.NONE),
])
def test_parser_bad_and_unsupported(offset,value,expected):
    wire=bytearray(frame()); wire[offset]=value
    result=classify(wire)
    assert result.drop==expected and not result.supported


def test_error_precedence_and_reservation():
    assert classify(b"",watchdog=True,bad_mask=True).drop==Drop.WATCHDOG
    assert classify(bytes(1515),bad_mask=True).drop==Drop.BAD_MASK
    assert classify(bytes(1515)).drop==Drop.OVERSIZE
    assert classify(bytes(59)).drop==Drop.RUNT
    wire=bytearray(frame()); wire[39]=0
    assert classify(wire,reserved=(False,)*4).drop==Drop.MALFORMED
    assert classify(frame(),reserved=(False,)*4).drop==Drop.FULL
    _,bad,_=observe_beats([(0,5,True)])
    assert bad


def test_ipv4_options_structural_check():
    wire=bytes(Ether()/IP(options=b"\x01\x01\x01\x01")/UDP()/Raw(bytes(18)))
    result=classify(wire)
    assert result.drop==Drop.NONE and not result.supported
    wire=bytearray(wire); wire[16:18]=b"\x00\x10"
    assert classify(wire).drop==Drop.MALFORMED


def test_descriptor_known_layout_and_completion():
    d=descriptor()
    raw=d.encode()
    assert len(raw)==64 and raw[:8].hex()=="efcdab8967452301"
    assert raw[8:32].hex()=="000000000100000000000000000000003c00010000000000"
    assert raw[32:].hex()=="000004003c000000"+"00"*24
    assert Descriptor.decode(raw)==d
    d.validate(replay=False,sequence=0,epoch=1,packet_length=60)
    c=Completion(d.cookie,0,1,0x1020304050607080,60,1,2,15)
    assert c.encode()[16:32].hex()=="80706050403020103c0001020f000000"
    assert Completion.decode(c.encode())==c


@pytest.mark.parametrize("changes",[
    {"segments":()}, {"segments":(Segment(0x40001,60),)},
    {"segments":(Segment(0x3FFF8,60),)}, {"segments":(Segment(0x7FFF8,60),)},
    {"segments":(Segment(0xFFFFFFF8,60),)}, {"segments":(Segment(0x40000,0),)},
    {"segments":(Segment(0x40000,31),Segment(0x41000,29))},
    {"segments":(Segment(0x40000,32),Segment(0x40018,28))},
    {"length":61}, {"sequence":1}, {"epoch":2}, {"timestamp":1},
])
def test_descriptor_rejections(changes):
    with pytest.raises(ValueError):
        replace(descriptor(),**changes).validate(replay=False,sequence=0,epoch=1)


@pytest.mark.parametrize("byte",[27,28,38,40,63])
def test_descriptor_reserved_bytes(byte):
    raw=bytearray(descriptor().encode()); raw[byte]=1
    with pytest.raises(ValueError): Descriptor.decode(raw)


def test_burst_boundary_and_strobes():
    assert list(bursts(0x40FF8,137))==[(0x40FF8,1,255),(0x41000,16,255),(0x41080,1,1)]
    for n in range(1,2049):
        for addr in (0x40000,0x40F80,0x40FF8):
            plan=list(bursts(addr,n))
            assert sum((beats-1)*8+strobe.bit_count() for _,beats,strobe in plan)==n
            assert all(1<=beats<=16 and a//4096==(a+8*beats-1)//4096 for a,beats,_ in plan)


def test_ownership_and_epoch_recovery():
    host=HostMemory(); key=host.publish(False,0,descriptor())
    with pytest.raises(ValueError): host.reclaim(key)
    assert host.claim(False,0)==key
    with pytest.raises(ValueError): host.publish(False,1,descriptor())
    host.completion_visible(key)
    with pytest.raises(ValueError): host.completion_visible(key)
    host.reclaim(key)
    host.bytes[0x40000]=0x12
    with pytest.raises(ValueError): host.recover(2,transport_quiescent=False)
    host.recover(2,transport_quiescent=True)
    assert host.bytes[0x40000]==0x12 and not host.owned


def test_cq_reservation_before_claim_and_counter_wrap():
    host=HostMemory(); ring=host.rings[False,0]
    ring.producer=ring.consumer=0xFFFFFFFF
    key=host.publish(False,0,descriptor(sequence=0xFFFFFFFF))
    assert ring.producer==0
    ring.cq_producer=64
    with pytest.raises(ValueError): host.claim(False,0)
    assert ring.consumer==0xFFFFFFFF
    ring.cq_consumer=1
    assert host.claim(False,0)==key and ring.consumer==0 and ring.reserved==1


def test_policy_vectors_and_endpoints():
    vectors=json.loads((Path(__file__).parent/"fixtures/policy_vectors.json").read_text())
    for v in vectors:
        assert loss_word(v["seed"],v["queue"],v["sequence"])==v["word"]
        assert not lost(v["seed"],v["queue"],v["sequence"],0)
        assert lost(v["seed"],v["queue"],v["sequence"],2**32)
        assert not lost(v["seed"],v["queue"],v["sequence"],v["word"])
        assert lost(v["seed"],v["queue"],v["sequence"],v["word"]+1)


def test_deadline_wrap_no_drift():
    due=due_tick(2**64-10,110,100,5)
    assert due==5 and not eligible(4,due) and eligible(5,due)
    assert lateness(8,due)==3
    with pytest.raises(ValueError): lateness(4,due)
    assert due_tick(10,0,0,7,sequence=3,interval=5)==32
    with pytest.raises(ValueError): due_tick(0,2**63,0,0)
