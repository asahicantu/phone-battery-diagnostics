package com.asahicantu.phonetuner

// Pure logic (no Android APIs) so it can be unit-tested on the PC. Mirrors Invoke-PhoneTuning.ps1.

private val PACKAGE_REGEX = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+$")

/** Package names are pasted into shell commands: accept only real package names. */
fun isValidPackage(name: String) = PACKAGE_REGEX.matches(name)

/** One shell command plus the command that reverts it (null = not revertible). */
data class Cmd(val label: String, val target: String, val command: String, val undo: String?)

enum class PkgAction(val title: String, private val doFmt: String, private val undoFmt: String?) {
    RESTRICT("Restrict background", "cmd appops set --user 0 %s RUN_ANY_IN_BACKGROUND ignore", "cmd appops set --user 0 %s RUN_ANY_IN_BACKGROUND allow"),
    ALLOW("Allow background", "cmd appops set --user 0 %s RUN_ANY_IN_BACKGROUND allow", "cmd appops set --user 0 %s RUN_ANY_IN_BACKGROUND ignore"),
    FORCE_STOP("Force stop", "am force-stop --user 0 %s", null),
    DISABLE("Disable", "pm disable-user --user 0 %s", "pm enable --user 0 %s"),
    ENABLE("Enable", "pm enable --user 0 %s", "pm disable-user --user 0 %s");

    fun cmd(pkg: String): Cmd {
        require(isValidPackage(pkg)) { "Invalid package name: $pkg" }
        return Cmd(title, pkg, doFmt.format(pkg), undoFmt?.format(pkg))
    }
}

val KILL_ALL = Cmd("Kill cached background apps", "all background apps", "am kill-all", null)

enum class Advice(val label: String) {
    RESTRICT("Restrict"), KEEP("Keep"), DISABLE_SAFE("Disable (safe)"),
    DISABLE_OPTIONAL("Disable (optional)"), NEVER("Never touch"), RARE("Rarely used")
}

data class Proc(var procs: Int = 0, var ramMb: Double = 0.0, val users: MutableSet<Int> = sortedSetOf())

val BUCKET_NAMES = mapOf(5 to "exempted", 10 to "active", 20 to "working set", 30 to "frequent", 40 to "rare", 45 to "restricted", 50 to "never")

data class QuickCheck(
    val screenOffHours: Double, val screenOffPct: Int, val screenOffRate: Double,
    val wifiWakeups: Int, val totalWakeups: Int, val multicastHolders: List<String>,
    val users: List<String>, val memAvailableMb: Int, val swapUsedMb: Int,
)

object Parsers {
    /** `pm list packages` output -> package names. */
    fun packages(out: String): Set<String> = out.lineSequence().map { it.trim() }
        .filter { it.startsWith("package:") }.map { it.removePrefix("package:").substringBefore(' ') }.toSet()

    /** One package per line (cmd appops query-op). */
    fun plainPackages(out: String): Set<String> = out.lineSequence().map { it.trim() }.filter(::isValidPackage).toSet()

    /** `am get-standby-bucket` -> package to bucket. */
    fun buckets(out: String): Map<String, Int> = out.lineSequence().mapNotNull {
        Regex("^(\\S+): (\\d+)$").find(it.trim())?.let { m -> m.groupValues[1] to m.groupValues[2].toInt() }
    }.toMap()

    /** `ps -A -o USER,RSS,NAME` -> package to processes/RAM/users (app UIDs only). */
    fun processes(out: String): Map<String, Proc> {
        val map = linkedMapOf<String, Proc>()
        out.lineSequence().drop(1).forEach { line ->
            val f = line.trim().split(Regex("\\s+"))
            if (f.size < 3) return@forEach
            val user = Regex("^u(\\d+)_a").find(f[0])?.groupValues?.get(1)?.toInt() ?: return@forEach
            val p = map.getOrPut(f[2].substringBefore(':')) { Proc() }
            p.procs++
            p.ramMb += (f[1].toDoubleOrNull() ?: 0.0) / 1024
            p.users += user
        }
        return map
    }

    /** "1h 2m 3s 500ms" -> seconds. */
    fun seconds(text: String): Double = Regex("(\\d+)(ms|d|h|m|s)\\b").findAll(text).sumOf {
        val n = it.groupValues[1].toDouble()
        when (it.groupValues[2]) { "d" -> n * 86400; "h" -> n * 3600; "m" -> n * 60; "s" -> n; else -> n / 1000 }
    }

    fun quickCheck(drain: String, wakeups: String, wifi: String, users: String, meminfo: String): QuickCheck {
        val offH = Regex("Time on battery screen off: (.+?) \\(").find(drain)?.groupValues?.get(1)?.let { seconds(it) / 3600 } ?: 0.0
        val pct = Regex("Amount discharged while screen off: (\\d+)").find(drain)?.groupValues?.get(1)?.toInt() ?: 0
        var wifiCount = 0; var total = 0
        // Reason names contain ": " themselves ("Abort: Last active Wakeup Source: qcom,cnss-kiwi"), so the
        // name runs up to the LAST ": <digit>" on the line (where the duration starts).
        Regex("Wakeup reason (.+): \\d[^(\\n]*\\((\\d+) times\\)").findAll(wakeups).forEach {
            val n = it.groupValues[2].toInt()
            total += n
            if (Regex("wlan|cnss|wifi", RegexOption.IGNORE_CASE).containsMatchIn(it.groupValues[1])) wifiCount += n
        }
        val holders = Regex("Multicaster\\{(\\S+) uid=(\\d+)\\}").findAll(wifi).map { "${it.groupValues[1]} (uid ${it.groupValues[2]})" }.distinct().toList()
        val running = users.lineSequence().filter { it.contains("running") }
            .mapNotNull { Regex("UserInfo\\{(\\d+):([^:]*):").find(it)?.let { m -> "${m.groupValues[1]} ${m.groupValues[2]}" } }.toList()
        fun kb(key: String) = Regex("$key:\\s+(\\d+) kB").find(meminfo)?.groupValues?.get(1)?.toLong() ?: 0L
        return QuickCheck(
            screenOffHours = offH, screenOffPct = pct, screenOffRate = if (offH > 0.5) pct / offH else 0.0,
            wifiWakeups = wifiCount, totalWakeups = total, multicastHolders = holders, users = running,
            memAvailableMb = (kb("MemAvailable") / 1024).toInt(), swapUsedMb = ((kb("SwapTotal") - kb("SwapFree")) / 1024).toInt(),
        )
    }

    /** Same rules as the PowerShell script. */
    fun advice(pkg: String, catalog: Catalog, isUserApp: Boolean, bucket: Int?, running: Boolean): Pair<Advice?, String> {
        catalog.restrict.find { it.pkg == pkg }?.let { return Advice.RESTRICT to it.reason }
        catalog.keep.find { it.pkg == pkg }?.let { return Advice.KEEP to it.reason }
        catalog.safe.find { it.pkg == pkg }?.let { return Advice.DISABLE_SAFE to listOf(it.name, it.note).filter(String::isNotBlank).joinToString(". ") }
        catalog.optional.find { it.pkg == pkg }?.let { return Advice.DISABLE_OPTIONAL to listOf(it.name, it.note).filter(String::isNotBlank).joinToString(". ") }
        catalog.never.find { it.pkg == pkg }?.let { return Advice.NEVER to it.note }
        if (isUserApp && bucket != null && bucket >= 40 && !running) return Advice.RARE to "Not used lately. Uninstall if you no longer need it."
        return null to ""
    }
}
