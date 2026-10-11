import argparse
import json
import random
from pathlib import Path

from scapy.all import IP, TCP, UDP, Ether, IPv6, Padding, Raw, ARP, Dot1Q

from models.abi import Descriptor, Segment
from models.packet import Drop, Rule, beats, classify, observe_beats
from models.policy import lost

CAPTURE_POOL = (0x40000, 0x80000)
REPLAY_POOL = (0x80000, 0xC0000)
DEFAULT_QUEUE = 3
RULES = [
    Rule(True, 0, dst_ip=0xC6336400, dst_mask=0xFFFFFF00, dst_port=5000),
    Rule(True, 1, src_ip=0xC0000200, src_mask=0xFFFFFF00),
    Rule(True, 2, src_port=0),
    Rule(False, 0),
    Rule(True, 2, src_ip=0x0A000001, src_mask=0xFFFFFFFF, src_port=7, dst_port=9),
    Rule(True, 1, dst_ip=0xCB007100, dst_mask=0xFFFFFF00),
    Rule(True, 0, dst_port=6100),
    Rule(True, 3, dst_port=6200),
]
LOSS_SEED = 0x13572468
LOSS_THRESHOLD = 1 << 30
DELAYS = (0, 150, 2000, 75)
INTERVAL = 4000
ROUND1_PER_QUEUE = 3
ROUND2_PER_QUEUE = 3
THROUGHPUT_FRAMES = 16


def rule_registers(rule):
    control = int(rule.enabled) | rule.queue << 1 | (rule.src_port is not None) << 3 | (rule.dst_port is not None) << 4
    ports = (rule.src_port or 0) | (rule.dst_port or 0) << 16
    return control, rule.src_ip, rule.src_mask, rule.dst_ip, rule.dst_mask, ports


