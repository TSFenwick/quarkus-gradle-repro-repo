# Repro: nondeterministic `local-projects` order in the serialized Quarkus application model

The Quarkus Gradle plugin serializes the application model to
`app/build/quarkus/application-model/quarkus-app-test-model.dat`. That file is a
content-hashed build-cache input of every `Test` task (and of `quarkusGenerateCode*`,
`quarkusAppPartsBuild`, and `quarkusBuild`). It is **not byte-stable across JVMs**:
the `local-projects` array is ordered differently in different JVMs, so the model
hash changes and the build-cache key of every consumer task is busted.

## Root cause

`DefaultApplicationModel` stores the reloadable workspace modules as

```java
this.localProjectArtifacts = Set.copyOf(builder.reloadableWorkspaceModules);
```

`Set.copyOf(...)` returns a JDK immutable set whose iteration order is **salted per
JVM** (`java.util.ImmutableCollections`, `SALT32L`, seeded from `System.nanoTime()`
at class-init). `ApplicationModel.asMap()` serializes that set directly under the
`local-projects` key, so whenever the model contains 2+ local projects the array
order is effectively a coin flip per JVM.

A multi-module test model always has 2+ entries — the module itself plus each local
project dependency — so this is the common case. A long-lived Gradle daemon reuses
one JVM and masks the problem locally; fresh-JVM CI builds miss the shared build
cache on essentially every run.

## This monorepo

`main` is a plain buildable multi-module monorepo; this branch adds the repro
harness on top. The relevant structure:

```
app/          Quarkus REST app; implementation(project(":lib-core")),
              testImplementation(project(":lib-testing"))
lib-core/     main-scope local project
lib-testing/  test-scope local project
```

`:app`'s test model therefore lists **three** local projects (`:app`, `:lib-core`,
`:lib-testing`), which is enough for the salted set order to flip between JVMs.

## Requirements

- **JDK 25**
- Internet access on the first `./gradlew` run (downloads Gradle 9.6.1 and Quarkus
  3.36.3 artifacts). The wrapper pins Gradle 9.6.1; `gradle.properties` pins Quarkus
  3.36.3.

## Reproduce

### Scripted

```bash
./repro.sh 8
```

Each run uses `--no-daemon` (fresh JVM, fresh salt). Expect output like:

```
run  1: hash=<a> "local-projects":["org.example:app::jar","org.example:lib-core::jar","org.example:lib-testing::jar"]
run  2: hash=<b> "local-projects":["org.example:app::jar","org.example:lib-testing::jar","org.example:lib-core::jar"]
...
NONDETERMINISTIC: N distinct orderings across 8 fresh JVMs
```

### Manual

```bash
./gradlew :app:quarkusGenerateTestAppModel --rerun-tasks
cp app/build/quarkus/application-model/quarkus-app-test-model.dat /tmp/a.dat
./gradlew --stop        # force a fresh daemon (fresh JVM salt)
./gradlew :app:quarkusGenerateTestAppModel --rerun-tasks
cmp /tmp/a.dat app/build/quarkus/application-model/quarkus-app-test-model.dat
```

Each daemon restart has a chance to flip the order, so repeat the stop/rerun cycle a
few times if the first comparison matches.

Optional: add `-Dorg.gradle.caching.debug=true` to a `test` build to watch the
model's hash change the task's cache key between runs.

## The fix

Serializing set-valued fields in a stable (e.g. sorted) order would make the model
byte-identical across JVMs. This repo ships that as an opt-in workaround so you can
watch the nondeterminism disappear:

```bash
./repro.sh 8 -PsortModel
```

`-PsortModel` (see `app/build.gradle.kts`) sorts the `local-projects` array in a
`doLast` on `QuarkusApplicationModelTask`. With it enabled, all runs produce a single
sorted ordering.

The proper upstream fix is to sort the reloadable workspace modules (and any other
set-valued fields) before serialization in `ApplicationModel.asMap`, or to store them
in a deterministically ordered collection.

## Relevant upstream code (Quarkus 3.36.3)

- `DefaultApplicationModel` — `localProjectArtifacts = Set.copyOf(builder.reloadableWorkspaceModules)`
- `ApplicationModel.asMap()` — serializes it under `MAPPABLE_LOCAL_PROJECTS` (`"local-projects"`)
- `io.quarkus.gradle.tasks.QuarkusApplicationModelTask` — the Gradle task that writes the `.dat`
- `java.util.ImmutableCollections` — per-JVM iteration-order salt