"""cocotb tests for rtl/stream_cdc_fifo.sv with two unrelated clocks
(run by tb/cocotb/test_cocotb.py).

A driver on s_clk offers random 37-bit words with random gaps, a consumer on
m_clk applies random backpressure, and a scoreboard checks every word arrives
once, in order, unchanged. Each test uses a different clock pair (similar
rates, slow reader, fast reader) with a random phase offset, and must reach
the flow-control edge it targets: full (s_ready low with data offered) for the
slow reader, empty (m_valid low after the first word) for the fast reader, and
both for similar rates.
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

WIDTH = 37


async def reset(dut, s_period, m_period):
    dut.s_rst.value = 1
    dut.m_rst.value = 1
    dut.s_valid.value = 0
    dut.s_data.value = 0
    dut.m_ready.value = 0
    await Timer(3 * max(s_period, m_period), unit="ns")
    await FallingEdge(dut.s_clk)
    dut.s_rst.value = 0
    await FallingEdge(dut.m_clk)
    dut.m_rst.value = 0


async def produce(dut, rng, words, stats, p_valid):
    sent = 0
    while sent < len(words):
        await FallingEdge(dut.s_clk)
        if dut.s_valid.value == 0 and rng.random() < p_valid:
            dut.s_data.value = words[sent]
            dut.s_valid.value = 1
        await RisingEdge(dut.s_clk)
        if dut.s_valid.value == 1:
            if dut.s_ready.value == 1:
                sent += 1
                await FallingEdge(dut.s_clk)
                dut.s_valid.value = 0
            else:
                stats["full"] += 1
    await FallingEdge(dut.s_clk)
    dut.s_valid.value = 0


async def consume(dut, rng, count, stats, p_ready):
    got = []
    while len(got) < count:
        await FallingEdge(dut.m_clk)
        dut.m_ready.value = int(rng.random() < p_ready)
        await RisingEdge(dut.m_clk)
        if dut.m_valid.value == 1 and dut.m_ready.value == 1:
            got.append(int(dut.m_data.value))
        elif dut.m_valid.value == 0 and got:
            stats["empty"] += 1
    return got


async def stream(dut, seed, s_period, m_period, count, p_valid, p_ready, need):
    rng = random.Random(seed)
    Clock(dut.s_clk, s_period, unit="ns").start()
    await Timer(rng.randint(1, m_period - 1), unit="ns")     # random phase between the clocks
    Clock(dut.m_clk, m_period, unit="ns").start()
    await reset(dut, s_period, m_period)
    words = [rng.getrandbits(WIDTH) for _ in range(count)]
    stats = {"full": 0, "empty": 0}
    producer = cocotb.start_soon(produce(dut, rng, words, stats, p_valid))
    got = await consume(dut, rng, count, stats, p_ready)
    await producer
    for i, (want, have) in enumerate(zip(words, got)):
        assert have == want, f"word {i}: got {have:#x}, want {want:#x}"
    for condition in need:   # the flow-control edge this clock pair is meant to exercise
        assert stats[condition] > 0, f"FIFO never {condition}"
    dut._log.info("CDC_STREAM_PASS s_clk=%dns m_clk=%dns words=%d full_cycles=%d empty_cycles=%d",
                  s_period, m_period, count, stats["full"], stats["empty"])


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def similar_rates(dut):
    """10 ns write clock, 13 ns read clock, bursty on both sides."""
    await stream(dut, 1, 10, 13, 3000, p_valid=0.8, p_ready=0.6, need=("full", "empty"))


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def slow_reader(dut):
    """7 ns write, 31 ns read: the FIFO fills and the writer is held off."""
    await stream(dut, 2, 7, 31, 1500, p_valid=0.9, p_ready=0.9, need=("full",))


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def fast_reader(dut):
    """29 ns write, 6 ns read: the FIFO runs empty between words."""
    await stream(dut, 3, 29, 6, 1500, p_valid=0.9, p_ready=0.7, need=("empty",))
