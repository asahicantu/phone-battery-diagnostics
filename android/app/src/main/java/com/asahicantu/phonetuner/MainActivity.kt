@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)

package com.asahicantu.phonetuner

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Shell.init()
        setContent { AppTheme { TunerApp() } }
    }

    override fun onResume() {
        super.onResume()
        Shell.refresh()
    }
}

@Composable
private fun AppTheme(content: @Composable () -> Unit) {
    val ctx = LocalContext.current
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx), content = content)
}

private enum class Tab(val title: String, val glyph: String) {
    APPS("Apps", "▦"), DEBLOAT("Debloat", "⌫"), FIXES("Fixes", "✓"), DIAG("Diagnose", "≡"), LOG("Log", "↺")
}

@Composable
private fun TunerApp(vm: TunerViewModel = viewModel()) {
    var tab by rememberSaveable { mutableStateOf(Tab.APPS) }
    var pending by remember { mutableStateOf<List<Cmd>?>(null) }
    val snackbar = remember { SnackbarHostState() }
    val status = Shell.status
    val ctx = LocalContext.current

    LaunchedEffect(status) { if (status == Shell.Status.READY || status == Shell.Status.NO_SHIZUKU) vm.refresh() }
    LaunchedEffect(vm.message) { vm.message?.let { snackbar.showSnackbar(it); vm.message = null } }
    LaunchedEffect(vm.lastError) { vm.lastError?.let { snackbar.showSnackbar("Error: $it"); vm.lastError = null } }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("Phone Tuner")
                        Text(statusText(status), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                },
                actions = { TextButton(onClick = { Shell.refresh(); vm.refresh() }) { Text("Refresh") } },
            )
        },
        bottomBar = {
            NavigationBar {
                Tab.entries.forEach {
                    NavigationBarItem(selected = tab == it, onClick = { tab = it }, icon = { Text(it.glyph, fontSize = 18.sp) }, label = { Text(it.title) })
                }
            }
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            if (status != Shell.Status.READY) ShizukuBanner(status)
            if (vm.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            val request: (List<Cmd>) -> Unit = { if (it.isNotEmpty()) pending = it }
            when (tab) {
                Tab.APPS -> AppsScreen(vm, request)
                Tab.DEBLOAT -> DebloatScreen(vm, request)
                Tab.FIXES -> FixesScreen(vm, request)
                Tab.DIAG -> DiagScreen(vm)
                Tab.LOG -> LogScreen(vm)
            }
        }
    }

    pending?.let { cmds ->
        ConfirmDialog(
            cmds = cmds, catalog = vm.catalog, canRun = Shell.ready,
            onRun = { vm.execute(cmds); pending = null },
            onCopy = { copy(ctx, cmds.joinToString("\n") { "adb shell ${it.command}" }); vm.message = "Copied ${cmds.size} adb command(s). Paste them in a PC terminal."; pending = null },
            onDismiss = { pending = null },
        )
    }
}

private fun statusText(s: Shell.Status) = when (s) {
    Shell.Status.READY -> "Connected via Shizuku: commands run on this phone"
    Shell.Status.CONNECTING -> "Connecting to Shizuku…"
    Shell.Status.NO_PERMISSION -> "Shizuku running: permission needed"
    Shell.Status.NO_SHIZUKU -> "PC mode: commands are copied for adb"
}

