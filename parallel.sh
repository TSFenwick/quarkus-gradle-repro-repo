#!/usr/bin/env bash
#
# Probe whether the resolved-paths value is a *scheduling* race rather than a
# function of tree state and graph shape.
#
# QuarkusApplicationModelTask has no ordering relationship with :app:processResources
# (neither dependsOn nor mustRunAfter), yet it reads whether that task's output
# directory exists. Two unordered tasks that communicate through the filesystem is
# the shape of a race. Gradle's default executor happens to schedule
# processResources first, but nothing in the build contract requires it.
#
# Each iteration cleans and rebuilds, so if the scheduler ever picks the other order
# the recorded resolved-paths value changes. A single distinct value over N runs is
# evidence that the ordering is stable in practice on this Gradle version, not proof
# that it is guaranteed.
#
# Usage:
#   ./parallel.sh [N] [extra gradle args...]
#     N   iterations per graph shape (default 8)
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh
require_jq

N="${1:-8}"
if [[ "$N" =~ ^[0-9]+$ ]]; then shift || true; else N=8; fi
EXTRA=("$@")

obs="$(mktemp)"; trap 'rm -f "$obs"' EXIT

probe() {
  local tag="$1"; shift
  local seen=""
  echo "### $tag"
  echo "    gradlew $*"
  for i in $(seq 1 "$N"); do
    gw clean -q >/dev/null
    gw "$@" -q "${EXTRA[@]+"${EXTRA[@]}"}" >/dev/null 2>&1 || true
    local p
    p="$(resolved_paths "$MAIN_MODEL" 2>/dev/null || echo '<no model>')"
    echo "$tag|$p" >> "$obs"
    case "$seen" in
      *"$p"*) ;;
      *) seen="$seen$p"; printf '  new value on run %d: %s\n' "$i" "$p" ;;
    esac
  done
  local d
  d="$(grep "^$tag|" "$obs" | cut -d'|' -f2 | sort -u | grep -c .)"
  printf '  %d distinct value(s) over %d runs\n\n' "$d" "$N"
}

echo "probing for scheduling sensitivity of the app artifact's resolved-paths"
echo "cores: $(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '?')"
echo

probe "parallel, consumer graph"        :app:quarkusGenerateCode --parallel
probe "parallel, full build graph"      :app:build --parallel -x test
probe "parallel + max-workers=2"        :app:build --parallel --max-workers=2 -x test
probe "sequential control"              :app:build --no-parallel -x test

echo "=============================================================="
total="$(cut -d'|' -f2 "$obs" | sort -u | grep -c .)"
racy=0
for tag in "parallel, consumer graph" "parallel, full build graph" "parallel + max-workers=2"; do
  d="$(grep "^$tag|" "$obs" | cut -d'|' -f2 | sort -u | grep -c .)"
  [[ "$d" -gt 1 ]] && racy=1
done

if [[ "$racy" -eq 1 ]]; then
  echo "RACE: a single graph shape produced more than one resolved-paths value under"
  echo "parallel execution. Directory presence depends on scheduling."
  exit 0
fi

echo "NO RACE OBSERVED: each graph shape produced exactly one resolved-paths value"
echo "over $N runs, so on this Gradle version the scheduler's order is stable."
echo "($total distinct value(s) across the graph shapes probed here; all of these"
echo "shapes include processResources, so they agree. repro.sh is what varies the"
echo "graph enough to move the value.)"
echo
echo "This is a negative result and should be reported as one. The unordered"
echo "task pair is still a latent hazard: nothing in the build contract fixes the"
echo "order, so it can change with a Gradle version, a plugin, or an added task."
exit 1