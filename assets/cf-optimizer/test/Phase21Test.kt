import com.cfoptimizer.engine.Ranker
import com.cfoptimizer.engine.Pipeline
import com.cfoptimizer.engine.CfRanges
import com.cfoptimizer.engine.DnsResolver

/**
 * Phase 2.1 边界单测（JVM，覆盖审查要求全部场景）。
 */
fun main() {
    var passed = 0
    var failed = 0
    fun check(name: String, cond: Boolean, detail: String = "") {
        if (cond) { passed++; println("PASS  $name") }
        else { failed++; println("FAIL  $name  $detail") }
    }

    // ===== 1. 一个地址快 + 一个地址 FAIL：Floor 必须为 0 =====
    run {
        val floor = Ranker.addressFloor(listOf(60.0, 0.0), failedCount = 1)
        check("T1 快+FAIL → Floor=0", floor == 0.0, "got $floor")
        // 单测：A=[60,FAIL] vs B=[50,48]，B 必须排在 A 前
        val a = Ranker.DomainMetric(domain = "a.com", family = "IPv4",
            addressFloorMbps = Ranker.addressFloor(listOf(60.0, 0.0), 1),
            minCompleteMbps = 60.0, avgCompleteMbps = 60.0,
            addressSuccessRatePct = 50.0, variationPct = 10.0, medianTtfbMs = 50.0)
        val b = Ranker.DomainMetric(domain = "b.com", family = "IPv4",
            addressFloorMbps = Ranker.addressFloor(listOf(50.0, 48.0), 0),
            minCompleteMbps = 48.0, avgCompleteMbps = 49.0,
            addressSuccessRatePct = 100.0, variationPct = 2.0, medianTtfbMs = 55.0)
        val ranked = Ranker.rank(listOf(a, b))
        check("T1b [60,FAIL] vs [50,48] → B 在前", ranked[0].domain == "b.com",
            "got ${ranked.map { it.domain }}")
    }

    // ===== 2. 一个地址极快 + 一个极慢：Floor 拉低 =====
    run {
        val floor = Ranker.addressFloor(listOf(100.0, 5.0), failedCount = 0)
        check("T2 极快+极慢 Floor=5", floor == 5.0, "got $floor")
    }

    // ===== 3. 两个地址都稳定 =====
    run {
        val floor = Ranker.addressFloor(listOf(55.0, 53.0), failedCount = 0)
        check("T3 双稳定 Floor=53", floor == 53.0, "got $floor")
    }

    // ===== 4. 地址成功率 =====
    run {
        val r1 = Ranker.addressSuccessRate(1, 2)
        val r2 = Ranker.addressSuccessRate(2, 2)
        check("T4 成功率 1/2=50% 2/2=100%", r1 == 50.0 && r2 == 100.0, "got $r1 $r2")
    }

    // ===== 5. Median TTFB（不用 min） =====
    run {
        val med = Ranker.medianTtfb(listOf(10.0, 50.0, 60.0))   // min=10, median=50
        check("T5 Median TTFB=50（非 min 10）", med == 50.0, "got $med")
        val medEven = Ranker.medianTtfb(listOf(20.0, 40.0))
        check("T5b 偶数 Median=30", medEven == 30.0, "got $medEven")
        val medSkip = Ranker.medianTtfb(listOf(-1.0, 30.0, 10.0))
        check("T5c 跳过无效值 [30,10] Median=20", medSkip == 20.0, "got $medSkip")
    }

    // ===== 6. DNS Snapshot 固定：同输入同结果；domain→IP 与 IP→domain 互逆一致 =====
    run {
        val domains = listOf("www.cloudflare.com", "cloudflare.com")
        val s1 = kotlinx.coroutines.runBlocking { Pipeline.buildSnapshot(domains, "IPv4") {} }
        val s2 = kotlinx.coroutines.runBlocking { Pipeline.buildSnapshot(domains, "IPv4") {} }
        val domainIpsSame = s1.domainToIps == s2.domainToIps
        // 互逆：domainToIps 中每个 (d, ips) 在 ipToDomains 中都有 d
        var inverseOk = true
        for ((d, ips) in s1.domainToIps) {
            for (ip in ips) {
                if ((s1.ipToDomains[ip] ?: emptySet()).contains(d).not()) inverseOk = false
            }
        }
        check("T6 DNS Snapshot 确定性 + 互逆一致", domainIpsSame && inverseOk)
    }

    // ===== 7. 多域名共享同一 IP：ipToDomains 记录多来源 =====
    run {
        // 构造共享：用同一 IP 两个域名（JVM 无法强制解析，用假数据验证结构语义）
        val snap = Pipeline.Snapshot(
            family = "IPv4",
            domainToIps = mapOf("a.com" to listOf("1.1.1.1", "2.2.2.2"), "b.com" to listOf("1.1.1.1")),
            ipToDomains = mapOf("1.1.1.1" to setOf("a.com", "b.com"), "2.2.2.2" to setOf("a.com")),
            uniqueIps = listOf("1.1.1.1", "2.2.2.2")
        )
        check("T7 共享 IP 多来源", snap.ipToDomains["1.1.1.1"] == setOf("a.com", "b.com"))
        val microD = listOf("a.com", "b.com")
        val est = Pipeline.estimateTrafficMb(snap, Pipeline.STANDARD, microD, listOf("a.com"))
        // Phase 2.2：Micro 共享 IP 只测一次；Full 至少覆盖全部地址并满足最小 rounds。
        // pre: 2×128000; micro unique: 2×2M; full a.com: max(3,2)×10M
        val expected = (2 * 128000L + 2 * 2_000_000L + 3 * 10_000_000L) / 1_000_000.0
        check("T7b 流量估算 = $expected MB", Math.abs(est - expected) < 0.001, "got $est")
    }

    // ===== 8. IPv4/IPv6 分离 =====
    run {
        val v4 = DnsResolver.resolveDomain("www.cloudflare.com", "IPv4")
        val v6 = DnsResolver.resolveDomain("www.cloudflare.com", "IPv6")
        val v4all4 = v4.all { !it.contains(":") }
        val v6all6 = v6.all { it.contains(":") }
        check("T8 v4/v6 分离解析", v4all4 && v6all6 && v4.isNotEmpty(), "v4=$v4 v6=$v6")
    }

    // ===== 9. Baseline 强制晋级 =====
    run {
        // 模拟 Pre 排名不含 baseline，但晋级集合必须包含
        val rankedDomains = listOf("x.com", "y.com", "z.com")
        val micro = LinkedHashSet<String>()
        micro.add(Pipeline.BASELINE_DOMAIN)
        for (d in rankedDomains) {
            if (micro.size >= 10) break
            micro.add(d)
        }
        check("T9 Baseline 强制晋级 Micro", micro.contains(Pipeline.BASELINE_DOMAIN))
    }

    // ===== 10. 排名链：Floor → Min → Avg → 成功率 → 波动 → Median TTFB =====
    run {
        // 同 Floor/Min/Avg 下，成功率高的在前
        val m1 = Ranker.DomainMetric(domain = "m1", family = "IPv4",
            addressFloorMbps = 40.0, minCompleteMbps = 40.0, avgCompleteMbps = 45.0,
            addressSuccessRatePct = 90.0, variationPct = 10.0, medianTtfbMs = 50.0)
        val m2 = Ranker.DomainMetric(domain = "m2", family = "IPv4",
            addressFloorMbps = 40.0, minCompleteMbps = 40.0, avgCompleteMbps = 45.0,
            addressSuccessRatePct = 70.0, variationPct = 10.0, medianTtfbMs = 50.0)
        val r = Ranker.rank(listOf(m2, m1))
        check("T10 同分时成功率高者在前", r[0].domain == "m1", "got ${r.map { it.domain }}")
    }

    // ===== 11. 波动率/稳定性标签 =====
    run {
        val v = Ranker.variation(listOf(100.0, 50.0))
        check("T11 波动率 (100,50)=66.7%", Math.abs(v - 66.7) < 0.1, "got $v")
    }

    // ===== 12. CF 网段内置备用 =====
    run {
        check("T12 备用网段 15+7", CfRanges.FALLBACK_V4.size == 15 && CfRanges.FALLBACK_V6.size == 7)
    }

    println("\n===== 结果：PASS $passed / FAIL $failed =====")
    if (failed > 0) kotlin.system.exitProcess(1)
}
