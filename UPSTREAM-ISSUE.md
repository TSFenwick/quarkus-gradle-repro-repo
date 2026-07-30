<!--
Draft upstream issue for quarkusio/quarkus. Not filed. Everything below the title is
the intended issue body.
-->

**Title:** Gradle: app artifact's `resolved-paths` is filtered by directory existence at model-task execution time, so the serialized application model is not deterministic

---

### Describe the bug

`QuarkusApplicationModelTask` filters the app artifact's `resolved-paths` by
`Files.exists()` while the task is executing, and nothing orders that task after the
tasks that create the directories it probes. The serialized application model is
therefore a function of which Gradle invocation produced it, not only of the build's
inputs.

`quarkus-app-model.dat` is the `applicationModel` `@InputFile` of `quarkusGenerateCode`,
and `quarkus-app-test-model.dat` is that of `quarkusGenerateCodeTests` as well as a
content-hashed input of every `Test` task, so the build-cache key of all of those tasks
moves with it.

On a three-module project (`:app`, plus a main-scope and a test-scope library), three
realistic invocations produce three different models — and three different cache keys —
from identical sources, identical versions and a single JVM:

| Tree | Invocation | app artifact `resolved-paths` |
| --- | --- | --- |
| clean | `:app:quarkusGenerateAppModel` | `[]` |
| clean | `:app:quarkusGenerateCode` | `["…/build/resources/main"]` |
| warm | model regenerated | `["…/build/classes/java/main","…/build/resources/main"]` |

The first two rows are **both clean trees**. They differ only in the requested task
graph: `quarkusGenerateCode` pulls `processResources` into the graph and Gradle
schedules it before the model task, while `quarkusGenerateAppModel` on its own does
not. So this is not a clean-versus-warm artifact — presence depends on the shape of the
requested graph.

### Mechanism

