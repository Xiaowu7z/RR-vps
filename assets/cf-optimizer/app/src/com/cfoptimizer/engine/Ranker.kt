package com.cfoptimizer.engine

import kotlin.math.abs
import kotlin.math.round

/**
 * 排名引擎（Phase 2.2）。
 *
 * 最终排名链：
 *   Final Address Floor（Full 每 IP 聚合，失败地址=0）
 * → Full Success Rate
 * → Minimum CompleteTransferMbps（FAIL 计 0）
 * → Average CompleteTransferMbps（FAIL 计 0）
 * → Final Address Success Rate
 * → 波动率（FAIL 计 0）
 * → Median TTFB
 *
 * Micro Floor 只负责预筛，不参与最终冠军第一排序键。
 */
object Ranker {

    data class DomainMetric(
        val domain: String,
        val family: String,
        // Full 完整测速指标（失败轮次按 0 参与统计）
        val minCompleteMbps: Double = 0.0,
        val avgCompleteMbps: Double = 0.0,
        val maxCompleteMbps: Double = 0.0,
        val minPayloadMbps: Double = 0.0,
        val avgPayloadMbps: Double = 0.0,
        val successRatePct: Double = 0.0,        // Full attempt 成功率
        val variationPct: Double = 0.0,          // FAIL=0 参与波动率
        val medianTtfbMs: Double = -1.0,
        // 地址级指标
        val microAddressFloorMbps: Double = 0.0, // 仅预筛参考
        val addressFloorMbps: Double = 0.0,      // Final Full Address Floor（正式排名）
        val microAddressSuccessRatePct: Double = 0.0,
        val addressSuccessRatePct: Double = 0.0, // Final Full 地址成功率
        val addressesTested: Int = 0,
        val sampled: Boolean = false,            // Phase 2.2 正常 finalist 应为 false
        val bestIp: String = "",
        val worstIp: String = "",
        val currentIps: List<String> = emptyList(),
        val ipPops: List<String> = emptyList(),
        val ipLoc: List<String> = emptyList(),
        val baselineMbps: Double = 0.0,
        val baselineRatioPct: Double = 0.0,
        // Phase 2.7: 亚洲入口狩猎元数据
        val primaryPop: String = "",
        val edgeScore: Int = 0,
        val popDrift: Boolean = false
    ) {
        val mbPerSec: Double get() = avgCompleteMbps / 8.0

        fun pctVs(against: Double): String =
            if (against > 0) "${if (avgCompleteMbps >= against) "+" else ""}${"%.1f".format((avgCompleteMbps - against) * 100 / against)}%"
            else "n/a"
    }

    enum class BaselineDecision {
        REPLACE, OBSERVE, KEEP
    }

    data class BaselineComparison(
        val decision: BaselineDecision,
        val floorGainPct: Double,
        val minimumGainPct: Double,
        val averageGainPct: Double,
        val reliabilityNotWorse: Boolean,
        val stabilityNotWorse: Boolean
    )

    /** 任一失败地址 → Floor=0；全部成功 → min。 */
    fun addressFloor(speeds: List<Double>, failedCount: Int): Double {
        if (failedCount > 0) return 0.0
        val valid = speeds.filter { it > 0.0 && it.isFinite() }
        return if (valid.isEmpty()) 0.0 else valid.minOrNull() ?: 0.0
    }

    fun addressSuccessRate(successes: Int, total: Int): Double =
        if (total <= 0) 0.0 else round(successes * 1000.0 / total) / 10.0

    fun successRate(successes: Int, total: Int): Double =
        if (total <= 0) 0.0 else round(successes * 1000.0 / total) / 10.0

    /** Median 只对实际成功拿到的 TTFB 计算（<=0 表示无效/FAIL）。 */
    fun medianTtfb(ttfbs: List<Double>): Double {
        val valid = ttfbs.filter { it > 0 && it.isFinite() }.sorted()
        if (valid.isEmpty()) return -1.0
        val n = valid.size
        return if (n % 2 == 1) valid[n / 2] else (valid[n / 2 - 1] + valid[n / 2]) / 2.0
    }

