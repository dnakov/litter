plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21"
}

android {
    namespace = "com.makyinc.litter.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.makyinc.litter.android"
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

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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
    implementation("com.github.mwiede:jsch:0.2.22")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
}
