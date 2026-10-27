import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// A Flutter integration target must never replace the regular application.
val flutterTarget = providers.gradleProperty("target").orNull.orEmpty().replace('\\', '/')
val dartDefines = providers.gradleProperty("dart-defines").orNull.orEmpty()
    .split(',').filter { it.isNotBlank() }
    .map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
// flutter test can replace the target with a generated listener. Preserve
// isolation using its define/environment marker even when that happens.
val integrationTarget = providers.gradleProperty("catatUangIntegrationTest").orNull == "true" ||
    flutterTarget.startsWith("integration_test/") || flutterTarget.contains("/integration_test/") ||
    dartDefines.any { it == "INTEGRATION_TEST=true" || it.startsWith("AUTH_TEST_API_URL=") }
val demoTarget = flutterTarget.endsWith("main_demo.dart") || dartDefines.any { it == "DEMO_BUILD=true" }
if (demoTarget && integrationTarget) throw GradleException("Demo and integration builds must be separate")

val releaseRequested = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
val releaseStorePath = providers.environmentVariable("CATATUANG_KEYSTORE_PATH").orNull
val releaseAlias = providers.environmentVariable("CATATUANG_KEY_ALIAS").orNull
val releaseStorePassword = providers.environmentVariable("CATATUANG_STORE_PASSWORD").orNull
val releaseKeyPassword = providers.environmentVariable("CATATUANG_KEY_PASSWORD").orNull
val releaseSigningReady = listOf(releaseStorePath, releaseAlias, releaseStorePassword, releaseKeyPassword).all { !it.isNullOrBlank() }
if (releaseRequested && !releaseSigningReady) {
    throw GradleException("Release requires CATATUANG_KEYSTORE_PATH, CATATUANG_KEY_ALIAS, CATATUANG_STORE_PASSWORD and CATATUANG_KEY_PASSWORD. See docs/native-verification.md.")
}

android {
    namespace = "dev.catatuang.catat_uang"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = if (demoTarget) "dev.catatuang.catat_uang.demo" else if (integrationTarget) "dev.catatuang.catat_uang.integration" else "dev.catatuang.catat_uang"
        manifestPlaceholders["appLabel"] = if (demoTarget) "Catat Uang Demo" else "Catat Uang"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningReady) {
            create("release") {
                storeFile = file(releaseStorePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseAlias
                keyPassword = releaseKeyPassword
            }
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
