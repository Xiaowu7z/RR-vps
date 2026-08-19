package com.cfoptimizer.engine

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.util.concurrent.atomic.AtomicInteger
import java.net.Inet6Address
import java.net.InetAddress
import kotlin.math.max

/**
 * Phase 2.2 主流水线。
 *
 * 核心约束：
 * 1. Snapshot 由调用方在开始前建立一次并传入，全流程禁止重新 DNS。
 * 2. Pre/Micro 对 unique IP 并发探测后 awaitAll，再单线程合并，避免并发 HashMap/计数器竞态。
 * 3. Micro Floor 只负责晋级；Final Floor 必须来自 Full per-IP 数据。
 * 4. finalist 的 Snapshot 每个有效 IP 至少 Full 一次；额外轮次在全地址覆盖后轮转。
 * 5. Full FAIL 以 0 Mbps 进入 Minimum/Average/Variation，并进入 Full Success Rate 惩罚。
 * 6. Baseline www.nexusmods.com 强制进入 Micro/Full。
 */
object Pipeline {

    const val BASELINE_DOMAIN = "www.nexusmods.com"

    // Phase 2.2.1：初筛/小流量是淘汰阶段，不允许单个黑洞 IP 把整个队列拖 20~30 秒。
    // Full 仍保留 30 秒，避免误杀高延迟但可用的最终候选。
    private const val PRE_TIMEOUT_SEC = 8
    private const val MICRO_TIMEOUT_SEC = 12
    private const val FULL_TIMEOUT_SEC = 30

    data class ModeParams(
        val topDomains: Int,
        val preBytes: Long,
        val microBytes: Long,
        val fullBytes: Long,
        val fullRounds: Int,      // 最小 Full attempt 数；地址更多时自动扩大以覆盖全部地址
        val finalDomains: Int,
        val concurrency: Int,
        val preConcurrency: Int = concurrency,   // 初筛并发（小流量，可高并发）
        val microConcurrency: Int = concurrency, // 小流量筛选并发
        val fullConcurrency: Int = 1             // 完整测速并发（大流量，低并发防发热）
    )

    // Phase 2.4：唯一均衡模式（原 Quick/Standard/Deep 三档保留常量仅作兼容，UI 只提供均衡）
    val QUICK = ModeParams(6, 64_000L, 1_000_000L, 5_000_000L, 2, 3, 3)
    val STANDARD = ModeParams(10, 128_000L, 2_000_000L, 10_000_000L, 3, 5, 3)
    val DEEP = ModeParams(16, 256_000L, 3_000_000L, 20_000_000L, 3, 8, 2)
    val BALANCED = ModeParams(
        topDomains = 12, preBytes = 128_000L, microBytes = 2_000_000L,
        fullBytes = 10_000_000L, fullRounds = 2, finalDomains = 5,
        concurrency = 4, preConcurrency = 8, microConcurrency = 6, fullConcurrency = 1
    )

    data class Stage(val name: String, val current: Int = 0, val total: Int = 0) {
        override fun toString(): String = if (total > 0) "$name $current/$total" else name
    }

    data class IpProbe(
        val ip: String,
        val ok: Boolean = false,
        val tcpMs: Double = -1.0,
        val tlsMs: Double = -1.0,
        val ttfbMs: Double = -1.0,
        val payloadMbps: Double = 0.0,
        val completeMbps: Double = 0.0,
        val colo: String = "",
        val loc: String = ""
    )

    data class Snapshot(
        val family: String,
        val domainToIps: Map<String, List<String>>,
        val ipToDomains: Map<String, Set<String>>,
        val uniqueIps: List<String>
    )

