import com.cfoptimizer.engine.Pipeline
import com.cfoptimizer.engine.ProbeEngine
import kotlinx.coroutines.*
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 2.6.0 停止测速专项（JVM）。
 * 验证：probeDownload 取消中断、runFamily 取消传播、buildSnapshot 取消检查。
 * 真实网络（speed.cloudflare.com / 少量域名 DNS）。
 */
fun main() = runBlocking {
    var pass = 0
    var fail = 0

    // [1] probeDownload 取消中断：cancel 必须触发 invokeOnCancellation → Call.cancel()
    run {
        println("\n=== 用例1：probeDownload 取消中断 ===")
        try {
            val started = AtomicBoolean(false)
            val cancelLogs = java.util.concurrent.CopyOnWriteArrayList<String>()
            val t0 = System.currentTimeMillis()
            val job = launch(Dispatchers.IO) {
                started.set(true)
                ProbeEngine.probeDownload("104.26.0.1", 32_000_000L, 30, includeTrace = false) { cancelLogs.add(it) }
            }
            while (!started.get()) delay(5)
            delay(100)  // 32MB 下载必然在途（DNS+TLS 已 >100ms）
            job.cancelAndJoin()
            val dt = System.currentTimeMillis() - t0
            val cancelFired = cancelLogs.any { it.contains("取消触发") }
            val ok = cancelFired && dt < 6000
            println("Call.cancel 触发=$cancelFired 取消耗时=${dt}ms → ${if (ok) "PASS" else "FAIL"}")
            if (ok) pass++ else fail++
        } catch (e: Throwable) {
            println("异常: ${e.javaClass.simpleName}: ${e.message} → FAIL")
            fail++
        }
    }

    // [2] runFamily 取消：await 必须重抛 CancellationException 且快速退出
    run {
        println("\n=== 用例2：runFamily 取消传播 ===")
        try {
            val snap = Pipeline.buildSnapshot(listOf("www.nexusmods.com", "cloudflare.com"), "IPv4") {}
            val t0 = System.currentTimeMillis()
            var cancelled = false
            val deferred = async(Dispatchers.Default) {
                Pipeline.runFamily(
                    snapshot = snap,
                    params = Pipeline.BALANCED,
                    networkInvalid = { false },
                    onStage = {},
                    log = {}
                )
            }
            delay(400)
            deferred.cancel()
            try {
                deferred.await()
            } catch (e: CancellationException) {
                cancelled = true
            }
            val dt = System.currentTimeMillis() - t0
            val ok = cancelled && dt < 10000
            println("CancellationException=$cancelled 退出耗时=${dt}ms → ${if (ok) "PASS" else "FAIL"}")
            if (ok) pass++ else fail++
        } catch (e: Throwable) {
            println("异常: ${e.javaClass.simpleName}: ${e.message} → FAIL")
            fail++
        }
    }

    // [3] buildSnapshot 取消：长域名循环中 cancel，await 必须重抛并快速退出
    run {
        println("\n=== 用例3：buildSnapshot 取消检查 ===")
        try {
            val domains = (1..60).map { "d$it.cloudflare.com" }
            val t0 = System.currentTimeMillis()
            var cancelled = false
            val deferred = async(Dispatchers.IO) {
                Pipeline.buildSnapshot(domains, "IPv4") {}
            }
            delay(150)
            deferred.cancel()
            try {
                deferred.await()
            } catch (e: CancellationException) {
                cancelled = true
            }
            val dt = System.currentTimeMillis() - t0
            val ok = cancelled && dt < 5000
            println("CancellationException=$cancelled 退出耗时=${dt}ms → ${if (ok) "PASS" else "FAIL"}")
            if (ok) pass++ else fail++
        } catch (e: Throwable) {
            println("异常: ${e.javaClass.simpleName}: ${e.message} → FAIL")
            fail++
        }
    }

    // [4] 取消后 scope 可复用（SupervisorJob + 顶层 scope 存活）
    run {
        println("\n=== 用例4：取消后 scope 可复用 ===")
        try {
            val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
            val j1 = scope.launch { delay(300) }
            j1.cancelAndJoin()
            var ran = false
            val j2 = scope.launch { ran = true }
            j2.join()
            println("第二轮正常执行=$ran → ${if (ran) "PASS" else "FAIL"}")
            if (ran) pass++ else fail++
            scope.cancel()
        } catch (e: Throwable) {
            println("异常: ${e.javaClass.simpleName}: ${e.message} → FAIL")
            fail++
        }
    }

    println("\n===== StopTest: PASS $pass / FAIL $fail =====")
    if (fail > 0) kotlin.system.exitProcess(1)
}
