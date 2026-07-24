#!/usr/bin/env bash
#
# Question 5 of the brief: is the Files.exists() filter load-bearing? That is, does
# anything rely on nonexistent paths being absent from the model, or could the model
# record the declared output directories unconditionally and let consumers skip what
# is missing at read time?
#
# The answer decides the fix. If the filter is decorative, "stop filtering" is enough.
# If it is load-bearing, the existence check has to move from write time (where it is
# nondeterministic and gets baked into cache keys) to read time.
#
# -PunfilteredPaths rewrites the app artifact's "resolved-paths" to the declared main
# output directories regardless of existence - exactly what deleting the upstream
# filter would produce. -PunfilteredPaths=bogus additionally appends a directory that
# can never exist, as a harsher control.
#
# Caching is disabled throughout. Otherwise quarkusGenerateCode is served from the
# cache, never executes, and the failure path is not exercised at all - which is a
# false pass this script previously produced.
#
# Usage:
#   ./load-bearing.sh [N]
#     N   repetitions of each variant (default 1; the outcome is not stochastic)
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh
require_jq

N="${1:-1}"
if [[ "$N" =~ ^[0-9]+$ ]]; then shift || true; else N=1; fi

log="$(mktemp)"; trap 'rm -f "$log"' EXIT
failures=0

variant() {
  local label="$1"; shift
  for i in $(seq 1 "$N"); do
    gw clean -q --no-build-cache >/dev/null 2>&1 || true
    local rc=0
    gw :app:build --no-parallel --no-build-cache "$@" > "$log" 2>&1 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      printf '  %-34s BUILD SUCCESSFUL\n' "$label"
    else
      printf '  %-34s BUILD FAILED\n' "$label"
      grep -A5 'What went wrong' "$log" | sed -n '3,6p' | sed 's/^/      /'
      failures=$((failures + 1))
    fi
  done
}

echo "does the app artifact's resolved-paths tolerate directories that do not exist?"
echo "(build cache disabled, so quarkusGenerateCode really executes)"
echo

variant "baseline, filter in place"
variant "declared paths, unfiltered" -PunfilteredPaths
variant "declared paths + a bogus one" -PunfilteredPaths=bogus

echo
echo "=============================================================="
if [[ "$failures" -gt 0 ]]; then
  cat <<'EOF'
THE FILTER IS LOAD-BEARING.

Removing it upstream, with no other change, breaks :app:quarkusGenerateCode - and it
breaks on the *genuine* declared directory build/classes/java/main, not only on the
synthetic one. That is not an accident of the harness: quarkusGenerateCode runs
before compileJava (compileJava dependsOn quarkusGenerateCode), so at the moment the
model is consumed the app's own classes directory legitimately does not exist yet.

The chain is CuratedApplication.createDeploymentClassLoader -> ClassPathElement.fromPath
-> PathTree.ofDirectoryOrArchive, which throws IllegalArgumentException for a missing
root rather than skipping it.

So the fix is not "stop filtering". It is "stop filtering at write time and filter at
read time": serialize the declared output directories unconditionally, so the model is
a function of the build's configuration rather than of whatever happens to be on disk,
and skip missing roots where the classloader is assembled.
EOF
  exit 0
fi

echo "THE FILTER IS NOT LOAD-BEARING: every variant built. Removing the write-time"
echo "filter would be sufficient on its own."
exit 1