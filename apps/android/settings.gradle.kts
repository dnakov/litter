pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "LitterAndroid"
include(":app")
include(":core:network")
include(":core:bridge")
include(":feature:conversation")
include(":feature:sessions")
include(":feature:discovery")
