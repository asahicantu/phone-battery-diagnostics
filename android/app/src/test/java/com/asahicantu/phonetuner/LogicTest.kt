package com.asahicantu.phonetuner

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LogicTest {
    @Test fun packageValidationBlocksShellInjection() {
        assertTrue(isValidPackage("com.alibaba.aliexpresshd"))
        assertTrue(isValidPackage("com.Slack"))
        assertFalse(isValidPackage("com.foo;reboot"))
        assertFalse(isValidPackage("com.foo\$(id)"))
        assertFalse(isValidPackage("com.foo bar"))
        assertFalse(isValidPackage("nodot"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun actionRejectsInvalidPackage() { PkgAction.DISABLE.cmd("com.x; rm -rf /") }

    @Test fun actionsHaveMatchingUndo() {
        val c = PkgAction.RESTRICT.cmd("dk.kanpla.unisonfm.twa")
        assertEquals("cmd appops set --user 0 dk.kanpla.unisonfm.twa RUN_ANY_IN_BACKGROUND ignore", c.command)
        assertEquals("cmd appops set --user 0 dk.kanpla.unisonfm.twa RUN_ANY_IN_BACKGROUND allow", c.undo)
        assertEquals("pm enable --user 0 com.hiya.star", PkgAction.DISABLE.cmd("com.hiya.star").undo)
        assertEquals(null, PkgAction.FORCE_STOP.cmd("com.hiya.star").undo)
    }

    @Test fun parsesSeconds() {
        assertEquals(3723.5, Parsers.seconds("1h 2m 3s 500ms"), 1e-9)
        assertEquals(56500.421, Parsers.seconds("15h 41m 40s 421ms"), 1e-6)
    }

    @Test fun parsesPackagesBucketsAndProcesses() {
        assertEquals(setOf("com.a.b", "com.c.d"), Parsers.packages("package:com.a.b\npackage:com.c.d uid:10350\n"))
        assertEquals(setOf("no.bergen.kommune.parko"), Parsers.plainPackages("no.bergen.kommune.parko\nNo operations.\n"))
        assertEquals(mapOf("com.a.b" to 45, "com.c.d" to 10), Parsers.buckets("com.a.b: 45\ncom.c.d: 10\n"))
        val ps = Parsers.processes(
            "USER  RSS NAME\nu0_a776 434176 com.alibaba.aliexpresshd\nu0_a776 10240 com.alibaba.aliexpresshd:channel\n" +
                "u95_a606 131072 com.whatsapp\nsystem 400000 system_server\n"
        )
        assertEquals(2, ps.getValue("com.alibaba.aliexpresshd").procs)
        assertEquals(434.0, ps.getValue("com.alibaba.aliexpresshd").ramMb, 0.01)
        assertEquals(setOf(95), ps.getValue("com.whatsapp").users)
        assertFalse(ps.containsKey("system_server"))
    }

    @Test fun quickCheckMatchesPcFindings() {
        val q = Parsers.quickCheck(
            drain = "  Time on battery screen off: 15h 41m 40s 421ms (83,5%) realtime\n    Amount discharged while screen off: 51\n",
            wakeups = "  Wakeup reason Abort: Last active Wakeup Source: qcom,cnss-kiwi: 1h 50m 50s 125ms (10033 times) realtime\n" +
                "  Wakeup reason 43 s2idle_wakeup:481 wlan_pci_wake_irq: 1h 5m 15s 749ms (9895 times) realtime\n" +
                "  Wakeup reason Abort: Pending Wakeup Sources: umts_ipc1: 5m 56s 534ms (487 times) realtime\n",
            wifi = "    Multicaster{MdnsServiceBrowserImpl uid=10274}\n    Multicaster{NsdService uid=1000}\n",
            users = "Users:\n\tUserInfo{0:Owner:4c13} running\n\tUserInfo{10:Jobbprofil:1030} running\n\tUserInfo{11:Old:0}\n",
            meminfo = "MemTotal:  7397292 kB\nMemAvailable: 1048576 kB\nSwapTotal: 8388604 kB\nSwapFree: 4802276 kB\n",
        )
        assertEquals(3.25, q.screenOffRate, 0.01)
        assertEquals(19928, q.wifiWakeups)
        assertEquals(20415, q.totalWakeups)
        assertEquals(2, q.multicastHolders.size)
        assertEquals(listOf("0 Owner", "10 Jobbprofil"), q.users)
        assertEquals(1024, q.memAvailableMb)
        assertEquals(3502, q.swapUsedMb)
    }

    @Test fun adviceFollowsCatalog() {
        val cat = Catalog(
            restrict = listOf(Rec("dk.kanpla.unisonfm.twa", "radio")), keep = listOf(Rec("com.whatsapp", "msgs")),
            safe = listOf(CatalogPkg("com.hiya.star", "Hiya", "")), optional = emptyList(),
            never = listOf(CatalogPkg("com.osp.app.signin", "Samsung account", "breaks")), tips = emptyList(), diagnostics = emptyList(),
        )
        assertEquals(Advice.RESTRICT, Parsers.advice("dk.kanpla.unisonfm.twa", cat, true, 40, false).first)
        assertEquals(Advice.KEEP, Parsers.advice("com.whatsapp", cat, true, 10, true).first)
        assertEquals(Advice.DISABLE_SAFE, Parsers.advice("com.hiya.star", cat, false, null, false).first)
        assertEquals(Advice.NEVER, Parsers.advice("com.osp.app.signin", cat, false, null, false).first)
        assertEquals(Advice.RARE, Parsers.advice("com.some.app", cat, true, 45, false).first)
        assertEquals(null, Parsers.advice("com.some.app", cat, true, 10, false).first)
    }
}
