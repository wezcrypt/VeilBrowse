#!/usr/bin/env bash
# Packages the tracked source tree (no build output, no secrets) into dist/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist/WezCryptSecureStudio-source.zip}"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
cd "$ROOT"
git ls-files -z | xargs -0 zip -q -X "$OUT"
echo "wrote $OUT ($(du -h "$OUT" | cut -f1), $(git ls-files | wc -l) files)"
