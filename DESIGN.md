# Design decisions

> **How to read this.** Each entry states what the RTL does, with file
> references, and then answers the design questions. The answers were
> **inferred from the code, tests and logs**, not taken from the author's
> notes, so they explain why the design works as it does, not a recorded
> history of the decision. Where the repository holds no evidence, the answer
> says so.

## 1. Descriptor ownership with absolute counters and reserved completion credit

**What the RTL does.** Each of the 8 submission and 8 completion rings has
absolute 32-bit producer/consumer counters in `engine_control`
(`rtl/engine_control.sv:7`). The host owns a descriptor until it advances
`sq_producer` with the doorbell (`:228`). A DMA worker may claim a descriptor
only if the completion ring has room, counting reservations already made
(`claim_eligible`, `:202`). Claiming advances `sq_consumer` and sets
`reserved` (`:237`). Commit writes the completion and advances `cq_producer`
(`:238`).

**Why absolute counters?** With free-running 32-bit counters, occupancy is
just `producer - consumer` in modular arithmetic, full and empty are never
ambiguous, and there is no wrap bit to keep in sync between host and device.
The ring index is the counter modulo the ring size. The counters also double
as sequence numbers: every descriptor and completion record carries one, so
the host can check that it received exactly the records it expected.

**Why reserve the completion slot at claim time?** The race it closes: if a
worker claimed a descriptor (taking ownership away from the host) and only
then found the completion ring full, it would hold a descriptor it couldn't
complete, and the host couldn't reuse that submission slot either. Counting
reservations in `claim_eligible` means a descriptor is only taken when its
completion slot is already guaranteed. The `CONTROL_PASS` run checks 595
claims against 584 commits with no ring violations
([control_seed17.log](results/regression/control_seed17.log)).