    /** finalist 的所有 Full 数据，按 IP 保存，POP/失败状态不会被最后一轮覆盖。 */
    data class DomainResult(
        val domain: String,
        val family: String,
        val addresses: List<String>,
        val microProbes: Map<String, IpProbe>,
        val fullProbesByIp: Map<String, List<IpProbe>>,
        val baselineMbps: Double = 0.0
    ) {
        fun toMetric(): Ranker.DomainMetric {
            val fullAttempts = addresses.flatMap { fullProbesByIp[it] ?: emptyList() }
            val fullSpeeds = fullAttempts.map { if (it.ok) it.completeMbps else 0.0 }
            val fullPayloads = fullAttempts.map { if (it.ok) it.payloadMbps else 0.0 }
            val fullTtfbs = fullAttempts.map { if (it.ok) it.ttfbMs else -1.0 }
            val fullSuccesses = fullAttempts.count { it.ok }

            // 每个 IP 的 Final 分数：该 IP 任一 Full FAIL -> 该地址 Final=0；否则取该 IP 多轮平均。
            val finalPerIp = LinkedHashMap<String, Double>()
            for (ip in addresses) {
                val attempts = fullProbesByIp[ip] ?: emptyList()
                val score = if (attempts.isEmpty() || attempts.any { !it.ok }) {
                    0.0
                } else {
                    attempts.map { it.completeMbps }.average()
                }
                finalPerIp[ip] = score
            }

            val finalAddressSuccesses = finalPerIp.values.count { it > 0.0 }
            val finalAddressFailures = addresses.size - finalAddressSuccesses
            val finalFloor = Ranker.addressFloor(finalPerIp.values.toList(), finalAddressFailures)

            val microList = addresses.mapNotNull { microProbes[it] }
            val microOk = microList.count { it.ok }
            val microFailed = addresses.size - microOk
            val microFloor = Ranker.addressFloor(
                addresses.map { microProbes[it]?.completeMbps ?: 0.0 },
                microFailed
            )

            // POP/loc 优先使用 Full 成功结果；没有则回退 Micro。
            val ipPops = ArrayList<String>()
            val ipLocs = ArrayList<String>()
            for (ip in addresses) {
                val fullOk = (fullProbesByIp[ip] ?: emptyList()).lastOrNull { it.ok }
                val source = fullOk ?: microProbes[ip]
                if (source != null && source.colo.isNotEmpty()) ipPops.add("$ip: ${source.colo}")
                if (source != null && source.loc.isNotEmpty()) ipLocs.add("$ip: ${source.loc}")
            }

            val bestIp = finalPerIp.entries.maxByOrNull { it.value }?.key ?: ""
            val worstIp = finalPerIp.entries.minByOrNull { it.value }?.key ?: ""
            val fullCoveredAll = addresses.isNotEmpty() && addresses.all { !fullProbesByIp[it].isNullOrEmpty() }

            val avgComplete = if (fullSpeeds.isEmpty()) 0.0 else fullSpeeds.average()
            return Ranker.DomainMetric(
                domain = domain,
                family = family,
                minCompleteMbps = if (fullSpeeds.isEmpty()) 0.0 else fullSpeeds.minOrNull() ?: 0.0,
                avgCompleteMbps = avgComplete,
                maxCompleteMbps = if (fullSpeeds.isEmpty()) 0.0 else fullSpeeds.maxOrNull() ?: 0.0,
                minPayloadMbps = if (fullPayloads.isEmpty()) 0.0 else fullPayloads.minOrNull() ?: 0.0,
                avgPayloadMbps = if (fullPayloads.isEmpty()) 0.0 else fullPayloads.average(),
                successRatePct = Ranker.successRate(fullSuccesses, fullAttempts.size),
                variationPct = Ranker.variation(fullSpeeds),
                medianTtfbMs = Ranker.medianTtfb(fullTtfbs),
                microAddressFloorMbps = microFloor,
                addressFloorMbps = finalFloor,
                microAddressSuccessRatePct = Ranker.addressSuccessRate(microOk, addresses.size),
                addressSuccessRatePct = Ranker.addressSuccessRate(finalAddressSuccesses, addresses.size),
                addressesTested = addresses.size,
                sampled = !fullCoveredAll,
                bestIp = bestIp,
                worstIp = worstIp,
                currentIps = addresses,
                ipPops = ipPops,
                ipLoc = ipLocs,
                baselineMbps = baselineMbps,
                baselineRatioPct = if (baselineMbps > 0.0 && avgComplete > 0.0) avgComplete * 100.0 / baselineMbps else 0.0
            )
        }
    }

