import java.io.File
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val candidateKeyFiles = listOf(
    rootProject.file("key.properties"),
    rootProject.file("../key.properties"),
    rootProject.file("../../key.properties"),
    project.file("key.properties")
)

val resolvedKeyFile = candidateKeyFiles.firstOrNull { it.exists() }
if (resolvedKeyFile != null) {
    val rawProps = Properties()
    resolvedKeyFile.bufferedReader(Charsets.UTF_8).use { reader ->
        rawProps.load(reader)
    }
    rawProps.forEach { k, v ->
        val cleanKey = k.toString().replace("\uFEFF", "").trim()
        val cleanValue = v.toString().replace("\uFEFF", "").trim()
        keystoreProperties.setProperty(cleanKey, cleanValue)
    }
    println("[Gradle Signing] Loaded and sanitized key.properties from: ${resolvedKeyFile.absolutePath}")
    println("[Gradle Signing] storeFile: '${keystoreProperties.getProperty("storeFile")}'")
    println("[Gradle Signing] storePassword: '${if (keystoreProperties.getProperty("storePassword") != null) "***" else "null"}'")
    println("[Gradle Signing] keyAlias: '${keystoreProperties.getProperty("keyAlias")}'")
    println("[Gradle Signing] keyPassword: '${if (keystoreProperties.getProperty("keyPassword") != null) "***" else "null"}'")
} else {
    println("[Gradle Signing] No key.properties found in candidates")
}

android {
    namespace = "com.example.local_ai_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.local_ai_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters.clear()
            abiFilters.addAll(listOf("arm64-v8a", "x86_64"))
        }

        externalNativeBuild {
            cmake {
                abiFilters.clear()
                abiFilters.addAll(listOf("arm64-v8a", "x86_64"))
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    val keyPath = keystoreProperties.getProperty("storeFile")
        ?: (project.findProperty("RELEASE_STORE_FILE") as String?)
    val keyFile = if (keyPath != null) {
        listOf(
            File(keyPath),
            rootProject.file(keyPath),
            rootProject.file("../$keyPath"),
            rootProject.file("../../$keyPath")
        ).firstOrNull { it.exists() }
    } else null

    val hasReleaseKeystore = keyFile != null && keyFile.exists()

    signingConfigs {
        create("release") {
            if (hasReleaseKeystore && keyFile != null) {
                storeFile = keyFile
                storePassword = keystoreProperties.getProperty("storePassword")
                    ?: (project.findProperty("RELEASE_STORE_PASSWORD") as String?)
                keyAlias = keystoreProperties.getProperty("keyAlias")
                    ?: (project.findProperty("RELEASE_KEY_ALIAS") as String?)
                keyPassword = keystoreProperties.getProperty("keyPassword")
                    ?: (project.findProperty("RELEASE_KEY_PASSWORD") as String?)
                println("[Gradle Signing] Configured release signing with keystore: ${keyFile.absolutePath}, alias: $keyAlias")
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
                println("[Gradle Signing] Successfully attached release signingConfig to release build")
            } else {
                signingConfig = signingConfigs.getByName("debug")
                println("[Gradle Signing] Warning: Keystore not found, falling back to debug signingConfig")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0")
}

flutter {
    source = "../.."
}
