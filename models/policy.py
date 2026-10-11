MASK64 = (1 << 64) - 1


def loss_word(seed: int, queue: int, sequence: int) -> int:
    if not 0 <= seed < 2**32 or not 0 <= sequence < 2**32 or not 0 <= queue < 4:
        raise ValueError("policy operand out of range")
    x = (seed ^ ((sequence * 2654435769) % 2**32) ^ ((queue * 2246822507) % 2**32))
    x ^= (x * 8192) % 2**32
    x ^= x // 131072
    return x ^ ((x * 32) % 2**32)


def lost(seed, queue, sequence, threshold):
    if not 0 <= threshold <= 2**32:
        raise ValueError("threshold must be 33-bit endpoint range")
    return loss_word(seed, queue, sequence) < threshold


def due_tick(start, captured, origin, delay, *, sequence=0, interval=None):
    delta = ((captured - origin) & MASK64) if interval is None else sequence * interval
    if not 0 <= delay < 2**63 or not 0 <= delta + delay < 2**63:
        raise ValueError("scheduling horizon exceeds half range")
    return (start + delta + delay) & MASK64


def eligible(now, due):
    return ((now - due) & MASK64) < 2**63


def lateness(now, due):
    if not eligible(now, due):
        raise ValueError("early departure")
    return (now - due) & MASK64
