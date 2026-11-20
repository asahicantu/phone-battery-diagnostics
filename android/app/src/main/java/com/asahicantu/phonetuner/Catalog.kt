package com.asahicantu.phonetuner

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

data class Rec(val pkg: String, val reason: String)
data class CatalogPkg(val pkg: String, val name: String, val note: String)
data class Tip(
    val id: String, val title: String, val detail: String,
    val check: String?, val goodValue: String?, val command: String?, val undo: String?, val intent: String?,
)
data class Diag(val id: String, val title: String, val command: String)

/** catalog.json, shared with Invoke-PhoneTuning.ps1 (copied into assets at build time). */
data class Catalog(
    val restrict: List<Rec>, val keep: List<Rec>,
    val safe: List<CatalogPkg>, val optional: List<CatalogPkg>, val never: List<CatalogPkg>,
    val tips: List<Tip>, val diagnostics: List<Diag>,
) {
    companion object {
        fun load(context: Context): Catalog {
            val root = JSONObject(context.assets.open("catalog.json").bufferedReader().use { it.readText() })
            val debloat = root.getJSONObject("debloat")
            return Catalog(
                restrict = root.getJSONArray("restrict").objects().map { Rec(it.getString("pkg"), it.optString("reason")) },
                keep = root.getJSONArray("keep").objects().map { Rec(it.getString("pkg"), it.optString("reason")) },
                safe = debloat.getJSONArray("safe").pkgs(),
                optional = debloat.getJSONArray("optional").pkgs(),
                never = debloat.getJSONArray("never").pkgs(),
                tips = root.getJSONArray("tips").objects().map {
                    Tip(it.getString("id"), it.getString("title"), it.optString("detail"),
                        it.str("check"), it.str("goodValue"), it.str("command"), it.str("undo"), it.str("intent"))
                },
                diagnostics = root.getJSONArray("diagnostics").objects().map { Diag(it.getString("id"), it.getString("title"), it.getString("command")) },
            )
        }

        private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }
        private fun JSONArray.pkgs() = objects().map { CatalogPkg(it.getString("pkg"), it.optString("name"), it.optString("note")) }
        private fun JSONObject.str(key: String) = if (has(key) && !isNull(key)) getString(key) else null
    }
}