class Allocator:

    def __init__(self, rng, low, high):
        self.rng, self.cursor, self.high = rng, low + 64, high

    def place(self, length, cross_4k=False):
        gap = 8 * self.rng.randrange(2, 9)
        start = self.cursor + gap
        if cross_4k:
            crossing = ((start + 4095) // 4096) * 4096 - 8 * self.rng.randrange(1, 5)
            if start <= crossing <= start + 512:
                start = crossing
        start = (start + 7) // 8 * 8
        self.cursor = start + length
        if self.cursor + 64 > self.high:
            raise RuntimeError("pool exhausted")
        return start

    def layout(self, total, count=None):
        count = count or self.rng.randrange(1, 5)
        count = max(1, min(count, total // 8))
        sizes = []
        remaining = total
        for i in range(count - 1):
            limit = (remaining - 8 * (count - 1 - i)) // 8
            sizes.append(8 * self.rng.randrange(1, max(2, limit)))
            remaining -= sizes[-1]
        sizes.append(remaining)
        if remaining <= 0:
            return self.layout(total, 1)
        order = list(range(count))
        self.rng.shuffle(order)
        addresses = [0] * count
        for position, index in enumerate(order):
            addresses[index] = self.place(sizes[index], cross_4k=self.rng.random() < 0.3)
        return tuple(Segment(a, s) for a, s in zip(addresses, sizes))


def build_frames(rng):
    frames = []

    def udp(size, src, dst, sport, dport, pad=0):
        body = size - 42 - pad
        payload = bytes(rng.randrange(256) for _ in range(body))
        return bytes(Ether(src="02:00:00:00:00:01", dst="02:00:00:00:00:02") / IP(src=src, dst=dst) /
                     UDP(sport=sport, dport=dport) / Raw(payload) / Padding(bytes([0x5A]) * pad))

    def add(phase, name, wire, keep_override=None, long_gap=None, gaps_zero=False):
        channel = list(beats(wire))
        if keep_override:
            index, keep = keep_override
            word, _, last = channel[index]
            channel[index] = (word, keep, last)
        observed, bad, _ = observe_beats(channel)
        gaps = [0 if gaps_zero else rng.randrange(4) for _ in channel]
        if long_gap:
            gaps[long_gap] = 65540
        expected = classify(observed, RULES, DEFAULT_QUEUE, bad_mask=bad, watchdog=bool(long_gap))
        frames.append(dict(phase=phase, name=name, words=channel, gaps=gaps, bytes=observed,
                           drop=int(expected.drop), supported=int(expected.supported),
                           queue=expected.queue, rule=expected.rule))

    sizes = (60, 61, 127, 128, 129, 600, 1513, 1514)
    templates = [
        lambda n, p: udp(n, "203.0.113.9", "198.51.100.7", 1111, 5000, p),
        lambda n, p: udp(n, "192.0.2.77", "198.51.101.1", 2222, 5000, p),
        lambda n, p: udp(n, "203.0.113.4", "198.51.101.1", 0, 4444, p),
        lambda n, p: udp(n, "203.0.113.4", "198.51.101.1", 3333, 6200, p),
    ]
    for i, size in enumerate(sizes):
        for q in range(4):
            add(0, f"q{q}_len{size}", templates[q](size, 6 if i % 3 == 0 else 0))
    add(0, "rule4", udp(90, "10.0.0.1", "8.8.8.8", 7, 9))
    add(0, "rule5", udp(91, "203.0.113.4", "203.0.113.200", 1, 2))
    add(0, "rule6", udp(92, "203.0.113.4", "8.8.4.4", 1, 6100))
    add(0, "rule4_port_miss_default", udp(93, "10.0.0.1", "8.8.8.8", 7, 10))
    base = Ether(src="02:00:00:00:00:01", dst="02:00:00:00:00:02")
    add(0, "vlan", bytes(base / Dot1Q(vlan=5) / IP(src="1.2.3.4", dst="5.6.7.8") / UDP() / Raw(bytes(40))))
    add(0, "ipv6", bytes(base / IPv6() / UDP() / Raw(bytes(30))))
    add(0, "arp", bytes(base / ARP()) + bytes(18))
    add(0, "tcp", bytes(base / IP(src="1.2.3.4", dst="5.6.7.8") / TCP() / Raw(bytes(30))))
    add(0, "ip_options", bytes(base / IP(src="1.2.3.4", dst="5.6.7.8", options=b"\x01\x01\x01\x00") / UDP() / Raw(bytes(30))))
    add(0, "fragment", bytes(base / IP(src="1.2.3.4", dst="5.6.7.8", flags="MF") / UDP() / Raw(bytes(30))))
    add(0, "runt59", udp(60, "1.1.1.1", "2.2.2.2", 1, 2)[:59])
    add(0, "oversize1515", udp(1514, "1.1.1.1", "2.2.2.2", 1, 2) + b"\x00")
    bad_ip = bytearray(udp(80, "1.1.1.1", "2.2.2.2", 1, 2)); bad_ip[17] = 0xFF
    add(0, "malformed_ip_length", bytes(bad_ip))
    add(0, "bad_final_keep", udp(64, "1.1.1.1", "2.2.2.2", 1, 2), keep_override=(-1, 5))
    add(0, "watchdog", udp(64, "1.1.1.1", "2.2.2.2", 1, 2), long_gap=4)
    for i in range(12):
        q = i % 4
        add(1, f"concurrent{i}", templates[q](rng.randrange(60, 1515), rng.randrange(4)))
    for i in range(6):
        add(2, f"full{i}", templates[0](rng.randrange(60, 300), 0))
    for i in range(8):
        add(3, f"abort{i}", templates[i % 4](rng.randrange(400, 1515), 0))
    for q in range(4):
        add(4, f"recovery{q}", templates[q](rng.randrange(60, 700), 0))
    for i in range(3):
        add(5, f"notify{i}", templates[0](rng.randrange(60, 200), 0))
    for i in range(THROUGHPUT_FRAMES):
        add(6, f"throughput{i}", templates[i % 4](1514, 0), gaps_zero=True)
    return frames


def generate(destination, seed):
    rng = random.Random(seed)
    destination.mkdir(parents=True, exist_ok=True)
    frames = build_frames(rng)
    stored = 0
    for f in frames:
        if f["phase"] == 2 and f["drop"] == 0:
            if stored >= 4:
                f["drop"], f["supported"], f["queue"], f["rule"] = int(Drop.FULL), 0, 0, 15
            else:
                stored += 1
    capture_alloc = Allocator(rng, *CAPTURE_POOL)
    replay_alloc = Allocator(rng, *REPLAY_POOL)
    capture = []
    cookies = iter(range(0x1000, 0x100000))
    for phase in (0, 1, 2, 3, 4, 5, 6):
        for q in range(4):
            queued = [i for i, f in enumerate(frames) if f["phase"] == phase and f["drop"] == 0 and f["queue"] == q]
            for n, index in enumerate(queued):
                length = len(frames[index]["bytes"])
                kind = 0
                if phase == 0 and n == 2 and q == 1:
                    kind = 1
                if phase == 0 and n == 3 and q == 2:
                    kind = 2
                if kind:
                    cap = max(60, length - 8) if kind == 2 and length > 68 else max(60, length)
                    if kind == 2 and cap >= length:
                        kind = 1
                    capture.append(dict(phase=phase, queue=q, frame=index, kind=kind, cookie=next(cookies),
                                        segments=capture_alloc.layout(cap)))
                kind = 3 if (phase == 0 and q == 0 and n == 5) else 0
                cap = min(2048, max(60, length + rng.choice((0, 0, 3, 64, 400))))
                capture.append(dict(phase=phase, queue=q, frame=index, kind=kind, cookie=next(cookies),
                                    segments=capture_alloc.layout(cap)))
    write_error_frames = {row["frame"] for row in capture if row["kind"] == 3}
    replay = []
    sequence = [0] * 4
    for round_id in (0, 1, 2, 3):
        for q in range(4):
            members = [row["frame"] for row in capture
                       if row["phase"] == 0 and row["queue"] == q and row["kind"] == 0 and row["frame"] not in write_error_frames]
            if round_id == 1:
                members = members[:ROUND1_PER_QUEUE]
            if round_id == 2:
                members = members[-ROUND2_PER_QUEUE:]
            if round_id == 3:
                members = [row["frame"] for row in capture if row["phase"] == 6 and row["queue"] == q]
                sequence[q] = 0 if not any(r["round"] == 3 and r["queue"] == q for r in replay) else sequence[q]
            for index in members:
                seq = sequence[q]
                sequence[q] += 1
                replay.append(dict(round=round_id, queue=q, frame=index, sequence=seq,
                                   lost=int(round_id != 3 and lost(LOSS_SEED, q, seq, LOSS_THRESHOLD)), read_error=0,
                                   cookie=next(cookies),
                                   segments=replay_alloc.layout(len(frames[index]["bytes"]), count=1 + seq % 4)))
    for row in replay:
        if row["round"] == 0 and row["queue"] == 2 and not row["lost"] and row["segments"][0].length >= 8:
            row["read_error"] = 1
            break
    for row in capture:
        d = Descriptor(row["cookie"], 0, 0, 0, sum(s.length for s in row["segments"]), row["segments"])
        d.validate(replay=False, sequence=0, epoch=0)
    for row in replay:
        d = Descriptor(row["cookie"], 0, 0, 1, sum(s.length for s in row["segments"]), row["segments"])
        d.validate(replay=True, sequence=0, epoch=0)
    lines = ["RULES"]
    lines += [" ".join(f"{v:x}" for v in rule_registers(r)) for r in RULES]
    lines.append(f"DEFAULT {DEFAULT_QUEUE}")
    lines.append(f"LOSS {LOSS_SEED:x} {LOSS_THRESHOLD >> 32:x} {LOSS_THRESHOLD & 0xFFFFFFFF:x}")
    lines.append("DELAYS " + " ".join(str(d) for d in DELAYS))
    lines.append(f"INTERVAL {INTERVAL}")
    lines.append(f"FRAMES {len(frames)}")
    for i, f in enumerate(frames):
        lines.append(f'{i} {f["phase"]} {len(f["words"])} {len(f["bytes"])} {f["drop"]} {f["supported"]} {f["queue"]} {f["rule"]}')
        lines += [f"{w:08x} {k:x} {int(l)} {g}" for (w, k, l), g in zip(f["words"], f["gaps"])]
    def segment_text(segments):
        cells = [f"{s.address:x} {s.length}" for s in segments] + ["0 0"] * (4 - len(segments))
        return f"{len(segments)} " + " ".join(cells)
    lines.append(f"CAPTURE {len(capture)}")
    lines += [f'{r["phase"]} {r["queue"]} {r["frame"]} {r["kind"]} {r["cookie"]:x} {segment_text(r["segments"])}' for r in capture]
    lines.append(f"REPLAY {len(replay)}")
    lines += [f'{r["round"]} {r["queue"]} {r["frame"]} {r["sequence"]} {r["lost"]} {r["read_error"]} {r["cookie"]:x} {segment_text(r["segments"])}'
              for r in replay]
    (destination / "engine.txt").write_text("\n".join(lines) + "\n")
    manifest = dict(seed=seed, loss_seed=LOSS_SEED, loss_threshold=LOSS_THRESHOLD, delays=DELAYS, interval=INTERVAL,
                    frames=[dict(name=f["name"], phase=f["phase"], length=len(f["bytes"]), drop=f["drop"],
                                 supported=f["supported"], queue=f["queue"], rule=f["rule"], hex=f["bytes"].hex()) for f in frames],
                    capture=[dict(r, segments=[(s.address, s.length) for s in r["segments"]]) for r in capture],
                    replay=[dict(r, segments=[(s.address, s.length) for s in r["segments"]]) for r in replay])
    (destination / "engine.json").write_text(json.dumps(manifest, indent=1))
    lost_count = sum(r["lost"] for r in replay)
    print(f"Generated {len(frames)} frames, {len(capture)} capture and {len(replay)} replay descriptors "
          f"({lost_count} seeded losses), seed={seed}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("build/engine"))
    parser.add_argument("--seed", type=int, default=20261010)
    args = parser.parse_args()
    generate(args.output, args.seed)
