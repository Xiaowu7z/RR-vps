import com.cfoptimizer.HistoryStore
import com.cfoptimizer.HistoryStore.HistoryEntry
import com.cfoptimizer.HistoryStore.ResultLine

/**
 * Phase 2.4 HistoryStore 序列化单测（纯 JVM，不依赖 Android）。
 */
object HistoryTest {
    private var pass = 0
    private var fail = 0

    private fun check(name: String, cond: Boolean, detail: String = "") {
        if (cond) { pass++; println("PASS  $name") }
        else { fail++; println("FAIL  $name  $detail") }
    }

    @JvmStatic
    fun main(args: Array<String>) {
        // T1: 往返一致（含中文/特殊字符）
        val e = HistoryEntry(
            id = 1755000000000L, ts = 1755000000000L,
            modeLabel = "均衡模式", families = "IPv4+IPv6",
            networkLabel = "Wi-Fi", vpn = true, invalid = false,
            champ = "www.openai.com", champMbps = "168.9",
            verdict = "建议替换当前基准 → www.openai.com",
            results = listOf(
                ResultLine(1, "www.openai.com", "168.9", "156.0", "100%", "", pops = "172.64.154.211 HKG"),
                ResultLine(2, "www.npmjs.com \"quoted\" \\ slash", "15.6", "15.3", "100%", "", pops = "")
            )
        )
        val json = HistoryStore.serialize(listOf(e, e))
        val back = HistoryStore.deserialize(json)
        check("T1 两条往返", back.size == 2, "got ${back.size}")
        check("T2 字段一致", back[0].champ == "www.openai.com" && back[0].champMbps == "168.9")
        check("T3 中文 verdict", back[0].verdict == "建议替换当前基准 → www.openai.com")
        check("T4 引号/反斜杠转义往返", back[0].results[1].domain == "www.npmjs.com \"quoted\" \\ slash",
            "got: ${back[0].results[1].domain}")
        check("T5 vpn/invalid 布尔", back[0].vpn && !back[0].invalid)
        check("T6 结果行字段", back[0].results[0].pops == "172.64.154.211 HKG")

        // T7: 空列表
        check("T7 空列表", HistoryStore.deserialize("[]").isEmpty())

        // T8: 损坏 JSON 不崩
        check("T8 损坏不崩", HistoryStore.deserialize("{bad json").isEmpty() ||
            HistoryStore.deserialize("not json at all").isEmpty())

        println()
        println("HistoryTest：PASS $pass / FAIL $fail")
        if (fail > 0) kotlin.system.exitProcess(1)
    }
}
