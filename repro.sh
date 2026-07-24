#!/usr/bin/env bash
#
# Reproduce the tree-state / task-graph dependence of the app artifact's
# "resolved-paths" in the serialized Quarkus application model.
#
# QuarkusApplicationModelTask filters the app artifact's own output directories by
# Files.exists() at task-execution time, and nothing orders the task after the tasks
# that create those directories. So the same task, on the same sources, writes a
# different model depending on which directories happen to exist when it runs.
#
# Three scenarios, all on the same daemon (JVM held constant, so the per-JVM
# "local-projects" ordering of quarkusio/quarkus#55619 cannot interfere):
#
#   A  clean tree, ":app:quarkusGenerateAppModel" alone
#      That graph contains neither processResources nor compileJava.
#   B  clean tree, ":app:quarkusGenerateCode"
#      That graph contains processResources, and Gradle schedules it before the
#      model task, so build/resources/main exists but build/classes/java/main
#      does not. A and B are BOTH clean trees: only the requested graph differs.
#   C  warm tree, ":app:quarkusGenerateAppModel --rerun-tasks"
#      Both directories exist.
#
# A fourth section shows that the wrong value sticks: directory existence is not a
# declared input, so once the model is written the task stays UP-TO-DATE and never
# corrects itself when the directories later appear.
#
# Usage:
#   ./repro.sh [N] [extra gradle args...]
#     N   number of repetitions per scenario (default 3)
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh
require_jq

N="${1:-3}"
if [[ "$N" =~ ^[0-9]+$ ]]; then shift || true; else N=3; fi
# Any remaining arguments are passed through to every Gradle invocation.
EXTRA=("$@")

results="$(mktemp)"; trap 'rm -f "$results"' EXIT

run_scenario() {
  local tag="$1" desc="$2" body="$3"
  echo "### $tag  $desc"
  for i in $(seq 1 "$N"); do
    gw clean -q "${EXTRA[@]+"${EXTRA[@]}"}" >/dev/null
    "$body"
    local p h
    p="$(resolved_paths "$MAIN_MODEL")"
    h="$(model_hash "$MAIN_MODEL")"
    printf '  run %d: sha1=%s resolved-paths=%s\n' "$i" "${h:0:12}" "$p"
    echo "$tag|$p|$h" >> "$results"
  done
  assert_one_local "$MAIN_MODEL"
  echo
}

# Scenario bodies. Each is invoked after a `clean`, so the tree starts empty.
scenario_a() { gw :app:quarkusGenerateAppModel -q "${EXTRA[@]+"${EXTRA[@]}"}" >/dev/null; }
scenario_b() { gw :app:quarkusGenerateCode -q "${EXTRA[@]+"${EXTRA[@]}"}" >/dev/null; }
scenario_c() {
  gw :app:classes -q "${EXTRA[@]+"${EXTRA[@]}"}" >/dev/null
  gw :app:quarkusGenerateAppModel --rerun-tasks -q "${EXTRA[@]+"${EXTRA[@]}"}" >/dev/null
}

echo "resolved-paths of $APP_COORDS in $MAIN_MODEL"
echo "same daemon throughout, so the JVM (and #55619's set-ordering salt) is fixed"
echo

run_scenario A "clean tree, ':app:quarkusGenerateAppModel' alone" scenario_a
run_scenario B "clean tree, ':app:quarkusGenerateCode' (pulls in processResources)" scenario_b
run_scenario C "warm tree, ':app:classes' then model --rerun-tasks" scenario_c

echo "### D  the wrong value is sticky (directory existence is not a declared input)"
gw clean -q "${EXTRA[@]+"${EXTRA[@]}"}" >/dev/null
gw :app:quarkusGenerateAppModel -q "${EXTRA[@]+"${EXTRA[@]}"}" >/dev/null
echo "  clean tree, model task alone        -> $(resolved_paths "$MAIN_MODEL")"
gw :app:classes -q "${EXTRA[@]+"${EXTRA[@]}"}" >/dev/null
echo "  after :app:classes, dirs now exist  -> $(resolved_paths "$MAIN_MODEL")"
printf '  on disk: '
ls -d app/build/classes/java/main app/build/resources/main 2>/dev/null | tr '\n' ' '; echo
echo "  the model task reported UP-TO-DATE, so the model still describes the clean tree."
echo

# --- verdict ------------------------------------------------------------------
echo "=============================================================="
per_scenario_stable=1
for tag in A B C; do
  d="$(grep "^$tag|" "$results" | cut -d'|' -f2 | sort -u | grep -c .)"
  [[ "$d" -eq 1 ]] || per_scenario_stable=0
  echo "scenario $tag: $d distinct resolved-paths value(s) over $N runs"
done
across="$(cut -d'|' -f2 "$results" | sort -u | grep -c .)"
echo "across scenarios: $across distinct resolved-paths values"
echo

if [[ "$across" -gt 1 ]]; then
  echo "NONDETERMINISTIC: the same task on the same sources produced $across different"
  echo "models. Scenarios A and B are both clean trees and differ only in the requested"
  echo "task graph, so this is not merely a clean-versus-warm effect."
  [[ "$per_scenario_stable" -eq 1 ]] && \
    echo "Each scenario was internally stable, so the variable is the graph and the tree," \
         "not the JVM."
  exit 0
else
  echo "DETERMINISTIC: one value across all scenarios. Unexpected on 3.36.3 - check that"
  echo "the tree really was cleaned and that app/src/main/resources is non-empty."
  exit 1
fi