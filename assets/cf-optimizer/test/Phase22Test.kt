import com.cfoptimizer.NetEnv
import com.cfoptimizer.engine.Pipeline
import com.cfoptimizer.engine.Ranker
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking

/** Phase 2.2 边界测试：聚焦最终冠军正确性与本轮修复。 */
fun main() = runBlocking {
    var passed = 0
    var failed = 0
    fun check(name: String, cond: Boolean, detail: String = "") {
        if (cond) { passed++; println("PASS  $name") }
        else { failed++; println("FAIL  $name  $detail") }
    }

    // T1: Full FAIL 不能被过滤：Min=0 / Avg 含0 / Variation 含0 / Final Floor=0。
    run {
        val micro = mapOf(
            "1.1.1.1" to Pipeline.IpProbe("1.1.1.1", true, completeMbps = 100.0),
            "2.2.2.2" to Pipeline.IpProbe("2.2.2.2", true, completeMbps = 90.0)
        )
        val full = mapOf(
            "1.1.1.1" to listOf(Pipeline.IpProbe("1.1.1.1", true, completeMbps = 60.0, payloadMbps = 70.0, ttfbMs = 50.0)),
            "2.2.2.2" to listOf(Pipeline.IpProbe("2.2.2.2", false, completeMbps = 0.0, payloadMbps = 0.0, ttfbMs = -1.0))
        )
        val m = Pipeline.DomainResult("a.com", "IPv4", listOf("1.1.1.1", "2.2.2.2"), micro, full).toMetric()
        check("T1 Final FAIL -> Floor=0", m.addressFloorMbps == 0.0, "got ${m.addressFloorMbps}")
        check("T1b Final FAIL -> Min=0", m.minCompleteMbps == 0.0, "got ${m.minCompleteMbps}")
        check("T1c Final FAIL -> Avg含0=30", kotlin.math.abs(m.avgCompleteMbps - 30.0) < 0.001, "got ${m.avgCompleteMbps}")
        check("T1d FullSuccess=50 AddressSuccess=50", m.successRatePct == 50.0 && m.addressSuccessRatePct == 50.0,
            "got full=${m.successRatePct} addr=${m.addressSuccessRatePct}")
        check("T1e Micro Floor 与 Final Floor 分离", m.microAddressFloorMbps == 90.0 && m.addressFloorMbps == 0.0,
            "micro=${m.microAddressFloorMbps} final=${m.addressFloorMbps}")
    }

    // T2: Final Floor 必须来自 Full per-IP，而不是 Micro。
    run {
        val micro = mapOf(
            "a" to Pipeline.IpProbe("a", true, completeMbps = 100.0),
            "b" to Pipeline.IpProbe("b", true, completeMbps = 90.0)
        )
        val full = mapOf(
            "a" to listOf(Pipeline.IpProbe("a", true, completeMbps = 50.0, payloadMbps = 60.0, ttfbMs = 40.0)),
            "b" to listOf(Pipeline.IpProbe("b", true, completeMbps = 40.0, payloadMbps = 50.0, ttfbMs = 45.0))
        )
        val m = Pipeline.DomainResult("x", "IPv4", listOf("a", "b"), micro, full).toMetric()
        check("T2 MicroFloor=90 FinalFloor=40", m.microAddressFloorMbps == 90.0 && m.addressFloorMbps == 40.0,
            "micro=${m.microAddressFloorMbps} final=${m.addressFloorMbps}")
        check("T2b best/worst 使用 Full", m.bestIp == "a" && m.worstIp == "b", "best=${m.bestIp} worst=${m.worstIp}")
    }

    // T3: 4 IP / fullRounds=3 仍必须全覆盖 4 IP。
    run {
        val schedule = Pipeline.fullSchedule(listOf("1", "2", "3", "4"), 3)
        check("T3 4IP fullRounds3 -> 4 attempts", schedule.size == 4, "got $schedule")
        check("T3b 4IP 全覆盖", schedule.toSet() == setOf("1", "2", "3", "4"), "got $schedule")
    }

    // T4: 地址少于最小轮数时，覆盖后轮转额外轮次。
    run {
        val schedule = Pipeline.fullSchedule(listOf("A", "B"), 3)
        check("T4 2IP fullRounds3 -> A,B,A", schedule == listOf("A", "B", "A"), "got $schedule")
    }

    // T5: Micro 共享 IP + Full max(addressCount, rounds) 流量计算。
    run {
        val snap = Pipeline.Snapshot(
            family = "IPv4",
            domainToIps = mapOf(
                "a.com" to listOf("1", "2"),
                "b.com" to listOf("1")
            ),
            ipToDomains = mapOf("1" to setOf("a.com", "b.com"), "2" to setOf("a.com")),
            uniqueIps = listOf("1", "2")
        )
        val mb = Pipeline.estimateTrafficMb(snap, Pipeline.STANDARD, listOf("a.com", "b.com"), listOf("a.com"))
        val expected = (2 * 128_000L + 2 * 2_000_000L + 3 * 10_000_000L) / 1_000_000.0
        check("T5 estimateTrafficMb=$expected", kotlin.math.abs(mb - expected) < 0.001, "got $mb")
    }

    // T6: IPv6 Probe 失败必须真正从 activeFamilies 移除。
    run {
        val active = Pipeline.activeFamilies(listOf("IPv4", "IPv6"), true, true, false)
        check("T6 IPv6 probe失败 -> active仅IPv4", active == listOf("IPv4"), "got $active")
        val active6 = Pipeline.activeFamilies(listOf("IPv6"), false, true, true)
        check("T6b IPv6 probe成功 -> 保留IPv6", active6 == listOf("IPv6"), "got $active6")
    }

    // T7: NetworkCallback 噪声（fingerprint 不变）不能 INVALID；真变化必须 INVALID。
    run {
        val f1 = NetEnv.NetworkFingerprint("101", "Mobile", false, true, true)
        val same = NetEnv.NetworkFingerprint("101", "Mobile", false, true, true)
        val vpn = NetEnv.NetworkFingerprint("202", "VPN", true, true, true)
        check("T7 fingerprint相同不算变化", !NetEnv.materiallyChanged(f1, same))
        check("T7b VPN/activeNetwork变化算变化", NetEnv.materiallyChanged(f1, vpn))
    }

    // T8: Baseline +9% 不替换；+10% 且可靠/稳定不差才替换。
    run {
        val base = Ranker.DomainMetric(
            "base", "IPv4", minCompleteMbps = 50.0, avgCompleteMbps = 50.0,
            successRatePct = 100.0, variationPct = 10.0,
            addressFloorMbps = 50.0, addressSuccessRatePct = 100.0
        )
        val plus9 = base.copy(domain = "plus9", minCompleteMbps = 54.5, avgCompleteMbps = 54.5, addressFloorMbps = 54.5)
        val plus10 = base.copy(domain = "plus10", minCompleteMbps = 55.0, avgCompleteMbps = 55.0, addressFloorMbps = 55.0)
        check("T8 +9% 不允许替换", Ranker.compareToBaseline(plus9, base).decision != Ranker.BaselineDecision.REPLACE)
        check("T8b +10% 且稳定 -> REPLACE", Ranker.compareToBaseline(plus10, base).decision == Ranker.BaselineDecision.REPLACE)
        val unstable = plus10.copy(domain = "unstable", variationPct = 20.1)
        check("T8c +10% 但波动明显更差 -> 不替换", Ranker.compareToBaseline(unstable, base).decision != Ranker.BaselineDecision.REPLACE)
    }

    // T9: 排名链在 Floor 同为0时，Full Success Rate 优先。
    run {
        val a = Ranker.DomainMetric("a", "IPv4", addressFloorMbps = 0.0, successRatePct = 50.0,
            minCompleteMbps = 0.0, avgCompleteMbps = 50.0, addressSuccessRatePct = 50.0)
        val b = Ranker.DomainMetric("b", "IPv4", addressFloorMbps = 0.0, successRatePct = 100.0,
            minCompleteMbps = 0.0, avgCompleteMbps = 40.0, addressSuccessRatePct = 50.0)
        check("T9 Floor同为0 -> Full Success高者优先", Ranker.rank(listOf(a, b)).first().domain == "b")
    }

    // T10: FAIL=0 必须进入波动率。
    run {
        val v = Ranker.variation(listOf(60.0, 0.0))
        check("T10 Variation包含FAIL=0", v > 100.0, "got $v")
    }

    // T11: 并发任务只返回结果，awaitAll 后数量完整（对应 Pipeline 的无共享写法）。
    run {
        val values = (0 until 100).map { i -> async { i to (i * 2) } }.awaitAll().toMap()
        check("T11 并发收集100项完整", values.size == 100 && values[99] == 198, "size=${values.size}")
    }

    println("\n===== Phase 2.2：PASS $passed / FAIL $failed =====")
    if (failed > 0) kotlin.system.exitProcess(1)
}
