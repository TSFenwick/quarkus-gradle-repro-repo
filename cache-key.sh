#!/usr/bin/env bash
#
# Show the downstream consequence of the nondeterministic model. The serialized
# model is an input of tasks that consume it, so when its bytes flip between JVMs
# the build cache key of those tasks flips too, and they miss the build cache even
# though every real input is identical.
#
# This runs a cacheable model consumer (quarkusGenerateCodeTests, which takes the
# test model as an applicationModel @InputFile) across N fresh JVMs and prints the
# build cache key Gradle computes for it each time.
#
# Usage:
#   ./cache-key.sh [N] [extra gradle args...]
#     N   number of fresh-JVM runs (default 6)
#
#   ./cache-key.sh 6               # expect the key to flip with the model order
#   ./cache-key.sh 6 -PsortModel   # the stopgap sort, expect one stable key
set -euo pipefail

cd "$(dirname "$0")"

N="${1:-6}"
if [[ "$N" =~ ^[0-9]+$ ]]; then shift || true; else N=6; fi

TASK=":app:quarkusGenerateCodeTests"
MODEL="app/build/quarkus/application-model/quarkus-app-test-model.dat"

keys_file="$(mktemp)"
trap 'rm -f "$keys_file"' EXIT

for i in $(seq 1 "$N"); do
  out="$(./gradlew --no-daemon "$TASK" --rerun-tasks -Dorg.gradle.caching.debug=true "$@" 2>&1)"
  key="$(printf '%s\n' "$out" | grep -oE "Build cache key for task '$TASK' is [0-9a-f]+" | awk '{print $NF}' | tail -1)"
  order="$(grep -o '"local-projects":\[[^]]*\]' "$MODEL")"
  printf 'run %2d: cacheKey=%s %s\n' "$i" "${key:-<none>}" "$order"
  echo "$key" >> "$keys_file"
done

distinct="$(sort -u "$keys_file" | grep -c .)"

echo
if [[ "$distinct" -gt 1 ]]; then
  echo "CACHE KEY UNSTABLE: $distinct distinct keys for $TASK across $N fresh JVMs"
  echo "Any build whose key differs from the stored one misses the build cache."
  exit 0
else
  echo "CACHE KEY STABLE: 1 key for $TASK across $N fresh JVMs"
  echo "  - with -PsortModel, the stopgap sort made it stable (expected)."
  echo "  - without it, this run was luck. Each fresh JVM randomizes the order, so run again."
  exit 1
fi