package com.cfoptimizer.engine

import okhttp3.ConnectionPool
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.util.concurrent.TimeUnit

/**
 * Phase 1.2 核心探测引擎。
 *
 * 硬性约束：
 * 1. 指定 IP + SNI：URL 恒为 https://speed.cloudflare.com/...；FixedDns 对该 hostname 返回指定 IP。
 * 2. 冷连接：每次 probe 新建 OkHttpClient + 空连接池。
 * 3. HTTP/1.1 强制。
 * 4. 分族：输入必须是 IP literal；remote 家族与 targetIp 等价判断全部基于 connectStart 捕获的
 *    真实 InetSocketAddress（InetAddress 字节比较），禁止字符串比较、禁止按 targetIp 推断。
 * 5. 完整下载 ≥ 目标字节 80% 才成功。
 * 6. 取消：所有网络阶段（下载 + POP trace）的 Call 都绑定协程取消——停止按钮立即中断。
 * 7. 三口径吞吐：PayloadMbps（纯 body）/ CompleteTransferMbps（connectStart→bodyEnd）/
 *    CallTotalMbps（callStart→bodyEnd，含 DNS）。与 PS v3.0 的对照口径由真机 A/B 后确定，不预先声称一致。
 */
object ProbeEngine {

    const val SPEED_HOST = "speed.cloudflare.com"

    data class ProbeResult(
        val ok: Boolean,
        val error: String = "",
        val family: String = "",              // 从真实 socket 远端地址判断（非 targetIp 推断）
        val targetIp: String = "",
        val actualRemoteAddress: String = "",  // connectStart 捕获的真实 TCP 远端字符串
        val targetMatchesRemote: Boolean = false, // 字节级等价判断（InetAddress 比较，非字符串）
        val remoteIsIpv6: Boolean = false,     // 真实 socket 远端是否为 AF_INET6
        val sni: String = SPEED_HOST,
        val certHostname: String = "",
        val certVerified: Boolean = false,
        val httpCode: Int = 0,
        val httpVersion: String = "",
        val dnsMs: Double = -1.0,
        val tcpMs: Double = -1.0,
        val tlsMs: Double = -1.0,
        val ttfbMs: Double = -1.0,
        val bodyMs: Double = -1.0,
        val totalMs: Double = -1.0,
        val callTotalMs: Double = -1.0,
        val bytesDownloaded: Long = 0L,
        val bytesTarget: Long = 0L,
        val payloadMbps: Double = 0.0,          // 纯 Body 吞吐
        val completeTransferMbps: Double = 0.0, // 完整传输（connectStart→bodyEnd）
        val callTotalMbps: Double = 0.0,        // Call 总吞吐（callStart→bodyEnd，含 DNS）
        val colo: String = "",
        val loc: String = "",
        val events: String = ""
    )

    /** IP literal 校验：必须是 IPv4 或 IPv6 字面量，禁止 hostname。 */
    fun isIpLiteral(input: String): Boolean {
        if (input.isEmpty()) return false
        // IPv4：四段十进制，每段 0-255
        val v4 = Regex("""^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$""").matchEntire(input)
        if (v4 != null) {
            return v4.groupValues.drop(1).all { it.toIntOrNull() in 0..255 }
        }
        // IPv6：含 ':'（hostname 不可能含 ':'）+ 仅 hex/冒号/点字符 + 可解析为 Inet6Address
        if (input.contains(':')) {
            if (!input.all { it in "0123456789abcdefABCDEF:." }) return false
            return try {
                InetAddress.getByName(input) is Inet6Address
            } catch (e: Exception) {
                false
            }
        }
        return false
    }

    /** 返回 IP literal 的协议族；非法输入返回 null。 */
    fun familyOf(input: String): String? {
        if (!isIpLiteral(input)) return null
        return when (InetAddress.getByName(input)) {
            is Inet4Address -> "IPv4"
            is Inet6Address -> "IPv6"
            else -> null
        }
    }

    /** InetAddress 字节级等价判断（禁止字符串比较 IPv6）。 */
    fun addressesEqual(a: InetAddress?, b: InetAddress?): Boolean {
        if (a == null || b == null) return false
        return java.util.Arrays.equals(a.address, b.address)
    }