    /** 建立一次 DNS Snapshot；调用方负责 CfRanges.refresh() 在此之前完成。 */
    fun buildSnapshot(domains: List<String>, family: String, log: (String) -> Unit): Snapshot {
        val wantV6 = family == "IPv6"
        val domainToIps = LinkedHashMap<String, List<String>>()
        val ipToDomains = LinkedHashMap<String, MutableSet<String>>()

        for (d in domains) {
            val name = d.trim().lowercase()
            if (name.isEmpty()) continue
            val addrs = try { InetAddress.getAllByName(name) } catch (_: Exception) { continue }
            val validIps = addrs
                .filter { (wantV6 && it is Inet6Address) || (!wantV6 && it !is Inet6Address) }
                .filter { CfRanges.isCloudflare(it) }
                .mapNotNull { it.hostAddress }
                .filter { it.isNotEmpty() }
                .distinct()
            if (validIps.isEmpty()) continue
            domainToIps[name] = validIps
            for (ip in validIps) ipToDomains.getOrPut(ip) { LinkedHashSet() }.add(name)
        }

        val snapshot = Snapshot(
            family = family,
            domainToIps = domainToIps,
            ipToDomains = ipToDomains.mapValues { it.value.toSet() },
            uniqueIps = ipToDomains.keys.toList()
        )
        log("DNS 快照($family)：有效域名 ${snapshot.domainToIps.size}，去重 Cloudflare IP ${snapshot.uniqueIps.size}")
        return snapshot
    }

    /** Full 总 attempt 数：至少覆盖所有 IP 一次，同时满足 profile 的最小轮数。 */
    fun requiredFullAttempts(addressCount: Int, fullRounds: Int): Int =
        if (addressCount <= 0) 0 else max(addressCount, fullRounds)

    /** Full 调度：先完整覆盖所有地址，再按 Snapshot 顺序轮转额外轮次。 */
    fun fullSchedule(ips: List<String>, fullRounds: Int): List<String> {
        if (ips.isEmpty()) return emptyList()
        val total = requiredFullAttempts(ips.size, fullRounds)
        return List(total) { index -> ips[index % ips.size] }
    }

    /**
     * 已知晋级名单时的实际理论流量。
     * Pre/Micro 的共享 IP 在真实执行中均只下载一次，因此 Micro 按 unique selected IP 计算。
     */
    fun estimateTrafficMb(
        snapshot: Snapshot,
        params: ModeParams,
        microDomains: List<String>,
        finalists: List<String>
    ): Double {
        val pre = snapshot.uniqueIps.size.toLong() * params.preBytes
        val microUniqueIps = microDomains.flatMap { snapshot.domainToIps[it] ?: emptyList() }.distinct().size
        val micro = microUniqueIps.toLong() * params.microBytes
        val full = finalists.sumOf { d ->
            val count = snapshot.domainToIps[d]?.size ?: 0
            requiredFullAttempts(count, params.fullRounds).toLong() * params.fullBytes
        }
        return (pre + micro + full) / 1_000_000.0
    }

    /**
     * 开始前 finalists 尚未知，因此只能给“安全预计上限”，不能称精确值。
     * 取地址数最多的 topDomains/finalDomains 作为最坏晋级组合。
     */
    fun estimateTrafficUpperBoundMb(snapshot: Snapshot, params: ModeParams): Double {
        val pre = snapshot.uniqueIps.size.toLong() * params.preBytes
        val counts = snapshot.domainToIps.values.map { it.size }.sortedDescending()
        val micro = counts.take(params.topDomains).sumOf { it.toLong() * params.microBytes }
        val full = counts.take(params.finalDomains).sumOf { count ->
            requiredFullAttempts(count, params.fullRounds).toLong() * params.fullBytes
        }
        return (pre + micro + full) / 1_000_000.0
    }

