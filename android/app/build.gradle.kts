import org.gradle.api.JavaVersion

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.voice_assistant"
    compileSdk = 34
    ndkVersion = "25.1.8937393"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = "11"
    }

    defaultConfig {
        applicationId = "com.example.voice_assistant"
        minSdk = 24 
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"

        // Enable multidex for large app dependencies
        multiDexEnabled = true

        // Required for installed_apps package or specific Android 11+ visibility permissions
        manifestPlaceholders["QUERY_ALL_PACKAGES"] = "true"
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("libs")
        }
    }

    // Native libraries packaging options
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
            excludes += "META-INF/DEPENDENCIES"
        }
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // OLD MANUAL WAY (Removed):
    // implementation(files("libs/orca-android-3.0.2.aar"))

    // NEW AUTOMATIC WAY (Recommended):
    // Ye line automatic internet se sahi Orca library download karegi.
    // Orca ka latest stable version 1.2.0+ hai (3.0.2 Orca ke liye exist nahi karta).
    implementation("ai.picovoice:orca-android:1.2.0")

    // JSON processing (required for Picovoice/Orca)
    implementation("com.google.code.gson:gson:2.10.1")

    // Multidex support
    implementation("androidx.multidex:multidex:2.0.1")

    // Core AndroidX libraries
    implementation("androidx.core:core-ktx:1.12.0")
}