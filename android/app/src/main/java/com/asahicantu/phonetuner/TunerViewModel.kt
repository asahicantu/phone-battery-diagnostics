package com.asahicantu.phonetuner

import android.app.Application
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

data class AppRow(
    val pkg: String, val label: String, val userApp: Boolean, val installed: Boolean,
    val proc: Proc?, val restricted: Boolean?, val disabled: Boolean, val bucket: Int?,
    val advice: Advice?, val why: String,
)

data class LogEntry(
    val time: String, val label: String, val target: String, val command: String,
    val undo: String?, val ok: Boolean, val output: String, val undoOf: String?,
) {
    val key get() = "$time|$target"
}

class TunerViewModel(app: Application) : AndroidViewModel(app) {
    val catalog = Catalog.load(app)
    private val pm = app.packageManager
    private val logFile = File(app.filesDir, "actions.jsonl")

    var apps by mutableStateOf<List<AppRow>>(emptyList()); private set
    var loading by mutableStateOf(false); private set
    var lastError by mutableStateOf<String?>(null)
    var log by mutableStateOf(readLog()); private set
    var quick by mutableStateOf<QuickCheck?>(null); private set
    val diagOutput = mutableStateMapOf<String, String>()
    val tipValues = mutableStateMapOf<String, String>()
    var message by mutableStateOf<String?>(null)

    // ---------------- apps ----------------
    fun refresh() = viewModelScope.launch {
        loading = true
        try {
            apps = if (Shell.ready) loadWithShell() else loadWithoutShell()
            if (Shell.ready) loadTipValues()
        } catch (e: Exception) {
            lastError = e.toString()
        } finally {
            loading = false
        }
    }

    private suspend fun loadWithShell(): List<AppRow> {
        val all = Parsers.packages(Shell.run("pm list packages --user 0").out)
        val third = Parsers.packages(Shell.run("pm list packages -3 --user 0").out)
        val disabled = Parsers.packages(Shell.run("pm list packages -d --user 0").out)
        val restricted = Parsers.plainPackages(Shell.run("cmd appops query-op --user 0 RUN_ANY_IN_BACKGROUND ignore").out)
        val buckets = Parsers.buckets(Shell.run("am get-standby-bucket").out)
        val procs = Parsers.processes(Shell.run("ps -A -o USER,RSS,NAME").out)
        val interesting = (third + catalogPkgs() + procs.keys.filter { it in third }).filter { it in all }
        return withContext(Dispatchers.Default) {
            interesting.map { p ->
                val proc = procs[p]
                val (adv, why) = Parsers.advice(p, catalog, p in third, buckets[p], proc != null)
                AppRow(p, label(p), p in third, true, proc, p in restricted, p in disabled, buckets[p], adv, why)
            }
        }
    }

    /** Without Shizuku we can still list apps and give advice; actions become "copy adb commands". */
    private suspend fun loadWithoutShell(): List<AppRow> = withContext(Dispatchers.Default) {
        val installed = pm.getInstalledApplications(PackageManager.MATCH_DISABLED_COMPONENTS).associateBy { it.packageName }
        val wanted = installed.values.filter { it.flags and ApplicationInfo.FLAG_SYSTEM == 0 }.map { it.packageName } +
            catalogPkgs().filter { it in installed }
        wanted.distinct().map { p ->
            val info = installed.getValue(p)
            val user = info.flags and ApplicationInfo.FLAG_SYSTEM == 0
            val (adv, why) = Parsers.advice(p, catalog, user, null, false)
            AppRow(p, info.loadLabel(pm).toString(), user, true, null, null, !info.enabled, null, adv, why)
        }
    }

    private fun catalogPkgs() = catalog.restrict.map { it.pkg } + catalog.keep.map { it.pkg } +
        catalog.safe.map { it.pkg } + catalog.optional.map { it.pkg } + catalog.never.map { it.pkg }

    private fun label(pkg: String) = try {
        pm.getApplicationInfo(pkg, PackageManager.MATCH_DISABLED_COMPONENTS).loadLabel(pm).toString()
    } catch (_: Exception) { pkg }

    fun isInstalled(pkg: String) = apps.any { it.pkg == pkg }
    fun row(pkg: String) = apps.find { it.pkg == pkg }

    // ---------------- running commands ----------------
    fun execute(cmds: List<Cmd>, undoOf: Map<Cmd, String> = emptyMap()) = viewModelScope.launch {
        var ok = 0
        val failed = mutableListOf<String>()
        for (c in cmds) {
            val r = Shell.run(c.command)
            appendLog(LogEntry(now(), c.label, c.target, c.command, c.undo, r.ok, r.out.trim().take(300), undoOf[c]))
            if (r.ok) ok++ else failed += "${c.target}: ${r.out.trim().take(120)}"
        }
        message = "$ok of ${cmds.size} done." + if (failed.isNotEmpty()) " Failed: " + failed.joinToString("; ") else ""
        refresh()
    }

    fun undo(entry: LogEntry) {
        val u = entry.undo ?: return
        val c = Cmd("Undo: ${entry.label}", entry.target, u, entry.command)
        execute(listOf(c), mapOf(c to entry.key))
    }

    fun undoneKeys() = log.mapNotNull { it.undoOf }.toSet()

    // ---------------- tips ----------------
    private suspend fun loadTipValues() {
        for (t in catalog.tips) t.check?.let { tipValues[t.id] = Shell.run(it).out.trim() }
    }

    fun tipCmd(t: Tip, undo: Boolean): Cmd? {
        val c = (if (undo) t.undo else t.command) ?: return null
        return Cmd(if (undo) "Revert: ${t.title}" else "Setting: ${t.title}", t.id, c, if (undo) t.command else t.undo)
    }

    // ---------------- diagnostics ----------------
    fun runDiag(d: Diag) = viewModelScope.launch {
        diagOutput[d.id] = "Running…"
        diagOutput[d.id] = Shell.run(d.command).out.ifBlank { "(no output)" }
    }

    fun runQuickCheck() = viewModelScope.launch {
        quick = Parsers.quickCheck(
            drain = Shell.run("dumpsys batterystats | grep -E 'Time on battery screen off|Amount discharged while screen off'").out,
            wakeups = Shell.run("dumpsys batterystats | grep -E '^  Wakeup reason'").out,
            wifi = Shell.run("dumpsys wifi | grep -E 'Multicaster'").out,
            users = Shell.run("pm list users").out,
            meminfo = Shell.run("cat /proc/meminfo").out,
        )
    }

    // ---------------- journal (undo log) ----------------
    private fun now() = LocalDateTime.now().format(DateTimeFormatter.ISO_LOCAL_DATE_TIME).take(19)

    private fun appendLog(e: LogEntry) {
        val o = JSONObject().put("time", e.time).put("label", e.label).put("target", e.target).put("command", e.command)
            .put("undo", e.undo ?: JSONObject.NULL).put("ok", e.ok).put("output", e.output).put("undoOf", e.undoOf ?: JSONObject.NULL)
        logFile.appendText(o.toString() + "\n")
        log = readLog()
    }

    private fun readLog(): List<LogEntry> = if (!logFile.exists()) emptyList() else logFile.readLines().filter(String::isNotBlank).mapNotNull {
        try {
            val o = JSONObject(it)
            LogEntry(o.getString("time"), o.getString("label"), o.getString("target"), o.getString("command"),
                o.optString("undo").takeIf { u -> u.isNotEmpty() && u != "null" }, o.getBoolean("ok"), o.optString("output"),
                o.optString("undoOf").takeIf { u -> u.isNotEmpty() && u != "null" })
        } catch (_: Exception) { null }
    }.reversed()
}