@Composable
private fun ShizukuBanner(status: Shell.Status) {
    val ctx = LocalContext.current
    Card(Modifier.fillMaxWidth().padding(12.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            when (status) {
                Shell.Status.NO_PERMISSION -> {
                    Text("Allow Phone Tuner in Shizuku to run commands on this phone.", fontWeight = FontWeight.SemiBold)
                    Button(onClick = { Shell.requestPermission() }) { Text("Grant permission") }
                }
                Shell.Status.CONNECTING -> Text("Connecting to the shell service…")
                else -> {
                    Text("Shizuku is not running", fontWeight = FontWeight.SemiBold)
                    Text(
                        "You can still browse advice; every action is copied as adb commands to run from your PC. " +
                            "To run commands directly on the phone: install Shizuku, start it (Wireless debugging on the phone, " +
                            "or the \"Start via adb\" command shown in Shizuku from your PC), then come back.",
                        style = MaterialTheme.typography.bodySmall,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = { open(ctx, Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=moe.shizuku.privileged.api"))) }) { Text("Get Shizuku") }
                        OutlinedButton(onClick = { Shell.refresh() }) { Text("Retry") }
                    }
                }
            }
        }
    }
}

@Composable
private fun ConfirmDialog(cmds: List<Cmd>, catalog: Catalog, canRun: Boolean, onRun: () -> Unit, onCopy: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (canRun) "Run ${cmds.size} command(s)?" else "Copy ${cmds.size} adb command(s)?") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                cmds.forEach { c ->
                    Column {
                        Text("${c.label}: ${c.target}", fontWeight = FontWeight.SemiBold)
                        catalog.keep.find { it.pkg == c.target }?.let { Text("⚠ Keep-list app: ${it.reason}", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                        Text(c.command, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
                        Text(if (c.undo != null) "Undo: ${c.undo}" else "No undo needed (temporary)", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        },
        confirmButton = { if (canRun) Button(onClick = onRun) { Text("Run") } else Button(onClick = onCopy) { Text("Copy for PC") } },
        dismissButton = {
            Row {
                if (canRun) TextButton(onClick = onCopy) { Text("Copy") }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}

// ------------------------------------------------------------------ Apps
private enum class AppFilter(val title: String) { RUNNING("Running"), RECOMMENDED("Recommended"), RESTRICTED("Restricted"), ALL("All apps") }

@Composable
private fun AppsScreen(vm: TunerViewModel, request: (List<Cmd>) -> Unit) {
    var filter by rememberSaveable { mutableStateOf(AppFilter.RUNNING) }
    var query by rememberSaveable { mutableStateOf("") }
    val selected = remember { mutableStateListOf<String>() }
    var detail by remember { mutableStateOf<AppRow?>(null) }
    val pendingAdvice = { r: AppRow -> (r.advice == Advice.RESTRICT || r.advice == Advice.RARE) && r.restricted != true && !r.disabled }

    val rows = vm.apps.filter {
        when (filter) {
            AppFilter.RUNNING -> it.proc != null
            AppFilter.RECOMMENDED -> pendingAdvice(it)
            AppFilter.RESTRICTED -> it.restricted == true || it.disabled
            AppFilter.ALL -> it.userApp
        } && (query.isBlank() || it.label.contains(query, true) || it.pkg.contains(query, true))
    }.sortedWith(compareByDescending<AppRow> { it.proc?.ramMb ?: 0.0 }.thenBy { it.label.lowercase() })

    Column(Modifier.fillMaxSize()) {
        Column(Modifier.padding(horizontal = 12.dp)) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                AppFilter.entries.forEach { FilterChip(selected = filter == it, onClick = { filter = it }, label = { Text(it.title) }) }
            }
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), placeholder = { Text("Search apps") }, singleLine = true)
            val running = vm.apps.filter { it.proc != null }
            Text(
                if (Shell.ready) "${running.size} apps running · ${running.sumOf { it.proc!!.ramMb }.toInt()} MB · ${rows.size} shown"
                else "${rows.size} shown · running state needs Shizuku",
                style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(vertical = 6.dp),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { selected.clear(); selected += vm.apps.filter { it.advice == Advice.RESTRICT && pendingAdvice(it) }.map { it.pkg } }) { Text("Select recommended") }
                OutlinedButton(onClick = { request(listOf(KILL_ALL)) }) { Text("Kill background") }
            }
        }
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(rows, key = { it.pkg }) { r ->
                AppItem(r, r.pkg in selected, onCheck = { if (it) selected += r.pkg else selected -= r.pkg }, onClick = { detail = r })
            }
        }
        if (selected.isNotEmpty()) {
            Surface(tonalElevation = 3.dp) {
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("${selected.size} selected")
                    Button(onClick = { request(selected.map { PkgAction.RESTRICT.cmd(it) }) }) { Text("Restrict") }
                    OutlinedButton(onClick = { request(selected.map { PkgAction.ALLOW.cmd(it) }) }) { Text("Allow") }
                    OutlinedButton(onClick = { request(selected.map { PkgAction.FORCE_STOP.cmd(it) }) }) { Text("Force stop") }
                    TextButton(onClick = { selected.clear() }) { Text("Clear") }
                }
            }
        }
    }
    detail?.let { AppDetailDialog(it, request) { detail = null } }
}

@Composable
private fun AppItem(r: AppRow, checked: Boolean, onCheck: (Boolean) -> Unit, onClick: () -> Unit) {
    Card(Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Checkbox(checked, onCheck)
            Column(Modifier.weight(1f)) {
                Text(r.label, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(r.pkg, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) { tags(r).forEach { Tag(it.first, it.second) } }
            }
        }
    }
}

private fun tags(r: AppRow): List<Pair<String, Boolean>> = buildList {
    r.proc?.let { add("${it.ramMb.toInt()} MB · ${it.procs}p · u${it.users.joinToString(",u")}" to false) }
    add(when { r.disabled -> "disabled" to false; r.restricted == true -> "restricted" to false; r.restricted == false -> "background allowed" to false; else -> "background ?" to false })
    r.bucket?.let { add((BUCKET_NAMES[it] ?: "bucket $it") to false) }
    r.advice?.let { add(it.label to (it == Advice.RESTRICT || it == Advice.DISABLE_SAFE || it == Advice.RARE)) }
}

@Composable
private fun Tag(text: String, strong: Boolean) {
    Surface(
        shape = MaterialTheme.shapes.small,
        color = if (strong) MaterialTheme.colorScheme.tertiaryContainer else MaterialTheme.colorScheme.surfaceVariant,
        modifier = Modifier.padding(top = 4.dp),
    ) { Text(text, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)) }
}

