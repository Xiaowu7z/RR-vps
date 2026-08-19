package com.cfoptimizer.engine

import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.util.concurrent.TimeUnit

/**
 * Cloudflare 官方网段：在线获取 + 内置备用 + CIDR 判定（字节级，v4/v6 通用）。
 * 与 PS v3.0 逻辑一致：在线获取失败自动用内置备用。
 */
object CfRanges {

    val FALLBACK_V4: List<String> = listOf(
        "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
        "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
        "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
        "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22"
    )

    val FALLBACK_V6: List<String> = listOf(
        "2400:cb00::/32", "2606:4700::/32", "2803:f800::/32",
        "2405:b500::/32", "2405:8100::/32", "2a06:98c0::/29", "2c0f:f248::/32"
    )

    @Volatile var rangesV4: List<String> = FALLBACK_V4
    @Volatile var rangesV6: List<String> = FALLBACK_V6
    @Volatile var v4FromOnline: Boolean = false
    @Volatile var v6FromOnline: Boolean = false

    /** 在线刷新官方网段（失败保持内置备用）。 */
    fun refresh() {
        try {
            val client = OkHttpClient.Builder()
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(10, TimeUnit.SECONDS)
                .build()
            val v4 = fetchText(client, "https://www.cloudflare.com/ips-v4")
            val v6 = fetchText(client, "https://www.cloudflare.com/ips-v6")
            val parsed4 = parseRanges(v4, v4 = true)
            val parsed6 = parseRanges(v6, v4 = false)
            if (parsed4.isNotEmpty()) { rangesV4 = parsed4; v4FromOnline = true }
            if (parsed6.isNotEmpty()) { rangesV6 = parsed6; v6FromOnline = true }
        } catch (e: Exception) {
            // 保持内置备用
        }
    }

    private fun fetchText(client: OkHttpClient, url: String): String? {
        return try {
            client.newCall(Request.Builder().url(url).get().build())
                .execute().use { it.body?.string() }
        } catch (e: Exception) { null }
    }

    private fun parseRanges(text: String?, v4: Boolean): List<String> {
        if (text.isNullOrEmpty()) return emptyList()
        val re = if (v4) Regex("""^\d+\.\d+\.\d+\.\d+/\d+$""")
                 else Regex("""^[0-9A-Fa-f:]+/\d+$""")
        return text.split(Regex("[\r\n]+")).map { it.trim() }.filter { re.matches(it) }
    }

    /** CIDR 判定：address 是否在 cidr 网段内（字节级）。 */
    fun inCidr(address: InetAddress, cidr: String): Boolean {
        try {
            val parts = cidr.split("/")
            val net = InetAddress.getByName(parts[0])
            val prefix = parts[1].toInt()
            val a = address.address          // 4 或 16 字节
            val n = net.address
            if (a.size != n.size) return false
            val fullBytes = prefix / 8
            val remBits = prefix % 8
            for (i in 0 until fullBytes) {
                if (a[i] != n[i]) return false
            }
            if (remBits > 0 && fullBytes < a.size) {
                val mask = (0xFF shl (8 - remBits)) and 0xFF
                if ((a[fullBytes].toInt() and mask) != (n[fullBytes].toInt() and mask)) return false
            }
            return true
        } catch (e: Exception) {
            return false
        }
    }

    /** 判断地址是否属于 CF 官方网段。 */
    fun isCloudflare(addr: InetAddress): Boolean {
        val ranges = when (addr) {
            is Inet4Address -> rangesV4
            is Inet6Address -> rangesV6
            else -> emptyList()
        }
        return ranges.any { inCidr(addr, it) }
    }
}
