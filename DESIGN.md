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