@Composable
private fun AppDetailDialog(r: AppRow, request: (List<Cmd>) -> Unit, onDismiss: () -> Unit) {
    val ctx = LocalContext.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(r.label) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(r.pkg, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
                tags(r).forEach { Text("• ${it.first}") }
                if (r.why.isNotBlank()) Text(r.why, style = MaterialTheme.typography.bodySmall)
                HorizontalDivider(Modifier.padding(vertical = 6.dp))
                val act = { a: PkgAction -> request(listOf(a.cmd(r.pkg))); onDismiss() }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (r.restricted != true) OutlinedButton(onClick = { act(PkgAction.RESTRICT) }) { Text("Restrict") }
                    if (r.restricted == true) OutlinedButton(onClick = { act(PkgAction.ALLOW) }) { Text("Allow") }
                    OutlinedButton(onClick = { act(PkgAction.FORCE_STOP) }) { Text("Force stop") }
                    if (!r.disabled && r.advice != Advice.NEVER) OutlinedButton(onClick = { act(PkgAction.DISABLE) }) { Text("Disable") }
                    if (r.disabled) OutlinedButton(onClick = { act(PkgAction.ENABLE) }) { Text("Enable") }
                    OutlinedButton(onClick = { open(ctx, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${r.pkg}"))) }) { Text("App info") }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
}

// ------------------------------------------------------------------ Debloat
@Composable
private fun DebloatScreen(vm: TunerViewModel, request: (List<Cmd>) -> Unit) {
    val selected = remember { mutableStateListOf<String>() }
    LaunchedEffect(vm.apps) {   // pre-tick safe packages that are still enabled
        if (selected.isEmpty()) selected += vm.catalog.safe.filter { vm.row(it.pkg)?.disabled == false }.map { it.pkg }
    }
    Column(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            item { Note("Disabling is reversible (Enable, or the Log tab). Do small batches, reboot, and use the phone for a day before the next batch.") }
            section("Safe to disable", vm.catalog.safe, vm, selected, true)
            section("Optional – only if you do not use the feature", vm.catalog.optional, vm, selected, true)
            section("Never touch", vm.catalog.never, vm, selected, false)
        }
        Surface(tonalElevation = 3.dp) {
            Row(Modifier.fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                val toDisable = selected.filter { vm.row(it)?.disabled == false }
                val toEnable = selected.filter { vm.row(it)?.disabled == true }
                Button(enabled = toDisable.isNotEmpty(), onClick = { request(toDisable.map { PkgAction.DISABLE.cmd(it) }) }) { Text("Disable (${toDisable.size})") }
                OutlinedButton(enabled = toEnable.isNotEmpty(), onClick = { request(toEnable.map { PkgAction.ENABLE.cmd(it) }) }) { Text("Enable (${toEnable.size})") }
            }
        }
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.section(
    title: String, list: List<CatalogPkg>, vm: TunerViewModel, selected: MutableList<String>, selectable: Boolean,
) {
    val installed = list.filter { vm.isInstalled(it.pkg) }
    item { Text("$title (${installed.size} installed)", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 10.dp)) }
    items(installed, key = { "$title-${it.pkg}" }) { p ->
        val row = vm.row(p.pkg)
        Card(Modifier.fillMaxWidth()) {
            Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (selectable) Checkbox(p.pkg in selected, { if (it) selected += p.pkg else selected -= p.pkg }) else Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(p.name.ifBlank { p.pkg }, fontWeight = FontWeight.SemiBold)
                    Text(p.pkg, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (p.note.isNotBlank()) Text(p.note, style = MaterialTheme.typography.bodySmall)
                }
                Tag(if (row?.disabled == true) "disabled" else "enabled", row?.disabled == false && selectable)
            }
        }
    }
}

// ------------------------------------------------------------------ Fixes (settings tips)
@Composable
private fun FixesScreen(vm: TunerViewModel, request: (List<Cmd>) -> Unit) {
    val ctx = LocalContext.current
    LazyColumn(contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(vm.catalog.tips, key = { it.id }) { t ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(t.title, fontWeight = FontWeight.SemiBold)
                    Text(t.detail, style = MaterialTheme.typography.bodySmall)
                    val v = vm.tipValues[t.id]
                    if (t.command != null) Tag(
                        when { v == null -> "status unknown"; v == t.goodValue -> "✓ done"; else -> "to do (now: $v)" },
                        v != null && v != t.goodValue,
                    ) else Tag("manual step", false)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        vm.tipCmd(t, undo = false)?.let { c -> Button(onClick = { request(listOf(c)) }) { Text("Apply") } }
                        vm.tipCmd(t, undo = true)?.let { c -> OutlinedButton(onClick = { request(listOf(c)) }) { Text("Revert") } }
                        t.intent?.let { a -> OutlinedButton(onClick = { open(ctx, Intent(a)) }) { Text("Open settings") } }
                    }
                }
            }
        }
    }
}

