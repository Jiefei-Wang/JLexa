import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
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

    signingConfigs {
        create("release") {
            val keyPath = keystoreProperties.getProperty("storeFile")
                ?: (project.findProperty("RELEASE_STORE_FILE") as String?)
            if (keyPath != null) {
                val keyFile = if (file(keyPath).isAbsolute) file(keyPath) else rootProject.file(keyPath)
                if (keyFile.exists()) {
                    storeFile = keyFile
                    storePassword = keystoreProperties.getProperty("storePassword")
                        ?: (project.findProperty("RELEASE_STORE_PASSWORD") as String?)
                    keyAlias = keystoreProperties.getProperty("keyAlias")
                        ?: (project.findProperty("RELEASE_KEY_ALIAS") as String?)
                    keyPassword = keystoreProperties.getProperty("keyPassword")
                        ?: (project.findProperty("RELEASE_KEY_PASSWORD") as String?)
                }
            }
        }
    }

    buildTypes {
        release {
            val releaseConfig = signingConfigs.getByName("release")
            if (releaseConfig.storeFile != null) {
                signingConfig = releaseConfig
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