    /**
     * 单次冷连接下载探测（suspend：取消时中断 Call + trace Call）。
     */
    suspend fun probeDownload(
        targetIp: String,
        bytes: Long,
        timeoutSec: Int,
        includeTrace: Boolean = true,
        log: (String) -> Unit
    ): ProbeResult {
        val events = StringBuilder()
        var timing: ProbeTimingListener.Timings? = null

        val client = newColdClient(targetIp, timeoutSec, events, { timing = it })
        val url = "https://$SPEED_HOST/__down?bytes=$bytes"
        val req = Request.Builder().url(url).get().build()
        val call = client.newCall(req)

        // 取消绑定：所有活跃 Call 统一在此取消
        val activeCalls = mutableListOf(call)

        var result: ProbeResult? = null
        kotlinx.coroutines.suspendCancellableCoroutine<Unit> { cont ->
            cont.invokeOnCancellation {
                activeCalls.forEach { it.cancel() }
                log(">>> 取消触发：${activeCalls.size} 个 Call 已 cancel()")
            }
            try {
                call.execute().use { resp ->
                    val bodyBytes = readBodyCounting(resp)
                    val t = timing ?: ProbeTimingListener.Timings()
                    // Phase 2.2.1：Pre/Micro/Baseline 不需要 POP。
                    // 只有最终 Full/显式 Debug 才做 trace，避免每个候选 IP 额外再建一次冷 TLS 连接。
                    val enoughBody = bytes <= 0L || bodyBytes >= (bytes * 0.8).toLong()
                    val (colo, loc) = if (includeTrace && resp.isSuccessful && enoughBody) {
                        try {
                            val traceCall = newTraceCall(targetIp, timeoutSec, events)
                            activeCalls.add(traceCall)
                            executeTrace(traceCall, events)
                        } catch (e: Exception) {
                            events.append("trace fail: ${e.javaClass.simpleName}\n")
                            Pair("", "")
                        }
                    } else {
                        Pair("", "")
                    }
                    result = buildResult(targetIp, t, resp, bodyBytes, bytes, colo, loc, events.toString())
                }
                cont.resumeWith(Result.success(Unit))
            } catch (e: java.io.IOException) {
                result = ProbeResult(
                    ok = false,
                    error = if (cont.isCancelled) "已取消" else "${e.javaClass.simpleName}: ${e.message?.take(100)}",
                    targetIp = targetIp,
                    events = events.toString()
                )
                cont.resumeWith(Result.success(Unit))
            } catch (e: Exception) {
                result = ProbeResult(
                    ok = false,
                    error = "${e.javaClass.simpleName}: ${e.message?.take(100)}",
                    targetIp = targetIp,
                    events = events.toString()
                )
                cont.resumeWith(Result.success(Unit))
            }
        }
        return result ?: ProbeResult(ok = false, error = "no result", targetIp = targetIp)
    }

    /** POP 查询（cdn-cgi/trace）——suspend + 可取消。 */
    suspend fun probeTrace(targetIp: String, timeoutSec: Int, log: (String) -> Unit): Pair<String, String> {
        val events = StringBuilder()
        val call = newTraceCall(targetIp, timeoutSec, events)
        return kotlinx.coroutines.suspendCancellableCoroutine { cont ->
            cont.invokeOnCancellation {
                call.cancel()
                log(">>> trace Call.cancel() 已触发")
            }
            try {
                cont.resumeWith(Result.success(executeTrace(call, events)))
            } catch (e: Exception) {
                log("trace fail: ${e.javaClass.simpleName}: ${e.message?.take(80)}")
                cont.resumeWith(Result.success(Pair("", "")))
            }
        }
    }

    // ---------- 内部 ----------

    /** 构造 trace call（不执行，不注册）。 */
    private fun newTraceCall(
        targetIp: String,
        timeoutSec: Int,
        events: StringBuilder
    ): okhttp3.Call {
        val client = newColdClient(targetIp, timeoutSec, events, {})
        val req = Request.Builder().url("https://$SPEED_HOST/cdn-cgi/trace").get().build()
        return client.newCall(req)
    }

    /** 执行 trace call 并解析 colo/loc。 */
    private fun executeTrace(call: okhttp3.Call, events: StringBuilder): Pair<String, String> {
        return try {
            call.execute().use { resp ->
                val text = resp.body?.string() ?: ""
                var colo = ""; var loc = ""
                text.lineSequence().forEach { line ->
                    when {
                        line.startsWith("colo=") -> colo = line.removePrefix("colo=").trim()
                        line.startsWith("loc=") -> loc = line.removePrefix("loc=").trim()
                    }
                }
                Pair(colo, loc)
            }
        } catch (e: Exception) {
            events.append("trace fail: ${e.javaClass.simpleName}\n")
            Pair("", "")
        }
    }

