import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release signing: CI passes the keystore through environment variables; locally an optional
// keystore.properties (not in git) points to the same keystore. Without either, release is unsigned.
val signing = Properties().apply {
    val f = rootProject.file("keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun sign(key: String, env: String): String? = System.getenv(env)?.takeIf { it.isNotEmpty() } ?: signing.getProperty(key)

android {
    namespace = "com.localkeys.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.localkeys.app"
        minSdk = 26
        targetSdk = 36
        versionCode = (System.getenv("BUILD") ?: "1").toInt()
        versionName = System.getenv("VERSION") ?: "1.0.0"
    }

    signingConfigs {
        create("release") {
            val store = sign("storeFile", "LK_KEYSTORE")
            if (store != null) {
                storeFile = file(store)
                storePassword = sign("storePassword", "LK_KEYSTORE_PASSWORD")
                keyAlias = sign("keyAlias", "LK_KEY_ALIAS") ?: "localkeys"
                keyPassword = sign("keyPassword", "LK_KEY_PASSWORD") ?: storePassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            if (sign("storeFile", "LK_KEYSTORE") != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}