[`QuarkusApplicationModelTask.getProjectArtifact`](https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/tasks/QuarkusApplicationModelTask.java#L186-L210)
builds the value with
[`collectDestinationDirs`](https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/tasks/QuarkusApplicationModelTask.java#L212-L220):

```java
final Path path = src.getOutputDir();
if (paths.contains(path) || !Files.exists(path)) {   // execution-time disk probe
    continue;
}
```

It is serialized as
[`"resolved-paths"`](https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/app-model/src/main/java/io/quarkus/bootstrap/BootstrapConstants.java#L80)
by [`ResolvedDependencyBuilder.putInMap`](https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/app-model/src/main/java/io/quarkus/maven/dependency/ResolvedDependencyBuilder.java#L21-L24).
The directory set is otherwise fully determined by configuration; this probe is the
only part of the value that is not.

Of the four `QuarkusApplicationModelTask` registrations in `QuarkusPlugin`, only
[`quarkusBuildAppModel`](https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/QuarkusPlugin.java#L253-L260)
declares `dependsOn(classes)`. It is correspondingly stable.
[`quarkusGenerateAppModel`](https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/QuarkusPlugin.java#L221-L227),
[`quarkusGenerateTestAppModel`](https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/QuarkusPlugin.java#L208-L214)
and
[`quarkusGenerateDevAppModel`](https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/QuarkusPlugin.java#L215-L220)
do not. The main model cannot: `compileJava`
[depends on `quarkusGenerateCode`](https://github.com/quarkusio/quarkus/blob/3.36.3/devtools/gradle/gradle-application-plugin/src/main/java/io/quarkus/gradle/QuarkusPlugin.java#L504),
which consumes `quarkusGenerateAppModel`, so the edge closes a cycle. Nor can the dev
model, once `quarkusDev` is in the graph, via
`compileJava.mustRunAfter(quarkusGenerateCodeDev)`. The test model is the exception —
`dependsOn(classes)` is acyclic there (checked with `--dry-run` on `:app:test` and
`:app:build`) — so an edge would fix that model, but not the one `quarkusGenerateCode`
reads.

Two further properties make this worse than a one-off:

**The value is sticky.** Directory existence is not a declared task input, so once the
model is written the task reports `UP-TO-DATE` indefinitely and never corrects itself,
even after the directories appear:

```
clean tree, model task alone        -> []
after :app:classes, dirs now exist  -> []      <-- both directories are on disk
```

**The filter is load-bearing**, so it cannot simply be deleted. Serializing the
declared directories unconditionally, with no other change, breaks
`quarkusGenerateCode` on the *genuine* declared directory:

```
> A failure occurred while executing io.quarkus.gradle.tasks.worker.CodeGenWorker
   > .../app/build/classes/java/main does not exist
```

Codegen runs before `compileJava`, so that directory really is absent at consumption
time, and
[`CuratedApplication.createDeploymentClassLoader`](https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/core/src/main/java/io/quarkus/bootstrap/app/CuratedApplication.java#L380-L382)
→ [`ClassPathElement.fromPath`](https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/core/src/main/java/io/quarkus/bootstrap/classloading/ClassPathElement.java#L99-L102)
→ [`PathTree.ofDirectoryOrArchive`](https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/app-model/src/main/java/io/quarkus/paths/PathTree.java#L51-L59)
throws rather than skipping the missing root.

### Why it busts the cache, and which tasks it hits

The model is a content-hashed input, so any byte that moves without a real input
changing costs a miss. Running the cacheable consumer `:app:quarkusGenerateCode` in the
three scenarios above, with Gradle's caching debug on and an empty local cache:

```
A  clean, narrow model invocation first : cacheKey=e90dbebe0b2d2670ad2a2bead82eb5aa  EXECUTED
A  repeat                               : cacheKey=e90dbebe0b2d2670ad2a2bead82eb5aa  FROM-CACHE
B  clean, consumer directly             : cacheKey=c171d95f8ec42e5ea48d248f3ad092ae  EXECUTED
C  warm tree                            : cacheKey=412b9b9f94cd868b98014c94b55a3cf6  EXECUTED

populate cache with scenario C          : EXECUTED (stored)
then run scenario A                     : EXECUTED (cache miss)
```

`applicationModel` is the only input fingerprint that differs between the scenarios:

```
A vs B:  < applicationModel=30c72ba4314d0765eeab57cc45a35f4a
         > applicationModel=2201c295f049aa1bfaa1500415d98eac
B vs C:  < applicationModel=2201c295f049aa1bfaa1500415d98eac
         > applicationModel=852a6dabffae980bb14ad349c178c064
```

Diffing the full pretty-printed models confirms `resolved-paths` is the only field that
moves anywhere in the file.

Affected tasks: `quarkusGenerateCode` and `imageCheckRequirements` (main model),
`quarkusGenerateCodeTests` and every `Test` task in a Quarkus module (test model).
`quarkusAppPartsBuild`, `quarkusBuild` and the other `QuarkusBuildTask`s are wired to
`quarkusBuildAppModel` and so are not affected.

Practical impact:

- Local and CI can never share entries for those tasks: local trees are warm, CI trees
  are clean.
- Two CI pipelines on the same commit disagree if their Gradle invocation sequences
  differ — a warmup step, a dependency-resolution step, or a separate model step is
  enough.
- Two *identical* pipelines do agree, which is why this does not show up in a
  CI-to-CI cache-key comparison.

Scope: only the artifact for the module the model is built for is affected; other local
projects resolve to their built jar. Only main sources are affected —
`getProjectArtifact` reads `getMainSources()` only, so `build/classes/java/test` never
appears, not even in the test model.

Not a scheduling race, as far as I could measure: four graph shapes × 8 runs — three under
parallel execution (`--parallel`, and `--parallel --max-workers=2`) and a sequential
control — each produced exactly one value on Gradle 9.6.1. Gradle does not run tasks of the
same project concurrently. The unordered `processResources` / `quarkusGenerateAppModel`
pair is still a latent hazard, since nothing in the build contract fixes their order.

### How to Reproduce

Minimal three-module reproduction with a scripted harness:
https://github.com/TSFenwick/quarkus-gradle-repro-repo/tree/resolved-paths-existence

```bash
git clone -b resolved-paths-existence https://github.com/TSFenwick/quarkus-gradle-repro-repo
cd quarkus-gradle-repro-repo
./repro.sh 3          # model bytes across tree state and graph shape
./cache-key.sh 2      # the resulting cache-key flip and a real miss
./load-bearing.sh     # shows the filter cannot simply be removed
```

By hand:

```bash
./gradlew clean && ./gradlew :app:quarkusGenerateAppModel
jq -c '.["app-artifact"]["resolved-paths"]' app/build/quarkus/application-model/quarkus-app-model.dat
# []

./gradlew clean && ./gradlew :app:quarkusGenerateCode
jq -c '.["app-artifact"]["resolved-paths"]' app/build/quarkus/application-model/quarkus-app-model.dat
# [".../app/build/resources/main"]
```

Both are clean trees; only the requested task graph differs.

### Proposed fix

Move the existence check from write time to read time: serialize the declared output
directories unconditionally, and skip roots that do not exist where the classloader is
assembled.

Both halves of that pattern already exist in the codebase, which is what makes it
low-risk:

- The same directories are already serialized unconditionally in the same file and the
  same object — the workspace module's `artifact-sources[].sources[].dest-dir` and
  `.resources[].dest-dir` list every output directory on a clean tree where none of
  them exist, while `resolved-paths` is filtered to `[]`. The format already carries
  nonexistent output directories.
- [`SourceDir.isOutputAvailable()`](https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/app-model/src/main/java/io/quarkus/bootstrap/workspace/SourceDir.java#L26-L29)
  already performs exactly this `Files.exists(outputDir)` check against the
  deserialized model; `ArtifactSources.isOutputAvailable()` aggregates it, and
  [`WorkspaceModule.getContentTree`](https://github.com/quarkusio/quarkus/blob/3.36.3/independent-projects/bootstrap/app-model/src/main/java/io/quarkus/bootstrap/workspace/WorkspaceModule.java#L53-L57)
  uses that to fall back to `EmptyPathTree`.

Concretely:

1. Drop the `!Files.exists(path)` clause from `collectDestinationDirs`, keeping the
   duplicate check.
2. Skip missing roots where the application root becomes classpath elements — in
   `CuratedApplication` that is four `for (Path root : quarkusBootstrap.getApplicationRoot())`
   loops (L297, L301, L380, L447); filtering inside `getApplicationRoot()` or a shared
   helper covers all of them at one choke point.

Step 2 touches shared bootstrap code used by the Maven integration as well, so it wants
maintainer input on the right choke point. Step 1 alone is not viable — it fails as
shown above.

Narrower alternatives that are **not** sufficient: `quarkusGenerateAppModel` could declare
`dependsOn(processResources)` without creating a cycle, pinning `build/resources/main`, and
`quarkusGenerateTestAppModel` could declare `dependsOn(classes)`. `build/classes/java/main`
would still vary between clean and warm trees in the main model.

### Environment

- Quarkus 3.36.3 (Gradle plugin `io.quarkus`)
- Gradle 9.6.1
- JDK 25 (Zulu 25.0.2), macOS 26.5 / darwin arm64
- Build cache enabled; reproduced with a project-local cache directory

### Relates to

- #54822 — absolute paths and a `lastModified`-derived version in the same model. Same
  field, different mechanism: that issue is about *what* is written (portability,
  content addressing), this one about *when* it is computed (determinism). Filed
  separately rather than folded in, but they will likely be fixed near each other.
- #55619 — `local-projects` ordering salted per JVM in the same file. Independent; both
  must be fixed for the model to be byte-stable.
- #55590 — `project.version` reaching cache keys through the model and three other
  channels.
