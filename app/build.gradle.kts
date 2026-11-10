import com.android.build.api.artifact.SingleArtifact
import org.w3c.dom.Element
import javax.xml.parsers.DocumentBuilderFactory

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.amirovandrew.docuscan"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.amirovandrew.docuscan"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    // OpenCV's native library is large, so besides a universal APK one APK per CPU type is built.
    // Almost every current phone needs the arm64-v8a one.
    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "armeabi-v7a", "x86_64")
            isUniversalApk = true
        }
    }

    packaging {
        jniLibs {
            // Compressed native libraries make the APK much smaller to download.
            useLegacyPackaging = true
            // 32-bit x86 devices practically don't exist.
            excludes += "lib/x86/**"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Signed with the debug key so the release APK can be installed right away.
            // Use your own signing config before publishing the app anywhere.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(project(":core"))
    implementation(libs.opencv.android)

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.exifinterface)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    debugImplementation(libs.androidx.compose.ui.tooling)

    implementation(libs.androidx.camera.core)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
}

// ---------------------------------------------------------------------------------------------
// Guard for what the released app may do and expose.
//
// Libraries can add permissions and components to the app's manifest without any change in this
// repository (a camera library once added ACCESS_NETWORK_STATE this way). The release build
// therefore fails if its final manifest contains anything that is not on these reviewed lists.
// "${applicationId}" stands for the application id.
// ---------------------------------------------------------------------------------------------

val reviewedPermissions = setOf(
    "android.permission.CAMERA",
    // Declared and used by androidx.core itself; keeps other apps from sending broadcasts to
    // receivers the app registers at runtime.
    "\${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION",
)

/** Components other apps (or the system) can start. */
val reviewedExportedComponents = setOf(
    // The launcher icon.
    "\${applicationId}.MainActivity",
    // androidx.profileinstaller: installs the app's startup profile; only callable by the system
    // and the adb shell (requires android.permission.DUMP).
    "androidx.profileinstaller.ProfileInstallReceiver",
)

abstract class CheckManifestTask : DefaultTask() {

    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val manifest: RegularFileProperty

    @get:Input
    abstract val allowedPermissions: SetProperty<String>

    @get:Input
    abstract val allowedExportedComponents: SetProperty<String>

    @TaskAction
    fun check() {
        val androidNs = "http://schemas.android.com/apk/res/android"
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val document = factory.newDocumentBuilder().parse(manifest.get().asFile)
        val applicationId = document.documentElement.getAttribute("package")
        check(applicationId.isNotEmpty()) { "No package attribute in ${manifest.get().asFile}" }

        fun elements(tag: String): List<Element> {
            val nodes = document.getElementsByTagName(tag)
            return (0 until nodes.length).map { nodes.item(it) as Element }
        }
        fun Set<String>.resolved() = map { it.replace("\${applicationId}", applicationId) }.toSet()

        val permissions = listOf("uses-permission", "uses-permission-sdk-23", "uses-permission-sdk-m")
            .flatMap(::elements)
            .map { it.getAttributeNS(androidNs, "name") }
            .toSet()

        val exported = listOf("activity", "activity-alias", "service", "receiver", "provider")
            .flatMap(::elements)
            .filter { component ->
                when (component.getAttributeNS(androidNs, "exported")) {
                    "true" -> true
                    "false" -> false
                    // Not stated: components with an intent filter used to be exported by default.
                    else -> component.getElementsByTagName("intent-filter").length > 0
                }
            }
            .map { it.getAttributeNS(androidNs, "name") }
            .toSet()

        val problems = (permissions - allowedPermissions.get().resolved()).sorted().map { "permission $it" } +
            (exported - allowedExportedComponents.get().resolved()).sorted().map { "exported component $it" }
        if (problems.isNotEmpty()) {
            throw GradleException(
                "The release build would contain something that is not on the reviewed lists:\n" +
                    problems.joinToString("\n") { "  - $it" } +
                    "\nFind out which library adds it (app/build/outputs/logs/manifest-merger-release-report.txt). " +
                    "Remove it in AndroidManifest.xml with tools:node=\"remove\", or, if the app really " +
                    "needs it, add it to the list in app/build.gradle.kts.",
            )
        }
        logger.lifecycle("Release manifest: ${permissions.size} permissions, ${exported.size} exported components, all on the reviewed lists.")
    }
}

androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        val variantName = variant.name.replaceFirstChar { it.uppercase() }
        val checkManifest = tasks.register<CheckManifestTask>("guard${variantName}Manifest") {
            group = "verification"
            description = "Checks the permissions and exported components of the ${variant.name} build against the reviewed lists."
            manifest.set(variant.artifacts.get(SingleArtifact.MERGED_MANIFEST))
            allowedPermissions.set(reviewedPermissions)
            allowedExportedComponents.set(reviewedExportedComponents)
        }
        // No release APK without the check.
        tasks.matching { it.name == "assemble$variantName" || it.name == "bundle$variantName" }.configureEach {
            dependsOn(checkManifest)
        }
        tasks.named("check") { dependsOn(checkManifest) }
    }
}
