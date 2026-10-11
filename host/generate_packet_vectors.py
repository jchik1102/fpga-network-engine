import argparse
import json
import random
from pathlib import Path
from scapy.all import Ether, IP, UDP, Raw, Padding, TCP
from models.packet import Rule, classify, beats, observe_beats, Drop

RULES=[Rule(True,0,dst_port=5000),Rule(True,1,0xC0000200,0xFFFFFF00),Rule(True,2,src_port=0)]


def generate(destination, seed=20261009):
    destination.mkdir(parents=True,exist_ok=True)
    rng=random.Random(seed)
    operations=[]; occupancy=[0]*4; tails=[0]*4; heads=[0]*4
    def packet(size=60, queue=0, *, ether=0x0800, pad=0):
        source="192.0.2.5" if queue==1 else "203.0.113.7"
        sport=0 if queue==2 else 1234
        dport=5000 if queue==0 else 6000
        payload=bytes(rng.randrange(256) for _ in range(size-42-pad))
        return bytes(Ether(src="02:00:00:00:00:01",dst="02:00:00:00:00:02",type=ether)/IP(src=source,dst="198.51.100.2")/UDP(sport=sport,dport=dport)/Raw(payload)/Padding(bytes([0xDE])*pad))
    def release(q):
        assert occupancy[q]
        occupancy[q]-=1; heads[q]=(heads[q]+1)%4
        operations.append(dict(action=1,queue=q,occupancy=occupancy.copy()))
    def send(name,wire,keep_override=None,gap_override=None,release_after=True):
        channel=list(beats(wire))
        if keep_override:
            index,keep=keep_override
            word,_,last=channel[index]; channel[index]=(word,keep,last)
        observed,bad,_=observe_beats(channel)
        gaps=[rng.randrange(8) for _ in channel]
        if gap_override: gaps[gap_override[0]]=gap_override[1]
        # watchdog is 256 in this unit test, the long gap trips it on purpose
        timed_out=bool(gap_override and gap_override[1]>=65536)
        expected=classify(observed,RULES,3,bad_mask=bad,watchdog=timed_out,reserved=tuple(n<4 for n in occupancy))
        slot=tails[expected.queue]
        if expected.drop==Drop.NONE:
            occupancy[expected.queue]+=1; tails[expected.queue]=(slot+1)%4
        operations.append(dict(action=0,name=name,words=channel,gaps=gaps,expected=expected.__dict__,
                               slot=slot,length=len(observed),occupancy=occupancy.copy(),hex=observed.hex()))
        if release_after and expected.drop==Drop.NONE: release(expected.queue)
    for q in range(4):
        for size in (60,61,62,63,64,127,128,129,1513,1514):
            send(f"queue{q}_length{size}",packet(size,q,pad=6))
    for eth in (0x8100,0x86DD,0x0806): send(f"unsupported_{eth:x}",packet(64,0,ether=eth))
    for offset,value in ((14,0x44),(14,0x65),(16,0xff),(39,7),(39,27),(20,0x20),(21,1),(23,6)):
        wire=bytearray(packet(64,1)); wire[offset]=value; send(f"field_{offset}_{value}",wire)
    for size in (1,14,42,59): send(f"runt_{size}",packet()[:size])
    for size in (1515,2048,2080): send(f"oversize_{size}",packet()+bytes(size-60))
    for keep in (0,2,4,5,6,8,9,10,11,12,13,14): send(f"bad_keep_{keep}",packet(),keep_override=(-1,keep))
    send("short_intermediate_keep",packet(),keep_override=(3,7))
    send("watchdog_then_drain",packet(),gap_override=(3,65540))
    for i in range(4): send(f"fill_q0_{i}",packet(queue=0),release_after=False)
    send("full_drop",packet(queue=0),release_after=False)
    send("malformed_beats_full",bytes(59),release_after=False)
    operations.append(dict(action=2,mode=0,ready=0,occupancy=occupancy.copy()))
    release(0)
    operations.append(dict(action=2,mode=0,ready=1,occupancy=occupancy.copy()))
    send("lossless_reclaimed_slot",packet(queue=0),release_after=False)
    operations.append(dict(action=2,mode=1,ready=1,occupancy=occupancy.copy()))
    for _ in range(4): release(0)
    for i in range(32): send(f"seeded_{i}",packet(rng.randrange(60,1515),rng.randrange(4),pad=rng.randrange(7)))
    rows=[str(len(operations))]
    for op in operations:
        rows.append(str(op["action"]))
        if op["action"]==0:
            e=op["expected"]
            rows.append(f'{len(op["words"])} {op["length"]} {int(e["drop"])} {int(e["supported"])} {e["queue"]} {e["rule"]} {op["slot"]}')
            rows += [f"{word:08x} {keep:x} {int(last)} {gap}" for (word,keep,last),gap in zip(op["words"],op["gaps"])]
        elif op["action"]==1: rows.append(str(op["queue"]))
        else: rows.append(f'{op["mode"]} {op["ready"]}')
        rows.append(" ".join(map(str,op["occupancy"])))
    (destination/"packets.txt").write_text("\n".join(rows)+"\n")
    (destination/"packets.json").write_text(json.dumps({"seed":seed,"rules":[r.__dict__ for r in RULES],"operations":operations},indent=2))
    print(f"Generated {len(operations)} independent operations, seed={seed}")


if __name__=="__main__":
    parser=argparse.ArgumentParser();parser.add_argument("--output",type=Path,default=Path("build/packet"));parser.add_argument("--seed",type=int,default=20261009)
    args=parser.parse_args();generate(args.output,args.seed)
