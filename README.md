# FPGA network capture/replay engine

A SystemVerilog packet capture, replay and impairment engine with scatter-gather DMA. One engine core (`rtl/engine_core.sv`) runs on two memory transports:

- **AXI** (`engine_axi`): AXI4 64-bit burst master, AXI-Lite control, level interrupt
- **Simulated PCIe** (`engine_pcie`): encoded MRd/MWr/Cpl/CplD TLPs on a 32-bit DWORD stream, DMA requester (one or four tags), 16 KiB BAR0 completer, MSI, read-flush visibility fences, completion timeout and tag quarantine. This is the transaction layer only. There is no PHY, DLL, link training, flow-control credits or enumeration

The engine has:

- an Ethernet II/IPv4/UDP parser with eight first-match rules (masked IPs, wildcardable ports)
- four capture queues of 4×2048-byte slots
- capture and replay DMA workers over four capture and four replay submission rings (32 × 64-byte descriptors), each paired with a completion ring (64 × 32-byte records)
- 1–4 segment scatter-gather
- original-time or fixed-interval replay with per-queue delay and seeded, packet-specific loss
- stop, abort and epoch recovery, plus sticky faults

Everything runs on one 50 MHz clock (1 tick = 20 ns).

## Layout

| Path | Content |
| --- | --- |
| `rtl/` | synthesizable design; `engine_axi` (in `engine_core.sv`) and `engine_pcie` are the transport tops |
| `tb/` | UVM agents (stream, AXI memory, AXI-Lite + RAL, PCIe root complex), module benches, host software, integrated tests |
| `models/`, `host/` | independent Python models, fixture generators, PCAP/tick export and the AXI-vs-PCIe comparison |
| `tests/` | Python model tests and the published replay-loss vectors |
| `constraints/` | Quartus project script, SDC, registered fit wrappers, timing report scripts |
| `scripts/` | launchers; `run-all.ps1` runs the full regression |
| `setup_checks/` | tool qualification benches used by `run-bounded.ps1` |

## Interface summary

Host memory is a 1 MiB aperture with these regions:

| Range | Use |
| --- | --- |
| `0x00000–0x3ffff` | control: rings and the 8-byte fence scratch word at `0x1f000` |
| `0x40000–0x7ffff` | capture payload pool |
| `0x80000–0xbffff` | replay payload pool |

On PCIe, host address = aperture base + offset, and it can be above 4 GiB.

**Descriptor (64 B):**

| Offset | Field |
| --- | --- |
| 0 | cookie |
| 8 | sequence |
| 12 | epoch |
| 16 | captured tick (replay) |
| 24 | capacity or length |
| 26 | segment count, 1–4 |
| 32 + 8i | segment i: address (4 B), length (2 B) |

**Completion record (32 B):**

| Offset | Field |
| --- | --- |
| 0 | cookie |
| 8 | sequence |
| 12 | epoch |
| 16 | tick |
| 24 | length |
| 26 | status: 0 OK, 1 UNSUPPORTED, 2 LOST, 3 BAD_DESC, 4 READ_ERROR, 5 WRITE_ERROR |
| 27 | queue |
| 28 | aux: matched rule, parsed-UDP flag |

All fields are little-endian. Ring counters are absolute 32-bit values.

**Registers** (AXI-Lite or BAR0, 16 KiB):

| Offset | Register |
| --- | --- |
| `0x0000` | ID `NET1` |
| `0x0008` | command: 1 RUN, 2 STOP, 4 ABORT |
| `0x000c` | status |
| `0x0010` | epoch |
| `0x0020`–`0x0028` | IRQ mask, conditions, W1C |
| `0x0030`–`0x003c` | sticky fault |
| `0x0040` | counter snapshot |
| `0x0100`–`0x0128` | replay mode, start, origin, interval, loss seed and threshold |
| `0x0140` | per-queue delays |
| `0x0200 + 32r` | classifier rules |
| `0x0400 + 64q` | capture rings |
| `0x0800 + 64q` | replay rings |
| `0x0c00` | drop counters |
| `0x1000`–`0x10ff` | PCIe transport (PCIe top only): four-tag mode, aperture base, error sticky bits, drain reset, counters |

Configuration writes need the engine quiescent. Bad accesses return SLVERR with no side effect. Register writes take effect on the second edge after AW and W are both held.

Replay timing:

- Original mode: `due = start + (capture_tick - origin) + queue_delay`
- Fixed mode: `due = start + seq*interval + queue_delay`

A packet never departs early. The loss decision is an xorshift hash of seed, sequence and queue, compared against a 33-bit threshold. It doesn't depend on stalls.

