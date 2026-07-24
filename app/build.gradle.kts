import io.quarkus.gradle.tasks.QuarkusApplicationModelTask

plugins {
    java
    id("io.quarkus")
}

repositories {
    mavenCentral()
}

val quarkusPlatformGroupId: String by project
val quarkusPlatformArtifactId: String by project
val quarkusPlatformVersion: String by project

dependencies {
    implementation(enforcedPlatform("${quarkusPlatformGroupId}:${quarkusPlatformArtifactId}:${quarkusPlatformVersion}"))
    implementation("io.quarkus:quarkus-rest")
    implementation("io.quarkus:quarkus-rest-jackson")
    implementation("io.quarkus:quarkus-arc")

    // Local project dependencies. These make :app a multi-module build: a
    // main-scope dependency on :lib-core and a test-scope dependency on
    // :lib-testing. Both are "reloadable workspace modules", so the serialized
    // test application model lists them (plus :app itself) in "local-projects".
    implementation(project(":lib-core"))
    testImplementation(project(":lib-testing"))

    testImplementation("io.quarkus:quarkus-junit")
    testImplementation("io.rest-assured:rest-assured")
}

group = "org.example"
version = "1.0.0-SNAPSHOT"

java {
    sourceCompatibility = JavaVersion.VERSION_25
    targetCompatibility = JavaVersion.VERSION_25
}

tasks.withType<JavaCompile> {
    options.encoding = "UTF-8"
    options.compilerArgs.add("-parameters")
}

// Opt-in validation harness (`-PunfilteredPaths`) for question 5 of the brief: is
// the Files.exists() filter load-bearing, or can the model record declared output
// directories unconditionally and let consumers skip what is missing?
//
// It rewrites the app artifact's "resolved-paths" to the declared main output
// directories whether or not they exist, which is exactly what removing the
// upstream filter would produce.
//
//   -PunfilteredPaths          the two declared main output directories
//   -PunfilteredPaths=bogus    the same, plus a directory that can never exist
//
// The plain form is the realistic one; the `bogus` form is a harsher stress test.
// Keeping them separate matters, because otherwise a failure cannot be attributed
// to the synthetic path rather than to the genuine one.
//
// This is a probe, not a proposed fix. Like the -PsortModel stopgap on the
// local-projects-order branch it rewrites the model task's own declared output from
// a doLast, which is exactly the shape a real fix should avoid; the fix belongs in
// QuarkusApplicationModelTask.collectDestinationDirs.
if (project.hasProperty("unfilteredPaths")) {
    val withBogus = project.property("unfilteredPaths") == "bogus"
    val dirs = mutableListOf(
        layout.buildDirectory.dir("classes/java/main"),
        layout.buildDirectory.dir("resources/main"),
    )
    if (withBogus) dirs += layout.buildDirectory.dir("classes/java/neverBuilt")
    val declaredPaths = dirs.map { it.get().asFile.absolutePath }

    tasks.withType<QuarkusApplicationModelTask>().configureEach {
        doLast {
            val f = applicationModel.get().asFile
            if (!f.exists()) return@doLast
            val replacement = declaredPaths.joinToString(",") { "\"$it\"" }
            val text = f.readText()
            // "app-artifact" is a top-level key and "resolved-paths" is its first,
            // so this targets the app artifact only and leaves dependencies alone.
            val rewritten = Regex("\"app-artifact\":\\{\"resolved-paths\":\\[[^\\]]*\\]")
                .replace(text) { "\"app-artifact\":{\"resolved-paths\":[$replacement]" }
            if (rewritten != text) f.writeText(rewritten)
        }
    }
}