    /** 纯函数：IPv6 真 Probe 失败后必须真正从 activeFamilies 删除。 */
    fun activeFamilies(
        requested: List<String>,
        ipv4LinkAvailable: Boolean,
        ipv6LinkAvailable: Boolean,
        ipv6InternetAvailable: Boolean
    ): List<String> {
        return requested.filter { family ->
            when (family) {
                "IPv4" -> ipv4LinkAvailable
                "IPv6" -> ipv6LinkAvailable && ipv6InternetAvailable
                else -> false
            }
        }.distinct()
    }

    /** 域名聚合 Pre 排序。 */
    private fun rankDomainsByPre(preByDomain: Map<String, List<IpProbe>>): List<String> {
        data class Agg(val domain: String, val floor: Double, val rate: Double, val ttfb: Double, val varPct: Double)
        return preByDomain.map { (d, probes) ->
            val ok = probes.count { it.ok }
            val failed = probes.size - ok
            val speeds = probes.map { if (it.ok) it.completeMbps else 0.0 }
            Agg(
                d,
                Ranker.addressFloor(speeds, failed),
                Ranker.addressSuccessRate(ok, probes.size),
                Ranker.medianTtfb(probes.map { it.ttfbMs }),
                Ranker.variation(speeds)
            )
        }.sortedWith(
            compareByDescending<Agg> { it.floor }
                .thenByDescending { it.rate }
                .thenBy { if (it.ttfb < 0) Double.MAX_VALUE else it.ttfb }
                .thenBy { it.varPct }
        ).map { it.domain }
    }

