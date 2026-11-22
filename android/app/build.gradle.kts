import java.io.IOException
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val keystorePropertiesError =
    if (keystorePropertiesFile.isFile) {
        try {
            keystorePropertiesFile.reader(Charsets.UTF_8).use { keystoreProperties.load(it) }
            null
        } catch (_: IOException) {
            "Unable to read android/key.properties. Check the file permissions."
        } catch (_: IllegalArgumentException) {
            "Unable to parse android/key.properties. Check the properties and path escaping."
        }
    } else {
        "Release signing requires android/key.properties."
    }
val releaseKeystore = keystoreProperties.getProperty("storeFile")
    ?.takeIf { it.isNotBlank() }
    ?.let { rootProject.file(it) }
val missingSigningProperties = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .filter { keystoreProperties.getProperty(it).isNullOrBlank() }

android {
    namespace = "com.example.fishing_build"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.jinhwan.fishing_build"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = releaseKeystore
            storePassword = keystoreProperties.getProperty("storePassword")
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

val validateReleaseSigningProperties = tasks.register("validateReleaseSigningProperties") {
    doLast {
        val error = keystorePropertiesError ?: when {
            missingSigningProperties.isNotEmpty() ->
                "Set ${missingSigningProperties.joinToString()} in android/key.properties."
            releaseKeystore?.isFile != true ->
                "Set storeFile in android/key.properties to an existing release keystore."
            else -> null
        }
        if (error != null) throw GradleException(error)
    }
}

androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.lifecycleTasks.registerPreBuild(validateReleaseSigningProperties)
    }
}

flutter {
    source = "../.."
}
