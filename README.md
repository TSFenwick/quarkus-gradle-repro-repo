# quarkus-repros

A monorepo of minimal, self-contained reproductions of **Quarkus Gradle build
reproducibility** bugs — cases where the serialized application model
(`build/quarkus/application-model/*.dat`) is not byte-stable across builds and
therefore poisons the Gradle build cache.

## How this repo is organised

`main` holds only the **reusable scaffold** — the Gradle wrapper, plugin
management, and Quarkus version pins. It has no modules and reproduces nothing on
its own.

**Each reproduction lives on its own branch**, branched off `main`, and adds only
the modules and scripts that reproduction needs. To run one, check out its branch
and follow that branch's `README.md`.

## Reproductions

| Branch | Bug |
| --- | --- |
| [`local-projects-order`](../../tree/local-projects-order) | The `local-projects` array in the serialized model is ordered by a per-JVM-salted `Set.copyOf(...)`, so its order flips between JVMs and busts the build-cache key of every task that consumes the model. |

_(More branches will be added for related issues, e.g. `resolved-paths` directory
existence filtering and absolute-path relocatability.)_

## Toolchain

- **JDK 25**
- **Gradle 9.6.1** (pinned via the wrapper — `./gradlew` downloads it on first run)
- **Quarkus 3.36.3** (pinned in `gradle.properties`)