#!/usr/bin/env bash
#
# Reproduce the nondeterministic ordering of the "local-projects" array in the
# serialized Quarkus application model.
#
# Each run uses `--no-daemon` so it starts a fresh JVM. The iteration order of the
# JDK immutable set backing "local-projects" is salted per JVM, so the serialized
# bytes (and hash) flip between runs even though every real input is identical.
#
# Usage:
#   ./repro.sh [N] [extra gradle args...]
#     N   number of fresh-JVM runs (default 8)
#
#   ./repro.sh 8               # reproduce the bug, expect multiple orderings
#   ./repro.sh 8 -PsortModel   # apply the stopgap sort, expect a single ordering
set -euo pipefail

cd "$(dirname "$0")"

N="${1:-8}"
if [[ "$N" =~ ^[0-9]+$ ]]; then shift || true; else N=8; fi

MODEL="app/build/quarkus/application-model/quarkus-app-test-model.dat"
TASK=":app:quarkusGenerateTestAppModel"

# Collect orderings in a temp file so this stays portable to the default macOS
# bash 3.2 (no associative arrays).
orders_file="$(mktemp)"
trap 'rm -f "$orders_file"' EXIT

for i in $(seq 1 "$N"); do
  ./gradlew --no-daemon "$TASK" --rerun-tasks -q "$@"
  if [[ ! -f "$MODEL" ]]; then
    echo "model not found: $MODEL" >&2
    exit 2
  fi
  order="$(grep -o '"local-projects":\[[^]]*\]' "$MODEL")"
  hash="$(shasum "$MODEL" | awk '{print $1}')"
  printf 'run %2d: hash=%s %s\n' "$i" "$hash" "$order"
  echo "$order" >> "$orders_file"
done

distinct="$(sort -u "$orders_file" | grep -c .)"

echo
if [[ "$distinct" -gt 1 ]]; then
  echo "NONDETERMINISTIC: $distinct distinct orderings across $N fresh JVMs"
  exit 0
else
  echo "DETERMINISTIC: 1 ordering across $N fresh JVMs"
  echo "  - with -PsortModel, the stopgap sort made it deterministic (expected)."
  echo "  - without it, this run was luck. Each fresh JVM randomizes the order, so run again."
  exit 1
fi