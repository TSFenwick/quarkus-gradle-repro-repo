# quarkus-repros

A monorepo of minimal, self-contained reproductions of **Quarkus Gradle build
reproducibility** bugs — cases where the serialized application model
(`build/quarkus/application-model/*.dat`) is not byte-stable across builds and
therefore poisons the Gradle build cache.

## How this repo is organised

`main` is a minimal but **buildable multi-module Quarkus monorepo** — a `:app`
module that depends on a `:lib-core` (main scope) and a `:lib-testing` (test scope)
library. It builds with `./gradlew build` and reproduces nothing specific on its
own; it is the reusable base that every reproduction shares.

**Each reproduction lives on its own branch**, branched off `main`, and layers on
the tooling and docs that reproduction needs (a `repro.sh`, extra Gradle config, a
bug-specific `README.md`). To run one, check out its branch and follow that
branch's `README.md`.

```
app/          Quarkus application module (depends on :lib-core and :lib-testing)
lib-core/     main-scope library
lib-testing/  test-scope library
```

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