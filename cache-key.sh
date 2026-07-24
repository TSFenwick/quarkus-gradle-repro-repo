#!/usr/bin/env bash
#
# Turn the model-bytes observation into a demonstrated cache miss.
#
# The serialized model is the `applicationModel` @InputFile of the cacheable
# :app:quarkusGenerateCode task. When the app artifact's "resolved-paths" moves,
# that task's build cache key moves with it, so builds that differ only in tree
# state or in the requested task graph cannot share cache entries.
#
# Same three scenarios as repro.sh, same daemon throughout:
#
#   A  clean tree, ":app:quarkusGenerateAppModel" first, then ":app:quarkusGenerateCode"
#      The narrow first invocation writes a model with no resolved paths. Directory
#      existence is not a declared input, so the model task is UP-TO-DATE in the
#      second invocation and the empty value survives into the consumer's key.
#      This is what a CI pipeline with a separate model/dependency step produces.
#   B  clean tree, ":app:quarkusGenerateCode" directly
#   C  warm tree, model regenerated (its output is deleted to force a rerun)
#
# As well as the key, the script records every input fingerprint Gradle appended,
# so the diff shows that `applicationModel` is the only input that moved.
#
# Usage:
#   ./cache-key.sh [N] [extra gradle args...]
#     N   number of repetitions per scenario (default 2)
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh
require_jq

N="${1:-2}"
if [[ "$N" =~ ^[0-9]+$ ]]; then shift || true; else N=2; fi
EXTRA=("$@")

TASK=":app:quarkusGenerateCode"
DEBUG=(-Dorg.gradle.caching.debug=true)

workdir="$(mktemp -d)"; trap 'rm -rf "$workdir"' EXIT
keys="$workdir/keys"

