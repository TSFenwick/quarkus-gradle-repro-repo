#!/usr/bin/env bash
#
# Shared helpers for the resolved-paths reproduction scripts.
#
# All three scripts vary *tree state* and *requested task graph* while holding the
# JVM constant, which is the opposite of the local-projects-order branch (that one
# varies the JVM). Holding the JVM constant is what isolates this bug from
# quarkusio/quarkus#55619, whose "local-projects" ordering is salted per JVM.
#
# Note the main model needs no such care on its own: it lists exactly one local
# project (the app), so its "local-projects" array cannot reorder. assert_one_local
# checks that invariant rather than assuming it.

MAIN_MODEL="app/build/quarkus/application-model/quarkus-app-model.dat"
TEST_MODEL="app/build/quarkus/application-model/quarkus-app-test-model.dat"
BUILD_MODEL="app/build/quarkus/application-model/quarkus-app-model-build.dat"

APP_COORDS="org.example:app::jar:1.0.0-SNAPSHOT"

# resolved_paths <model.dat>
# The app artifact's "resolved-paths", shortened to build-relative form so the
# output is legible and machine-independent.
resolved_paths() {
  jq -c --arg c "$APP_COORDS" \
    '[.. | objects | select(.["maven-artifact"]? == $c) | .["resolved-paths"]][0]
     | map(sub(".*/app/build/"; "build/"))' "$1"
}

# model_hash <model.dat>
model_hash() { shasum "$1" | awk '{print $1}'; }

# local_projects <model.dat>
local_projects() { jq -c '.["local-projects"]' "$1"; }

# assert_one_local <model.dat>
# The isolation check. If the model ever lists more than one local project its
# order can move per-JVM (#55619) and hashes stop being attributable to this bug.
assert_one_local() {
  local n
  n="$(jq '.["local-projects"] | length' "$1")"
  if [[ "$n" -gt 1 ]]; then
    echo "  WARNING: $1 lists $n local projects; its byte order can also move per-JVM (#55619)." >&2
    echo "           Compare resolved-paths rather than hashes for this file." >&2
  fi
}

# gw <args...>
# Always the same daemon, so the JVM (and therefore the #55619 salt) is held fixed.
gw() { ./gradlew "$@"; }

require_jq() {
  command -v jq >/dev/null 2>&1 || { echo "this harness needs jq on PATH" >&2; exit 2; }
}