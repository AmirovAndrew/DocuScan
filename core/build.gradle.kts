import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    // Pure image-processing logic. It is written against the OpenCV Java API only:
    // the Android app supplies the real library (org.opencv:opencv AAR) at runtime,
    // while the desktop build below is used to compile and to run unit tests on the JVM.
    compileOnly(libs.opencv.desktop)

    testImplementation(libs.opencv.desktop)
    testImplementation(libs.junit)
}
