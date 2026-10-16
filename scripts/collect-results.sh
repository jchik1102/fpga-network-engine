#!/usr/bin/env bash
# Copy the logs and reports that back the README numbers from build/ into
# results/, with a provenance file. Run after scripts/run-all.ps1.
set -euo pipefail
cd "$(dirname "$0")/.."
out=results
mkdir -p "$out/regression" "$out/fit"
cp build/regression/*.log build/regression/summary.txt "$out/regression/"
cp build/comparison_s*.json "$out/" 2>/dev/null || true
for top in engine_axi engine_pcie; do
  src=build/fit/$top
  [[ -d $src ]] || continue
  mkdir -p "$out/fit/$top"
  cp "$src"/output_files/${top}_fit.{fit.summary,map.summary,sta.summary,sta.rpt} \
     "$src"/{result.txt,sta-paths.log,path_setup_worst.txt,path_hold_worst.txt} "$out/fit/$top/"
done
{
  echo "collected: $(date -Iseconds)"
  echo "commit: $(git rev-parse HEAD)$(git -c core.autocrlf=true diff --quiet HEAD -- rtl tb host models scripts constraints || echo ' (+ uncommitted changes)')"
  echo "summary.txt written: $(date -Iseconds -r build/regression/summary.txt)"
} > "$out/PROVENANCE.txt"
echo "COLLECTED into $out/"