    /** 传入预先冻结的 Snapshot，函数内部绝不重新 DNS。 */
    suspend fun runFamily(
        snapshot: Snapshot,
        params: ModeParams,
        networkInvalid: () -> Boolean,
        onStage: (Stage) -> Unit,
        log: (String) -> Unit
    ): Pair<List<Ranker.DomainMetric>, Boolean> = coroutineScope {
        val family = snapshot.family
        if (snapshot.domainToIps.isEmpty()) return@coroutineScope Pair(emptyList(), false)

        var invalid = false
        fun checkNet(): Boolean {
            if (networkInvalid()) {
                invalid = true
                log("!! 网络已变化 → INVALID_NETWORK_CHANGED（本轮作废）")
                return true
            }
            return false
        }

        // [1] Pre：每个 unique IP 一次。
        // Phase 2.2.1：用 Semaphore 做滑动并发，不再 chunked 后等待整批最慢 IP。
        // 进度按“完成数”递增，避免 9/97、8/97 这种看似倒退的显示。
        val preCache = LinkedHashMap<String, IpProbe>()
        val preSemaphore = Semaphore(params.preConcurrency)
        val preCompleted = AtomicInteger(0)
        onStage(Stage("初筛 $family", 0, snapshot.uniqueIps.size))
        val preBatch = snapshot.uniqueIps.map { ip ->
            async {
                preSemaphore.withPermit {
                    if (checkNet()) return@withPermit ip to IpProbe(ip, ok = false)
                    val r = ProbeEngine.probeDownload(
                        targetIp = ip,
                        bytes = params.preBytes,
                        timeoutSec = PRE_TIMEOUT_SEC,
                        includeTrace = false
                    ) {}
                    val probe = IpProbe(
                        ip = ip, ok = r.ok, tcpMs = r.tcpMs, tlsMs = r.tlsMs,
                        ttfbMs = r.ttfbMs, payloadMbps = r.payloadMbps,
                        completeMbps = r.completeTransferMbps, colo = r.colo, loc = r.loc
                    )
                    val done = preCompleted.incrementAndGet()
                    onStage(Stage("初筛 $family", done, snapshot.uniqueIps.size))
                    ip to probe
                }
            }
        }.awaitAll()
        if (checkNet()) return@coroutineScope Pair(emptyList(), true)
        for ((ip, probe) in preBatch) preCache[ip] = probe
        log("$family 初筛完成：${preCache.values.count { it.ok }}/${snapshot.uniqueIps.size} IP 可用")

        // [2] 域名整体预筛。
        val preByDomain = LinkedHashMap<String, MutableList<IpProbe>>()
        for ((ip, probe) in preCache) {
            for (d in snapshot.ipToDomains[ip] ?: emptySet()) {
                preByDomain.getOrPut(d) { mutableListOf() }.add(probe)
            }
        }
        val rankedDomains = rankDomainsByPre(preByDomain)
        val microDomains = LinkedHashSet<String>()
        if (snapshot.domainToIps.containsKey(BASELINE_DOMAIN)) microDomains.add(BASELINE_DOMAIN)
        for (d in rankedDomains) {
            if (microDomains.size >= params.topDomains) break
            microDomains.add(d)
        }
        log("$family 入围小流量筛选：${microDomains.joinToString(", ")}${if (snapshot.domainToIps.containsKey(BASELINE_DOMAIN)) "（含基准）" else ""}")

        // [3] Micro：对晋级域名涉及的 unique IP 仅测试一次，再映射回所有域名。
        val microIps = microDomains.flatMap { snapshot.domainToIps[it] ?: emptyList() }.distinct()
        val microCache = LinkedHashMap<String, IpProbe>()
        val microSemaphore = Semaphore(params.microConcurrency)
        val microCompleted = AtomicInteger(0)
        onStage(Stage("小流量筛选 $family", 0, microIps.size))
        val microBatch = microIps.map { ip ->
            async {
                microSemaphore.withPermit {
                    if (checkNet()) return@withPermit ip to IpProbe(ip, ok = false)
                    val r = ProbeEngine.probeDownload(
                        targetIp = ip,
                        bytes = params.microBytes,
                        timeoutSec = MICRO_TIMEOUT_SEC,
                        includeTrace = false
                    ) {}
                    val probe = IpProbe(
                        ip = ip, ok = r.ok, tcpMs = r.tcpMs, tlsMs = r.tlsMs,
                        ttfbMs = r.ttfbMs, payloadMbps = r.payloadMbps,
                        completeMbps = r.completeTransferMbps, colo = r.colo, loc = r.loc
                    )
                    val done = microCompleted.incrementAndGet()
                    onStage(Stage("小流量筛选 $family", done, microIps.size))
                    ip to probe
                }
            }
        }.awaitAll()
        if (checkNet()) return@coroutineScope Pair(emptyList(), true)
        for ((ip, probe) in microBatch) microCache[ip] = probe
        log("$family 小流量筛选完成：去重 IP ${microCache.size} 个（共享 IP 自动复用）")

        // [4] Micro Floor 只决定 finalists；Baseline 强制进 Full。
        data class MicroAgg(val domain: String, val floor: Double, val rate: Double, val ttfb: Double)
        val microAggs = microDomains.map { d ->
            val ips = snapshot.domainToIps[d] ?: emptyList()
            val probes = ips.map { microCache[it] ?: IpProbe(it, ok = false) }
            val ok = probes.count { it.ok }
            val failed = probes.size - ok
            MicroAgg(
                d,
                Ranker.addressFloor(probes.map { if (it.ok) it.completeMbps else 0.0 }, failed),
                Ranker.addressSuccessRate(ok, probes.size),
                Ranker.medianTtfb(probes.map { it.ttfbMs })
            )
        }.sortedWith(
            compareByDescending<MicroAgg> { it.floor }
                .thenByDescending { it.rate }
                .thenBy { if (it.ttfb < 0) Double.MAX_VALUE else it.ttfb }
        )

        val finalists = LinkedHashSet<String>()
        if (snapshot.domainToIps.containsKey(BASELINE_DOMAIN)) finalists.add(BASELINE_DOMAIN)
        for (m in microAggs) {
            if (finalists.size >= params.finalDomains) break
            finalists.add(m.domain)
        }
        val finalistList = finalists.toList()
        log("$family 决赛名单：${finalistList.joinToString(", ")}${if (snapshot.domainToIps.containsKey(BASELINE_DOMAIN)) "（含基准）" else ""}")
        log("$family 当前晋级组合理论流量 ≈ ${"%.1f".format(estimateTrafficMb(snapshot, params, microDomains.toList(), finalistList))} MB")

        // [5] Full：每个 finalist Snapshot IP 至少 1 次；额外轮次再轮转。
        val fullSchedules = finalistList.associateWith { d -> fullSchedule(snapshot.domainToIps[d] ?: emptyList(), params.fullRounds) }
        val fullTotal = fullSchedules.values.sumOf { it.size }
        var fullDone = 0
        val results = ArrayList<DomainResult>()

        for (d in finalistList) {
            if (checkNet()) return@coroutineScope Pair(emptyList(), true)
            val ips = snapshot.domainToIps[d] ?: emptyList()
            val schedule = fullSchedules[d] ?: emptyList()
            val fullByIp = LinkedHashMap<String, MutableList<IpProbe>>()
            for (ip in ips) fullByIp[ip] = mutableListOf()

            for ((roundIndex, ip) in schedule.withIndex()) {
                if (checkNet()) return@coroutineScope Pair(emptyList(), true)
                onStage(Stage("完整测速 $family $d", fullDone + 1, fullTotal))
                val r = ProbeEngine.probeDownload(ip, params.fullBytes, FULL_TIMEOUT_SEC, includeTrace = true) {}
                val probe = IpProbe(
                    ip = ip, ok = r.ok, tcpMs = r.tcpMs, tlsMs = r.tlsMs,
                    ttfbMs = r.ttfbMs, payloadMbps = r.payloadMbps,
                    completeMbps = r.completeTransferMbps, colo = r.colo, loc = r.loc
                )
                fullByIp.getOrPut(ip) { mutableListOf() }.add(probe)
                if (!r.ok) log("$d 完整测速 第 ${roundIndex + 1}/${schedule.size} 轮 失败（$ip）：${r.error}")
                fullDone++
                // 降温间隔：大流量连续下载是发热主源，轮间短停让 CPU/基带散热
                delay(300)
            }
            // 域间降温：让下一个域名开始前设备短暂散热
            delay(400)

            val microForDomain = ips.associateWith { ip -> microCache[ip] ?: IpProbe(ip, ok = false) }
            results.add(
                DomainResult(
                    domain = d,
                    family = family,
                    addresses = ips,
                    microProbes = microForDomain,
                    fullProbesByIp = fullByIp.mapValues { it.value.toList() }
                )
            )
        }

        onStage(Stage("排名 $family"))
        Pair(Ranker.rank(results.map { it.toMetric() }), invalid)
    }

