package com.pyom

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.apache.commons.compress.archivers.tar.TarArchiveEntry
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.gzip.GzipCompressorInputStream
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.nio.file.Paths
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {

    private val mainHandler      = Handler(Looper.getMainLooper())
    private var currentProcess: Process? = null
    private val isSetupCancelled = AtomicBoolean(false)
    private val executor         = Executors.newCachedThreadPool()

    // ══════════════════════════════════════════════════════════════════════
    // STORAGE PATHS
    //
    // Linux rootfs MUST be on external storage — internal /data is MS_NOEXEC.
    // These paths MATCH what Dart uses:
    //   getApplicationDocumentsDirectory() → getExternalFilesDir(null) on Android
    //   = /storage/emulated/0/Android/data/com.pyom/files/
    // ══════════════════════════════════════════════════════════════════════

    private val extDir   get() = getExternalFilesDir(null) ?: filesDir
    private val envRoot  get() = File(extDir,   "linux_env")
    private val binDir   get() = File(filesDir, "bin")
    private val prootBin get() = File(applicationInfo.nativeLibraryDir, "libproot.so")

    private val rootfsSources = mapOf(
        "alpine" to listOf(
            "https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/alpine-minirootfs-3.19.1-aarch64.tar.gz",
            "https://dl-cdn.alpinelinux.org/alpine/v3.18/releases/aarch64/alpine-minirootfs-3.18.6-aarch64.tar.gz",
            "https://github.com/alpinelinux/docker-alpine/raw/main/aarch64/alpine-minirootfs-3.19.0-aarch64.tar.gz",
        ),
        "ubuntu" to listOf(
            "https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.3-base-arm64.tar.gz",
            "https://cdimage.ubuntu.com/ubuntu-base/releases/20.04/release/ubuntu-base-20.04.6-base-arm64.tar.gz",
        ),
    )

    private var eventSink: EventChannel.EventSink? = null
    private val CHANNEL        = "com.pyom/linux_environment"
    private val OUTPUT_CHANNEL = "com.pyom/process_output"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, OUTPUT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(a: Any?, sink: EventChannel.EventSink?) { eventSink = sink }
                override fun onCancel(a: Any?) { eventSink = null }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setupEnvironment" -> {
                        isSetupCancelled.set(false)
                        val distro = call.argument<String>("distro") ?: "alpine"
                        val envId  = call.argument<String>("envId")  ?: "alpine-3.19"
                        executor.execute { setupEnvironment(distro, envId, result) }
                    }
                    "cancelSetup"            -> { isSetupCancelled.set(true); result.success(null) }
                    "executeCommand"         -> executeCommand(call, result)
                    "isEnvironmentInstalled" -> {
                        val envId = call.argument<String>("envId") ?: ""
                        result.success(isEnvInstalled(envId))
                    }
                    "listEnvironments"       -> result.success(listEnvironments())
                    "deleteEnvironment"      -> {
                        val envId = call.argument<String>("envId") ?: ""
                        File(envRoot, envId).deleteRecursively()
                        result.success(true)
                    }
                    "getStorageInfo" -> result.success(mapOf(
                        "filesDir"     to filesDir.absolutePath,
                        "envRoot"      to envRoot.absolutePath,
                        "freeSpaceMB"  to (extDir.freeSpace  / 1_048_576L),
                        "totalSpaceMB" to (extDir.totalSpace / 1_048_576L),
                        "prootPath"    to prootBin.absolutePath,
                        "prootExists"  to prootBin.exists(),
                    ))
                    "checkProotUpdate" -> executor.execute {
                        mainHandler.post {
                            flutterEngine?.dartExecutor?.binaryMessenger?.let { m ->
                                MethodChannel(m, CHANNEL).invokeMethod(
                                    "onProotUpdated",
                                    mapOf("version" to "bundled", "updated" to false)
                                )
                            }
                        }
                    }
                    "saveFileToDownloads" -> {
                        val src  = call.argument<String>("sourcePath") ?: ""
                        val name = call.argument<String>("fileName")   ?: "file.py"
                        saveFileToDownloads(src, name, result)
                    }
                    "shareFile" -> result.success(null)
                    else        -> result.notImplemented()
                }
            }
    }

    // ══════════════════════════════════════════════════════════════════════
    // FIX: REINSTALL ON EVERY OPEN
    // Old code only checked bin/sh — but Alpine's /bin/sh is a symlink
    // to /bin/busybox, and symlinks often fail silently (SELinux + FUSE).
    // Now also check /bin/busybox as proof of successful Alpine extraction.
    // ══════════════════════════════════════════════════════════════════════

    private fun isEnvInstalled(envId: String): Boolean {
        if (envId.isEmpty()) return false
        val dir = File(envRoot, envId)
        if (!dir.exists()) return false
        return File(dir, "bin/sh").exists()
            || File(dir, "usr/bin/sh").exists()
            || File(dir, "bin/busybox").exists()
    }

    // ══════════════════════════════════════════════════════════════════════
    // ENVIRONMENT SETUP
    // ══════════════════════════════════════════════════════════════════════

    private fun sendProgress(msg: String, progress: Double) {
        mainHandler.post {
            flutterEngine?.dartExecutor?.binaryMessenger?.let { m ->
                MethodChannel(m, CHANNEL).invokeMethod(
                    "onSetupProgress", mapOf("message" to msg, "progress" to progress)
                )
            }
        }
    }

    private fun setupEnvironment(distro: String, envId: String, result: MethodChannel.Result) {
        try {
            envRoot.mkdirs(); binDir.mkdirs()
            val envDir = File(envRoot, envId).also { it.mkdirs() }

            sendProgress("Checking proot binary…", 0.03)
            if (!prootBin.exists()) {
                mainHandler.post {
                    result.error("SETUP_ERROR",
                        "libproot.so not found. Add to jniLibs/arm64-v8a/ and " +
                        "set android:extractNativeLibs=\"true\".", null)
                }
                return
            }
            sendProgress("✅ proot ready (bundled)", 0.06)
            if (isCancelled(result)) return

            // Download
            sendProgress("Downloading $distro rootfs…", 0.10)
            val tarFile = File(extDir, "rootfs_$envId.tar.gz")
            val urls = rootfsSources[distro] ?: rootfsSources["alpine"]!!
            var downloaded = false
            for ((i, url) in urls.withIndex()) {
                sendProgress("Trying mirror ${i + 1}/${urls.size}…", 0.12 + i * 0.04)
                try { downloadWithProgress(url, tarFile, 0.12, 0.58); downloaded = true; break }
                catch (_: Exception) { tarFile.delete() }
            }
            if (!downloaded) { mainHandler.post { result.error("SETUP_ERROR", "All mirrors failed.", null) }; return }
            if (isCancelled(result)) { tarFile.delete(); return }

            // Extract
            sendProgress("Extracting rootfs…", 0.60)
            extractTarGz(tarFile, envDir)
            tarFile.delete()

            // FIX ALPINE SHELL — write wrapper scripts for busybox applets
            sendProgress("Configuring shell…", 0.74)
            fixShell(envDir, distro)
            if (isCancelled(result)) return

            // DNS
            sendProgress("Configuring network…", 0.77)
            try {
                File(envDir, "etc").mkdirs()
                File(envDir, "etc/resolv.conf").writeText("nameserver 8.8.8.8\nnameserver 1.1.1.1\n")
            } catch (_: Exception) {}

            // Python
            sendProgress("Installing Python 3 (2-5 min)…", 0.80)
            val installCmd = when (distro) {
                "ubuntu" -> "apt-get update -qq 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 python3-pip python3-dev build-essential 2>&1"
                else     -> "apk update -q 2>&1 && apk add --no-cache -q python3 py3-pip gcc musl-dev linux-headers python3-dev 2>&1"
            }
            runInProot(envId, installCmd)
            sendProgress("Upgrading pip…", 0.93)
            runInProot(envId, "pip3 install --upgrade pip setuptools wheel --quiet 2>&1 || true")

            sendProgress("✅ Environment ready!", 1.0)
            mainHandler.post { result.success(mapOf("success" to true, "distro" to distro, "envId" to envId)) }

        } catch (e: Exception) {
            mainHandler.post { result.error("SETUP_ERROR", e.message ?: "Unknown error", null) }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // FIX: ALPINE /bin/sh NOT FOUND
    //
    // Problem: Alpine's /bin/sh is a symlink → /bin/busybox.
    //   - Runtime.exec("ln -sf") → blocked by SELinux on Android 10+
    //   - NIO Files.createSymbolicLink() → may fail on external storage
    //     (sdcardfs/FUSE does not support symlinks on many devices)
    //
    // Solution: Write tiny #!/bin/sh wrapper scripts.
    //   busybox IS a real binary (not a symlink), so exec works.
    //   Busybox dispatches to the right applet from argv[0].
    // ══════════════════════════════════════════════════════════════════════

    private fun fixShell(envDir: File, distro: String) {
        if (distro != "alpine") return
        val binD = File(envDir, "bin")
        val busybox = File(binD, "busybox")
        if (!busybox.exists()) return

        fun writeWrapper(dir: File, name: String, exec: String) {
            val f = File(dir, name)
            if (f.exists() && f.length() > 20L) return  // already a real file
            try {
                f.writeText("#!/bin/busybox sh\nexec $exec \"\$@\"\n")
                f.setExecutable(true, false)
            } catch (_: Exception) {}
        }

        // Critical: /bin/sh and /bin/bash must work for proot to start
        writeWrapper(binD, "sh",   "/bin/busybox sh")
        writeWrapper(binD, "bash", "/bin/busybox sh")

        // All standard busybox applets
        for (name in listOf(
            "ls","cat","echo","pwd","mkdir","rm","cp","mv","chmod","chown",
            "grep","find","which","env","true","false","test","head","tail",
            "sed","awk","sort","uniq","cut","tr","wc","touch","ln","stat",
            "id","whoami","hostname","uname","date","ps","kill","sleep",
            "read","printf","xargs","expr","dirname","basename","realpath"
        )) {
            writeWrapper(binD, name, "/bin/busybox $name")
        }
    }

    private fun isSymlink(file: File): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Files.isSymbolicLink(file.toPath())
        else
            file.canonicalPath != file.absolutePath
    } catch (_: Exception) { false }

    // ══════════════════════════════════════════════════════════════════════
    // FIX: EXECUTE COMMAND KEY MISMATCH
    // Dart sends key 'environmentId' — old code read 'envId' → always empty
    // → proot ran with wrong rootfs path → /bin/sh not found
    // ══════════════════════════════════════════════════════════════════════

    private fun executeCommand(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val envId      = call.argument<String>("environmentId") ?: ""
                val command    = call.argument<String>("command")       ?: ""
                val workingDir = call.argument<String>("workingDir")    ?: "/"
                val timeoutMs  = call.argument<Int>("timeoutMs")        ?: 300_000

                if (envId.isEmpty()) {
                    mainHandler.post { result.error("EXEC_ERROR", "No environment selected.", null) }
                    return@execute
                }
                mainHandler.post { result.success(runCommandInProot(envId, command, workingDir, timeoutMs)) }
            } catch (e: Exception) {
                mainHandler.post { result.error("EXEC_ERROR", e.message, null) }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // PROOT RUNNER
    //
    // Flags:
    //  -k 4.14.111       → fake kernel version, prevents seccomp signal 11
    //  PROOT_NO_SECCOMP=1→ disable seccomp entirely (Ubuntu glibc)
    //  --link2symlink    → hard-links → symlinks (FUSE/external storage safe)
    //  -b filesDir:/pdata→ expose internal storage inside proot
    //  PROOT_LOADER=...  → proot self-loader path
    // ══════════════════════════════════════════════════════════════════════

    private fun runInProot(envId: String, cmd: String): String {
        val r = runCommandInProot(envId, cmd, "/", 300_000)
        return "${r["stdout"]}\n${r["stderr"]}"
    }

    private fun runCommandInProot(
        envId: String, command: String, workingDir: String, timeoutMs: Int
    ): Map<String, Any> {
        val envDir = File(envRoot, envId)
        val tmpDir = File(envDir, "tmp").also { it.mkdirs() }

        if (!prootBin.exists()) return mapOf(
            "stdout" to "", "exitCode" to -1,
            "stderr" to "proot not found: ${prootBin.absolutePath}"
        )

        val shell = listOf("bin/sh", "bin/bash", "usr/bin/sh", "usr/bin/bash")
            .map { File(envDir, it) }
            .firstOrNull { it.exists() }
            ?.absolutePath?.removePrefix(envDir.absolutePath)
            ?: "/bin/sh"

        val args = mutableListOf(
            prootBin.absolutePath, "--kill-on-exit",
            "-k", "4.14.111",
            "--link2symlink",
            "-r", envDir.absolutePath,
            "-w", workingDir,
            "-b", "/dev", "-b", "/proc", "-b", "/sys",
            "-b", "${filesDir.absolutePath}:/pdata",
            "-0",
            shell, "-c", command
        )

        val pb = ProcessBuilder(args).apply {
            directory(filesDir)
            redirectErrorStream(false)
            environment().apply {
                put("HOME",                    "/root")
                put("PATH",                    "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
                put("LANG",                    "C.UTF-8")
                put("LC_ALL",                  "C.UTF-8")
                put("TERM",                    "xterm-256color")
                put("COLORTERM",               "truecolor")
                put("TMPDIR",                  "/tmp")
                put("PROOT_TMP_DIR",           tmpDir.absolutePath)
                put("PROOT_NO_SECCOMP",        "1")
                put("PROOT_LOADER",            "/proc/self/exe")
                put("PYTHONDONTWRITEBYTECODE", "1")
                put("PIP_NO_CACHE_DIR",        "off")
            }
        }

        val process = pb.start().also { currentProcess = it }
        val stdout = StringBuilder(); val stderr = StringBuilder()

        val t1 = Thread {
            process.inputStream.bufferedReader().lines().forEach { line ->
                stdout.append(line).append('\n')
                mainHandler.post { eventSink?.success(line) }
            }
        }
        val t2 = Thread {
            process.errorStream.bufferedReader().lines().forEach { line ->
                stderr.append(line).append('\n')
                mainHandler.post { eventSink?.success("[err] $line") }
            }
        }
        t1.start(); t2.start()
        val done = process.waitFor(timeoutMs.toLong(), java.util.concurrent.TimeUnit.MILLISECONDS)
        t1.join(3_000); t2.join(3_000)

        return if (done) mapOf(
            "stdout" to stdout.toString(), "stderr" to stderr.toString(), "exitCode" to process.exitValue()
        ) else {
            process.destroyForcibly()
            mapOf("stdout" to stdout.toString(), "stderr" to "Timed out after ${timeoutMs/1000}s", "exitCode" to -1)
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // EXTRACT TAR.GZ — NIO symlinks + shell wrapper fallback
    // ══════════════════════════════════════════════════════════════════════

    private fun extractTarGz(tarFile: File, destDir: File) {
        destDir.mkdirs()
        data class PendingLink(val link: File, val target: String, val isExec: Boolean)
        val pending = mutableListOf<PendingLink>()

        TarArchiveInputStream(
            GzipCompressorInputStream(BufferedInputStream(tarFile.inputStream()))
        ).use { tar ->
            var entry: TarArchiveEntry? = tar.nextTarEntry
            while (entry != null) {
                if (!tar.canReadEntryData(entry)) { entry = tar.nextTarEntry; continue }
                val name = entry.name.removePrefix("./").removePrefix("/")
                if (name.isEmpty() || name == ".") { entry = tar.nextTarEntry; continue }
                val target = File(destDir, name)
                if (!target.canonicalPath.startsWith(destDir.canonicalPath)) { entry = tar.nextTarEntry; continue }

                when {
                    entry.isDirectory    -> target.mkdirs()
                    entry.isSymbolicLink -> pending.add(PendingLink(target, entry.linkName, entry.mode and 0b001001001 != 0))
                    else -> {
                        target.parentFile?.mkdirs()
                        FileOutputStream(target).use { tar.copyTo(it) }
                        if (entry.mode and 0b001001001 != 0) target.setExecutable(true, false)
                    }
                }
                entry = tar.nextTarEntry
            }
        }

        // Apply symlinks after all regular files extracted
        for ((link, linkTarget, isExec) in pending) {
            link.parentFile?.mkdirs()
            if (link.exists() && !isSymlink(link)) link.delete()
            if (link.exists()) continue

            var ok = false
            // Try NIO symlink first
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try { Files.createSymbolicLink(link.toPath(), Paths.get(linkTarget)); ok = true }
                catch (_: Exception) {}
            }
            // Fallback: shell wrapper for executable bin/* entries
            if (!ok && isExec && link.parentFile?.name?.contains("bin") == true) {
                try {
                    val abs = if (linkTarget.startsWith("/")) linkTarget
                              else "${link.parentFile!!.absolutePath.removePrefix(destDir.absolutePath)}/$linkTarget"
                    link.writeText("#!/bin/sh\nexec $abs \"\$@\"\n")
                    link.setExecutable(true, false)
                } catch (_: Exception) {}
            }
        }
    }

    private fun isCancelled(result: MethodChannel.Result): Boolean {
        if (!isSetupCancelled.get()) return false
        mainHandler.post { result.error("CANCELLED", "Cancelled.", null) }
        return true
    }

    private fun listEnvironments(): List<Map<String, Any>> {
        if (!envRoot.exists()) return emptyList()
        return envRoot.listFiles()?.filter { it.isDirectory }?.map { dir ->
            mapOf("id" to dir.name, "path" to dir.absolutePath, "exists" to isEnvInstalled(dir.name))
        } ?: emptyList()
    }

    private fun downloadWithProgress(url: String, dest: File, p0: Double, p1: Double) {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 30_000; readTimeout = 180_000; instanceFollowRedirects = true; connect()
        }
        val total = conn.contentLengthLong.toDouble(); var bytes = 0L
        conn.inputStream.use { inp -> FileOutputStream(dest).use { out ->
            val buf = ByteArray(65_536); var n: Int
            while (inp.read(buf).also { n = it } != -1) {
                out.write(buf, 0, n); bytes += n
                if (total > 0) sendProgress("Downloading… ${bytes/1_048_576} MB", p0 + (bytes/total)*(p1-p0))
            }
        }}
        conn.disconnect()
    }

    private fun saveFileToDownloads(sourcePath: String, fileName: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                val src = File(sourcePath)
                if (!src.exists()) { mainHandler.post { result.error("NOT_FOUND", "Not found: $sourcePath", null) }; return@execute }
                val savedPath: String
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val mime = when { fileName.endsWith(".py") -> "text/x-python"; fileName.endsWith(".txt") -> "text/plain"; fileName.endsWith(".json") -> "application/json"; else -> "application/octet-stream" }
                    val cv = ContentValues().apply { put(MediaStore.Downloads.DISPLAY_NAME, fileName); put(MediaStore.Downloads.MIME_TYPE, mime); put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Pyom") }
                    val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv)!!
                    contentResolver.openOutputStream(uri)!!.use { os -> src.inputStream().use { it.copyTo(os) } }
                    savedPath = "Downloads/Pyom/$fileName"
                } else {
                    @Suppress("DEPRECATION")
                    val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "Pyom").also { it.mkdirs() }
                    src.copyTo(File(dir, fileName), overwrite = true); savedPath = "${dir.absolutePath}/$fileName"
                }
                mainHandler.post { result.success(mapOf("success" to true, "path" to savedPath)) }
            } catch (e: Exception) { mainHandler.post { result.error("SAVE_ERROR", e.message, null) } }
        }
    }

    override fun onDestroy() { super.onDestroy(); currentProcess?.destroyForcibly(); executor.shutdown() }
}
