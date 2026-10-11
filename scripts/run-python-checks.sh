#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/setup/python
.venv/bin/python -m pip check | tee build/setup/python/pip-check.txt
.venv/bin/python -m pytest setup_checks/test_setup.py -v --junitxml=build/setup/python/junit.xml 2>&1 | tee build/setup/python/pytest.log