    /** 本机 Cloudflare 基准（正常 DNS 解析后，指定协议族）。 */
    suspend fun baseline(family: String, bytes: Long, log: (String) -> Unit): Double {
        val wantV6 = family == "IPv6"
        val addr = try {
            InetAddress.getAllByName(ProbeEngine.SPEED_HOST).firstOrNull { wantV6 == (it is Inet6Address) }
        } catch (_: Exception) { null } ?: return 0.0
        val ip = addr.hostAddress ?: return 0.0
        val r = ProbeEngine.probeDownload(ip, bytes, FULL_TIMEOUT_SEC, includeTrace = false) {}
        if (!r.ok) log("$family 基准失败：${r.error}")
        return if (r.ok) r.completeTransferMbps else 0.0
    }

    suspend fun ipv6InternetAvailable(bytes: Long = 256_000L, log: (String) -> Unit): Boolean {
        val addr = try {
            InetAddress.getAllByName(ProbeEngine.SPEED_HOST).firstOrNull { it is Inet6Address }
        } catch (_: Exception) { null } ?: return false
        val ip = addr.hostAddress ?: return false
        val r = ProbeEngine.probeDownload(ip, bytes, 12, includeTrace = false) {}
        log("IPv6 Internet Probe：${if (r.ok) "可用（${"%.1f".format(r.completeTransferMbps)} Mbps）" else "不可用（${r.error}）"}")
        return r.ok
    }
}
