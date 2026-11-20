plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// The app bundles ../catalog.json (shared with Invoke-PhoneTuning.ps1) as an asset.
abstract class CopyCatalogTask : DefaultTask() {
    @get:InputFile abstract val catalog: RegularFileProperty
    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val out = outputDir.get().asFile.apply { mkdirs() }
        catalog.get().asFile.copyTo(File(out, "catalog.json"), overwrite = true)
    }
}

val copyCatalog = tasks.register<CopyCatalogTask>("copyCatalog") {
    catalog.set(rootProject.layout.projectDirectory.file("../catalog.json"))
}

android {
    namespace = "com.asahicantu.phonetuner"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.asahicantu.phonetuner"
        minSdk = 30          // Android 11: wireless debugging, needed to start Shizuku without a PC
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")   // personal sideloaded app
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        aidl = true
        buildConfig = true
    }
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(copyCatalog, CopyCatalogTask::outputDir)
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.material3)
    implementation(libs.shizuku.api)
    implementation(libs.shizuku.provider)
    testImplementation(libs.junit)
}
