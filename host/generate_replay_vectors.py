import json
import random
from pathlib import Path
from models.policy import due_tick, loss_word, lost


def main():
    rng = random.Random(20261010)
    cases = []
    gold = json.loads(Path("tests/fixtures/policy_vectors.json").read_text())
    for row in gold:
        for threshold in [0, row["word"], row["word"] + 1, 2**32]:
            cases.append((0, 1000, 130, 100, 0, 7, row["sequence"], row["seed"], row["queue"], threshold))
    for n in range(192):
        mode = n % 2
        sequence = rng.randrange(2**32) if n % 5 == 0 else rng.randrange(100)
        origin = rng.randrange(2**64)
        delta = rng.randrange(100000) if n % 7 else 2**63
        interval = rng.randrange(200) if n % 11 else 2**64 - 1
        delay = rng.randrange(10000) if n % 13 else 2**63
        cases.append((mode, rng.randrange(2**64), (origin + delta) % 2**64, origin,
                      interval, delay, sequence, rng.randrange(2**32), rng.randrange(4), rng.randrange(2**32 + 1)))
    cases += [(1, 0, 0, 0, 2**64-1, 2**64-1, 2**32-1, 0, 0, 0),
              (0, 2**64-10, 8, 0, 0, 1, 0, 0, 0, 1),
              (1, 2**64-10, 0, 0, 3, 1, 5, 17, 2, 2**32)]
    lines = [str(len(cases))]
    manifest = []
    for mode, start, captured, origin, interval, delay, seq, seed, q, threshold in cases:
        try:
            due = due_tick(start, captured, origin, delay, sequence=seq, interval=interval if mode else None)
            valid = 1
        except ValueError:
            due, valid = 0, 0
        word = loss_word(seed, q, seq)
        loss = int(lost(seed, q, seq, threshold))
        fields = [mode, start, captured, origin, interval, delay, seq, seed, q, threshold, valid, due, word, loss]
        lines.append(" ".join(f"{v:x}" for v in fields))
        manifest.append(fields)
    target = Path("build/replay")
    target.mkdir(parents=True, exist_ok=True)
    (target / "policy.txt").write_text("\n".join(lines) + "\n")
    (target / "policy.json").write_text(json.dumps({"seed": 20261010, "cases": manifest}, indent=2))
    print(f"Generated {len(cases)} replay policy cases")


if __name__ == "__main__":
    main()