## Prerequisites

- Windows with Vivado/XSim 2025.2 at `C:\AMDDesignTools\2025.2\Vivado` (bundled UVM 1.2)
- Quartus Prime Lite 24.1std with MAX 10 support at `C:\intelFPGA_lite\24.1std`
- WSL2 Ubuntu (24.04 tested) with `python3` and `python3-venv`
- PowerShell 7 (`pwsh`). Windows PowerShell 5 aborts on Quartus's harmless stderr output
- optional: Wireshark/TShark at `C:\Program Files\Wireshark` (only `setup_checks/test_setup.py` uses it)

The scripts hardcode the Vivado and Quartus paths. Edit `scripts/run-rtl.ps1`, `run-fit.ps1`, `run-xsim.ps1` and `run-quartus.ps1` if yours differ.

## Setup

```powershell
Set-Location C:\projects\fpga-network-engine
wsl -d Ubuntu -- bash scripts/setup-python.sh          # .venv from requirements-lock.txt
wsl -d Ubuntu -- bash scripts/run-models.sh            # 41 model tests
pwsh -NoProfile -File scripts/run-bounded.ps1 -Check XSim      # optional tool qualification
pwsh -NoProfile -File scripts/run-bounded.ps1 -Check Quartus
```

## Running

Full regression. It writes fixtures, runs the model tests, every RTL test per seed and the AXI-vs-PCIe comparison:

```powershell
pwsh -NoProfile -File scripts/run-all.ps1 -Seeds 17
pwsh -NoProfile -File scripts/run-all.ps1 -Seeds 17,29 -Mutations -Fit
```

`build/regression/summary.txt` lists each step with PASS/FAIL, exit code and time. On the development machine, each seed takes about 10 min, the mutation campaign about 11 min and the two fits about 8 min.

Individual steps:

```powershell
wsl -d Ubuntu -- .venv/bin/python -m host.generate_engine_vectors       # integrated fixture -> build/engine
pwsh -NoProfile -File scripts/run-rtl.ps1 -Test engine_axi               # integrated AXI test
pwsh -NoProfile -File scripts/run-rtl.ps1 -Test engine_pcie              # PCIe, 1 tag, RCB 64
pwsh -NoProfile -File scripts/run-rtl.ps1 -Test engine_pcie -Label stress -Plusargs FOUR_TAG,RCB128,HIGH_APERTURE,HIGH_BAR
pwsh -NoProfile -File scripts/run-rtl.ps1 -Test pcie                     # requester unit test
wsl -d Ubuntu -- .venv/bin/python -m host.export_observations --axi build/engine_axi --pcie build/engine_pcie
pwsh -NoProfile -File scripts/run-mutations.ps1                          # 10 deliberate defects
pwsh -NoProfile -File scripts/run-fit.ps1 -Top engine_axi                # or engine_pcie
```

Other module tests are `-Test packet|axi|sg|control|replay`. Their fixtures come from `host.generate_{packet,dma,replay}_vectors`. Use `-Seed N` to pick the simulation seed. Run XSim jobs one at a time, because parallel runs share tool state.

Each integrated run writes `export/capture.pcap` and `export/replay.pcap` (nanosecond PCAP that opens in Wireshark) and `export/ticks.json` (exact integer ticks) under its `build/` directory.

## DE10-Lite

Both transport tops fit the DE10-Lite's MAX 10 (`10M50DAF484C7G`) and meet 50 MHz in all three timing corners:

| Top | LEs | Memory bits | Setup slack (slow 85 °C) | Fmax |
| --- | --- | --- | --- | --- |
| `engine_axi_fit` | 28,657 / 49,760 (58%) | 327,680 (20%) | +1.518 ns | 54.1 MHz |
| `engine_pcie_fit` | 29,413 / 49,760 (59%) | 327,680 (20%) | +0.317 ns | 50.8 MHz |

To reproduce:

```powershell
pwsh -NoProfile -File scripts/run-fit.ps1 -Top engine_axi    # output in build/fit/engine_axi
```

**Board programming isn't set up.** The fit wrappers (`constraints/engine_fit.sv`) register every port, and `constraints/engine.tcl` turns all of them except `clk` into virtual pins. There is no DE10-Lite board top and no pin assignments, so `clk` isn't tied to a physical pin and nothing drives the engine's streams or memory bus on the board. The results show the design fits and closes timing, but there's no `.sof` to program. Running on hardware would need a board top that wires the engine to an on-chip memory or the SDRAM, a packet source and sink, and the DE10-Lite pin file.

