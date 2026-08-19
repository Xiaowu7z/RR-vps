package com.cfoptimizer

import java.io.File

/**
 * 历史测试记录存储（Phase 2.4）。
 * 纯 Kotlin stdlib 手写 JSON（不依赖 Android API，JVM 可单测）。
 * 持久化到 app 私有目录 files/history.json，最多保留 50 条。
 */
object HistoryStore {

    data class HistoryEntry(
        val id: Long,
        val ts: Long,                 // epoch millis
        val modeLabel: String,        // 均衡模式
        val families: String,         // IPv4 / IPv6 / IPv4+IPv6
        val networkLabel: String,     // Wi-Fi / Mobile
        val vpn: Boolean,
        val invalid: Boolean,
        val wifiSsid: String = "",    // WiFi 名称（2.4.7+）
        val carrier: String = "",     // 运营商名称（2.4.7+）
        val phoneModel: String = "",  // 手机型号（2.4.7+）
        val champ: String,            // 冠军域名
        val champMbps: String,        // 冠军平均吞吐
        val verdict: String,          // 结论
        val results: List<ResultLine> // 排行榜明细
    )

    data class ResultLine(
        val rank: Int,
        val domain: String,
        val avg: String,
        val min: String = "",
        val floor: String,
        val sr: String,
        val variation: String = "",
        val ttfb: String = "",
        val stability: String = "",
        val sampled: Boolean = false,
        val pops: String
    )

    const val MAX_ENTRIES = 50

    fun file(contextDir: File): File = File(contextDir, "history.json")

    fun save(contextDir: File, entry: HistoryEntry) {
        val all = loadAll(contextDir).toMutableList()
        all.add(0, entry)
        if (all.size > MAX_ENTRIES) all.subList(MAX_ENTRIES, all.size).clear()
        file(contextDir).writeText(serialize(all))
    }

    fun loadAll(contextDir: File): List<HistoryEntry> {
        val f = file(contextDir)
        if (!f.exists()) return emptyList()
        return try { deserialize(f.readText()) } catch (_: Exception) { emptyList() }
    }

    /** 删除指定 id 的历史记录 */
    fun delete(contextDir: File, id: Long): Boolean {
        val all = loadAll(contextDir)
        val keep = all.filter { it.id != id }
        if (keep.size == all.size) return false
        if (keep.isEmpty()) { file(contextDir).delete(); return true }
        file(contextDir).writeText(serialize(keep))
        return true
    }

    /** 清空全部历史 */
    fun clearAll(contextDir: File) {
        file(contextDir).delete()
    }

    // ---------- 手写 JSON 序列化（stdlib only） ----------

    fun serialize(entries: List<HistoryEntry>): String {
        val sb = StringBuilder("[")
        entries.forEachIndexed { i, e ->
            if (i > 0) sb.append(',')
            sb.append(serializeEntry(e))
        }
        sb.append(']')
        return sb.toString()
    }

    fun serializeEntry(e: HistoryEntry): String {
        val sb = StringBuilder("{")
        sb.append("\"id\":").append(e.id)
        sb.append(",\"ts\":").append(e.ts)
        sb.append(",\"mode\":\"").append(esc(e.modeLabel)).append('"')
        sb.append(",\"families\":\"").append(esc(e.families)).append('"')
        sb.append(",\"net\":\"").append(esc(e.networkLabel)).append('"')
        sb.append(",\"ssid\":\"").append(esc(e.wifiSsid)).append('"')
        sb.append(",\"carrier\":\"").append(esc(e.carrier)).append('"')
        sb.append(",\"model\":\"").append(esc(e.phoneModel)).append('"')
        sb.append(",\"vpn\":").append(e.vpn)
        sb.append(",\"invalid\":").append(e.invalid)
        sb.append(",\"champ\":\"").append(esc(e.champ)).append('"')
        sb.append(",\"champMbps\":\"").append(esc(e.champMbps)).append('"')
        sb.append(",\"verdict\":\"").append(esc(e.verdict)).append('"')
        sb.append(",\"results\":[")
        e.results.forEachIndexed { i, r ->
            if (i > 0) sb.append(',')
            sb.append("{\"rank\":").append(r.rank)
                .append(",\"domain\":\"").append(esc(r.domain)).append('"')
                .append(",\"avg\":\"").append(esc(r.avg)).append('"')
                .append(",\"min\":\"").append(esc(r.min)).append('"')
                .append(",\"floor\":\"").append(esc(r.floor)).append('"')
                .append(",\"sr\":\"").append(esc(r.sr)).append('"')
                .append(",\"var\":\"").append(esc(r.variation)).append('"')
                .append(",\"ttfb\":\"").append(esc(r.ttfb)).append('"')
                .append(",\"st\":\"").append(esc(r.stability)).append('"')
                .append(",\"sampled\":").append(r.sampled)
                .append(",\"pops\":\"").append(esc(r.pops)).append('"')
                .append('}')
        }
        sb.append("]}")
        return sb.toString()
    }

