import com.cfoptimizer.engine.CfRanges
import com.cfoptimizer.engine.DnsResolver
import com.cfoptimizer.engine.Ranker
import java.net.InetAddress

/**
 * Phase 2 JVM 单测：CF 网段判定 / 解析去重 / Address Floor / 排名链。
 * （Pipeline 全流程集成测试依赖真机网络环境——服务器端 1034 会大量拒绝候选 IP，无法代表真机。）
 */
fun main() {
    // [1] CF 网段判定
    println("=== 1. CF 网段判定 ===")
    val cfV4 = InetAddress.getByName("104.16.123.96")
    val nonCfV4 = InetAddress.getByName("8.8.8.8")
    val cfV6 = InetAddress.getByName("2606:4700::1")
    println("104.16.123.96 isCF=${CfRanges.isCloudflare(cfV4)}（应 true）")
    println("8.8.8.8 isCF=${CfRanges.isCloudflare(nonCfV4)}（应 false）")
    println("2606:4700::1 isCF=${CfRanges.isCloudflare(cfV6)}（应 true）")
    println("内置备用 v4 段数=${CfRanges.FALLBACK_V4.size} v6 段数=${CfRanges.FALLBACK_V6.size}")

    // [2] 解析 + 去重（构造小域名池，服务器端仅验证逻辑不依赖 1034）
    println("\n=== 2. 解析去重（构造 3 个域名） ===")
    val pool = listOf("www.cloudflare.com", "cloudflare.com", "www.google.com")
    val v4res = DnsResolver.resolvePool(pool, "IPv4") { println("  $it") }
    println("去重 v4 IP 数=${v4res.size}")
    val shared = v4res.values.filter { it.sourceDomains.size > 1 }
    println("多域名共享 IP 数=${shared.size}（共享来源示例：${shared.firstOrNull()?.sourceDomains}）")

    // [3] Address Floor 与排名链
    println("\n=== 3. Address Floor + 排名链 ===")
    // 构造：域名A 两地址 100/20 → floor 20；域名B 单地址 50 → floor 50；域名C 两地址 40/45 → floor 40
    val metrics = listOf(
        Ranker.DomainMetric(domain = "a.com", family = "IPv4", addressFloorMbps = 20.0,
            minCompleteMbps = 80.0, avgCompleteMbps = 95.0, successRatePct = 100.0,
            variationPct = 10.0, medianTtfbMs = 50.0, addressesTested = 2, bestIp = "1.1.1.1", worstIp = "2.2.2.2"),
        Ranker.DomainMetric(domain = "b.com", family = "IPv4", addressFloorMbps = 50.0,
            minCompleteMbps = 50.0, avgCompleteMbps = 50.0, successRatePct = 100.0,
            variationPct = 5.0, medianTtfbMs = 60.0, addressesTested = 1, bestIp = "3.3.3.3", worstIp = "3.3.3.3"),
        Ranker.DomainMetric(domain = "c.com", family = "IPv4", addressFloorMbps = 40.0,
            minCompleteMbps = 40.0, avgCompleteMbps = 42.0, successRatePct = 95.0,
            variationPct = 8.0, medianTtfbMs = 55.0, addressesTested = 2, bestIp = "4.4.4.4", worstIp = "5.5.5.5")
    )
    val ranked = Ranker.rank(metrics)
    println("排名（应 b.com > c.com > a.com——a.com 峰值 95 但 Floor 只有 20 被压后）：")
    ranked.forEachIndexed { i, m ->
        println("  ${i + 1}. ${m.domain} floor=${m.addressFloorMbps} avg=${m.avgCompleteMbps}")
    }

    // [4] 波动率与成功率
    println("\n=== 4. 波动/成功率/稳定性 ===")
    println("波动(100,90,80)=${Ranker.variation(listOf(100.0, 90.0, 80.0))}")
    println("成功率(2/3)=${Ranker.successRate(2, 3)}%")
    println("稳定性(v=10,rate=100)=${Ranker.stabilityLabel(10.0, 100.0)}")
    println("稳定性(v=40,rate=60)=${Ranker.stabilityLabel(40.0, 60.0)}")

    // [5] IPv4/IPv6 独立解析验证
    println("\n=== 5. 双栈独立解析 ===")
    val v4 = DnsResolver.resolveDomain("www.cloudflare.com", "IPv4")
    val v6 = DnsResolver.resolveDomain("www.cloudflare.com", "IPv6")
    println("v4 地址数=${v4.size} v6 地址数=${v6.size}")
    println("v4 示例=${v4.take(2)} v6 示例=${v6.take(2)}")
}
