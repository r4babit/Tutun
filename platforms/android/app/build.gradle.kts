import java.time.Instant

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val signingNames = listOf("TUTUN_ANDROID_STORE_FILE", "TUTUN_ANDROID_STORE_PASSWORD", "TUTUN_ANDROID_KEY_ALIAS", "TUTUN_ANDROID_KEY_PASSWORD")
val signingValues = signingNames.associateWith { providers.environmentVariable(it).orNull }
require(signingValues.values.none { !it.isNullOrBlank() } || signingValues.values.all { !it.isNullOrBlank() }) {
    "Set all TUTUN_ANDROID_* signing variables, or leave all unset for an unsigned release."
}

android {
    namespace = "app.tutun"
    compileSdk = 36
    defaultConfig {
        applicationId = "app.tutun"
        minSdk = 26
        targetSdk = 36
        versionCode = 10
        versionName = rootProject.file("../../VERSION").readText().trim()
        buildConfigField("String", "BUILD_STAMP", "\"${Instant.now()}\"")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
    }
    signingConfigs {
        if (signingValues.values.all { !it.isNullOrBlank() }) {
            create("production") {
                storeFile = rootProject.file(signingValues.getValue("TUTUN_ANDROID_STORE_FILE")!!)
                storePassword = signingValues.getValue("TUTUN_ANDROID_STORE_PASSWORD")
                keyAlias = signingValues.getValue("TUTUN_ANDROID_KEY_ALIAS")
                keyPassword = signingValues.getValue("TUTUN_ANDROID_KEY_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("production")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true; buildConfig = true }
    testOptions { unitTests.isReturnDefaultValues = false }
    packaging { jniLibs { useLegacyPackaging = true } }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    implementation(files("libs/libv2ray.aar"))
    implementation("com.google.zxing:core:3.5.4")
    implementation(platform("androidx.compose:compose-bom:2025.04.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}

// A Mac wording change reaches Android on the next build; incomplete catalogs fail early.
val generateAndroidL10n by tasks.registering(Exec::class) {
    workingDir(rootProject.file("../.."))
    commandLine("python3", "scripts/l10n/android.py")
    inputs.files(fileTree(rootProject.file("../../scripts/l10n")) { include("*.tsv", "android-extra.json", "android.py") })
    inputs.files(fileTree("src/main/java") { include("**/*.kt") })
    outputs.files(file("src/main/assets/l10n.json"), rootProject.file("../../scripts/l10n/android-keys.json"))
}
tasks.named("preBuild").configure { dependsOn(generateAndroidL10n) }

val syncThirdPartyLicenses by tasks.registering(Sync::class) {
    from(rootProject.file("../../licenses"))
    into("src/main/assets/licenses")
}
tasks.named("preBuild").configure { dependsOn(syncThirdPartyLicenses) }
