# Repro: `resolved-paths` depends on tree state and task graph in the Quarkus application model

The Quarkus Gradle plugin serializes an application model to
`app/build/quarkus/application-model/*.dat`. The app artifact's `resolved-paths` array is
filtered by `Files.exists()` when the model task runs, and nothing orders that task after
the tasks that create the directories being tested. So the same task, on the same sources,
at the same version, writes a **different model depending on which Gradle invocation
produced it** — and the build-cache key of everything that reads it moves with it.

What reads it: the main model is the `applicationModel` `@InputFile` of
`quarkusGenerateCode`, and the test model is that of `quarkusGenerateCodeTests` and a
content-hashed input of every `Test` task. `quarkusAppPartsBuild` and `quarkusBuild` read
`quarkusBuildAppModel` instead, which is stable —
see [below](#which-paths-and-which-models).

Measured here: three realistic invocations produce three different models and three
different cache keys for `:app:quarkusGenerateCode`, with one JVM and identical
sources. The wrong value is also sticky: directory existence is not a declared input,
so once written the model task reports `UP-TO-DATE` forever and never corrects itself.

## Root cause

[`QuarkusApplicationModelTask.getProjectArtifact`][1] builds the app artifact's
`resolved-paths` from its own source-set output directories, via
[`collectDestinationDirs`][2]:

```java
private static void collectDestinationDirs(Collection<SourceDir> sources, final PathList.Builder paths) {
    for (SourceDir src : sources) {
        final Path path = src.getOutputDir();
        if (paths.contains(path) || !Files.exists(path)) {   // <-- execution-time disk probe
            continue;
        }
        paths.add(path);
    }
}
```

`Files.exists` runs inside the task action, and the result is serialized into
[`"resolved-paths"`][3] by [`ResolvedDependencyBuilder.putInMap`][4]. The set of
directories is otherwise fully determined by configuration, so this disk probe is the
only thing in the value that is not.

Nothing orders the model task after the tasks that create those directories. Of the
four `QuarkusApplicationModelTask` registrations in [`QuarkusPlugin`][5], exactly one
declares the dependency:

| Task | Model file | `dependsOn(classes)` |
| --- | --- | --- |
| [`quarkusGenerateAppModel`][6] | `quarkus-app-model.dat` | no |
| [`quarkusGenerateTestAppModel`][7] | `quarkus-app-test-model.dat` | no |
| [`quarkusGenerateDevAppModel`][8] | `quarkus-app-dev-model.dat` | no |
| [`quarkusBuildAppModel`][9] | `quarkus-app-model-build.dat` | **yes** |

`quarkusBuildAppModel` is the control, and it behaves: even requested alone against a
clean tree it records both directories, because it runs after `classes`. The other
three inherit whatever the scheduler happened to do.

### Why the obvious fix does not work

Copying `dependsOn(classes)` onto `quarkusGenerateAppModel` creates a cycle.
[`compileJava.dependsOn(quarkusGenerateCode)`][10] and `quarkusGenerateCode` consumes
`quarkusGenerateAppModel`, so the model task must run *before* compilation:

```
quarkusGenerateAppModel -> classes -> compileJava -> quarkusGenerateCode -> quarkusGenerateAppModel
```

`quarkusGenerateDevAppModel` cycles the same way once `quarkusDev` is in the graph, via
`compileJava.mustRunAfter(quarkusGenerateCodeDev)`. `quarkusGenerateTestAppModel` is the
exception — the edge is acyclic there, checked with `--dry-run` on `:app:test` and
`:app:build` — and `quarkusBuildAppModel` can declare it because nothing compiles after it.

So an edge would fix the test model but not the main one, which is the model
`quarkusGenerateCode` reads. Codegen genuinely runs before `compileJava`, so
`build/classes/java/main` legitimately does not exist when the main model is consumed.
That is *why* the filter is there — and why the fix has to move the check rather than add
an edge or delete the filter.

## What the harness shows

Three scenarios, all on one daemon so the JVM is held constant. That isolation matters
because [quarkusio/quarkus#55619][i55619] moves `local-projects` ordering per JVM in
the same file. The **main** model needs no such care on its own — it lists exactly one
local project, so its array cannot reorder — but the test model lists three and does.
`lib.sh` asserts the invariant rather than assuming it.

| Scenario | Tree | Invocation | `resolved-paths` |
| --- | --- | --- | --- |
| A | clean | `:app:quarkusGenerateAppModel` | `[]` |
| B | clean | `:app:quarkusGenerateCode` | `["build/resources/main"]` |
| C | warm | model regenerated | `["build/classes/java/main","build/resources/main"]` |

**A and B are both clean trees.** They differ only in the requested task graph:
`quarkusGenerateCode` pulls `processResources` into the graph and Gradle schedules it
before the model task, so `build/resources/main` exists; `quarkusGenerateAppModel`
alone does not. So this is not a clean-versus-warm effect — presence is a function of the
requested task graph, which makes it an invocation-level nondeterminism rather than only a
local-versus-CI mismatch.

`resolved-paths` is the **only** field that moves. Diffing the pretty-printed models
pairwise by hand yields exactly one hunk each time (A vs C shown; the harness diffs
cache-key fingerprints, not model text):

```
82c82,85
<     "resolved-paths": [],
---
>     "resolved-paths": [
>       "…/classes/java/main",
>       "…/resources/main"
>     ],
```

### Reproduce

```bash
./repro.sh 3          # model bytes across tree state and graph shape
./cache-key.sh 2      # what that does to a consumer's build-cache key
./parallel.sh 8       # probe for a scheduling race (negative result, see below)
./load-bearing.sh     # is the filter load-bearing? (yes, see below)
```

Each script exits `0` when it reproduces what it is looking for, so `parallel.sh` exits
non-zero on its expected result — no race. Do not chain them with `&&`.

Manual equivalent:

```bash
./gradlew clean && ./gradlew :app:quarkusGenerateAppModel
jq -c '.["app-artifact"]["resolved-paths"]' app/build/quarkus/application-model/quarkus-app-model.dat
# []
./gradlew clean && ./gradlew :app:quarkusGenerateCode
jq -c '.["app-artifact"]["resolved-paths"]' app/build/quarkus/application-model/quarkus-app-model.dat
# [".../app/build/resources/main"]
```

### Cache key

`cache-key.sh` runs the cacheable consumer `:app:quarkusGenerateCode` in each scenario
and prints Gradle's build-cache key, plus every input fingerprint it appended:

```
### A  clean, narrow model invocation first, then the consumer
  run 1: cacheKey=e90dbebe0b2d2670ad2a2bead82eb5aa  EXECUTED     resolved-paths=[]
  run 2: cacheKey=e90dbebe0b2d2670ad2a2bead82eb5aa  FROM-CACHE   resolved-paths=[]

### B  clean, consumer directly
  run 1: cacheKey=c171d95f8ec42e5ea48d248f3ad092ae  EXECUTED     resolved-paths=["build/resources/main"]
  run 2: cacheKey=c171d95f8ec42e5ea48d248f3ad092ae  FROM-CACHE   resolved-paths=["build/resources/main"]

### C  warm tree, model regenerated
  run 1: cacheKey=412b9b9f94cd868b98014c94b55a3cf6  EXECUTED     resolved-paths=["build/classes/java/main","build/resources/main"]
  run 2: cacheKey=412b9b9f94cd868b98014c94b55a3cf6  FROM-CACHE   resolved-paths=["build/classes/java/main","build/resources/main"]

### can one scenario reuse the entry another scenario stored?
  populate cache with scenario C : EXECUTED (stored)
  then run scenario A            : EXECUTED (cache miss)

### which inputs actually moved
  A vs B:
    < applicationModel=30c72ba4314d0765eeab57cc45a35f4a
    > applicationModel=2201c295f049aa1bfaa1500415d98eac
  B vs C:
    < applicationModel=2201c295f049aa1bfaa1500415d98eac
    > applicationModel=852a6dabffae980bb14ad349c178c064
```

Within a scenario the second run is `FROM-CACHE`, so caching demonstrably works. Across
scenarios it is a real miss, and `applicationModel` is the only input fingerprint that
differs. The script uses a project-local build cache (`.gradle-build-cache`, configured
in `settings.gradle.kts`) so it can start empty without touching `~/.gradle`.

### The wrong value is sticky

Directory existence is not a declared input of the model task, so a model written
against a clean tree is never corrected:

```
clean tree, model task alone        -> []
after :app:classes, dirs now exist  -> []
on disk: app/build/classes/java/main app/build/resources/main
```

The model task reports `UP-TO-DATE` and the stale value survives into every subsequent
build in that workspace until some unrelated input changes. Any narrow invocation —
`./gradlew :app:quarkusGenerateAppModel`, a dependency-resolution warmup, an IDE sync —
poisons the model for everything that follows.

### Not a scheduling race

`parallel.sh` runs four graph shapes 8 times each: three parallel (`--parallel` on the
consumer graph, `--parallel` on the full build graph, and `--parallel --max-workers=2`)
and a sequential control. **Every shape produced exactly one value.** Reported as a
negative result: on Gradle 9.6.1 the scheduler's order for the unordered
`processResources` / `quarkusGenerateAppModel` pair is stable, so this is tree state and
graph shape, not a race. Gradle does not run tasks of the same project concurrently, which
is why parallelism does not add variance here.

That is observed behaviour, not a guarantee. Two unordered tasks communicating through the
filesystem is still a latent hazard: nothing in the build contract fixes the order, so it
can change with a Gradle version, a plugin, or an added task.

### Which paths, and which models

Only the artifact for **the module the model is built for** gets output directories.
Other local projects resolve to their built jar, because they come through
[`collectDependencies`][11], which calls `setResolvedPath(artifact.file.toPath())` on the
resolved artifact. In this repo `org.example:lib-core` and `org.example:lib-testing` are
always jars; only `org.example:app` is exposed.

Only **main** sources are affected. `getProjectArtifact` reads
`module.getMainSources()` only, so `build/classes/java/test` never appears in
`resolved-paths` — not even in the test model. Both the main and test models carry the
same two main-scope directories and the same exposure:

| Model | requested alone, clean tree | reached via a graph that compiles first |
| --- | --- | --- |
| `quarkus-app-model.dat` | `[]` | `["…/classes/java/main","…/resources/main"]` |
| `quarkus-app-test-model.dat` | `[]` | `["…/classes/java/main","…/resources/main"]` |
| `quarkus-app-model-build.dat` | `["…/classes/java/main","…/resources/main"]` | same |

The build model is stable, and it is the model every `QuarkusBuildTask` reads — the
`applicationModel` of `quarkusAppPartsBuild`, `quarkusBuild`, `quarkusRun`, `imageBuild`
and `deploy` is wired to `quarkusBuildAppModel`, not to `quarkusGenerateAppModel`. Those
tasks are therefore *not* exposed. The tasks that are: `quarkusGenerateCode` (main model),
`quarkusGenerateCodeTests` and every `Test` task (test model, added as a task input in
`QuarkusPlugin`), and `imageCheckRequirements` (main model).

## The filter is load-bearing

`load-bearing.sh` answers whether the model could simply record the declared
directories unconditionally. It rewrites the app artifact's `resolved-paths` to the
declared main output directories regardless of existence — exactly what deleting the
upstream filter would produce — and rebuilds with the cache disabled:

```
  baseline, filter in place          BUILD SUCCESSFUL
  declared paths, unfiltered         BUILD FAILED
      > A failure occurred while executing io.quarkus.gradle.tasks.worker.CodeGenWorker
         > .../app/build/classes/java/main does not exist
  declared paths + a bogus one       BUILD FAILED   (same error, same genuine path)
```

It fails on the **genuine** declared directory, not on the synthetic one — because
codegen runs before `compileJava`, so that directory really is absent at consumption
time. The chain is [`CuratedApplication.createDeploymentClassLoader`][12] →
[`ClassPathElement.fromPath`][13] → [`PathTree.ofDirectoryOrArchive`][14], which throws
`IllegalArgumentException` for a missing root instead of skipping it.

So "stop filtering" is not sufficient on its own.

> Disabling the build cache for this check matters. With caching on,
> `quarkusGenerateCode` is served from the cache, never executes, and the run passes
> without exercising the failure at all.

## Proposed fix

**Move the existence check from write time to read time.** Serialize the declared
output directories unconditionally, so the model is a function of the build's
configuration rather than of whatever happens to be on disk when the task runs, and
skip roots that do not exist where the classloader is assembled.

Both halves already exist upstream, which is what makes this low-risk:

- The same directories are **already** serialized unconditionally, in the same file, in
  the same object. The workspace module's `artifact-sources[].sources[].dest-dir` and
  `.resources[].dest-dir` list all eight of the app module's output directories (classes
  and resources × `main`, `test`, `integrationTest`, `native-test`) on a clean tree where
  none of them exist, while `resolved-paths` is filtered to `[]`. The format already
  carries nonexistent output directories and consumers already read them.
- The read-time idiom already exists. [`SourceDir.isOutputAvailable()`][15] performs
  precisely the same `Files.exists(outputDir)` check on the deserialized model;
  `ArtifactSources.isOutputAvailable()` aggregates it, and
  [`WorkspaceModule.getContentTree`][16] uses that to fall back to `EmptyPathTree`.

So the write-time filter in `collectDestinationDirs` is the anomaly, not the pattern.
Concretely:

1. Drop the `!Files.exists(path)` clause from [`collectDestinationDirs`][2], keeping the
   duplicate check. The model then records the declared set and is byte-stable across
   tree states and graph shapes.
2. Skip missing roots where the application root becomes classpath elements. In
   `CuratedApplication` that is four sites (L297, L301, L380, L447), all
   `for (Path root : quarkusBootstrap.getApplicationRoot())` followed by
   `ClassPathElement.fromPath`; filtering inside `getApplicationRoot()` or a shared
   helper covers all of them at one choke point.

### Trade-offs

- Step 2 changes shared bootstrap code used by the Maven integration too, so it needs
  care and upstream review; it is not a Gradle-plugin-local change. Doing step 1 alone
  breaks the build, as `load-bearing.sh` shows.
- A read-time skip is silent where the write-time filter was also silent, so it adds no
  new failure mode — but a genuinely missing root that *should* have been present now
  fails later and less obviously than it would have.
- Smaller partial fixes exist and are not sufficient: `quarkusGenerateAppModel` could
  declare `dependsOn(processResources)` without a cycle, which would pin
  `build/resources/main`, and `quarkusGenerateTestAppModel` could take `dependsOn(classes)`
  outright. `build/classes/java/main` would still vary in the main model, so the model
  `quarkusGenerateCode` reads stays unstable. Not worth doing on their own.
- Independent of [#55619][i55619], which is set-ordering per JVM in the same file. Both
  must be closed for the model to be byte-stable.

## Severity, as measured

Grounded in what this harness measured, not in what the mechanism could do:

- **Does not** break CI-to-CI reuse between identical pipelines. Within a fixed task
  graph and a fixed starting tree state the value is deterministic: every scenario was
  internally stable across repeats, and no scheduling race appeared in 24 parallel runs
  plus an 8-run sequential control. This matches a separate CI-to-CI comparison over 271
  tasks, which came back clean.
- **Does** break local-to-CI reuse permanently. Local trees are warm, CI trees are
  clean, so the two compute different models and can never share cache entries for
  `quarkusGenerateCode`, `quarkusGenerateCodeTests` or any `Test` task.
- **Does** break reuse between pipelines whose Gradle invocation sequence differs. Any
  job that runs a narrower Gradle command before the main one — a warmup, a
  dependency-resolution step, a separate model step — gets a different model on the
  same commit. Measured as a real cache miss, not inferred.
- **Is sticky**, which is the part that makes it more than a nuisance. The bad value
  persists in the workspace indefinitely because it is not derived from any declared
  input.
- One narrow correctness hazard, not exercised here: the filter can produce an empty
  `resolved-paths`, and [`PathList.getSinglePath()`][17] throws `IllegalStateException`
  for any count other than one. `DevModeTask` and `ReaugmentTask`
  (`io.quarkus.deployment.mutability`, reading a mutable jar's serialized model) call it
  on the app artifact's resolved paths.

Net: a persistent cache-reuse defect across machines and across differing pipelines,
not a within-pipeline flake. Worth fixing upstream, but it would not have shown up in a
CI-to-CI key comparison, which is why it went unnoticed.

## Relates to

- [quarkusio/quarkus#54822][i54822] — absolute paths and a `lastModified`-derived
  version in the same model. Same field, different mechanism: that issue is about *what*
  is written (portability, content addressing); this one is about *when* it is computed
  (determinism). Filed separately and cross-referenced rather than folded in.
- [quarkusio/quarkus#55619][i55619] — `local-projects` ordering salted per JVM.
- [quarkusio/quarkus#55590][i55590] — `project.version` reaching cache keys.

## Toolchain

- **JDK 25**
- **Gradle 9.6.1** (pinned via the wrapper — `./gradlew` downloads it on first run)
- **Quarkus 3.36.3** (pinned in `gradle.properties`); all source links are to that tag
- `jq` on `PATH`; first run needs network access

<!-- Quarkus 3.36.3 source -->
[1]: https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/tasks/QuarkusApplicationModelTask.java#L186-L210
[2]: https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/tasks/QuarkusApplicationModelTask.java#L212-L220
[3]: https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/app-model/src/main/java/io/quarkus/bootstrap/BootstrapConstants.java#L80
[4]: https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/app-model/src/main/java/io/quarkus/maven/dependency/ResolvedDependencyBuilder.java#L21-L24
[5]: https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/QuarkusPlugin.java
[6]: https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/QuarkusPlugin.java#L221-L227
[7]: https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/QuarkusPlugin.java#L208-L214
[8]: https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/QuarkusPlugin.java#L215-L220
[9]: https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/QuarkusPlugin.java#L253-L260
[10]: https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/QuarkusPlugin.java#L504
[11]: https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/tasks/QuarkusApplicationModelTask.java#L328-L334
[12]: https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/core/src/main/java/io/quarkus/bootstrap/app/CuratedApplication.java#L380-L382
[13]: https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/core/src/main/java/io/quarkus/bootstrap/classloading/ClassPathElement.java#L99-L102
[14]: https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/app-model/src/main/java/io/quarkus/paths/PathTree.java#L51-L59
[15]: https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/app-model/src/main/java/io/quarkus/bootstrap/workspace/SourceDir.java#L26-L29
[16]: https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/app-model/src/main/java/io/quarkus/bootstrap/workspace/WorkspaceModule.java#L53-L57
[17]: https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/app-model/src/main/java/io/quarkus/paths/PathList.java#L79-L84

[i54822]: https://github.com/quarkusio/quarkus/issues/54822
[i55590]: https://github.com/quarkusio/quarkus/issues/55590
[i55619]: https://github.com/quarkusio/quarkus/issues/55619