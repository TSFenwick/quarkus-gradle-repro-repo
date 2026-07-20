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

// Opt-in workaround (`-PsortModel`) demonstrating the fix: sort the "local-projects"
// array in the serialized model after the model tasks run, making the output
// deterministic across JVMs. Off by default so the bug reproduces out of the box.
if (project.hasProperty("sortModel")) {
    tasks.withType<QuarkusApplicationModelTask>().configureEach {
        doLast {
            val f = applicationModel.get().asFile
            if (!f.exists()) return@doLast
            val text = f.readText()
            val sorted = Regex("\"local-projects\":\\[([^\\]]*)\\]").replace(text) { m ->
                val entries = m.groupValues[1].split(',').filter { it.isNotBlank() }.sorted()
                "\"local-projects\":[${entries.joinToString(",")}]"
            }
            if (sorted != text) f.writeText(sorted)
        }
    }
}
