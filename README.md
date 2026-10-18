# FPGA network capture/replay engine

[![CI](https://github.com/jchik1102/fpga-network-engine/actions/workflows/ci.yml/badge.svg)](https://github.com/jchik1102/fpga-network-engine/actions/workflows/ci.yml)

A SystemVerilog packet capture, replay and impairment engine with scatter-gather DMA, built around one engine core (`rtl/engine_core.sv`) that runs on two memory transports: an AXI4 64-bit burst master with AXI-Lite control (`engine_axi`), and a simulated PCIe transaction layer with a 1- or 4-tag DMA requester, a 16 KiB BAR0 completer and MSI (`engine_pcie`). The core classifies Ethernet II/IPv4/UDP traffic into four capture queues, moves packets to host memory through eight descriptor rings with 1–4 segment scatter-gather, and replays them at their original or fixed intervals with per-queue delay and seeded loss. It is verified with UVM 1.2 agents and a register model in XSim, independent Python models, a record-by-record AXI-versus-PCIe comparison and a mutation campaign, and both tops fit the DE10-Lite's MAX 10 at 50 MHz. The PCIe side stops at the transaction layer: there is no PHY, data link layer, flow-control credits or enumeration, and nothing has run on hardware.

![Block diagram](docs/block_diagram.svg)

The diagram is an SVG with the draw.io model embedded; open `docs/block_diagram.svg` in draw.io to edit it.

**Demo video:** _placeholder — link to be added._

## Running it

Prerequisites (from the original setup, unchanged):

- Windows with Vivado/XSim 2025.2 at `C:\AMDDesignTools\2025.2\Vivado` (bundled UVM 1.2); `make vivado` also needs Vivado's Artix-7 device support
- Quartus Prime Lite 24.1std with MAX 10 support at `C:\intelFPGA_lite\24.1std`
- WSL2 Ubuntu (24.04 tested) with `python3`, `python3-venv` and `make`
- PowerShell 7 (`pwsh`). Windows PowerShell 5 aborts on Quartus's harmless stderr output. The Makefile uses `pwsh.exe` from `PATH`, or set `PWSH=/path/to/pwsh.exe`
- for `make questa` only: Questa Intel Starter FPGA Edition 2024.3 (from the Quartus 24.1std download) at `C:\intelFPGA_lite\24.1std\questa_fse` with its free licence, and a python.org Python 3.13 on Windows with cocotb 2.1.0 and pytest in `%USERPROFILE%\.venvs\cocotb-win` (Questa cannot load the Microsoft Store Python)
- for `make formal` only: OSS CAD Suite in WSL (the 2026-10-14 build was used; it includes SymbiYosys, the yosys-slang plugin, Yices and Bitwuzla; versions in [versions.txt](results/formal/versions.txt)). `scripts/run-formal.sh` adds `~/oss-cad-suite/bin` to `PATH` if it exists
- optional: Wireshark/TShark at `C:\Program Files\Wireshark` (only `setup_checks/test_setup.py` uses it)

One-time setup, from WSL in the repository root:

```bash
bash scripts/setup-python.sh
```

Then:

| Command (WSL, repository root) | What it runs |
| --- | --- |
| `make models` | 41 Python model tests |
| `make test` | `scripts/run-all.ps1 -Seeds 17,29 -Mutations -Fit`, then `make results` |
| `make test-quick` | `scripts/run-all.ps1 -Seeds 17` |
| `make fpga` | Quartus fits of `engine_axi_fit` and `engine_pcie_fit` |
| `make results` | copies the logs and reports that back this README from `build/` into `results/` |
| `make formal` | SymbiYosys proofs and covers in `formal/` (needs OSS CAD Suite with the yosys-slang plugin on `PATH`), then the async FIFO proof on 4 FIFO mutants, each of which must fail; see "Formal verification" under [Results](#results) |
| `make cocotb` | cocotb tests of the async FIFO with two unrelated clocks (Icarus Verilog), then the same tests on the 4 mutants, each of which must fail |
| `make vhdl` | the VHDL-2008 async FIFO: the same cocotb tests with GHDL, its 4 VHDL mutants (each must fail), EQY equivalence against the SystemVerilog FIFO, and the same check on each mutant (each must fail); see "VHDL version of the FIFO" under [Results](#results) |
| `make questa` | The cocotb FIFO tests in a second simulator, Questa Starter, on the SystemVerilog and the VHDL FIFO, with one mutant each; see "Questa" under [Results](#results) |
| `make vivado-vhdl` | Vivado implementation of the two-clock top with the VHDL FIFO, out of context, reports in `results/vivado/engine_axi_cdc_vhdl/` |
| `make fpga-cdc` | Quartus fit of `engine_axi_cdc_fit`: the engine with its packet input on a separate 125 MHz clock, plus the metastability report |
| `make vivado` | Vivado synthesis, placement and routing of the three fit tops for an Artix-7, out of context; see "Vivado implementation" under [Results](#results) |

Per-step run times from the last full run are in [summary.txt](results/regression/summary.txt).

Each `make` target saves its console output under `results/`. The PowerShell scripts can still be run directly from PowerShell 7, as before:

```powershell
pwsh -NoProfile -File scripts/run-rtl.ps1 -Test engine_axi               # integrated AXI test
pwsh -NoProfile -File scripts/run-rtl.ps1 -Test engine_pcie              # PCIe, 1 tag, RCB 64
pwsh -NoProfile -File scripts/run-rtl.ps1 -Test engine_pcie -Label stress -Plusargs FOUR_TAG,RCB128,HIGH_APERTURE,HIGH_BAR
pwsh -NoProfile -File scripts/run-rtl.ps1 -Test pcie                     # requester unit test
pwsh -NoProfile -File scripts/run-mutations.ps1                          # 10 deliberate defects
pwsh -NoProfile -File scripts/run-fit.ps1 -Top engine_axi                # or engine_pcie
```

Other module tests are `-Test packet|axi|sg|control|replay`. Their fixtures come from `host.generate_{packet,dma,replay}_vectors`. Use `-Seed N` to pick the simulation seed. Run XSim jobs one at a time, because parallel runs share tool state. Each integrated run writes `export/capture.pcap`, `export/replay.pcap` (nanosecond PCAP that opens in Wireshark) and `export/ticks.json` under its `build/` directory.

## Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push and pull request, on GitHub's Ubuntu runners: the Python model tests, `scripts/run-formal.sh` (the SymbiYosys proofs and covers, with the same OSS CAD Suite build as `make formal`) with the async FIFO mutant check, and the cocotb tests with their mutant check. The XSim/UVM regression and the Quartus fits need the Windows vendor tools, so `make test` and `make fpga` run locally and their logs are committed under `results/`.

## Results

Every number below is copied from a log in [`results/`](results/), produced by `make test` (seeds 17 and 29, mutations and both fits). [`results/PROVENANCE.txt`](results/PROVENANCE.txt) records the commit and date. Where a test reports per-seed values, the seed-17 value is shown.

**Regression**

| Check | Result | Log |
| --- | --- | --- |
| Full regression steps | 25 of 25 pass | [summary.txt](results/regression/summary.txt) |
| Python model tests | 41 passed | [models.log](results/regression/models.log) |
| Packet parser/classifier | 111 packets, 34,339 bytes checked, coverage 100% | [packet_seed17.log](results/regression/packet_seed17.log) |
| AXI burst master | 395 transactions, 24,776 byte checks, coverage 100% | [axi_seed17.log](results/regression/axi_seed17.log) |
| Scatter-gather | 76 cases (20 invalid, 4 bus errors), 23,328 bytes checked | [sg_seed17.log](results/regression/sg_seed17.log) |
| AXI-Lite control + RAL | 42,627 checks, 595 claims, 584 commits, 68 rejected writes; ring and bus coverage 100% | [control_seed17.log](results/regression/control_seed17.log) |
| Replay policy | 227 policies, 61 frames, 8 lost; coverage and policy coverage 100% | [replay_seed17.log](results/regression/replay_seed17.log) |
| PCIe requester unit | 4 tags outstanding, 346 cross-tag reorderings, 30 negative cases (6 unexpected, 4 late, 8 malformed, 2 poisoned completions, 4 timeouts), coverage 100% | [pcie_seed17.log](results/regression/pcie_seed17.log) |
| Integrated AXI | 160 completion records, 57 replay frames, 102,951 payload bytes and 8,099 guard bytes checked; record coverage 100% | [engine_axi_seed17.log](results/regression/engine_axi_seed17.log) |
| Integrated PCIe, 1 tag | 163 records, 57 replay frames, 103,927 bytes checked; record coverage 100% | [engine_pcie_seed17.log](results/regression/engine_pcie_seed17.log) |
| Integrated PCIe stress (4 tags, RCB 128, aperture and BAR0/MSI above 4 GiB) | 163 records, 57 replay frames, 103,927 bytes checked | [engine_pcie_stress_seed17.log](results/regression/engine_pcie_stress_seed17.log) |

**Mutation campaign:** all 10 injected defects detected by their intended checker ([mutations.log](results/regression/mutations.log)): bad final strobe, wrong SG byte, early departure, early completion, loss ignoring queue, wrong PCIe byte enable, wrong tag, early tag reuse, premature completion publication and a disabled byte checker.

**Code coverage** (XSim statement, branch and condition coverage of each bench's design instances, testbench excluded; seed 17, from [results/code-coverage/](results/code-coverage/)):

| Bench | Statements | Branches | Conditions |
| --- | ---: | ---: | ---: |
| Packet parser/classifier | 174/174 (100%) | 54/57 (94.74%) | 139/154 (90.26%) |
| AXI burst master | 86/86 (100%) | 25/26 (96.15%) | 20/22 (90.91%) |
| Scatter-gather | 215/219 (98.17%) | 70/81 (86.42%) | 87/110 (79.09%) |
| AXI-Lite control | 348/392 (88.78%) | 169/234 (72.22%) | 175/222 (78.83%) |
| Replay policy and staging | 136/138 (98.55%) | 47/50 (94.00%) | 33/34 (97.06%) |
| PCIe requester unit | 290/298 (97.32%) | 116/128 (90.62%) | 177/202 (87.62%) |
| Integrated AXI | 1,277/1,316 (97.04%) | 483/589 (82.00%) | 528/670 (78.81%) |
| Integrated PCIe, 1 tag | 1,712/1,819 (94.12%) | 647/842 (76.84%) | 761/998 (76.25%) |
| Integrated PCIe stress | 1,713/1,819 (94.17%) | 659/842 (78.27%) | 770/998 (77.15%) |

Each file lists the lines that never executed. Seed 29 gives the same statement counts. The integrated PCIe runs cover only 85.20% of `pcie_requester`'s statements because they never produce its error paths (address-translation failures, timeouts, and late, malformed or unexpected completions); the requester's unit bench injects them and covers 97.11%. The coverage is per bench, not merged across benches, since each bench elaborates its own top. Toggle coverage is not collected: Vivado 2025.2's report tool crashed on it (seen on the riscv-soc core).

**AXI vs PCIe:** no differences in either PCIe variant for either seed ([compare_seed17.log](results/regression/compare_seed17.log), [compare_seed29.log](results/regression/compare_seed29.log)). Replay output (57 frames), per-queue order, the 13 seeded-loss decisions and the completion records are identical. The comparison excludes the abort phase, the AXI WRITE_ERROR row and the PCIe MSI phase ([comparison_s17.json](results/comparison_s17.json)). Only timing differs, in ticks of 20 ns:

| Workload (seed 17) | AXI max lateness | PCIe 1-tag max lateness |
| --- | ---: | ---: |
| Original-time replay | 6,654 | 15,355 |
| Throughput burst | 23,565 | 46,011 |

**Throughput** (16 × 1514-byte frames, simulation at 50 MHz, seed 17, from [comparison_s17.json](results/comparison_s17.json)):

| Transport | Capture | Replay |
| --- | ---: | ---: |
| AXI | 155.6 MB/s | 50.59 MB/s |
| PCIe, 1 tag | 156.59 MB/s | 26.96 MB/s |
| PCIe, 4 tags | 154.51 MB/s | 24.09 MB/s |

Capture is close to the 4 B/tick ingress limit of the 32-bit stream. Replay is limited by a single gather engine with one read outstanding, and four-tag mode only overlaps the pieces of one command.

**Formal verification** (`make formal`, SymbiYosys with the yosys-slang frontend; [summary.txt](results/formal/summary.txt)). The two modules with the most protocol state are checked on their own, with every input free except for the assumptions listed below. "Proof" means unbounded: the property holds in every reachable state, not just up to a depth.

| Module | Task | What is checked | Result | Log |
| --- | --- | --- | --- | --- |
| `engine_control` | prove (k-induction, yices) | AXI-Lite slave: one response per request, responses held until accepted, only OKAY or SLVERR, read data from the address accepted at the AR handshake (ID register, `sq_producer[0]`, an unmapped address), a rejected write changes no configuration; for each of the 8 rings, a submission ring never holds more than 32 descriptors and completed plus reserved records never exceed the 64-entry completion ring | proof passes | [log](results/formal/engine_control_prove/logfile.txt) |
| `engine_control` | cover | an OKAY write, a SLVERR write, a ring register read, a claim followed by a commit | all 4 reached | [log](results/formal/engine_control_cover/logfile.txt) |
| `pcie_requester` | prove (ABC PDR) | no MRd on a tag that is still outstanding, single-tag mode uses only tag 0, every accepted completion belongs to an outstanding tag of this requester, an MRd TLP is never cut short on the TX stream | proof passes | [log](results/formal/pcie_requester_prove/logfile.txt) |
| `pcie_requester` | cover | two tags outstanding, a completion accepted, a tag quarantined, a tag reused after its completion | all 4 reached | [log](results/formal/pcie_requester_cover/logfile.txt) |
| `stream_cdc_fifo` | prove (ABC PDR, two free-running clocks) | async FIFO: never overflows or underflows, Gray pointers always encode their binary pointers, each synchronized pointer only lags the real one, and a word chosen by the solver is read back unchanged from the same position (ordering, no loss or duplication) | proof passes | [log](results/formal/stream_cdc_fifo_prove/logfile.txt) |
| `stream_cdc_fifo` | cover | FIFO full, the tracked word read, drained afterwards | all 3 reached | [log](results/formal/stream_cdc_fifo_cover/logfile.txt) |

**Two RTL bugs found.** Neither was reachable by the UVM agents, and both are fixed (explained in [DESIGN.md](DESIGN.md#bugs-found-by-formal-verification)): `engine_control` decoded most read addresses from the live `ARADDR` instead of the address latched at the handshake, and `pcie_requester` could time out in the middle of sending an MRd and leave a truncated TLP on the link. [`scripts/formal-before-fix.sh`](scripts/formal-before-fix.sh) re-runs the proofs on the RTL from before each fix, and both fail ([before_fix/summary.txt](results/formal/before_fix/summary.txt)).

Assumptions and limits:

- The harnesses use immediate assertions in clocked blocks, because the yosys-slang frontend does not support concurrent SVA.
- `engine_control`: the AXI-Lite master keeps VALID and its payload stable until the handshake. Once the engine has been seen stopped and quiescent, no worker claims a descriptor until RUN; `engine_core`, `capture_dma` and `replay_dma` guarantee this, and without it a stale `claim_eligible` could over-claim a ring (DESIGN.md, decision 1). The proof also uses helper invariants (stated as assertions, so they are proved too) on the slave's handshake state and on what `claim_ready` implies about the counters.
- `pcie_requester` is checked with `TIMEOUT=8` instead of 65,536 so the timeout and quarantine paths are reachable; the logic does not depend on the value. The configuration inputs are held constant, no completion arrives during a drain reset, and a completion with this requester's ID never names a tag whose new MRd is still being sent (the transaction-layer limit listed under "Not tested or limited"). Foreign IDs and late completions for quarantined tags are unconstrained.
- Data movement (DMA payloads, scatter-gather, replay timing) is not checked formally; the simulation regression covers it.

**Clock-domain crossing.** [`rtl/stream_cdc_fifo.sv`](rtl/stream_cdc_fifo.sv) is an asynchronous FIFO for the packet stream: binary pointers with Gray-code copies, each Gray pointer crossing through a two-flop synchronizer, pessimistic full and empty flags, and a first-word-fall-through read port. `engine_axi_cdc_fit` ([`constraints/engine_cdc_fit.sv`](constraints/engine_cdc_fit.sv)) puts it in front of the unchanged engine, so packets can arrive on their own clock. For Quartus, [`constraints/engine_cdc.sdc`](constraints/engine_cdc.sdc) declares the two clocks asynchronous. For Vivado, [`constraints/engine_cdc.xdc`](constraints/engine_cdc.xdc) bounds the crossing instead of cutting it, the way Xilinx constrains its own CDC macros: data-path delay under the 8 ns packet-clock period, and skew between the bits of each Gray pointer under 8 ns too. The synchronizer flops carry `ASYNC_REG` and Quartus's synchronizer attribute.

| Check | Result | Log |
| --- | --- | --- |
| Formal proof, both clocks free (every interleaving of edges), 4 entries | passes; the same proof fails on all 4 FIFO mutants (missed full, write while full, read without ready, missed empty) | [summary.txt](results/formal/summary.txt), [cdc_fifo_mutants.txt](results/formal/cdc_fifo_mutants.txt) |
| cocotb, 16 entries, 37-bit words, random valid/ready on both sides | 3 of 3 tests pass: 10/13 ns clocks (3,000 words, FIFO filled and drained), 7/31 ns slow reader (1,500 words, held full), 29/6 ns fast reader (1,500 words, ran empty); every word in order and unchanged. All 4 mutants make the tests fail | [cocotb.log](results/cocotb.log) |
| Quartus fit, engine at 50 MHz and packet clock at 125 MHz | 28,573 LEs (57%); setup slack +1.400 ns (engine clock) and +1.181 ns (packet clock) at slow 85 °C, Fmax 53.76 and 146.65 MHz; worst hold +0.088 ns | [fit](results/fit/engine_axi_cdc/engine_axi_cdc_fit.fit.summary), [sta](results/fit/engine_axi_cdc/engine_axi_cdc_fit.sta.summary), [Fmax](results/fit/engine_axi_cdc/engine_axi_cdc_fit.sta.rpt) |
| Synchronizers (Quartus metastability analysis) | 10 two-flop chains found (the 5 pointer bits each way), worst-case MTBF above 1 billion years; the only paths between the clocks are the declared false paths | [metastability.txt](results/fit/engine_axi_cdc/metastability.txt), [clock_transfers.txt](results/fit/engine_axi_cdc/clock_transfers.txt) |
| Vivado, Artix-7, same two clocks | every crossing path meets its 8 ns bound (+5.388 ns slack packet→engine over 42 endpoints, +6.656 ns engine→packet over 5); Gray pointer skew 0.709 ns (write) and 0.987 ns (read) against 8 ns | [timing](results/vivado/engine_axi_cdc/timing_summary.txt), [bus_skew.txt](results/vivado/engine_axi_cdc/bus_skew.txt), [clock_interaction.txt](results/vivado/engine_axi_cdc/clock_interaction.txt) |
| Vivado `report_cdc` | no critical findings: 2 CDC-6 warnings (each multi-bit Gray pointer through its `ASYNC_REG` synchronizer, the intended structure) and 37 CDC-26 warnings (the FIFO memory, built from LUTRAM, is read and written on different clocks; the pointer protocol never reads a word while it is being written) | [cdc.txt](results/vivado/engine_axi_cdc/cdc.txt) |

Formal and simulation sample signals ideally, so they check the pointer protocol, not metastability itself; the Gray coding and the synchronizers, confirmed by the metastability report, are what make the crossing safe in hardware. The UVM regression still runs the single-clock tops; the two-clock top is checked by the FIFO proof, the cocotb tests and the fit.

**VHDL version of the FIFO.** [`rtl/vhdl/stream_cdc_fifo.vhd`](rtl/vhdl/stream_cdc_fifo.vhd) is the same asynchronous FIFO in VHDL-2008: the same ports, generics, registers and register names, with the storage in its own process so synthesis sees a plain RAM write port. `make vhdl` ([`scripts/vhdl-cdc-fifo.sh`](scripts/vhdl-cdc-fifo.sh)) checks it three ways, and `make vivado-vhdl` builds the two-clock top with it.

| Check | Result | Log |
| --- | --- | --- |
| The cocotb tests above, unchanged, on the VHDL with GHDL 7.0-dev ([`tb/cocotb_vhdl/`](tb/cocotb_vhdl/test_cocotb_vhdl.py)) | 3 of 3 tests pass, with the same words, end times and flow-control counts as the SystemVerilog under Icarus, except one: the slow-reader test counts 4,031 held-off cycles against Icarus's 4,032 (inferred: the bench samples `s_ready` on the same edge the FIFO updates it, and the two simulators order that sample differently; the words, their order and every test's end time are the same, and the equivalence check below proves the designs equal) | [cocotb.log](results/vhdl/cocotb.log) |
| The same tests on the VHDL versions of the 4 FIFO mutants | each mutant fails (2, 2, 3 and 2 of the 3 tests) | [summary.txt](results/vhdl/summary.txt) |
| EQY equivalence, VHDL (GHDL's Yosys plugin) against SystemVerilog (yosys-slang), default generics (37-bit words, 16 entries) | equivalent: all 31 partitions proved by k-induction (every register bit, including the 16 memory words, matched by name) | [eqy-vhdl_vs_sv.log](results/vhdl/eqy-vhdl_vs_sv.log) |
| The same equivalence check with each VHDL mutant as the design under test | each fails, naming the partitions it could not prove (for example `m_valid` and `empty` for the missed-empty mutant) | [summary.txt](results/vhdl/summary.txt) |
| Vivado, the two-clock top built with the VHDL FIFO in place of the SystemVerilog one (`make vivado-vhdl`, a mixed-language design) | 13,905 slice LUTs (13,904 with the SystemVerilog FIFO), the same 15,114 registers, 10 block RAM tiles and 3 DSPs; setup slack +3.857 ns (engine clock) and +3.743 ns (packet clock), hold +0.093 and +0.028 ns; Gray pointer skew 0.845 and 1.370 ns against 8 ns; `report_cdc` gives the same findings as for the SystemVerilog FIFO (2 CDC-6, 37 CDC-26) | [result](results/vivado/engine_axi_cdc_vhdl/result.txt), [timing](results/vivado/engine_axi_cdc_vhdl/timing_summary.txt), [bus_skew.txt](results/vivado/engine_axi_cdc_vhdl/bus_skew.txt), [cdc.txt](results/vivado/engine_axi_cdc_vhdl/cdc.txt), [log](results/vivado-engine_axi_cdc_vhdl.log) |

The equivalence check needed one change to the VHDL: its memory write repeats the SystemVerilog's `s_rst` condition, which `write_en` already implies. EQY cuts the design at matched signals, so it saw `s_ready` as a free input and found a state where the VHDL wrote during reset and the SystemVerilog did not. The extra term costs nothing after synthesis and makes the two match structurally.

**Questa.** `make questa` ([`scripts/run-questa.ps1`](scripts/run-questa.ps1)) runs what the free Questa Intel Starter FPGA Edition 2024.3 licence allows. The UVM benches do not run: the licence has no SystemVerilog verification feature, so Questa refuses `randomize()` and covergroups, which every bench in `tb/` uses ([uvm_packet_attempt.log](results/questa/uvm_packet_attempt.log): error vsim-1 when loading `packet_tb`). What runs is the cocotb FIFO tests, unchanged, through Questa's VPI (`COCOTB_SIM=questa`):

| Check | Result | Log |
| --- | --- | --- |
| The cocotb tests on the SystemVerilog FIFO | 3 of 3 pass; words, end times and flow-control counts equal GHDL's on the VHDL, including the slow-reader test's 4,031 held-off cycles, where Icarus counts 4,032 (consistent with the sampling-order explanation above) | [cocotb_sv.log](results/questa/cocotb_sv.log) |
| The cocotb tests on the VHDL FIFO | 3 of 3 pass, with the same counts | [cocotb_vhdl.log](results/questa/cocotb_vhdl.log) |
| The missed-empty mutant (`empty_misses_data`), SystemVerilog and VHDL | each fails 2 of the 3 tests, as under Icarus and GHDL | [summary.txt](results/questa/summary.txt) |

The other three mutants run in Questa too, but they hang the FIFO and fail only on the tests' 20 ms and 60 ms timeouts. The Starter edition with cocotb ran these benches at 3,363 simulated ns per second for the SystemVerilog (Icarus: 202,015) and 18,828 for the VHDL (GHDL: 408,652), so each of those mutants would take hours; they stay on Icarus and GHDL (`make cocotb`, `make vhdl`). The licence allows one Questa session at a time on the machine.

**Quartus Prime Lite 24.1, 10M50DAF484C7G, 50 MHz:**

| Top | Logic elements | Memory bits | Setup slack (slow 85 °C) | Worst hold slack | Fmax (slow 85 °C) | Reports |
| --- | --- | --- | --- | --- | --- | --- |
| `engine_axi_fit` | 28,445 / 49,760 (57%) | 327,680 (20%) | +1.529 ns | +0.147 ns | 54.14 MHz | [fit](results/fit/engine_axi/engine_axi_fit.fit.summary), [sta](results/fit/engine_axi/engine_axi_fit.sta.summary), [Fmax](results/fit/engine_axi/engine_axi_fit.sta.rpt) |
| `engine_pcie_fit` | 29,646 / 49,760 (60%) | 327,680 (20%) | +2.201 ns | +0.101 ns | 56.18 MHz | [fit](results/fit/engine_pcie/engine_pcie_fit.fit.summary), [sta](results/fit/engine_pcie/engine_pcie_fit.sta.summary), [Fmax](results/fit/engine_pcie/engine_pcie_fit.sta.rpt) |

Both margins were under 1 ns until the fault-clear change below, and the PCIe fit's router warns about congestion ([fit_engine_pcie.log](results/regression/fit_engine_pcie.log)).

**Vivado implementation.** `make vivado` runs the same three fit wrappers through Vivado 2025.2 for an Artix-7 xc7a100tcsg324-1, out of context: synthesis, placement, physical optimization and routing ([`scripts/vivado-impl.tcl`](scripts/vivado-impl.tcl), [`scripts/run-vivado.ps1`](scripts/run-vivado.ps1)). The engine clock is 50 MHz as on the MAX 10, and the two-clock top adds the 125 MHz packet clock with [`constraints/engine_cdc.xdc`](constraints/engine_cdc.xdc). It shows that the RTL is not tied to Quartus. Nothing was run on Xilinx hardware.

| Top | Slice LUTs | Registers | Block RAM tiles | DSPs | Setup slack | Hold slack | Reports |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `engine_axi_fit` | 13,280 / 63,400 (21%) | 15,030 | 10 | 3 | +4.101 ns | +0.096 ns | [result](results/vivado/engine_axi/result.txt), [utilization](results/vivado/engine_axi/utilization.txt), [timing](results/vivado/engine_axi/timing_summary.txt), [log](results/vivado-engine_axi.log) |
| `engine_pcie_fit` | 15,051 / 63,400 (24%) | 15,653 | 10 | 3 | +0.456 ns | +0.096 ns | [result](results/vivado/engine_pcie/result.txt), [utilization](results/vivado/engine_pcie/utilization.txt), [timing](results/vivado/engine_pcie/timing_summary.txt), [log](results/vivado-engine_pcie.log) |
| `engine_axi_cdc_fit` | 13,904 / 63,400 (22%) | 15,114 | 10 | 3 | +3.527 ns (engine), +4.349 ns (packet) | +0.096 ns (engine), +0.028 ns (packet) | [result](results/vivado/engine_axi_cdc/result.txt), [utilization](results/vivado/engine_axi_cdc/utilization.txt), [timing](results/vivado/engine_axi_cdc/timing_summary.txt), [log](results/vivado-engine_axi_cdc.log) |

The PCIe top's worst path is a single LUT after the PCIe requester's parse-state register, with 19.0 ns of routing to a far endpoint of its 1,024-bit read-data register ([worst path](results/vivado/engine_pcie/worst_setup_path.txt)); a run before the fault-clear change below had +1.791 ns there, so this margin moves with placement. The replay buffer is four RAMB18s, one per byte lane, and all 3 DSPs are in the replay loss policy (`replay_policy`) ([hierarchy](results/vivado/engine_pcie/utilization_hierarchy.txt)).

**Board programming isn't set up.** The fit wrappers (`constraints/engine_fit.sv`) register every port, and `constraints/engine.tcl` turns all of them except `clk` into virtual pins. There is no DE10-Lite board top and no pin assignments, so the results show that the design fits and closes timing, but there's no `.sof` to program. Running on hardware would need a board top that wires the engine to an on-chip memory or the SDRAM, a packet source and sink, and the DE10-Lite pin file.

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

Design decisions and the reasoning behind them are in [DESIGN.md](DESIGN.md).

## Layout

| Path | Content |
| --- | --- |
| `rtl/` | synthesizable design; `engine_axi` (in `engine_core.sv`) and `engine_pcie` are the transport tops |
| `tb/` | UVM agents (stream, AXI memory, AXI-Lite + RAL, PCIe root complex), module benches, host software, integrated tests |
| `models/`, `host/` | independent Python models, fixture generators, PCAP/tick export and the AXI-vs-PCIe comparison |
| `tests/` | Python model tests and the published replay-loss vectors |
| `tb/cocotb/` | cocotb tests of the async FIFO and their pytest runner |
| `rtl/vhdl/`, `tb/cocotb_vhdl/` | VHDL-2008 version of the async FIFO, and the runner that puts the cocotb tests on it with GHDL |
| `formal/` | SymbiYosys harnesses (`*_formal.sv`), `.sby` files and the task list run by `make formal` |
| `constraints/` | Quartus project script, SDC, Vivado XDC for the two-clock top, registered fit wrappers, timing report scripts |
| `scripts/` | launchers; `run-all.ps1` runs the full regression, `collect-results.sh` gathers the evidence |
| `setup_checks/` | tool qualification benches used by `run-bounded.ps1` |
| `results/` | committed logs and reports behind the numbers in this README |
| `docs/` | block diagram |

## Problems hit during development

- **XSim ignored `$fatal` in its exit code.** The simulator returned exit 0 even after an HDL `$fatal`, so a failing test looked like a pass. `scripts/check-xsim-log.ps1` now scans each log for errors, fatals and watchdogs, and requires a per-test success marker.
- **Replay buffer built from flip-flops.** The first full-engine fit inferred the four byte-enabled replay head arrays as flip-flops and LUTs, several times the MAX 10's capacity. Rewriting them as a single 2048×32 RAM in Quartus's byte-enable template moved them into block RAM, and the engine dropped to 57–59% of the device. Vivado did not recognize that packed byte-enable array as a RAM (a "3D-RAM" warning) and built it from 65,536 registers, so placement failed for lack of slices ([log](results/vivado/engine_axi_cdc-packed-ram-failed.log)). The buffer is now four 2048×8 RAMs, one per byte lane, each the plain simple dual-port template that both tools infer as block RAM (four RAMB18s in Vivado, the same 327,680 memory bits in Quartus).
- **A 50 MHz path with under 1 ns of margin.** After the RAM change, the first Quartus fit of the two-clock top missed 50 MHz by 0.068 ns at slow 85 °C ([worst path](results/fit/engine_axi_cdc-before-fault-clear/path_setup_worst.txt)). The path had been the worst in every fit, at +0.84 to +0.98 ns: the register-write check (`write_ok`: an 8-to-1 ring mux, 32-bit subtracts and a compare) gated the sticky fault registers, although a FAULT_CLEAR write never depends on the ring. `engine_control` now computes that write's acceptance on its own (`fault_clear`). A yosys sequential equivalence check proves the new module equivalent to the old one ([`scripts/equiv-engine-control.sh`](scripts/equiv-engine-control.sh), [log](results/formal/engine_control_equiv.log)), and the same check fails when a condition is dropped from `fault_clear`. Setup slack rose to +1.529 ns (`engine_axi_fit`), +2.201 ns (`engine_pcie_fit`) and +1.400 ns (two-clock top, engine clock).
- **TLP header silently truncated.** Every TLP's DW0 was built from a concatenation that was 36 bits wide, which shifted out the Fmt field. A CplD left the BAR completer looking like an MRd, and XSim gave no width warning. The independent host-side TLP decoder caught it, and all four encoders now use `{fmt,type,14'b0,length}`.
- **Record coverage stuck at 96.875%.** Unsupported frames (IPv6, ARP, VLAN) reach a capture ring only through the default queue, and every test phase left it at queue 3, so rings 0 to 2 never returned an UNSUPPORTED completion record. A final phase (`phase_default_queue` in [`tb/host_software_pkg.sv`](tb/host_software_pkg.sv)) points the default queue at each of those rings in turn and sends one such frame. Its frames and descriptors are appended to the fixture after the existing ones, so the earlier stimulus is unchanged, and record coverage is now 100% in all six integrated runs.
- **Coverage bins named with reserved words.** Bins called `small`, `medium` and `large` (plus identifiers `sequence` and `before`) are SystemVerilog keywords and broke compilation, so they were renamed.
- **Replay monitor sampled too early.** The replay monitor read metadata on the same edge as TLAST, before the DUT's nonblocking update had landed. It now samples on the following falling edge.
- The bundled UVM had no usable default timescale at elaboration, fixed with `xelab -timescale 1ns/1ps`.
- Comma-joined `-Seeds 17,29` reached the script as a single token (seed 1729) through `pwsh -File`, so the launchers now split comma lists.

## Not tested or limited

- Hard reset with bus transactions in flight is not exercised. The design assumes an external drain guarantee, and tag quarantine covers the case without one.
- A duplicate completion that exactly matches a reissued tag's byte count and lower address can't be detected at the transaction layer.
- The PCIe host model only guarantees read-flush ordering. This is deliberately weaker than real root complexes, so a missing fence would show up.
- The skew between Gray pointer bits at the clock crossing is bounded and checked only in the Vivado flow; the Quartus SDC cuts those paths (see [DESIGN.md](DESIGN.md#6-packet-input-on-its-own-clock-through-an-asynchronous-fifo)).
- Nothing has run on hardware: no physical Ethernet, PCIe, SDRAM or board.