// ------------------------------------------------------------------ Diagnostics
@Composable
private fun DiagScreen(vm: TunerViewModel) {
    val ctx = LocalContext.current
    LazyColumn(contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (!Shell.ready) item { Note("Diagnostics need Shizuku. From the PC run Invoke-PhoneDiagnostics.ps1, or copy a command below and run it with adb shell.") }
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Quick check", fontWeight = FontWeight.SemiBold)
                    Button(enabled = Shell.ready, onClick = { vm.runQuickCheck() }) { Text("Run quick check") }
                    vm.quick?.let { q ->
                        Metric("Screen-off drain", if (q.screenOffRate > 0) "%.2f %%/h (%d%% in %.1f h)".format(q.screenOffRate, q.screenOffPct, q.screenOffHours) else "not enough time off charger",
                            when { q.screenOffRate == 0.0 -> null; q.screenOffRate < 1 -> "Good"; q.screenOffRate < 1.5 -> "Watch"; else -> "Critical" })
                        Metric("Wi-Fi chip wakeups", "${q.wifiWakeups} of ${q.totalWakeups}", when { q.wifiWakeups < 2000 -> "Good"; q.wifiWakeups < 8000 -> "Watch"; else -> "Critical" })
                        Metric("Multicast lock holders", q.multicastHolders.ifEmpty { listOf("none") }.joinToString(), if (q.multicastHolders.isEmpty()) "Good" else "Watch")
                        Metric("Profiles running", q.users.joinToString(), if (q.users.size <= 1) "Good" else "High")
                        Metric("Memory", "${q.memAvailableMb} MB available · swap used ${q.swapUsedMb} MB", if (q.swapUsedMb < 1024) "Good" else if (q.swapUsedMb < 2048) "Watch" else "High")
                    }
                }
            }
        }
        items(vm.catalog.diagnostics, key = { it.id }) { d ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(d.title, fontWeight = FontWeight.SemiBold)
                    Text(d.command, fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(enabled = Shell.ready, onClick = { vm.runDiag(d) }) { Text("Run") }
                        OutlinedButton(onClick = { copy(ctx, "adb shell \"${d.command}\""); vm.message = "adb command copied" }) { Text("Copy adb") }
                        vm.diagOutput[d.id]?.let { out -> TextButton(onClick = { copy(ctx, out); vm.message = "Output copied" }) { Text("Copy output") } }
                    }
                    vm.diagOutput[d.id]?.let { out ->
                        Box(Modifier.fillMaxWidth().heightIn(max = 320.dp).verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState())) {
                            Text(out, fontFamily = FontFamily.Monospace, fontSize = 11.sp, softWrap = false)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Metric(name: String, value: String, status: String?) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(name, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(value)
        }
        status?.let { Tag(when (it) { "Good" -> "✓ Good"; "Watch" -> "! Watch"; "High" -> "▲ High"; else -> "✕ $it" }, it != "Good") }
    }
}