## Problems hit during development

- **XSim ignored `$fatal` in its exit code.** The simulator returned exit 0 even after an HDL `$fatal`, so a failing test looked like a pass. `scripts/check-xsim-log.ps1` now scans each log for errors, fatals and watchdogs, and requires a per-test success marker.
- **Replay buffer built from flip-flops.** The first full-engine fit inferred the four byte-enabled replay head arrays as about 66K registers and 53K LUTs, about 3× the MAX 10's capacity. Rewriting them as a single 2048×32 RAM in Quartus's byte-enable template moved them into block RAM, and the engine dropped to 58–59% of the device.
- **TLP header silently truncated.** Every TLP's DW0 was built from a concatenation that was 36 bits wide, which shifted out the Fmt field. A CplD left the BAR completer looking like an MRd, and XSim gave no width warning. The independent host-side TLP decoder caught it, and all four encoders now use `{fmt,type,14'b0,length}`.
- **Coverage bins named with reserved words.** Bins called `small`, `medium` and `large` (plus identifiers `sequence` and `before`) are SystemVerilog keywords and broke compilation, so they were renamed.
- **Replay monitor sampled too early.** The replay monitor read metadata on the same edge as TLAST, before the DUT's nonblocking update had landed. It now samples on the following falling edge.

Two smaller ones:

- The bundled UVM had no usable default timescale at elaboration, fixed with `xelab -timescale 1ns/1ps`.
- Comma-joined `-Seeds 17,29` reached the script as a single token (seed 1729) through `pwsh -File`, so the launchers now split comma lists.

## Results

Latest full run: `run-all.ps1 -Seeds 17,29 -Mutations -Fit`.

**Regression:** all 25 steps pass:

- fixtures and 41 Python model tests
- for both seeds 17 and 29:
  - the packet, AXI burst, SG, control and replay module tests
  - the PCIe requester unit test
  - integrated AXI, integrated PCIe and PCIe stress (four tags, RCB 128, aperture and BAR0/MSI above 4 GiB)
  - the AXI-vs-PCIe comparison
- the mutation campaign and both Quartus fits

Highlights from seed 17:

- Integrated AXI: 157 completion records, 57 replay frames, about 103K payload bytes plus 8K guard bytes checked
- PCIe requester: 4 tags outstanding, 346 cross-tag reorderings, 30 negative cases (UR/CA/CRS, poison, malformed, unexpected/duplicate tags, timeout and late completions)
- Functional coverage is 100% on the module tests and 96.9% on the integrated record covergroup. The remaining 3 bins are unreachable by design

**Mutation testing:** all 10 deliberately injected defects are detected by their intended checker:

- bad final strobe and wrong SG byte
- early departure, early completion and loss ignoring queue
- wrong PCIe byte enable, wrong tag and early tag reuse
- a removed completion fence
- a disabled byte checker

The clean design passes afterwards.

**AXI vs PCIe:** 0 mismatches across both PCIe variants and both seeds. Replay output, per-queue order, the 13 seeded-loss decisions and every completion record are identical. Only timing differs:

| Workload | AXI max lateness | PCIe max lateness |
| --- | --- | --- |
| Original-time replay | 6,654 ticks | 15,355 ticks |
| Throughput burst | 23,565 ticks | 46,011 ticks |

No packet left early in any run.

**Throughput** (16 × 1514-byte frames, simulation model at 50 MHz):

| Transport | Capture | Replay |
| --- | --- | --- |
| AXI | 155.6 MB/s | 50.6 MB/s |
| PCIe, 1 tag | 156.6 MB/s | 27.0 MB/s |
| PCIe, 4 tags | 154.5 MB/s | 24.1 MB/s |

Capture is close to the 4 B/tick ingress limit. Replay is limited by a single gather engine with one read outstanding, and four-tag mode only overlaps the pieces of one command. AXI write efficiency is 99.5% useful bytes.

**Quartus:** see the DE10-Lite table above. Hold slack is at least +0.100 ns. The PCIe top's +0.32 ns setup margin is thin, and its router reported regional congestion.

**Not tested or limited:**

- Hard reset with bus transactions in flight is not exercised. The design assumes an external drain guarantee, and tag quarantine covers the case without one.
- A duplicate completion that exactly matches a reissued tag's byte count and lower address can't be detected at the transaction layer.
- The PCIe host model only guarantees read-flush ordering. This is deliberately weaker than real root complexes, so a missing fence would show up.
- Nothing has run on hardware: no physical Ethernet, PCIe, SDRAM or board.
