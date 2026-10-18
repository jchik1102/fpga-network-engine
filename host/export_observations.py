import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path

from scapy.all import Ether, PcapWriter

TICK_NS = 20


def parse(log_path):
    data = dict(inputs={}, outputs=[], records=[], phases={})
    phase = "setup"
    for line in Path(log_path).read_text().splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "IN":
            data["inputs"][int(f[1])] = (int(f[2]), int(f[3]))
        elif f[0] == "OUT":
            q, rnd, seq, frame, first, last, due = map(int, f[1:8])
            data["outputs"].append(dict(queue=q, round=rnd, sequence=seq, frame=frame, first=first, last=last, due=due,
                                        lateness=first - due, phase=phase))
        elif f[0] == "CQ":
            ring, seq, status, queue, length, tick = map(int, f[1:7])
            data["records"].append(dict(ring=ring, sequence=seq, status=status, queue=queue, length=length, tick=tick,
                                        cookie=int(f[7], 16), phase=phase))
        elif f[0] == "PHASE":
            data["phases"][f[1]] = int(f[2])
            phase = f[1]
    return data


def write_pcap(path, frames):
    with PcapWriter(str(path), nano=True, sync=True) as writer:
        for tick, raw in frames:
            packet = Ether(raw)
            packet.time = tick * TICK_NS / 1e9
            writer.write(packet)


