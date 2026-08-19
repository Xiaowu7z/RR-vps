import com.cfoptimizer.engine.CfRanges
import com.cfoptimizer.engine.DnsResolver
import com.cfoptimizer.engine.Pipeline
import com.cfoptimizer.engine.ProbeEngine
import java.net.Inet6Address
import java.net.InetAddress

/**
 * RR优选 IPv6 专项边界测试（JVM 可跑，不依赖 Android）。
 *
 * 覆盖链路：
 *   isIpLiteral / familyOf（输入校验）→ CfRanges.inCidr（CF v6 网段验证）
 *   → DnsResolver.resolveDomain（v6 解析）→ Pipeline.buildSnapshot（IPv6 Snapshot）
 *   → addressesEqual（字节等价，Probe 结果校验用）。
 *
 * SKIP 语义：仅 DNS 网络用例允许 SKIP（本机 DNS 无 AAAA / 不可达时跳过，不 FAIL）；
 * 其余纯函数用例必须 PASS。
 *
 * 已知工具链事实（JDK 17.0.20，与 Android libcore 同源）：
 *   - InetAddress.getByName("::ffff:1.2.3.4") 返回 Inet4Address（OpenJDK 对 v4-mapped 的
 *     标准行为），因此当前 isIpLiteral 对 v4-mapped 判为"非字面量"（拒绝），familyOf 返回 null。
 *     —— 平台相关，见审查结论；真机需复核 Android 判族一致性。
 *   - Inet6Address.getHostAddress() 返回 8 组展开小写形式（如 2606:4700:0:0:0:0:0:1），
 *     是稳定规范形，可作为 map key / 重解析输入。
 *   - zone 形式（fe80::1%eth0）能被 JDK 解析，但被 isIpLiteral 的字符白名单拒绝（设计如此）。
 */
