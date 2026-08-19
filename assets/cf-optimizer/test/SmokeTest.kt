import com.cfoptimizer.engine.ProbeEngine
import kotlinx.coroutines.*

/**
 * JVM 冒烟测试（Phase 1.2）。
 * 验证：IP literal 校验、字节级远端等价、真实 socket 家族、三口径 Mbps、取消绑定（含 trace）。
 * 注：1034（Edge IP Restricted）记录为"不同网络环境下 Edge validation 行为可能不同"，
 * 待 Android 中国移动真机数据验证。
 */
fun main() = runBlocking {
    val v4 = java.net.InetAddress.getAllByName(ProbeEngine.SPEED_HOST)
        .firstOrNull { it is java.net.Inet4Address }?.hostAddress ?: "162.159.140.220"

    println("测试目标 v4=$v4")

    run {
        println("\n=== 用例1：IP literal / 族校验 ===")
        println("'162.159.140.220' literal=${ProbeEngine.isIpLiteral("162.159.140.220")} family=${ProbeEngine.familyOf("162.159.140.220")}")
        println("'2606:4700::1' literal=${ProbeEngine.isIpLiteral("2606:4700::1")} family=${ProbeEngine.familyOf("2606:4700::1")}")
        println("'speed.cloudflare.com' literal=${ProbeEngine.isIpLiteral("speed.cloudflare.com")}（应 false）")
    }

    run {
        println("\n=== 用例2：字节级等价（IPv6 压缩形式等价判定） ===")
        val a = java.net.InetAddress.getByName("2606:4700::1")
        val b = java.net.InetAddress.getByName("2606:4700:0:0:0:0:0:1")
        val c = java.net.InetAddress.getByName("2606:4700::2")
        println("'2606:4700::1' vs '2606:4700:0:0:0:0:0:1' equal=${ProbeEngine.addressesEqual(a, b)}（应 true）")
        println("'2606:4700::1' vs '2606:4700::2' equal=${ProbeEngine.addressesEqual(a, c)}（应 false）")
        val rawA = "2606:4700::1"; val rawB = "2606:4700:0:0:0:0:0:1"
        println("字符串比较对照（原始输入）: '$rawA' == '$rawB' -> ${rawA == rawB}（应 false——压缩形式不同，证明字节比较才可靠）")
    }

    run {
        println("\n=== 用例3：IPv4 全链路（真实 socket 家族 + 三口径） ===")
        val r = ProbeEngine.probeDownload(v4, 2_000_000L, 30) {}
        println("ok=${r.ok} http=${r.httpCode} ${r.httpVersion}")
        println("family=${r.family}（应 IPv4，来自真实 socket） remoteIsIpv6=${r.remoteIsIpv6}")
        println("targetIp=${r.targetIp} actualRemote=${r.actualRemoteAddress} byteMatch=${r.targetMatchesRemote}")
        println("dns=${r.dnsMs} tcp=${r.tcpMs} tls=${r.tlsMs} ttfb=${r.ttfbMs}")
        println("body=${r.bodyMs} total=${r.totalMs} callTotal=${r.callTotalMs}")
        println("bytes=${r.bytesDownloaded}/${r.bytesTarget}")
        println("Payload=${"%.2f".format(r.payloadMbps)} Complete=${"%.2f".format(r.completeTransferMbps)} CallTotal=${"%.2f".format(r.callTotalMbps)}")
        println("POP=${r.colo} ${r.loc}")
        println("error=${r.error}")
    }

    run {
        println("\n=== 用例4：取消绑定（10MB 下载 200ms 后取消） ===")
        val t0 = System.currentTimeMillis()
        val job = launch {
            val r = ProbeEngine.probeDownload(v4, 10_000_000L, 60) {}
            println("取消后结果: ok=${r.ok} error=${r.error} bytes=${r.bytesDownloaded}")
        }
        delay(200)
        job.cancel()
        job.join()
        println("取消耗时 ${System.currentTimeMillis() - t0}ms（若下载先完成 ok=true 亦合规）")
    }

    run {
        println("\n=== 用例5：trace 取消绑定（trace 启动后立即取消） ===")
        val job = launch {
            val (colo, loc) = ProbeEngine.probeTrace(v4, 60) { println("  [ev] $it") }
            println("trace 结果: colo=$colo loc=$loc")
        }
        delay(50)
        job.cancel()
        job.join()
        println("trace 取消完成（无挂起无异常）")
    }

    run {
        println("\n=== 用例6：80% 完整性负例 ===")
        val r = ProbeEngine.probeDownload(v4, 1_000_000_000L, 8) {}
        println("ok=${r.ok}（应 false）error=${r.error} bytes=${r.bytesDownloaded}")
    }
}
