import java.util.Properties
import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeyPropertiesFile = rootProject.file("key.properties")
val releaseKeyProperties = Properties().apply {
    if (releaseKeyPropertiesFile.exists()) {
        releaseKeyPropertiesFile.inputStream().use(::load)
    }
}

fun releaseSigningValue(name: String): String =
    releaseKeyProperties.getProperty(name)?.takeIf { it.isNotBlank() }
        ?: throw GradleException("Propriedade '$name' ausente em android/key.properties")

fun dartDefineValue(name: String): String? =
    providers.gradleProperty("dart-defines").orNull
        ?.split(',')
        ?.mapNotNull { encoded ->
            runCatching { String(Base64.getDecoder().decode(encoded)) }.getOrNull()
        }
        ?.firstOrNull { it.startsWith("$name=") }
        ?.substringAfter('=')

val releaseRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
val androidPackageId =
    dartDefineValue("ANDROID_PACKAGE_ID") ?: "br.dev.star.tracker.entregas"
if (releaseRequested) {
    val backendUrl = dartDefineValue("BACKEND_URL")
    if (backendUrl == null || !backendUrl.startsWith("https://")) {
        throw GradleException(
            "Build release exige BACKEND_URL=https://... via --dart-define-from-file.",
        )
    }
    if (dartDefineValue("ANDROID_PACKAGE_ID") == null) {
        throw GradleException(
            "Build release exige ANDROID_PACKAGE_ID via --dart-define-from-file.",
        )
    }
}

android {
    namespace = "br.dev.star.tracker.entregas"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = androidPackageId
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseKeyPropertiesFile.exists()) {
            create("release") {
                keyAlias = releaseSigningValue("keyAlias")
                keyPassword = releaseSigningValue("keyPassword")
                storeFile = rootProject.file(releaseSigningValue("storeFile"))
                storePassword = releaseSigningValue("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // APKs Android precisam ser assinados mesmo quando distribuidos fora da loja.
            // Sem a upload key, mantemos o build otimizado de release e usamos a chave
            // de desenvolvimento apenas para permitir a instalacao direta.
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
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
