# Repro: nondeterministic `local-projects` order in the Quarkus application model

The Quarkus Gradle plugin serializes the application model to
`app/build/quarkus/application-model/quarkus-app-test-model.dat`. That file is a
content-hashed build-cache input of every `Test` task, and of `quarkusBuild`,
`quarkusGenerateCode*`, and `quarkusAppPartsBuild`. Its `local-projects` array is not
byte-stable across JVMs, so the model hash changes between builds and invalidates the
build-cache key of every task that reads it. A long-lived Gradle daemon hides this
because it reuses one JVM. CI builds that start a fresh JVM miss the shared cache on
most runs.

## Root cause

[`DefaultApplicationModel`][1] stores the reloadable workspace modules with
`Set.copyOf(builder.reloadableWorkspaceModules)`, and [`ApplicationModel.asMap()`][2]
serializes that set into the [`"local-projects"`][3] key. `Set.copyOf(...)` returns a
JDK immutable set whose iteration order is randomized per JVM by
`java.util.ImmutableCollections`, so when the model has two or more local projects the
array order varies from one JVM to the next. A multi-module test model always has two
or more entries (the module itself plus each local project dependency), so it is
affected by default.

## This repo

`main` is a plain buildable multi-module monorepo. This branch adds the repro harness.
`:app` depends on `:lib-core` (main scope) and `:lib-testing` (test scope), so its test
model lists three local projects (`:app`, `:lib-core`, `:lib-testing`), which is enough
for the order to vary. Requires JDK 25. The wrapper pins Gradle 9.6.1 and
`gradle.properties` pins Quarkus 3.36.3. The first run needs network access.

## Reproduce

```bash
./repro.sh 8              # fresh JVM per run, expect "NONDETERMINISTIC: N orderings"
./repro.sh 8 -PsortModel  # the fix, expect one ordering and one hash
```

Manual equivalent:

```bash
./gradlew :app:quarkusGenerateTestAppModel --rerun-tasks
cp app/build/quarkus/application-model/quarkus-app-test-model.dat /tmp/a.dat
./gradlew --stop   # fresh daemon, fresh JVM salt
./gradlew :app:quarkusGenerateTestAppModel --rerun-tasks
cmp /tmp/a.dat app/build/quarkus/application-model/quarkus-app-test-model.dat
```

## Fix

`-PsortModel` (see [`app/build.gradle.kts`](app/build.gradle.kts)) sorts the
`local-projects` array in a `doLast` on [`QuarkusApplicationModelTask`][4]. That is a
workaround. The upstream fix is to serialize set-valued fields in a stable order,
either sorting before writing or storing them in an ordered collection, in
`ApplicationModel.asMap`.

<!-- Quarkus 3.36.3 source -->
[1]: https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/app-model/src/main/java/io/quarkus/bootstrap/model/DefaultApplicationModel.java#L34
[2]: https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/app-model/src/main/java/io/quarkus/bootstrap/model/ApplicationModel.java#L196-L197
[3]: https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/app-model/src/main/java/io/quarkus/bootstrap/BootstrapConstants.java#L69
[4]: https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/tasks/QuarkusApplicationModelTask.java