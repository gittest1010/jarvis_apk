// Java 11 ko import karein
import org.gradle.api.JavaVersion

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// NAYA: Gradle ko batayein ki 'libs' folder se .aar file dhoondhe
repositories {
    flatDir {
        dirs("libs")
    }
}

android {
    namespace = "com.example.voice_assistant" 
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.example.voice_assistant"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// NAYA: Orca (Native TTS) ki .aar file ko dependency banayein
dependencies {
    // FIX: Yeh .kts (Kotlin) file ke liye sahi syntax hai
    implementation(files("libs/orca-android-1.2.0.aar"))
}