# fingerprints <raw-log>
# Reduce Gradle's caching-debug block for $TASK to "property=hash" lines. The
# classpath fingerprint line is thousands of characters, so only the summary hash
# is kept.
fingerprints() {
  awk -v marker="Build cache key for task '$TASK' is" '
    # Each task block starts with its implementation line, so restart the buffer there.
    /Appending implementation to build cache key/ { buf = $0 "\n"; next }
    /Appending/                                   { buf = buf $0 "\n"; next }
    /Build cache key for task/ { if (index($0, marker)) printf "%s", buf; buf=""; next }
  ' "$1" | sed -E \
      -e "s/^Appending (input value fingerprint|input file fingerprints) for '([^']+)' to build cache key: ([0-9a-f]+).*/\2=\3/" \
      -e "s/^Appending (additional )?implementation to build cache key: .*@([0-9a-f]+)/implementation=\2/" \
      -e "s/^Appending output property name to build cache key: (.*)/output:\1=-/"
}

# task_outcome <log> -- "FROM-CACHE", "UP-TO-DATE", or "EXECUTED". Every grep here is
# guarded: an unmatched grep exits 1, which under `set -o pipefail` would abort the
# script rather than report a missing outcome.
task_outcome() {
  local line
  line="$(grep -oE "^> Task $TASK( .*)?$" "$1" | tail -1 || true)"
  line="${line#> Task $TASK}"
  line="${line# }"
  printf '%s' "${line:-EXECUTED}"
}

# task_key <log> -- the build cache key Gradle computed for $TASK, or "<none>".
task_key() {
  local k
  k="$(grep -oE "Build cache key for task '$TASK' is [0-9a-f]+" "$1" | awk '{print $NF}' | tail -1 || true)"
  printf '%s' "${k:-<none>}"
}

run_scenario() {
  local tag="$1" desc="$2" body="$3"
  echo "### $tag  $desc"
  for i in $(seq 1 "$N"); do
    gw clean -q "${EXTRA[@]+"${EXTRA[@]}"}" >/dev/null
    "$body" > "$workdir/$tag.log" 2>&1
    local key outcome paths
    key="$(task_key "$workdir/$tag.log")"
    outcome="$(task_outcome "$workdir/$tag.log")"
    paths="$(resolved_paths "$MAIN_MODEL")"
    printf '  run %d: cacheKey=%s  %-12s resolved-paths=%s\n' \
      "$i" "$key" "$outcome" "$paths"
    echo "$tag $key" >> "$keys"
  done
  fingerprints "$workdir/$tag.log" | sort > "$workdir/$tag.fp"
  assert_one_local "$MAIN_MODEL"
  echo
}

scenario_a() {
  gw :app:quarkusGenerateAppModel -q "${EXTRA[@]+"${EXTRA[@]}"}" >/dev/null
  gw "$TASK" "${DEBUG[@]}" "${EXTRA[@]+"${EXTRA[@]}"}"
}
scenario_b() {
  gw "$TASK" "${DEBUG[@]}" "${EXTRA[@]+"${EXTRA[@]}"}"
}
scenario_c() {
  gw :app:classes -q "${EXTRA[@]+"${EXTRA[@]}"}" >/dev/null
  rm -f "$MAIN_MODEL"   # force the model task to rerun, now against a warm tree
  gw "$TASK" "${DEBUG[@]}" "${EXTRA[@]+"${EXTRA[@]}"}"
}

CACHE_DIR=".gradle-build-cache"   # project-local, configured in settings.gradle.kts

echo "build cache key of $TASK, whose applicationModel input is $MAIN_MODEL"
echo "same daemon throughout, so the JVM (and #55619's set-ordering salt) is fixed"
echo "build cache: $CACHE_DIR (project-local, emptied before each section)"
echo

rm -rf "$CACHE_DIR"
run_scenario A "clean, narrow model invocation first, then the consumer" scenario_a
run_scenario B "clean, consumer directly" scenario_b
run_scenario C "warm tree, model regenerated" scenario_c

# Within a scenario the first run stores an entry and the second reads it back, so
# caching demonstrably works. The question is whether entries cross scenarios.
echo "### can one scenario reuse the entry another scenario stored?"
rm -rf "$CACHE_DIR"
gw clean -q "${EXTRA[@]+"${EXTRA[@]}"}" >/dev/null
scenario_c > "$workdir/reuse-c.log" 2>&1
echo "  populate cache with scenario C : $(task_outcome "$workdir/reuse-c.log") (stored)"
gw clean -q "${EXTRA[@]+"${EXTRA[@]}"}" >/dev/null
scenario_a > "$workdir/reuse-a.log" 2>&1
reuse_a="$(task_outcome "$workdir/reuse-a.log")"
if [[ "$reuse_a" == "EXECUTED" ]]; then
  echo "  then run scenario A            : EXECUTED (cache miss)"
else
  echo "  then run scenario A            : $reuse_a (unexpected - entry was reused)"
fi
echo "  identical sources, identical versions, one JVM - and still a miss."
echo

echo "### which inputs actually moved"
for pair in "A B" "B C"; do
  set -- $pair
  echo "  $1 vs $2:"
  if diff_out="$(diff "$workdir/$1.fp" "$workdir/$2.fp")"; then
    echo "    (no input fingerprints differ)"
  else
    printf '%s\n' "$diff_out" | grep -E '^[<>]' | sed 's/^/    /'
  fi
done
echo

echo "=============================================================="
distinct="$(awk '{print $2}' "$keys" | sort -u | grep -c .)"
echo "$distinct distinct cache keys for $TASK across 3 scenarios x $N runs"
echo

if [[ "$distinct" -gt 1 ]]; then
  echo "CACHE KEY UNSTABLE: $TASK gets $distinct different keys with identical sources,"
  echo "identical versions and one JVM. Any build whose key differs from the stored one"
  echo "misses the cache, and every other model consumer (quarkusGenerateCodeTests,"
  echo "quarkusAppPartsBuild, quarkusBuild, and every Test task) is keyed the same way."
  exit 0
else
  echo "CACHE KEY STABLE: 1 key across all scenarios. Unexpected on 3.36.3."
  exit 1
fi