    /**
     * 波动率：0 代表失败吞吐时必须参与，不再过滤失败轮次。
     * -1/NaN/Infinity 仍视为无效数据，不参与。
     */
    fun variation(speeds: List<Double>): Double {
        val values = speeds.filter { it >= 0.0 && it.isFinite() }
        if (values.size < 2) return 0.0
        val avg = values.average()
        if (avg <= 0.0) return 0.0
        return round(((values.maxOrNull()!! - values.minOrNull()!!) / avg) * 1000) / 10.0
    }

    /** Phase 2.2 正式排名链。 */
    fun rank(metrics: List<DomainMetric>): List<DomainMetric> {
        return metrics.sortedWith(
            compareByDescending<DomainMetric> { it.addressFloorMbps }
                .thenByDescending { it.successRatePct }
                .thenByDescending { it.minCompleteMbps }
                .thenByDescending { it.avgCompleteMbps }
                .thenByDescending { it.addressSuccessRatePct }
                .thenBy { it.variationPct }
                .thenBy { if (it.medianTtfbMs < 0) Double.MAX_VALUE else it.medianTtfbMs }
        )
    }


    /** 亚洲入口榜：先看入口价值，再看 Final Floor / 可靠性 / 吞吐。 */
    fun rankAsia(metrics: List<DomainMetric>): List<DomainMetric> {
        return metrics.sortedWith(
            compareByDescending<DomainMetric> { it.edgeScore }
                .thenBy { it.popDrift }
                .thenByDescending { it.addressFloorMbps }
                .thenByDescending { it.successRatePct }
                .thenByDescending { it.minCompleteMbps }
                .thenByDescending { it.avgCompleteMbps }
                .thenBy { it.variationPct }
                .thenBy { if (it.medianTtfbMs < 0) Double.MAX_VALUE else it.medianTtfbMs }
        )
    }

    /**
     * 守擂规则：默认要求三项核心吞吐均至少 +10%，可靠性不能下降，波动率最多差 5 个百分点。
     * Baseline 自身无有效成绩时不做自动替换结论，只返回 OBSERVE。
     */
    fun compareToBaseline(
        challenger: DomainMetric,
        baseline: DomainMetric,
        requiredGainPct: Double = 10.0,
        allowedVariationWorsePoints: Double = 5.0
    ): BaselineComparison {
        fun gain(value: Double, base: Double): Double =
            if (base > 0.0) (value - base) * 100.0 / base else Double.NaN

        val floorGain = gain(challenger.addressFloorMbps, baseline.addressFloorMbps)
        val minGain = gain(challenger.minCompleteMbps, baseline.minCompleteMbps)
        val avgGain = gain(challenger.avgCompleteMbps, baseline.avgCompleteMbps)

        val reliabilityOk = challenger.successRatePct + 1e-9 >= baseline.successRatePct &&
            challenger.addressSuccessRatePct + 1e-9 >= baseline.addressSuccessRatePct
        val stabilityOk = challenger.variationPct <= baseline.variationPct + allowedVariationWorsePoints + 1e-9

        val baselineValid = baseline.addressFloorMbps > 0.0 &&
            baseline.minCompleteMbps > 0.0 && baseline.avgCompleteMbps > 0.0 &&
            baseline.successRatePct > 0.0 && baseline.addressSuccessRatePct > 0.0

        val threshold = requiredGainPct - 1e-9
        val beatsClearly = baselineValid &&
            floorGain >= threshold && minGain >= threshold && avgGain >= threshold &&
            reliabilityOk && stabilityOk

        val betterButNotEnough = baselineValid &&
            floorGain > 0.0 && minGain > 0.0 && avgGain > 0.0 &&
            reliabilityOk && stabilityOk

        val decision = when {
            beatsClearly -> BaselineDecision.REPLACE
            !baselineValid -> BaselineDecision.OBSERVE
            betterButNotEnough -> BaselineDecision.OBSERVE
            else -> BaselineDecision.KEEP
        }

        return BaselineComparison(
            decision = decision,
            floorGainPct = floorGain,
            minimumGainPct = minGain,
            averageGainPct = avgGain,
            reliabilityNotWorse = reliabilityOk,
            stabilityNotWorse = stabilityOk
        )
    }

    fun stabilityLabel(variationPct: Double, successRatePct: Double): String = when {
        successRatePct >= 90 && variationPct <= 15 -> "优秀"
        successRatePct >= 75 && variationPct <= 30 -> "良好"
        successRatePct >= 50 -> "一般"
        else -> "较差"
    }
}
