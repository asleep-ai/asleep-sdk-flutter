group = "ai.asleep.asleep_sdk_flutter"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "ai.asleep.asleep_sdk_flutter"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
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
    implementation("ai.asleep:asleepsdk:3.2.1") {
        exclude(group = "com.android.support")
    }
    implementation("com.google.code.gson:gson:2.10.1")
    implementation("androidx.core:core-ktx:1.17.0")
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}

val verifyLibraryManifestPolicy by tasks.registering {
    val manifestFile = layout.projectDirectory.file("src/main/AndroidManifest.xml")
    inputs.file(manifestFile)

    doLast {
        check(
            "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" !in
                manifestFile.asFile.readText(),
        ) {
            "The Flutter library must not force battery-optimization exemption into consumer manifests"
        }
    }
}

tasks.configureEach {
    if (name.startsWith("test") && name.endsWith("UnitTest")) {
        dependsOn(verifyLibraryManifestPolicy)
    }
}
