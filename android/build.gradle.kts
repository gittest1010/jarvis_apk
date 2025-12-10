// Yeh file android/build.gradle.kts location par honi chahiye
// (android/app/build.gradle.kts se alag hai)

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Build directory ko sahi location (root ke bahar) set karne ka logic
// Explicit types (e.g. ": Directory") hata diye gaye hain taaki import errors na aayein
val newBuildDir = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}