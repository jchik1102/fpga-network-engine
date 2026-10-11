#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m venv .venv
if [[ -f requirements-lock.txt ]]; then
  .venv/bin/python -m pip install -r requirements-lock.txt
else
  .venv/bin/python -m pip install scapy pytest numpy matplotlib
  .venv/bin/python -m pip freeze > requirements-lock.txt
fi
