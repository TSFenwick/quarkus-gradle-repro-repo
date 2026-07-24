pluginManagement {
    val quarkusPluginVersion: String by settings
    val quarkusPluginId: String by settings
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
    plugins {
        id(quarkusPluginId) version quarkusPluginVersion
    }
}
rootProject.name = "quarkus-repros"

include(":app", ":lib-core", ":lib-testing")

// Keep the build cache inside the checkout so cache-key.sh can start from an empty
// cache and show a genuine miss, without touching the developer's ~/.gradle cache.
// Deliberately not under build/, so `gradlew clean` cannot wipe it mid-experiment.
buildCache {
    local {
        directory = file(".gradle-build-cache")
    }
}
