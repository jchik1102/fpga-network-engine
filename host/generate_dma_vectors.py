import json
from pathlib import Path
from models.abi import Descriptor, Segment


def generate(destination=Path("build/sg")):
    destination.mkdir(parents=True,exist_ok=True)
    cases=[]
    def add(raw,replay,packet_length,error=0):
        try:
            desc=Descriptor.decode(raw)
            desc.validate(replay=replay,sequence=7,epoch=3,packet_length=None if replay else packet_length)
            valid=True
        except ValueError: valid=False
        cases.append(dict(raw=raw.hex(),replay=int(replay),length=packet_length,valid=int(valid),error=error))
    for replay in (False,True):
        for n in range(1,5):
            for size in (60,61,127,128,129,1514):
                each=((size//n)//8)*8
                sizes=[each]*(n-1)+[size-each*(n-1)]
                base=0x80000 if replay else 0x40000
                desc=Descriptor(0xFEDCBA9876543210,7,3,99 if replay else 0,size,
                    tuple(Segment(base+i*0x4000+0xFF8,length) for i,length in enumerate(sizes)))
                add(desc.encode(),replay,size)
                if n==4 and size==1514:
                    add(desc.encode(),replay,size,2);add(desc.encode(),replay,size,3)
                if not replay and size==1514: add(desc.encode(),False,61)
        desc=Descriptor(1,7,3,0,60,(Segment(0x80000 if replay else 0x40000,60),))
        for offset,value in ((8,8),(12,4),(26,0),(26,5),(27,1),(28,1),(32,1),(38,1),(40,1),(36,0)):
            raw=bytearray(desc.encode());raw[offset]=value;add(bytes(raw),replay,60)
    rows=[str(len(cases))]
    for case in cases:
        rows.append(f'{case["replay"]} {case["length"]} {case["valid"]} {case["error"]}')
        rows.append(" ".join(f"{b:02x}" for b in bytes.fromhex(case["raw"])))
    (destination/"dma.txt").write_text("\n".join(rows)+"\n")
    (destination/"dma.json").write_text(json.dumps(cases,indent=2))
    print(f"Generated {len(cases)} DMA descriptor/payload cases")


if __name__=="__main__":generate()