fun main() {
    var passed = 0
    var failed = 0
    var skipped = 0

    fun check(name: String, cond: Boolean, detail: String = "") {
        if (cond) { passed++; println("PASS  $name") }
        else { failed++; println("FAIL  $name  $detail") }
    }

    fun skip(name: String, reason: String) {
        skipped++; println("SKIP  $name  ($reason)")
    }

    fun ip(s: String): InetAddress = InetAddress.getByName(s)

    // ================= A. isIpLiteral / familyOf（纯函数，无网络） =================
    println("---- A. 输入校验 isIpLiteral / familyOf ----")

    // A1: v6 压缩形式
    check("A1 isIpLiteral 压缩形式 2606:4700::1", ProbeEngine.isIpLiteral("2606:4700::1"),
        "got false")
    check("A1b familyOf 压缩形式 == IPv6", ProbeEngine.familyOf("2606:4700::1") == "IPv6",
        "got ${ProbeEngine.familyOf("2606:4700::1")}")

    // A2: v6 展开形式（8 组全写）
    check("A2 isIpLiteral 展开形式", ProbeEngine.isIpLiteral("2606:4700:0000:0000:0000:0000:0000:0001"),
        "got false")
    check("A2b familyOf 展开形式 == IPv6", ProbeEngine.familyOf("2606:4700:0000:0000:0000:0000:0000:0001") == "IPv6",
        "got ${ProbeEngine.familyOf("2606:4700:0000:0000:0000:0000:0000:0001")}")

    // A3: 内嵌 IPv4 的 v6（2606:4700::1.2.3.4 是合法 v6 字面量）
    check("A3 isIpLiteral 内嵌IPv4 v6", ProbeEngine.isIpLiteral("2606:4700::1.2.3.4"), "got false")
    check("A3b familyOf 内嵌IPv4 == IPv6", ProbeEngine.familyOf("2606:4700::1.2.3.4") == "IPv6",
        "got ${ProbeEngine.familyOf("2606:4700::1.2.3.4")}")

    // A4: 大小写十六进制等价
    check("A4 isIpLiteral 大写hex", ProbeEngine.isIpLiteral("2606:4700::A"), "got false")
    check("A4b isIpLiteral 小写hex", ProbeEngine.isIpLiteral("2606:4700::a"), "got false")

    // A5: v4-mapped（::ffff:1.2.3.4）
    // 工具链事实：JDK17 对 v4-mapped 返回 Inet4Address → 当前实现判为非字面量（familyOf=null）。
    // 即：不会误入 IPv4 池，也不会被当作 IPv6 探测目标——语义上 v4-mapped 就是 IPv4。
    // 注意：若未来 JDK/Android 返回 Inet6Address，本实现将改判 IPv6（平台相关，见审查结论）。
    check("A5 v4-mapped 不判为 IPv6（JDK17 返回 Inet4Address → 拒绝）",
        !ProbeEngine.isIpLiteral("::ffff:1.2.3.4"), "got true")
    check("A5b v4-mapped 不得误入 IPv4 池",
        ProbeEngine.familyOf("::ffff:1.2.3.4") != "IPv4",
        "got ${ProbeEngine.familyOf("::ffff:1.2.3.4")}")
    check("A5c v4-mapped 展开形式同样拒绝",
        !ProbeEngine.isIpLiteral("0:0:0:0:0:ffff:1.2.3.4"), "got true")

    // A6: zone 后缀必须拒绝（字符白名单不含 '%'）
    check("A6 zone 后缀 fe80::1%eth0 拒绝", !ProbeEngine.isIpLiteral("fe80::1%eth0"), "got true")
    check("A6b zone 百分号编码 %25 拒绝", !ProbeEngine.isIpLiteral("fe80::1%25eth0"), "got true")
    check("A6c familyOf zone == null", ProbeEngine.familyOf("fe80::1%eth0") == null,
        "got ${ProbeEngine.familyOf("fe80::1%eth0")}")

    // A7: 非法输入
    check("A7 空串拒绝", !ProbeEngine.isIpLiteral(""))
    check("A7b ':::' 拒绝", !ProbeEngine.isIpLiteral(":::"))
    check("A7c 9组拒绝", !ProbeEngine.isIpLiteral("1:2:3:4:5:6:7:8:9"))
    check("A7d 双压缩拒绝", !ProbeEngine.isIpLiteral("2606:4700::1::2"))
    check("A7e 非法字符拒绝", !ProbeEngine.isIpLiteral("2606:4700::zz"))
    check("A7f 尾随空格拒绝", !ProbeEngine.isIpLiteral("2606:4700::1 "))
    check("A7g 前导空格拒绝", !ProbeEngine.isIpLiteral(" 2606:4700::1"))
    check("A7h 冒号结尾拒绝", !ProbeEngine.isIpLiteral("2606:4700::1:"))

    // A8: hostname 必须拒绝（不触发 DNS 的纯判据：无 ':'）
    check("A8 hostname www.cloudflare.com 拒绝", !ProbeEngine.isIpLiteral("www.cloudflare.com"))
    check("A8b hostname speed.cloudflare.com 拒绝", !ProbeEngine.isIpLiteral("speed.cloudflare.com"))
    check("A8c hostname 尾点拒绝", !ProbeEngine.isIpLiteral("cloudflare.com."))
    check("A8d familyOf hostname == null", ProbeEngine.familyOf("www.cloudflare.com") == null)

    // A9: IPv4 回归 + 非法 v4
    check("A9 v4 正常", ProbeEngine.isIpLiteral("104.16.123.96") && ProbeEngine.familyOf("104.16.123.96") == "IPv4",
        "got ${ProbeEngine.familyOf("104.16.123.96")}")
    check("A9b v4 越界拒绝", !ProbeEngine.isIpLiteral("256.1.1.1"))
    check("A9c v4 五段拒绝", !ProbeEngine.isIpLiteral("1.2.3.4.5"))

    // A10: 特殊字面量
    check("A10 '::' 未指定地址是合法 v6", ProbeEngine.isIpLiteral("::") && ProbeEngine.familyOf("::") == "IPv6",
        "got ${ProbeEngine.familyOf("::")}")

    // ================= B. CfRanges.inCidr（纯函数，无网络） =================
    println("---- B. CF v6 网段验证 inCidr / isCloudflare ----")

    // B1-B3: 2606:4700::/32 网段内
    check("B1 2606:4700::1 在 /32 内", CfRanges.inCidr(ip("2606:4700::1"), "2606:4700::/32"))
    check("B2 网段首地址在 /32 内", CfRanges.inCidr(ip("2606:4700::"), "2606:4700::/32"))
    check("B3 网段末地址在 /32 内", CfRanges.inCidr(ip("2606:4700:ffff:ffff:ffff:ffff:ffff:ffff"), "2606:4700::/32"))

    // B4-B5: 网段外（含边界外）
    check("B4 2607:4700::1 在 /32 外", !CfRanges.inCidr(ip("2607:4700::1"), "2606:4700::/32"))
    check("B5 2606:4701::1 边界外", !CfRanges.inCidr(ip("2606:4701::1"), "2606:4700::/32"))

    // B6: /128 精确匹配
    check("B6 /128 精确命中", CfRanges.inCidr(ip("2606:4700::1"), "2606:4700::1/128"))
    check("B6b /128 邻址不命中", !CfRanges.inCidr(ip("2606:4700::2"), "2606:4700::1/128"))

    // B7: /0 全匹配
    check("B7 /0 全匹配", CfRanges.inCidr(ip("2606:4700::1"), "::/0") && CfRanges.inCidr(ip("::"), "::/0"))

    // B8: /29 余位掩码路径（2a06:98c0::/29）
    check("B8 2a06:98c0::1 在 /29 内", CfRanges.inCidr(ip("2a06:98c0::1"), "2a06:98c0::/29"))
    check("B8b /29 末地址在网段内", CfRanges.inCidr(ip("2a06:98c7:ffff:ffff:ffff:ffff:ffff:ffff"), "2a06:98c0::/29"))
    check("B8c 2a06:98c8::1 在 /29 外", !CfRanges.inCidr(ip("2a06:98c8::1"), "2a06:98c0::/29"))

    // B9: 跨族比较必须 false
    check("B9 v4地址 vs v6网段 false", !CfRanges.inCidr(ip("104.16.0.1"), "2606:4700::/32"))
    check("B9b v6地址 vs v4网段 false", !CfRanges.inCidr(ip("2606:4700::1"), "104.16.0.0/13"))

    // B10: v4 回归（字节级路径共用）
    check("B10 v4 网段内", CfRanges.inCidr(ip("104.16.1.1"), "104.16.0.0/13") && CfRanges.inCidr(ip("104.23.255.255"), "104.16.0.0/13"))
    check("B10b v4 网段外", !CfRanges.inCidr(ip("104.24.0.0"), "104.16.0.0/13"))

    // B11: 畸形网段 → false（前缀非数字 / 网段不可解析）
    check("B11 前缀非数字 false", !CfRanges.inCidr(ip("2606:4700::1"), "2606:4700::/abc"))
    check("B11b 网段非法 false", !CfRanges.inCidr(ip("2606:4700::1"), "::::/32"))
    check("B11c 无斜杠 false", !CfRanges.inCidr(ip("2606:4700::1"), "2606:4700::"))

    // B12: isCloudflare 走内置 FALLBACK_V6（未 refresh，确定性）
    check("B12 2606:4700::1 是 CF", CfRanges.isCloudflare(ip("2606:4700::1")))
    check("B12b 2607:4700::1 非 CF", !CfRanges.isCloudflare(ip("2607:4700::1")))
    check("B12c v4 1.1.1.1 非 CF", !CfRanges.isCloudflare(ip("1.1.1.1")))
    check("B12d v4 104.16.1.1 是 CF", CfRanges.isCloudflare(ip("104.16.1.1")))

    // ================= C. DnsResolver.resolveDomain IPv6（网络，可 SKIP） =================
    println("---- C. DnsResolver.resolveDomain IPv6（依赖本机 DNS） ----")
    val v6 = try {
        DnsResolver.resolveDomain("www.cloudflare.com", "IPv6")
    } catch (e: Exception) { emptyList<String>() }

    if (v6.isEmpty()) {
        skip("C resolveDomain IPv6 结果为空", "本机 DNS 无 AAAA / 解析不可用")
    } else {
        check("C1 解析到 ≥1 个 v6 地址", v6.isNotEmpty(), "got $v6")
        check("C2 全部是 v6 字面量",
            v6.all { ProbeEngine.isIpLiteral(it) && ProbeEngine.familyOf(it) == "IPv6" },
            "got $v6")
        check("C3 全部可重解析为 Inet6Address",
            v6.all { runCatching { InetAddress.getByName(it) is Inet6Address }.getOrDefault(false) },
            "got $v6")
        check("C4 全部落在 CF FALLBACK_V6 网段",
            v6.all { a -> CfRanges.FALLBACK_V6.any { CfRanges.inCidr(ip(a), it) } },
            "got $v6 (有非 CF 地址)")
        // C5: 族分离——IPv4 请求不得混入 v6
        val v4 = try { DnsResolver.resolveDomain("www.cloudflare.com", "IPv4") } catch (e: Exception) { emptyList<String>() }
        if (v4.isNotEmpty()) {
            check("C5 IPv4 请求不含 v6", v4.all { ProbeEngine.familyOf(it) == "IPv4" }, "got $v4")
        } else {
            skip("C5 IPv4 请求结果为空", "本机 DNS 无 A 记录")
        }
        println("    实际解析到的 v6: ${v6.joinToString(", ")}")
    }

    // ================= D. Pipeline.buildSnapshot("IPv6")（网络，可 SKIP） =================
    println("---- D. Pipeline.buildSnapshot IPv6（依赖本机 DNS） ----")
    val domains = listOf(
        "www.cloudflare.com", "cloudflare.com", "speed.cloudflare.com",
        "one.one.one.one", "www.nexusmods.com"
    )
    val snap = try {
        kotlinx.coroutines.runBlocking { Pipeline.buildSnapshot(domains, "IPv6") {} }
    } catch (e: Exception) {
        Pipeline.Snapshot("IPv6", emptyMap(), emptyMap(), emptyList())
    }

    if (snap.domainToIps.isEmpty()) {
        skip("D buildSnapshot IPv6 无有效地址", "本机 DNS 无 AAAA / 全部非 CF")
    } else {
        val allIps = snap.domainToIps.values.flatten()
        check("D1 Snapshot.family == IPv6", snap.family == "IPv6", "got ${snap.family}")
        check("D2 domainToIps 值全为 v6 字面量",
            allIps.isNotEmpty() && allIps.all { ProbeEngine.isIpLiteral(it) && ProbeEngine.familyOf(it) == "IPv6" },
            "got ${allIps.take(5)}")
        check("D3 每个 IP 可重解析为 Inet6Address（FixedDns/probe 可用）",
            allIps.all { runCatching { InetAddress.getByName(it) is Inet6Address }.getOrDefault(false) },
            "got ${allIps.take(5)}")
        check("D4 domain 内无重复 IP", snap.domainToIps.values.all { it.distinct().size == it.size })
        check("D5 ipToDomains 互逆（正向）",
            snap.domainToIps.all { (d, ips) -> ips.all { snap.ipToDomains[it]?.contains(d) == true } },
            "正向映射断裂")
        check("D6 ipToDomains 互逆（反向）",
            snap.ipToDomains.keys.all { ip -> snap.domainToIps.values.any { ip in it } },
            "反向映射断裂")
        check("D7 uniqueIps == ipToDomains.keys",
            snap.uniqueIps == snap.ipToDomains.keys.toList(),
            "unique=${snap.uniqueIps} keys=${snap.ipToDomains.keys}")
        println("    有效域名 ${snap.domainToIps.size} 个，去重 v6 IP ${snap.uniqueIps.size} 个")
    }

    // ================= E. addressesEqual 字节等价（纯函数） =================
    println("---- E. addressesEqual 压缩/展开字节等价 ----")
    check("E1 压缩 == 展开", ProbeEngine.addressesEqual(ip("2606:4700::1"), ip("2606:4700:0000:0000:0000:0000:0000:0001")))
    check("E2 大写 == 小写", ProbeEngine.addressesEqual(ip("2606:4700::A"), ip("2606:4700::a")))
    check("E3 不同地址不等", !ProbeEngine.addressesEqual(ip("2606:4700::1"), ip("2606:4700::2")))
    check("E4 null 安全", !ProbeEngine.addressesEqual(null, ip("2606:4700::1")) && !ProbeEngine.addressesEqual(ip("2606:4700::1"), null))
    check("E5 v4 vs v6 不等", !ProbeEngine.addressesEqual(ip("104.16.1.1"), ip("2606:4700::1")))

    println("\n===== IPv6 专项：PASS $passed / FAIL $failed / SKIP $skipped =====")
    if (failed > 0) kotlin.system.exitProcess(1)
}
