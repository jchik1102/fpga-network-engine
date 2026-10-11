#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/models
.venv/bin/python -m pytest tests/test_models.py -v --junitxml=build/models/junit.xml 2>&1 | tee build/models/pytest.log
