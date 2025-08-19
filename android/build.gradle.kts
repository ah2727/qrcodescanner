// android/build.gradle.kts
import java.io.File
import org.gradle.api.Project

// 1) مخازن
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// 2) متمرکز کردن خروجی بیلد به ../../build/<module>
val rootOutDir = file("../../build")
rootProject.buildDir = rootOutDir

subprojects {
    buildDir = File(rootOutDir, name)
    // اگر واقعاً لازمته نگه دار؛ اغلب نیاز نیست:
    // evaluationDependsOn(":app")

    // برای کتابخانه‌های اندرویدی
    plugins.withId("com.android.library") {
        applyNamespaceIfMissing()
    }
    // برای اپلیکیشن‌های اندرویدی
    plugins.withId("com.android.application") {
        applyNamespaceIfMissing()
    }
}

// 3) هلسپر: ست‌کردن namespace اگر خالی بود (بدون afterEvaluate)
fun Project.applyNamespaceIfMissing() {
    val androidExt = extensions.findByName("android") ?: return

    // خواندن namespace فعلی با ریفلکشن (AGP 7/8)
    val getNs = androidExt.javaClass.methods.firstOrNull {
        it.name == "getNamespace" && it.parameterTypes.isEmpty()
    }
    val currentNs = getNs?.invoke(androidExt) as? String

    if (!currentNs.isNullOrBlank()) return

    // تلاش برای استخراج package از مانیفست
    val manifestFile = file("src/main/AndroidManifest.xml")
    var manifestPkg: String? = null
    if (manifestFile.exists()) {
        val text = manifestFile.readText()
        val match = Regex("""<manifest[^>]*\bpackage\s*=\s*"([^"]+)"""").find(text)
        manifestPkg = match?.groupValues?.getOrNull(1)
    }

    val finalNs = manifestPkg?.takeIf { it.isNotBlank() }
        ?: "fix.${name.replace("-", "_")}"

    // ست کردن namespace با ریفلکشن
    val setNs = androidExt.javaClass.methods.firstOrNull {
        it.name == "setNamespace" && it.parameterTypes.size == 1
    }
    setNs?.invoke(androidExt, finalNs)

    println("Applied namespace '$finalNs' to module '$name'")
}

// 4) clean
tasks.register<Delete>("clean") {
    delete(rootProject.buildDir)
}