    private fun newColdClient(
        targetIp: String,
        timeoutSec: Int,
        events: StringBuilder,
        onTimings: (ProbeTimingListener.Timings) -> Unit
    ): OkHttpClient {
        val listener = ProbeTimingListener(
            onEvent = { events.append(it).append("\n") },
            onTimings = onTimings
        )
        return OkHttpClient.Builder()
            .dns(FixedDns.forCloudflare(targetIp))
            .protocols(listOf(Protocol.HTTP_1_1))
            .connectionPool(ConnectionPool(0, 1, TimeUnit.NANOSECONDS))
            .connectTimeout(timeoutSec.toLong(), TimeUnit.SECONDS)
            .readTimeout(timeoutSec.toLong(), TimeUnit.SECONDS)
            .callTimeout((timeoutSec + 10).toLong(), TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
            .eventListener(listener)
            .build()
    }

    private fun readBodyCounting(resp: Response): Long {
        val body = resp.body ?: return 0L
        var count = 0L
        val buf = ByteArray(256 * 1024)
        body.byteStream().use { ins ->
            while (true) {
                val n = ins.read(buf)
                if (n < 0) break
                count += n
            }
        }
        return count
    }

    private fun peerCn(resp: Response): String {
        return try {
            val cert = resp.handshake?.peerCertificates?.firstOrNull()
                as? java.security.cert.X509Certificate
            cert?.subjectX500Principal?.name ?: ""
        } catch (e: Exception) { "" }
    }

    private fun buildResult(
        targetIp: String,
        t: ProbeTimingListener.Timings,
        resp: Response,
        bytesDownloaded: Long,
        bytesTarget: Long,
        colo: String,
        loc: String,
        events: String
    ): ProbeResult {
        // 真实 socket 数据（connectStart 捕获的 InetAddress）
        val actualAddr = t.actualRemoteAddr
        val remoteIsV6 = actualAddr is Inet6Address
        val family = if (actualAddr != null) {
            if (remoteIsV6) "IPv6" else "IPv4"
        } else "未知"

        // 字节级等价判断（禁止字符串比较，IPv6 压缩形式不同也能正确判定）
        val targetAddr = try { InetAddress.getByName(targetIp) } catch (e: Exception) { null }
        val targetMatches = addressesEqual(targetAddr, actualAddr)

        // 80% 完整性规则
        val complete = bytesTarget <= 0L || bytesDownloaded >= (bytesTarget * 0.80).toLong()
        val ok = resp.code in 200..399 && resp.handshake != null && complete

        // 三口径吞吐
        fun mbps(ms: Double): Double =
            if (ok && ms > 0.0) (bytesDownloaded * 8 / 1_000_000.0) / (ms / 1000.0) else 0.0

        return ProbeResult(
            ok = ok,
            error = when {
                resp.code !in 200..399 -> "HTTP ${resp.code}"
                !complete -> "下载不完整：$bytesDownloaded / $bytesTarget（<80%）"
                resp.handshake == null -> "TLS 握手失败"
                else -> ""
            },
            family = family,
            targetIp = targetIp,
            actualRemoteAddress = t.actualRemoteAddress,
            targetMatchesRemote = targetMatches,
            remoteIsIpv6 = remoteIsV6,
            sni = SPEED_HOST,
            certHostname = peerCn(resp),
            certVerified = resp.handshake != null,
            httpCode = resp.code,
            httpVersion = resp.protocol.toString(),
            dnsMs = t.dnsMs(),
            tcpMs = t.tcpMs(),
            tlsMs = t.tlsMs(),
            ttfbMs = t.ttfbMs(),
            bodyMs = t.bodyMs(),
            totalMs = t.totalMs(),
            callTotalMs = t.callTotalMs(),
            bytesDownloaded = bytesDownloaded,
            bytesTarget = bytesTarget,
            payloadMbps = mbps(t.bodyMs()),
            completeTransferMbps = mbps(t.totalMs()),
            callTotalMbps = mbps(t.callTotalMs()),
            colo = colo,
            loc = loc,
            events = events
        )
    }
}