**Is the reservation alone enough?** Not for `engine_control` on its own.
`claim_eligible` is registered, so it reflects the counters one cycle late. Formal
checking (`formal/engine_control_formal.sv`) found that if `RING_RECOVER` empties
a ring and a claim arrives in the very next cycle, the stale `claim_eligible`
still allows it, and `sq_consumer` passes `sq_producer`. In the full engine that
cannot happen: ring reconfiguration requires a quiescent engine, and once it is
stopped and quiescent no worker claims until RUN (`capture_dma` needs a non-empty
queue, nothing is admitted while stopped, and `replay_dma` claims only while
running). So the comment at `engine_control.sv:48` ("a stale value only delays a
claim") holds for the engine, not for the module alone. The formal harness states
this as its one environment assumption.

**How does the host know a completion record is visible?** Before publishing,
`capture_dma` issues a read after its payload writes (`PAYLOAD_FENCE`) and
again after writing the completion record (`CQ_FENCE`)
(`rtl/capture_dma.sv:82`, `:96`). A read can't complete before earlier posted
writes on the same path, so when the fence read returns, the data is in host
memory, and only then does the producer counter move. The
`PREMATURE_PUBLICATION` mutation removes a fence and is caught
([mutations.log](results/regression/mutations.log)).

## 2. Register writes only when quiescent, and no side effects on error

**What the RTL does.** Configuration writes are rejected unless the engine is
stopped and quiescent (`config_locked`, `engine_control.sv:46`, `:146`).
Doorbells and completion ACKs are exempt. Every register kind has a legality
check (`:144-171`), and illegal accesses return SLVERR without changing state.
Ring base and counter-origin writes also require empty rings (`:159-171`).

**Why lock configuration rather than shadow it?** Shadow registers would need
a defined point at which every worker switches to the new values together,
and a ring base changed under an in-flight DMA would corrupt memory. Requiring
quiescence makes every configuration change atomic with respect to traffic,
with no extra storage. Doorbells and ACKs are exempt because they are the
normal run-time interface.

**Why does a write take effect on the second edge?** The slave first captures
AW and W into holding registers, independently and in either order
(`engine_control.sv:192-193`). On the next edge it decodes the address and the
legality checks into registered state (`decoded`, `d_kind`), and only then
executes (`execute_write`, `:54`). Registering the decode keeps the large
address compare and legality logic out of the same cycle as the state update.

**Which tests check SLVERR and the no-side-effect rule?** The control module
test drives the AXI-Lite agent through the RAL, which maps a non-OKAY response
to a failed register status (`tb/axil_agent_pkg.sv:136`). Its run reports 68
rejected writes with 100% bus and ring coverage
([control_seed17.log](results/regression/control_seed17.log)).

## 3. PCIe tag quarantine instead of reuse

**What the RTL does.** `pcie_requester` tracks up to four tags. On a timeout or
a malformed completion, a tag that still has bytes outstanding is quarantined
rather than freed, because a late completion could still arrive (comment at
`rtl/pcie_requester.sv:167`). New reads are refused while any tag is
quarantined (`:142`) until a drain reset clears them (`:132`).

**Why quarantine rather than reuse after a timeout?** A timed-out request may
still be in flight. If the tag were reused, a late completion for the old
request would match the new one and its data would be written into the wrong
buffer, a silent corruption. Quarantine turns that into a refused request:
while any tag is quarantined, a new read goes straight to `R_FAIL`
(`pcie_requester.sv:142-144`) instead of being issued. The `EARLY_TAG_REUSE` mutation is
caught by the requester bench
([mutations.log](results/regression/mutations.log)).

**Why block all new reads, not just that tag?** Tags are assigned by position
within a command (`request_index`, `pcie_requester.sv:81`), so the requester
can't simply skip one. After a timeout or malformed completion the link is
already in an error state that software has to handle, so stopping new reads
until a drain reset is the simplest behaviour that can't corrupt memory.

**Why is the duplicate-completion case a transaction-layer limit?** A
completion is matched on requester ID, tag, byte count and lower address. If a
stale completion for a reissued tag happens to carry the same byte count and
lower address as the new request, nothing in the TLP distinguishes the two.
Telling them apart needs state below the transaction layer, which this design
doesn't model.

## 4. One engine core behind two transports

**What the RTL does.** `engine_core` (`rtl/engine_core.sv`) exposes generic
read/write command ports through `dma_command_arbiter`. `engine_axi` maps them
to `axi_burst_master`. `engine_pcie` maps them to `pcie_requester`, and its
BAR0 completer drives the same AXI-Lite register port
(`rtl/engine_pcie.sv:63`).

**Why add PCIe beside AXI rather than replace it?** Keeping the transport
behind a small read/write command interface means the capture, replay, ring
and classifier logic is identical in both builds. AXI remains the simple
reference transport, and PCIe adds tags, completion splitting, reordering and
MSI without touching the engine.

**What does the AXI-versus-PCIe comparison prove?** Running the same fixture
through both tops and comparing replay output, per-queue order, the seeded
loss decisions and every completion record shows that the PCIe layer changes
only timing, not behaviour: 0 differences in both PCIe variants for both
seeds ([compare_seed17.log](results/regression/compare_seed17.log)). The
per-transport tests can each pass while the two disagree, and this check
catches that.

**Why stop at the transaction layer?** The board has no PCIe hardware, so a
PHY or link layer could never be run, and the transaction layer is where the
DMA engine interacts with PCIe semantics: tags, ordering, completions and
interrupts. That is the part a simulated root complex can check. The README
states the limitation.

## 5. Stall-independent replay loss

**What the RTL does.** `replay_policy` decides loss with an xorshift hash of
the loss seed, the packet sequence number and the queue
(`rtl/replay_policy.sv:31`, `:41-43`), compared against a 33-bit threshold
(`:45`). Lines 27 and 29 are mutation variants used by the mutation campaign.

**Why a hash rather than an LFSR?** An LFSR stepped once per packet makes the
decision for a packet depend on how many packets came before it on that
queue, and so on arrival order, stalls and aborts. Hashing the packet's own
sequence number and queue makes the decision a pure function of the packet,
so the AXI and PCIe runs, with different timing, make the same 13 loss
decisions ([compare_seed17.log](results/regression/compare_seed17.log)), and
the Python model can predict every one.

**Why a 33-bit threshold?** The hash is 32 bits and the test is
`{1'b0,x} < threshold` (`:45`). With 33 bits, a threshold of 0 means no loss
and 2^32 means every packet is lost. A 32-bit threshold couldn't express 100%
loss.

**Which mutation checks that the queue is part of the hash?**
`LOSS_IGNORES_QUEUE` drops the queue term, and the integrated AXI test's host
oracle catches it ([mutations.log](results/regression/mutations.log)).

## 6. Packet input on its own clock through an asynchronous FIFO

**What the RTL does.** `rtl/stream_cdc_fifo.sv` carries the 37-bit packet
stream (`{last, keep, data}`) from a packet clock into the engine clock. Each
side keeps a binary pointer one bit wider than the address and a Gray-code
copy; only the Gray pointers cross, each through two flip-flops. The write side
compares its pointer with the synchronized read pointer to decide full, and the
read side compares with the synchronized write pointer to decide empty.
`constraints/engine_cdc_fit.sv` puts it in front of the unchanged engine, with
the packet clock at 125 MHz.

**Why Gray code?** A binary pointer can change several bits at once (7 to 8
changes all four low bits), and a receiving flip-flop that samples mid-change
can capture a value that was never the pointer. A Gray pointer changes one bit
per increment, so the receiver sees either the old or the new value. Both are
valid, only late.

**Why is a late pointer safe?** Each side only ever sees the other's pointer
behind where it really is. The writer may think the FIFO is fuller than it is,
and the reader may think it is emptier, so full and empty can only be
pessimistic: a stall, never an overflow or a read of unwritten data. The
formal proof states this directly (`ap_r_view_lags`, `ap_w_view_lags`) along
with no overflow, no underflow and data integrity.

**Why one extra pointer bit?** With an address-width pointer, "equal" would mean
both empty and full. The extra bit counts laps: equal pointers mean empty, and
pointers equal except for the lap bit mean full. In Gray code that shows up as
the top two bits differing and the rest equal.

**Why two flip-flops?** The first flop may go metastable when it samples a
changing input; the second gives it a full clock period to settle. Quartus's
metastability analysis finds the 10 chains and puts the worst-case MTBF above a
billion years ([metastability.txt](results/fit/engine_axi_cdc/metastability.txt)).

**Why declare the clocks asynchronous instead of timing the crossing?** There
is no fixed phase between the clocks, so a setup check between them has no
meaning. The synchronizers and the Gray-code protocol carry the correctness, and
`set_clock_groups -asynchronous` tells the timing analyzer not to time those
paths. The FIFO memory is read across domains too; that is safe because a word
is written on the same edge that advances the write pointer, and the reader
only sees that pointer two of its own clock edges later, by which time the word
has been stable for at least that long.

**What does cutting the paths leave unchecked?** Once the paths are cut, the
tools no longer limit how long a pointer bit takes to reach its first
synchronizer flop, or how far apart the bits of one pointer arrive. The Gray
code argument needs both. If two bits of a pointer arrived more than a
receiving period apart, the receiver could capture a value with two bits
changed, which is not a pointer the writer ever had. The Vivado constraints
([engine_cdc.xdc](constraints/engine_cdc.xdc)) bound the crossing instead of
cutting it, the way Xilinx constrains its own CDC macros:
`set_max_delay -datapath_only` of 8 ns (the packet-clock period) on every
crossing path, and `set_bus_skew` of 8 ns on each Gray pointer. The routed
Artix-7 design meets them, with 0.709 ns and 0.987 ns of pointer skew
([bus_skew.txt](results/vivado/engine_axi_cdc/bus_skew.txt)). The synchronizer
flops carry `ASYNC_REG`, so Vivado keeps each pair together and `report_cdc`
classifies the pointers as synchronized ([cdc.txt](results/vivado/engine_axi_cdc/cdc.txt)).
The same bound was tried in the Quartus SDC with `set_max_skew` and
`set_net_delay`. The Timing Analyzer matched the registers but reported no
paths for either constraint and ignored them, so the Quartus flow keeps the
cut, and the bound is checked only in Vivado.

**What the proof cannot show.** The solver samples signals ideally, so it checks
the pointer protocol, not metastability. Metastability is handled structurally
(Gray code, two-flop synchronizers) and measured by the Quartus report.

## 7. A VHDL version of the async FIFO, proven equal to the SystemVerilog one

**What was built.** `rtl/vhdl/stream_cdc_fifo.vhd` is `stream_cdc_fifo` in
VHDL-2008, written to be a drop-in replacement: same entity name, ports,
generics, and the same registers under the same names. The two-clock top
builds with either (`make vivado-vhdl`).

**Why keep the same register names?** Equivalence checking by name is then
direct. EQY (with GHDL's Yosys plugin on the VHDL side and yosys-slang on the
SystemVerilog side) matches every register bit, including the 16 memory words
once both memories are mapped to registers, and proves each partition by
induction. A proof that the two designs are equivalent carries the
SystemVerilog FIFO's formal proof and its tests over to the VHDL.

**Why still run the cocotb tests on it?** The equivalence check compares the
designs as Yosys reads them, through two different front ends; simulation
with GHDL checks the VHDL as a VHDL simulator elaborates it. The same test
module runs unchanged on both languages, and the VHDL mutants (the same four
defects as the SystemVerilog mutants) must fail both the tests and the
equivalence check, so neither can pass vacuously.

**Why does the VHDL write repeat the reset term?** The memory write sits in
its own process so synthesis sees a plain RAM, enabled by `s_valid and
s_ready_i`, where `s_ready_i` already includes `not s_rst`. EQY cuts the
designs at matched signals, so it treated `s_ready` as a free input and found
a state where the VHDL wrote during reset and the SystemVerilog (whose write
is in the reset's `else` branch) did not. Repeating `s_rst = '0'` in the VHDL
write makes the two structurally the same; synthesis removes the redundant
term.

## Bugs found by formal verification

Both were found by the SymbiYosys checks in `formal/`, fixed in separate
commits, and re-checked by the same properties (`make formal`) and the full
regression. `scripts/formal-before-fix.sh` re-runs the proofs on the RTL from
before each fix to show that they catch the bug.

### engine_control read decode used the live address

**What was wrong.** The AR handshake latches the read address into `ar_address`,
and the read data is computed on the next cycle. The fixed registers were decoded
from `ar_address`, but the `default:` branch (queue delays, rules, every ring
register, drop snapshots) compared the live input `s_araddr`. AXI allows a master
to change `ARADDR` once the handshake is done, so a read could return a different
register's data, or OKAY for an unmapped address.

**How it was found.** The read-data properties check the response against the
address captured at the AR handshake. While the harness was being written,
`ap_read_unmapped` (a read of an unmapped address returns SLVERR) failed: the
master read `0x3ffc`, moved `ARADDR` to `0xc00` the next cycle, and received OKAY
with the drop-snapshot data. On the pre-fix RTL the committed proof fails the
same way at step 4, on `ap_read_sq_producer0`
([before_fix/summary.txt](results/formal/before_fix/summary.txt),
[log](results/formal/before_fix/engine_control_prove.log)). The UVM agent holds
the address until the response, so simulation never exercised this.

**The fix.** Those 17 comparisons now use `ar_address`, like the rest of the
decoder (commit "engine_control: decode reads from the address latched at the AR
handshake"). No timing change: `ar_address` is already a register.

### pcie_requester could truncate an MRd on completion timeout

**What was wrong.** The completion timer runs in both `R_SEND` and `R_WAIT`, so it
also counts while the request TLPs are still being transmitted. If it expired just
after an MRd's first beat was accepted, the read went to `R_DONE` and the rest of
that TLP was never sent; the next request then started a new `sop` on the same
stream. With the real 65,536-cycle timeout this needs a very long transmit stall,
but the result is a malformed TLP on the link.

**How it was found.** The harness tracks MRd framing on the TX stream. With the
timeout set to 8 cycles for the proof, `ap_mrd_framing` (a new `sop` only after the
previous `eop`) failed in four-tag mode: the timeout fired in the same cycle as the
second MRd's first beat. On the pre-fix RTL the committed proof fails it at step 14
([log](results/formal/before_fix/pcie_requester_prove.log)).

**The fix.** The timeout now waits while a TLP is in progress or its first beat is
being accepted (`!(read_state==R_SEND && (read_beat!=0 || r_ready))`). The timer
keeps counting, so it fires as soon as the current TLP is complete, at most one TLP
later (commit "pcie_requester: do not time out a read in the middle of an MRd
TLP").

