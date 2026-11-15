#!/usr/bin/env python3
"""List the RTL lines that no bench executes.

Each bench's code-coverage summary (results/code-coverage/<bench>_s<seed>.txt)
lists the lines of each module that never executed in that bench. A line is
reported here only if it is in that list for every bench and seed whose
design contains the module. Writes results/code-coverage/never_executed.txt.
"""
import collections
import glob
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
reports = sorted(glob.glob(str(ROOT / 'results/code-coverage/*_s*.txt')))
missing = collections.defaultdict(dict)
present = collections.defaultdict(set)
source_of = {}
for report in reports:
    text = Path(report).read_text().replace('\r', '')
    for match in re.finditer(r'^(\w+)\s+\d+\s+\d+/\d+', text, re.M):
        if match.group(1) != 'TOTAL':
            present[match.group(1)].add(report)
    for match in re.finditer(r'^(\w+) \((rtl/[\w./]+)\): ([\d, ]+)$', text, re.M):
        missing[match.group(1)][report] = {int(n) for n in match.group(3).split(',')}
        source_of[match.group(1)] = match.group(2)
lines = []
for module in sorted(present):
    never = set.intersection(*[missing[module].get(report, set()) for report in present[module]])
    if not never:
        continue
    source = (ROOT / source_of[module]).read_text().replace('\r', '').split('\n')
    lines += [f'{source_of[module]}:{n}: {source[n - 1].strip()}' for n in sorted(never)]
out = ROOT / 'results/code-coverage/never_executed.txt'
out.write_text(f'RTL lines that no bench executes (in the never-executed list of every one of the {len(reports)} '
               'reports whose design contains the module):\n' + '\n'.join(lines) + f'\nNEVER_EXECUTED lines={len(lines)}\n',
               newline='\n')
print(out.read_text(), end='')
