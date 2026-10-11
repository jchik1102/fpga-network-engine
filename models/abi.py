import struct
from dataclasses import dataclass


@dataclass(frozen=True)
class Segment:
    address: int
    length: int


@dataclass(frozen=True)
class Descriptor:
    cookie: int
    sequence: int
    epoch: int
    timestamp: int
    length: int
    segments: tuple[Segment, ...]

    def encode(self):
        if not 1 <= len(self.segments) <= 4:
            raise ValueError("segment count")
        header = struct.pack("<QIIQHBBI", self.cookie, self.sequence, self.epoch,
                             self.timestamp, self.length, len(self.segments), 0, 0)
        return header + b"".join(struct.pack("<IHH", s.address, s.length, 0) for s in self.segments) + bytes(8*(4-len(self.segments)))

    @classmethod
    def decode(cls, raw):
        if len(raw) != 64:
            raise ValueError("descriptor extent")
        cookie, seq, epoch, tick, length, n, flags, reserved = struct.unpack_from("<QIIQHBBI", raw)
        if flags or reserved or not 1 <= n <= 4:
            raise ValueError("descriptor header")
        segments = []
        for i in range(4):
            address, size, pad = struct.unpack_from("<IHH", raw, 32+8*i)
            if pad or (i >= n and (address or size)):
                raise ValueError("reserved SG")
            if i < n:
                segments.append(Segment(address, size))
        return cls(cookie, seq, epoch, tick, length, tuple(segments))

    def validate(self, *, replay, sequence, epoch, packet_length=None):
        low, high = (0x80000, 0xC0000) if replay else (0x40000, 0x80000)
        if self.sequence != sequence or self.epoch != epoch:
            raise ValueError("sequence/epoch")
        if not replay and self.timestamp:
            raise ValueError("capture timestamp reserved")
        if not 60 <= self.length <= (1514 if replay else 2048):
            raise ValueError("length")
        if not 1 <= len(self.segments) <= 4:
            raise ValueError("segment count")
        if sum(s.length for s in self.segments) != self.length:
            raise ValueError("capacity sum")
        for i, seg in enumerate(self.segments):
            if seg.address % 8 or not 0 < seg.length <= 65535 or (i+1 < len(self.segments) and seg.length % 8):
                raise ValueError("segment alignment/length")
            if not low <= seg.address < seg.address + seg.length <= high:
                raise ValueError("pool bounds/overflow")
            for other in self.segments[:i]:
                if max(other.address, seg.address) < min(other.address+other.length, seg.address+seg.length):
                    raise ValueError("segment overlap")
        if packet_length is not None and self.length < packet_length:
            raise ValueError("insufficient capacity")


@dataclass(frozen=True)
class Completion:
    cookie: int
    sequence: int
    epoch: int
    timestamp: int
    length: int
    status: int
    queue: int
    auxiliary: int = 0

    def encode(self):
        return struct.pack("<QIIQHBBI", self.cookie, self.sequence, self.epoch,
                           self.timestamp, self.length, self.status, self.queue, self.auxiliary)

    @classmethod
    def decode(cls, raw):
        if len(raw) != 32:
            raise ValueError("completion extent")
        return cls(*struct.unpack("<QIIQHBBI", raw))


def bursts(address, size):
    if address % 8 or size <= 0:
        raise ValueError("invalid AXI range")
    while size:
        count = min(size, 128, 4096 - address % 4096)
        beats = (count + 7) // 8
        yield address, beats, (1 << (count - 8*(beats-1))) - 1
        address += count
        size -= count
