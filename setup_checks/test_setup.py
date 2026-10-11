import hashlib
import json
import subprocess
import sys
from decimal import Decimal
from pathlib import Path

import numpy as np
import pytest
from scapy.all import Ether, IP, UDP, Raw, Padding, PcapWriter, rdpcap

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/setup/python"
OUT.mkdir(parents=True, exist_ok=True)
PS = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
TSHARK = "/mnt/c/Program Files/Wireshark/tshark.exe"

def windows(path):
    return subprocess.check_output(["wslpath", "-w", str(path)], text=True).strip()

def test_imports_plot():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    assert np.arange(8).sum() == 28
    plt.plot([0, 1], [0, 1]); plt.savefig(OUT / "plot.png"); plt.close()
    assert (OUT / "plot.png").stat().st_size > 100

def test_windows_roundtrip():
    source = OUT / "path with spaces" / "fixture bytes.bin"
    source.parent.mkdir(exist_ok=True)
    dest = source.with_name("returned bytes.bin")
    data = bytes(range(256)) * 17 + b"\x00\xff\r\n"
    source.write_bytes(data)
    result = subprocess.run([PS,"-NoProfile","-ExecutionPolicy","Bypass","-File",
        windows(ROOT / "setup_checks/roundtrip.ps1"), "-Source", windows(source),
        "-Destination", windows(dest)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    digest = hashlib.sha256(data).hexdigest()
    assert result.stdout.strip() == digest
    assert dest.read_bytes() == data
    (OUT / "roundtrip.json").write_text(json.dumps({"sha256":digest,"bytes":len(data)}, indent=2))
    failed = subprocess.run([PS,"-NoProfile","-Command","exit 23"], capture_output=True, timeout=20)
    assert failed.returncode == 23
    with pytest.raises(subprocess.TimeoutExpired):
        subprocess.run([PS,"-NoProfile","-Command","Start-Sleep -Seconds 10"], capture_output=True, timeout=1)

def make_pcap():
    packets=[]; records=[]
    for index,size in enumerate([60,61,64,127,512,1514]):
        payload=bytes(((j * 37 + index * 19) & 255) for j in range(size-42-6))
        packet=Ether(src="02:00:00:00:00:01",dst="02:00:00:00:00:02")/IP(src="192.0.2.1",dst="198.51.100.2",id=0x1200+index)/UDP(sport=4000+index,dport=5000+index)/Raw(payload)/Padding(bytes([0xa0+index])*6)
        wire=bytes(packet); assert len(wire)==size
        packet=Ether(wire)
        tick=101+index*37
        stamp=Decimal(1700000000)+Decimal(tick*20)/Decimal(10**9)
        packet.time=stamp; packets.append(packet)
        records.append({"id":0x1200+index,"length":size,"tick":tick,"time":str(stamp),"hex":wire.hex(),"sport":4000+index,"dport":5000+index})
    path=OUT / "fixture.pcap"
    with PcapWriter(str(path), nano=True, sync=True) as writer:
        for packet in packets: writer.write(packet)
    (OUT / "manifest.json").write_text(json.dumps({"tick_ns":20,"packets":records},indent=2))
    return path,records

def test_pcap_exact_and_malformed():
    path,records=make_pcap(); actual=rdpcap(str(path))
    assert len(actual)==len(records)
    for p,r in zip(actual,records):
        assert bytes(p).hex()==r["hex"]
        assert Decimal(p.time)==Decimal(r["time"])
        assert bytes(p)[-6:]==bytes([0xa0+r["id"]-0x1200])*6
    malformed=bytearray(bytes(actual[0]))
    malformed[16:18]=b"\x00\x01"
    malformed[38:40]=b"\x00\x02"
    with PcapWriter(str(OUT / "malformed.pcap"),linktype=1,nano=True) as writer:
        writer.write(bytes(malformed))
    raw=rdpcap(str(OUT / "malformed.pcap"))[0]
    assert bytes(raw)==malformed
    assert bytes(raw)[16:18]==b"\x00\x01" and bytes(raw)[38:40]==b"\x00\x02"

def test_tshark_fields():
    path,records=make_pcap()
    args=[TSHARK,"-n","-r",windows(path),"-T","fields"]
    for field in ["frame.len","ip.id","udp.srcport","udp.dstport","frame.time_epoch"]: args += ["-e",field]
    result=subprocess.run(args,capture_output=True,text=True,check=True,timeout=30)
    (OUT / "tshark.tsv").write_text(result.stdout)
    rows=[line.split("\t") for line in result.stdout.strip().splitlines()]
    assert len(rows)==len(records)
    for row,r in zip(rows,records):
        assert [int(row[0]),int(row[1],0),int(row[2]),int(row[3])]==[r["length"],r["id"],r["sport"],r["dport"]]
        assert Decimal(row[4])==Decimal(r["time"])
