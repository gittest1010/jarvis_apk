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
        // UPGRADE: Modern Gradle/Flutter requires Java 17
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
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
            // Note: Use your own keystore for production releases
            signingConfig = signingConfigs.getByName("debug")
            
            // Set these to true if you want code shrinking (requires correct proguard rules)
            // If you get errors in Release mode, set these back to false
            isMinifyEnabled = false 
            isShrinkResources = false 
            
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        
        debug {
            signingConfig = signingConfigs.getByName("debug")
            
            // FIX: This fixes the "Removing unused resources requires unused code shrinking" error
            isMinifyEnabled = false
            isShrinkResources = false
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
    // Ye line automatic internet se sahi Orca library download karegi.
    // Orca ka latest stable version 1.2.0+ hai.
    implementation("ai.picovoice:orca-android:1.2.0")

    // JSON processing (required for Picovoice/Orca)
    implementation("com.google.code.gson:gson:2.10.1")

    // Multidex support
    implementation("androidx.multidex:multidex:2.0.1")

    // Core AndroidX libraries
    implementation("androidx.core:core-ktx:1.12.0")
}