// ------------------------------------------------------------------ Log
@Composable
private fun LogScreen(vm: TunerViewModel) {
    val ctx = LocalContext.current
    val undone = vm.undoneKeys()
    LazyColumn(contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(enabled = vm.log.isNotEmpty(), onClick = {
                    copy(ctx, vm.log.filter { it.ok && it.undo != null && it.undoOf == null && it.key !in undone }.joinToString("\n") { "adb shell ${it.undo}" })
                    vm.message = "Undo commands copied"
                }) { Text("Copy all undo commands") }
            }
        }
        if (vm.log.isEmpty()) item { Note("No changes made yet. Every command you run is recorded here with its undo.") }
        items(vm.log, key = { it.key + it.label }) { e ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("${e.label}: ${e.target}", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                        Tag(if (e.ok) "✓ OK" else "✕ failed", !e.ok)
                    }
                    Text(e.time.replace('T', ' '), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(e.command, fontFamily = FontFamily.Monospace, fontSize = 11.sp)
                    if (e.output.isNotBlank()) Text(e.output, style = MaterialTheme.typography.bodySmall)
                    when {
                        e.undoOf != null -> Text("(this was an undo)", style = MaterialTheme.typography.bodySmall)
                        e.key in undone -> Text("Undone", style = MaterialTheme.typography.bodySmall)
                        e.ok && e.undo != null -> OutlinedButton(enabled = Shell.ready, onClick = { vm.undo(e) }) { Text("Undo") }
                    }
                }
            }
        }
    }
}

// ------------------------------------------------------------------ helpers
@Composable
private fun Note(text: String) {
    Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = MaterialTheme.shapes.medium, modifier = Modifier.fillMaxWidth()) {
        Text(text, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(10.dp))
    }
}

private fun copy(ctx: Context, text: String) {
    (ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Phone Tuner", text))
}

private fun open(ctx: Context, intent: Intent) {
    try {
        ctx.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (_: ActivityNotFoundException) {
        ctx.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
