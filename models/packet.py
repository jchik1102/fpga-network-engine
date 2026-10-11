from dataclasses import dataclass
from enum import IntEnum


class Drop(IntEnum):
    NONE = 0
    WATCHDOG = 1
    BAD_MASK = 2
    OVERSIZE = 3
    RUNT = 4
    MALFORMED = 5
    FULL = 6


@dataclass(frozen=True)
class Rule:
    enabled: bool = False
    queue: int = 0
    src_ip: int = 0
    src_mask: int = 0
    dst_ip: int = 0
    dst_mask: int = 0
    src_port: int | None = None
    dst_port: int | None = None

    def matches(self, fields):
        src, dst, sport, dport = fields
        return (self.enabled and (src & self.src_mask) == (self.src_ip & self.src_mask)
                and (dst & self.dst_mask) == (self.dst_ip & self.dst_mask)
                and (self.src_port is None or sport == self.src_port)
                and (self.dst_port is None or dport == self.dst_port))


@dataclass(frozen=True)
class Classification:
    drop: Drop = Drop.NONE
    supported: bool = False
    queue: int = 0
    rule: int = 15
    fields: tuple[int, int, int, int] = (0, 0, 0, 0)


def classify(frame: bytes, rules=(), default_queue=0, *, bad_mask=False,
             watchdog=False, reserved=(True,) * 4) -> Classification:
    if not 0 <= default_queue < 4 or len(rules) > 8:
        raise ValueError("invalid classifier configuration")
    reason = (Drop.WATCHDOG if watchdog else Drop.BAD_MASK if bad_mask else
              Drop.OVERSIZE if len(frame) > 1514 else Drop.RUNT if len(frame) < 60 else Drop.NONE)
    if reason:
        return Classification(drop=reason)
    queue, matched, fields, supported = default_queue, 15, (0, 0, 0, 0), False
    number = lambda lo, hi: int.from_bytes(frame[lo:hi], "big")
    if number(12, 14) == 0x0800:
        ihl = (frame[14] & 15) * 4
        total = number(16, 18)
        if frame[14] >> 4 != 4 or ihl < 20 or 14 + ihl > len(frame) or total < ihl or total > len(frame) - 14:
            return Classification(drop=Drop.MALFORMED)
        fragmented = bool(number(20, 22) & 0x3FFF)
        if ihl == 20 and not fragmented and frame[23] == 17:
            udp_length = number(38, 40)
            if total < 28 or udp_length < 8 or udp_length != total - 20:
                return Classification(drop=Drop.MALFORMED)
            supported = True
            fields = number(26, 30), number(30, 34), number(34, 36), number(36, 38)
            for index, rule in enumerate(rules):
                if not 0 <= rule.queue < 4:
                    raise ValueError("invalid queue")
                if rule.matches(fields):
                    queue, matched = rule.queue, index
                    break
    if not reserved[queue]:
        return Classification(drop=Drop.FULL)
    return Classification(supported=supported, queue=queue, rule=matched, fields=fields)


def beats(frame: bytes):
    if not frame:
        raise ValueError("empty frame")
    for offset in range(0, len(frame), 4):
        part = frame[offset:offset+4]
        yield int.from_bytes(part, "little"), (1 << len(part)) - 1, offset + 4 >= len(frame)


def observe_beats(accepted):
    data = bytearray()
    bad_mask = False
    ended = False
    for word, keep, last in accepted:
        if ended:
            raise ValueError("beat after TLAST")
        bad_mask |= keep not in (1, 3, 7, 15) or (not last and keep != 15)
        data.extend((word >> (8 * lane)) & 255 for lane in range(4) if keep & (1 << lane))
        ended = last
    return bytes(data), bool(bad_mask), ended
