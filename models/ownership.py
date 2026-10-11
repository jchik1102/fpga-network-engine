from dataclasses import dataclass
from .abi import Descriptor


@dataclass
class Ring:
    producer: int = 0
    consumer: int = 0
    reserved: int = 0
    cq_producer: int = 0
    cq_consumer: int = 0

    @staticmethod
    def distance(a, b):
        return (a-b) & 0xFFFFFFFF


class HostMemory:
    def __init__(self, epoch=1):
        self.bytes = bytearray([0xA5]) * 0x100000
        self.epoch = epoch
        self.rings = {(r, q): Ring() for r in (False, True) for q in range(4)}
        self.owned = {}
        self.claimed = set()
        self.completed = set()

    def publish(self, replay, queue, descriptor: Descriptor):
        ring = self.rings[replay, queue]
        descriptor.validate(replay=replay, sequence=ring.producer, epoch=self.epoch)
        if ring.distance(ring.producer, ring.consumer) >= 32:
            raise ValueError("SQ full")
        for old in self.owned.values():
            for a in old.segments:
                for b in descriptor.segments:
                    if max(a.address,b.address) < min(a.address+a.length,b.address+b.length):
                        raise ValueError("payload already owned")
        key = replay, queue, descriptor.sequence, self.epoch
        if key in self.owned:
            raise ValueError("descriptor already owned")
        self.owned[key] = descriptor
        ring.producer = (ring.producer+1) & 0xFFFFFFFF
        return key

    def claim(self, replay, queue):
        ring = self.rings[replay, queue]
        if not ring.distance(ring.producer, ring.consumer):
            raise ValueError("SQ empty")
        if ring.distance(ring.cq_producer, ring.cq_consumer) + ring.reserved >= 64:
            raise ValueError("CQ full")
        key = replay, queue, ring.consumer, self.epoch
        if key not in self.owned or key in self.claimed:
            raise ValueError("invalid claim")
        self.claimed.add(key)
        ring.consumer = (ring.consumer+1) & 0xFFFFFFFF
        ring.reserved += 1
        return key

    def completion_visible(self, key):
        if key not in self.claimed or key in self.completed:
            raise ValueError("false or duplicate completion")
        ring = self.rings[key[:2]]
        self.completed.add(key)
        ring.reserved -= 1
        ring.cq_producer = (ring.cq_producer+1) & 0xFFFFFFFF

    def reclaim(self, key):
        if key not in self.completed:
            raise ValueError("premature reclaim")
        self.completed.remove(key)
        self.claimed.remove(key)
        del self.owned[key]
        ring = self.rings[key[:2]]
        ring.cq_consumer = (ring.cq_consumer+1) & 0xFFFFFFFF

    def recover(self, new_epoch, *, transport_quiescent):
        if not transport_quiescent or new_epoch == self.epoch:
            raise ValueError("unsafe recovery")
        memory = self.bytes
        self.__init__(new_epoch)
        self.bytes = memory
