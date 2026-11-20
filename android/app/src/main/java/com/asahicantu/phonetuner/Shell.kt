package com.asahicantu.phonetuner

import android.content.ComponentName
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.IBinder
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import rikka.shizuku.Shizuku
import kotlin.system.exitProcess

/** Runs in Shizuku's shell-privileged process (same rights as `adb shell`). */
class ShellService : IShellService.Stub() {
    override fun destroy() = exitProcess(0)

    override fun exec(command: String): String = try {
        val p = ProcessBuilder("sh", "-c", command).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().use { it.readText() }
        val code = p.waitFor()
        // Binder transactions are limited to ~1 MB; keep replies well below that.
        val body = if (out.length > MAX_CHARS) out.take(MAX_CHARS) + "\n…[output truncated]" else out
        "$code\n$body"
    } catch (e: Exception) {
        "-1\n$e"
    }

    private companion object { const val MAX_CHARS = 200_000 }
}

data class ShellResult(val code: Int, val out: String) {
    val ok get() = code == 0 && !FAILURE.containsMatchIn(out)
    private companion object { val FAILURE = Regex("Exception|Failure|Error:|Unknown package") }
}

/** Client side: connects to Shizuku, binds [ShellService], runs commands. */
object Shell {
    enum class Status { NO_SHIZUKU, NO_PERMISSION, CONNECTING, READY }

    var status by mutableStateOf(Status.NO_SHIZUKU)
        private set

    private var service: IShellService? = null
    private const val REQUEST_CODE = 4711

    private val args by lazy {
        Shizuku.UserServiceArgs(ComponentName(BuildConfig.APPLICATION_ID, ShellService::class.java.name))
            .daemon(false)
            .processNameSuffix("shell")
            .debuggable(BuildConfig.DEBUG)
            .version(BuildConfig.VERSION_CODE)
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = binder?.takeIf { it.pingBinder() }?.let(IShellService.Stub::asInterface)
            status = if (service != null) Status.READY else Status.NO_SHIZUKU
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            refresh()
        }
    }

    fun init() {
        Shizuku.addBinderReceivedListenerSticky { refresh() }
        Shizuku.addBinderDeadListener { service = null; status = Status.NO_SHIZUKU }
        Shizuku.addRequestPermissionResultListener { _, _ -> refresh() }
    }

    fun refresh() {
        status = when {
            !Shizuku.pingBinder() || Shizuku.isPreV11() -> Status.NO_SHIZUKU
            Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED -> Status.NO_PERMISSION
            service != null -> Status.READY
            else -> { Shizuku.bindUserService(args, connection); Status.CONNECTING }
        }
    }

    fun requestPermission() {
        if (Shizuku.pingBinder()) Shizuku.requestPermission(REQUEST_CODE)
    }

    val ready get() = status == Status.READY && service != null

    suspend fun run(command: String): ShellResult = withContext(Dispatchers.IO) {
        val s = service ?: return@withContext ShellResult(-1, "Not connected to Shizuku.")
        try {
            val raw = s.exec(command)
            ShellResult(raw.substringBefore('\n').toIntOrNull() ?: -1, raw.substringAfter('\n', ""))
        } catch (e: Exception) {
            ShellResult(-1, e.toString())
        }
    }
}
