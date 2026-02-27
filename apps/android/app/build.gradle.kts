plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.kapt")
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21"
    id("com.github.triplet.play")
}

fun projectPropOrEnv(name: String): String? =
    (findProperty(name) as? String)?.takeIf { it.isNotBlank() }
        ?: System.getenv(name)?.takeIf { it.isNotBlank() }

val uploadStoreFile = projectPropOrEnv("LITTER_UPLOAD_STORE_FILE")
val uploadStorePassword = projectPropOrEnv("LITTER_UPLOAD_STORE_PASSWORD")
val uploadKeyAlias = projectPropOrEnv("LITTER_UPLOAD_KEY_ALIAS")
val uploadKeyPassword = projectPropOrEnv("LITTER_UPLOAD_KEY_PASSWORD")
val hasUploadSigning = listOf(uploadStoreFile, uploadStorePassword, uploadKeyAlias, uploadKeyPassword).all { !it.isNullOrBlank() }

android {
    namespace = "com.sigkitten.litter.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.sigkitten.litter.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    flavorDimensions += "runtime"
    productFlavors {
        create("onDevice") {
            dimension = "runtime"
            buildConfigField("boolean", "ENABLE_ON_DEVICE_BRIDGE", "true")
            buildConfigField("String", "RUNTIME_STARTUP_MODE", "\"hybrid\"")
            buildConfigField("String", "APP_RUNTIME_TRANSPORT", "\"app_bridge_rpc_transport\"")
            manifestPlaceholders["runtimeStartupMode"] = "hybrid"
            manifestPlaceholders["enableOnDeviceBridge"] = "true"
        }
        create("remoteOnly") {
            dimension = "runtime"
            buildConfigField("boolean", "ENABLE_ON_DEVICE_BRIDGE", "false")
            buildConfigField("String", "RUNTIME_STARTUP_MODE", "\"remote_only\"")
            buildConfigField("String", "APP_RUNTIME_TRANSPORT", "\"app_bridge_rpc_transport\"")
            manifestPlaceholders["runtimeStartupMode"] = "remote_only"
            manifestPlaceholders["enableOnDeviceBridge"] = "false"
        }
    }

    if (hasUploadSigning) {
        signingConfigs {
            create("upload") {
                storeFile = file(uploadStoreFile!!)
                storePassword = uploadStorePassword
                keyAlias = uploadKeyAlias
                keyPassword = uploadKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (hasUploadSigning) {
                signingConfig = signingConfigs.getByName("upload")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        jniLibs {
            // Ensure native libs are extracted to a filesystem path so they can be executed.
            useLegacyPackaging = true
        }
    }
}

play {
    defaultToAppBundles.set(true)
    track.set(projectPropOrEnv("LITTER_PLAY_TRACK") ?: "internal")
    val serviceAccountPath = projectPropOrEnv("LITTER_PLAY_SERVICE_ACCOUNT_JSON")
    if (!serviceAccountPath.isNullOrBlank()) {
        serviceAccountCredentials.set(file(serviceAccountPath))
    }
}

dependencies {
    implementation(project(":core:bridge"))
    implementation(project(":core:network"))

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation(platform("androidx.compose:compose-bom:2024.09.00"))
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("io.noties.markwon:core:4.6.2")
    implementation("io.noties.markwon:syntax-highlight:4.6.2") {
        exclude(group = "org.jetbrains", module = "annotations-java5")
    }
    implementation("io.noties:prism4j:2.0.0") {
        exclude(group = "org.jetbrains", module = "annotations-java5")
    }
    kapt("io.noties:prism4j-bundler:2.0.0")
    implementation("com.github.mwiede:jsch:0.2.22")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
}

val downloadBundledAssets by tasks.registering(Exec::class) {
    workingDir = rootProject.projectDir
    commandLine("bash", "scripts/download-bundled-assets.sh")
}

tasks.named("preBuild") {
    dependsOn(downloadBundledAssets)
}
