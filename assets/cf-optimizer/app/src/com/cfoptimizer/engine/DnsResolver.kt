package com.cfoptimizer.engine

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress

/**
 * DNS 解析 + Cloudflare 验证 + 全局 IP 去重。
 * IPv4 / IPv6 完全独立：分别解析、分别验证、分别去重。
 */
object DnsResolver {

    data class ResolvedIp(
        val ip: String,
        val addr: InetAddress,
        val family: String,      // IPv4 / IPv6
        val sourceDomains: MutableSet<String> = mutableSetOf()
    )

    /**
     * 解析域名池 → 每个协议族的去重 CF IP 列表。
     * 多域名解析到同一 IP 时只保留一个（sourceDomains 记录来源）。
     * 非 Cloudflare / 解析失败的域名自动跳过。
     */
    fun resolvePool(
        domains: List<String>,
        family: String,
        log: (String) -> Unit
    ): Map<String, ResolvedIp> {
        val wantV6 = family == "IPv6"
        val result = LinkedHashMap<String, ResolvedIp>()
        var domainOk = 0
        var skipped = 0

        for (d in domains) {
            val name = d.trim().lowercase()
            if (name.isEmpty()) continue
            val addrs = try {
                InetAddress.getAllByName(name)
            } catch (e: Exception) {
                skipped++
                continue
            }
            var got = 0
            for (a in addrs) {
                val isV6 = a is Inet6Address
                if (wantV6 && !isV6) continue
                if (!wantV6 && isV6) continue
                if (!CfRanges.isCloudflare(a)) continue   // 非 CF 自动跳过
                got++
                val key = a.hostAddress ?: continue
                val existing = result[key]
                if (existing != null) {
                    existing.sourceDomains.add(name)
                } else {
                    result[key] = ResolvedIp(
                        ip = key,
                        addr = a,
                        family = family,
                        sourceDomains = mutableSetOf(name)
                    )
                }
            }
            if (got > 0) domainOk++
        }
        log("解析完成：${family} 有效域名 $domainOk 个，去重 CF IP ${result.size} 个（跳过 $skipped）")
        return result
    }

    /** 指定域名按族解析（结果页展示用）。 */
    fun resolveDomain(domain: String, family: String): List<String> {
        val wantV6 = family == "IPv6"
        return try {
            InetAddress.getAllByName(domain)
                .filter {
                    val isV6 = it is Inet6Address
                    (wantV6 && isV6) || (!wantV6 && !isV6)
                }
                .filter { CfRanges.isCloudflare(it) }
                .map { it.hostAddress ?: "" }
                .filter { it.isNotEmpty() }
        } catch (e: Exception) { emptyList() }
    }
}