def metrics(name, data, manifest):
    frames = manifest["frames"]
    phases = data["phases"]
    order = ["capture", "replay0", "replay1", "drop_on_full", "abort", "fault_recovery", "throughput_capture",
             "throughput_replay", "default_queue", "end"]
    durations = {order[i]: phases[order[i + 1]] - phases[order[i]] for i in range(len(order) - 1)
                 if order[i] in phases and order[i + 1] in phases}
    capture_in = [i for i, f in enumerate(frames) if f["phase"] == 0 and i in data["inputs"]]
    first = min(data["inputs"][i][0] for i in capture_in)
    last = max(data["inputs"][i][1] for i in capture_in)
    offered = sum(frames[i]["length"] for i in capture_in)
    captured = sum(r["length"] for r in data["records"] if r["ring"] < 4 and r["status"] in (0, 1) and r["phase"] == "capture")
    by_round = defaultdict(list)
    for o in data["outputs"]:
        by_round[o["round"]].append(o)
    rounds = {}
    for rnd, outs in sorted(by_round.items()):
        late = sorted(o["lateness"] for o in outs)
        span = max(o["last"] for o in outs) - min(o["first"] for o in outs) + 1
        replay_bytes = sum(frames[o["frame"]]["length"] for o in outs)
        rounds[rnd] = dict(outputs=len(outs), bytes=replay_bytes, span_ticks=span,
                           mbytes_per_s=round(replay_bytes / (span * TICK_NS) * 1e3, 2),
                           lateness_min=late[0], lateness_median=late[len(late) // 2], lateness_max=late[-1],
                           lateness_p95=late[min(len(late) - 1, int(0.95 * len(late)))])
    drops = Counter(f["drop"] for f in frames if f["phase"] == 0 and f["drop"])
    tput_in = [data["inputs"][i] for i, f in enumerate(frames) if f["phase"] == 6 and i in data["inputs"]]
    tput_out = [o for o in data["outputs"] if o["round"] == 3]
    throughput = {}
    if tput_in:
        span = max(t[1] for t in tput_in) - min(t[0] for t in tput_in) + 1
        throughput["capture"] = dict(frames=len(tput_in), bytes=1514 * len(tput_in), span_ticks=span,
                                     mbytes_per_s=round(1514 * len(tput_in) / (span * TICK_NS) * 1e3, 2),
                                     bytes_per_tick=round(1514 * len(tput_in) / span, 3))
    if tput_out:
        span = max(o["last"] for o in tput_out) - min(o["first"] for o in tput_out) + 1
        throughput["replay"] = dict(frames=len(tput_out), bytes=1514 * len(tput_out), span_ticks=span,
                                    mbytes_per_s=round(1514 * len(tput_out) / (span * TICK_NS) * 1e3, 2),
                                    bytes_per_tick=round(1514 * len(tput_out) / span, 3),
                                    lateness_max=max(o["lateness"] for o in tput_out))
    return dict(platform=name, phase_ticks=durations, throughput=throughput,
                capture=dict(frames=len(capture_in), offered_bytes=offered, captured_record_bytes=captured,
                             input_span_ticks=last - first + 1,
                             input_mbytes_per_s=round(offered / ((last - first + 1) * TICK_NS) * 1e3, 2),
                             fixture_drop_causes={str(k): v for k, v in sorted(drops.items())}),
                replay_rounds={k: v for k, v in rounds.items()},
                record_status=dict(Counter(r["status"] for r in data["records"])))


def axi_bus_metrics(run_dir):
    path = Path(run_dir) / "axi_handshakes.txt"
    if not path.exists():
        return None
    aw = ar = w = r = strobed = 0
    for line in path.read_text().splitlines():
        f = line.split()
        if f[0] == "AW":
            aw += 1
        elif f[0] == "AR":
            ar += 1
        elif f[0] == "W":
            w += 1
            strobed += bin(int(f[3], 16)).count("1")
        elif f[0] == "R":
            r += 1
    return dict(write_bursts=aw, write_beats=w, read_bursts=ar, read_beats=r,
                mean_write_burst_beats=round(w / aw, 2) if aw else 0, mean_read_burst_beats=round(r / ar, 2) if ar else 0,
                write_strobed_bytes=strobed, write_byte_efficiency=round(strobed / (8 * w), 4) if w else 0)


def pcie_link_metrics(run_dir):
    log = Path(run_dir) / "seed17.log"
    candidates = sorted(p for p in Path(run_dir).glob("seed*.log") if ".console" not in p.name)
    if candidates:
        log = candidates[0]
    text = log.read_text(errors="replace")
    line = next((l for l in text.splitlines() if "ENGINE_PCIE_PASS" in l), "")
    values = {k: int(v) for k, v in (item.split("=") for item in line.split() if "=" in item and item.split("=")[1].isdigit())}
    keys = ("mwr", "mrd", "msi", "device_cpl", "bar_requests", "bar_cpl", "header_dw", "payload_dw", "splits", "reordered",
            "max_outstanding_tags", "visibility_max", "visibility_mean", "device_max_tags")
    result = {k: values[k] for k in keys if k in values}
    if "header_dw" in result and "payload_dw" in result:
        total = result["header_dw"] + result["payload_dw"]
        result["device_to_host_header_overhead"] = round(result["header_dw"] / total, 4) if total else 0
    return result


def export(name, run_dir, manifest):
    log = Path(run_dir) / f"observed_{name}.txt"
    data = parse(log)
    frames = manifest["frames"]
    out = Path(run_dir) / "export"
    out.mkdir(exist_ok=True)
    capture = sorted((data["inputs"][i][0], bytes.fromhex(frames[i]["hex"])) for i in data["inputs"]
                     if frames[i]["drop"] == 0)
    replay = sorted((o["first"], bytes.fromhex(frames[o["frame"]]["hex"])) for o in data["outputs"])
    write_pcap(out / "capture.pcap", capture)
    write_pcap(out / "replay.pcap", replay)
    (out / "ticks.json").write_text(json.dumps(dict(
        tick_ns=TICK_NS,
        capture=[dict(frame=i, first_tick=t[0], last_tick=t[1]) for i, t in sorted(data["inputs"].items())],
        replay=data["outputs"], records=data["records"], phases=data["phases"]), indent=1))
    m = metrics(name, data, manifest)
    m["transport"] = axi_bus_metrics(run_dir) if name == "AXI" else pcie_link_metrics(run_dir)
    (out / "metrics.json").write_text(json.dumps(m, indent=1))
    return data, m


def compare(axi, pcie):
    problems = []
    deterministic = {"capture", "replay0", "replay1", "drop_on_full", "fault_recovery", "throughput_capture", "throughput_replay",
                     "default_queue"}
    def replay_key(data):
        return {(o["round"], o["queue"], o["sequence"]): o["frame"] for o in data["outputs"] if o["round"] != 2}
    a, p = replay_key(axi), replay_key(pcie)
    if a != p:
        problems.append(f"replay output identity differs: {sorted(set(a.items()) ^ set(p.items()))[:6]}")
    for q in range(4):
        aq = [o["frame"] for o in axi["outputs"] if o["queue"] == q and o["round"] != 2]
        pq = [o["frame"] for o in pcie["outputs"] if o["queue"] == q and o["round"] != 2]
        if aq != pq:
            problems.append(f"queue {q} replay order differs")
    transport_specific = {(r["phase"], r["ring"], r["sequence"]) for r in axi["records"] if r["status"] == 5}
    def record_key(data, rings):
        return Counter((r["phase"], r["ring"], r["sequence"], r["status"], r["queue"], r["length"], r["cookie"]) for r in data["records"]
                       if r["ring"] in rings and r["phase"] in deterministic
                       and (r["phase"], r["ring"], r["sequence"]) not in transport_specific)
    for label, rings in (("capture", range(4)), ("replay", range(4, 8))):
        ka, kp = record_key(axi, rings), record_key(pcie, rings)
        diff = (ka - kp) + (kp - ka)
        if diff:
            problems.append(f"{label} records differ: {list(diff.items())[:6]}")
    lost_a = sorted((r["ring"], r["sequence"]) for r in axi["records"] if r["status"] == 2 and r["phase"] in deterministic)
    lost_p = sorted((r["ring"], r["sequence"]) for r in pcie["records"] if r["status"] == 2 and r["phase"] in deterministic)
    if lost_a != lost_p:
        problems.append("seeded loss decisions differ")
    return problems, len(lost_a)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", type=Path, default=Path("build/engine/engine.json"))
    parser.add_argument("--axi", type=Path, default=Path("build/engine_axi"))
    parser.add_argument("--pcie", type=Path, nargs="*", default=[Path("build/engine_pcie")])
    parser.add_argument("--output", type=Path, default=Path("build/comparison.json"))
    args = parser.parse_args()
    manifest = json.loads(args.fixture.read_text())
    axi, axi_metrics = export("AXI", args.axi, manifest)
    report = dict(axi=axi_metrics, pcie=[], comparisons=[])
    failed = False
    for run in args.pcie:
        pcie, pcie_metrics = export("PCIe", run, manifest)
        problems, lost = compare(axi, pcie)
        pcie_metrics["run"] = str(run)
        report["pcie"].append(pcie_metrics)
        report["comparisons"].append(dict(run=str(run), problems=problems, seeded_losses=lost, excluded="abort phase, AXI WRITE_ERROR row, PCIe MSI phase",
                                          replay_outputs=len(pcie["outputs"])))
        failed |= bool(problems)
        print(f"{run}: {'MATCH' if not problems else 'MISMATCH'} outputs={len(pcie['outputs'])} losses={lost} {problems}")
    args.output.write_text(json.dumps(report, indent=1))
    print(json.dumps(report["axi"]["capture"]), json.dumps(report["axi"]["replay_rounds"]))
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