    fun deserialize(text: String): List<HistoryEntry> {
        val entries = mutableListOf<HistoryEntry>()
        var i = text.indexOf('{')
        while (i >= 0) {
            val end = findObjEnd(text, i)
            if (end < 0) break
            parseEntry(text.substring(i, end + 1))?.let { entries.add(it) }
            i = text.indexOf('{', end + 1)
        }
        return entries
    }

    private fun findObjEnd(s: String, start: Int): Int {
        var depth = 0
        var inStr = false
        var i = start
        while (i < s.length) {
            val c = s[i]
            if (inStr) {
                if (c == '\\') { i += 2; continue }
                if (c == '"') inStr = false
            } else {
                when (c) {
                    '"' -> inStr = true
                    '{' -> depth++
                    '}' -> { depth--; if (depth == 0) return i }
                }
            }
            i++
        }
        return -1
    }

    private fun parseEntry(obj: String): HistoryEntry? {
        fun strField(name: String): String {
            val m = Regex("\"$name\":\"((?:[^\"\\\\]|\\\\.)*)\"").find(obj) ?: return ""
            return unesc(m.groupValues[1])
        }
        fun longField(name: String): Long =
            Regex("\"$name\":(-?\\d+)").find(obj)?.groupValues?.get(1)?.toLongOrNull() ?: 0L
        fun boolField(name: String): Boolean =
            Regex("\"$name\":(true|false)").find(obj)?.groupValues?.get(1) == "true"

        val results = mutableListOf<ResultLine>()
        val resultsIdx = obj.indexOf("\"results\":[")
        if (resultsIdx >= 0) {
            var ri = obj.indexOf('{', resultsIdx)
            while (ri >= 0 && ri < obj.length - 1) {
                val re = findObjEnd(obj, ri)
                if (re < 0) break
                val ro = obj.substring(ri, re + 1)
                results.add(
                    ResultLine(
                        rank = Regex("\"rank\":(\\d+)").find(ro)?.groupValues?.get(1)?.toIntOrNull() ?: 0,
                        domain = strFieldOf(ro, "domain"),
                        avg = strFieldOf(ro, "avg"),
                        min = strFieldOf(ro, "min"),
                        floor = strFieldOf(ro, "floor"),
                        sr = strFieldOf(ro, "sr"),
                        variation = strFieldOf(ro, "var"),
                        ttfb = strFieldOf(ro, "ttfb"),
                        stability = strFieldOf(ro, "st"),
                        sampled = Regex("\"sampled\":(true|false)").find(ro)?.groupValues?.get(1) == "true",
                        pops = strFieldOf(ro, "pops")
                    )
                )
                ri = obj.indexOf('{', re + 1)
            }
        }
        return HistoryEntry(
            id = longField("id"), ts = longField("ts"),
            modeLabel = strField("mode"), families = strField("families"),
            networkLabel = strField("net"), vpn = boolField("vpn"),
            invalid = boolField("invalid"),
            wifiSsid = strField("ssid"), carrier = strField("carrier"),
            phoneModel = strField("model"), champ = strField("champ"),
            champMbps = strField("champMbps"), verdict = strField("verdict"),
            results = results
        )
    }

    private fun strFieldOf(obj: String, name: String): String {
        val m = Regex("\"$name\":\"((?:[^\"\\\\]|\\\\.)*)\"").find(obj) ?: return ""
        return unesc(m.groupValues[1])
    }

    private fun esc(s: String): String = s
        .replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n")

    private fun unesc(s: String): String = s
        .replace("\\n", "\n")
        .replace("\\\"", "\"")
        .replace("\\\\", "\\")
}
