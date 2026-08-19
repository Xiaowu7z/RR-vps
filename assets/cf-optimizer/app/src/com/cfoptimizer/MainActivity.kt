package com.cfoptimizer

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.app.Dialog
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.view.animation.LinearInterpolator
import android.view.animation.DecelerateInterpolator
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.*
import com.cfoptimizer.engine.CfRanges
import com.cfoptimizer.engine.Pipeline
import com.cfoptimizer.engine.Ranker
import kotlinx.coroutines.*
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * RR优选 Phase 3 UI（2.3.1 中文化 + 美化）。
 *
 * 2.3.1 UI 改动（纯外观/文案，算法与流程零改动）：
 * - 白底深字 + 蓝色主色（#0A66C2），卡片化圆角布局（代码 GradientDrawable，CLI 工具链无 drawable 资源）。
 * - 结果页全部数据行中文标签：平均/最低/地址下限/成功率/波动/中位 TTFB/节点 POP/稳定性/最佳IP/最差IP。
 * - 测速页进度条加粗 14dp + 百分比文字，当前任务行大字号突出，日志区内边距/行距加大。
 *
 * 卡机修复（2.3.0 保留）：
 * - 日志不再逐行刷主线程：后台 ConcurrentLinkedQueue 收集，UI 200ms 批量 flush，限 150 行。
 * - 进度独立小视图，只显示阶段 + 单调递增计数。
 * - 结果页一次性构建卡片，不做高频全文本重绘。
 */
class MainActivity : Activity() {

    // ---- 主题色 ----
    // DMIT 美术风格（深色面板科技风）：深蓝黑底 + #0088FF 品牌蓝 + 亮绿状态
    private val C_BG = Color.parseColor("#0D1320")       // 页面背景（深蓝黑）
    private val C_CARD = Color.parseColor("#16203A")     // 卡片背景（深蓝）
    private val C_CARD_TOP = Color.parseColor("#1B2B52") // 前三名卡片高亮蓝
    private val C_STROKE = Color.parseColor("#26355C")   // 卡片描边
    private val C_TEXT = Color.parseColor("#F5F8FF")     // 主文字（白）
    private val C_SUB = Color.parseColor("#A9B7D6")      // 数据行文字（浅蓝灰）
    private val C_MUTED = Color.parseColor("#5D6B8C")    // 弱化文字
    private val C_ACCENT = Color.parseColor("#0088FF")   // DMIT 品牌蓝
    private val C_GREEN = Color.parseColor("#1FCB7A")    // 正向强调（亮绿）
    private val C_RED = Color.parseColor("#C0392B")      // 停止/警示
    private val C_BTN_OFF = Color.parseColor("#1E2A47")  // 分段按钮未选中（深色）

    private lateinit var homeView: View
    private lateinit var runView: View
    private lateinit var resultView: View

    private lateinit var statusText: TextView
    private lateinit var protoLabel: TextView
    private lateinit var stageText: TextView
    private lateinit var progressBar: ProgressBar
    private lateinit var percentLabel: TextView
    private lateinit var logView: TextView
    private lateinit var resultContainer: LinearLayout

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var job: Job? = null
    private var currentPage = "home"  // 2.6.0：手势/返回键定位当前页面
    private var unregisterNetWatch: (() -> Unit)? = null

    private var protocolMode = "Dual"      // IPv4 / IPv6 / Dual
    private var profileMode = "均衡"        // 均衡 / 亚洲入口狩猎
    private var lineLabelMode = "自动"       // 自动 / 中国移动 / 中国电信 / 中国联通
    private var builtinDomains: List<String> = emptyList()

    // ---- 日志节流 ----
    private val logQueue = ConcurrentLinkedQueue<String>()
    private val logLines = ArrayDeque<String>()
    private var flushScheduled = false
    private val flushHandler = android.os.Handler(android.os.Looper.getMainLooper())

    @SuppressLint("SetTextI18n")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // DMIT 深色主题：状态栏与页面同色，浅色图标
        window.statusBarColor = Color.parseColor("#0D1320")
        window.navigationBarColor = Color.parseColor("#0D1320")
        builtinDomains = loadDomains()
        buildHome()
        buildRun()
        buildResult()
        switchTo(homeView, "home")
        refreshStatus()
    }

    // ================= 工具 =================
    private fun dp(v: Int): Int = (v * resources.displayMetrics.density + 0.5f).toInt()

    private fun rounded(color: Int, radiusDp: Int, stroke: Int? = null, strokeDp: Int = 1): GradientDrawable =
        GradientDrawable().apply {
            cornerRadius = dp(radiusDp).toFloat()
            setColor(color)
            if (stroke != null) setStroke(dp(strokeDp), stroke)
        }

    /** 白色圆角卡片容器（背景色 + 圆角 + 轻微阴影感）。 */
    private fun cardContainer(content: LinearLayout.() -> Unit): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(16))
            background = rounded(C_CARD, 14, C_STROKE)
            elevation = dp(2).toFloat()
            content()
        }

    private fun dataLine(text: String, size: Float, color: Int, bold: Boolean = false): TextView =
        TextView(this).apply {
            this.text = text
            textSize = size
            setTextColor(color)
            if (bold) setTypeface(null, Typeface.BOLD)
            setPadding(0, dp(3), 0, 0)
        }

    private fun modeCn(mode: String): String = when (mode) {
        "Quick" -> "快速"
        "Deep" -> "深度"
        else -> "标准"
    }

    // ================= 首页 =================
    @SuppressLint("SetTextI18n")
    private fun buildHome() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(28), dp(48), dp(28), dp(28))
            setBackgroundColor(C_BG)
        }

        root.addView(TextView(this).apply {
            text = "CF 域名优选"
            textSize = 30f
            setTypeface(null, Typeface.BOLD)
            setTextColor(C_TEXT)
            gravity = Gravity.CENTER_HORIZONTAL
        })
        root.addView(TextView(this).apply {
            text = "Cloudflare 域名入口优选"
            textSize = 14f
            gravity = Gravity.CENTER_HORIZONTAL
            setTextColor(C_MUTED)
        })

        statusText = TextView(this).apply {
            textSize = 13f
            gravity = Gravity.CENTER_HORIZONTAL
            setTextColor(C_SUB)
            setPadding(0, dp(18), 0, dp(18))
        }
        root.addView(statusText)

        root.addView(cardContainer {
            addView(sectionLabel("协议"))
            protoLabel = TextView(this@MainActivity).apply {
                textSize = 13f
                setTextColor(C_SUB)
            }
            addView(protoLabel)
            addView(buildSegmented(
                listOf("IPv4", "IPv6", "双栈"),
                initial = "双栈"
            ) { sel ->
                protocolMode = sel; refreshStatus()
            })

            addView(sectionLabel("测速模式"))
            addView(buildSegmented(
                listOf("均衡", "亚洲入口狩猎"),
                labels = listOf("均衡", "亚洲入口狩猎"),
                initial = "均衡"
            ) { sel ->
                profileMode = sel; refreshStatus()
            })
            addView(dataLine("亚洲入口狩猎：先发现 POP，优先 HKG > NRT > SIN > ICN > TPE", 11.5f, C_MUTED))

            addView(sectionLabel("线路标签"))
            addView(buildSegmented(
                listOf("自动", "中国移动", "中国电信", "中国联通"),
                labels = listOf("自动", "移动", "电信", "联通"),
                initial = "自动"
            ) { sel ->
                lineLabelMode = sel; refreshStatus()
            })
            addView(dataLine("Wi-Fi 无法可靠自动识别宽带运营商，测试电信/移动宽带时建议手动选择。", 11.5f, C_MUTED))

        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(18)
        })

        root.addView(Button(this).apply {
            text = "开始测速"
            textSize = 16f
            setTypeface(null, Typeface.BOLD)
            setAllCaps(false)
            setTextColor(Color.WHITE)
            background = rounded(C_ACCENT, 12)
            setPadding(dp(16), dp(14), dp(16), dp(14))
            setOnClickListener { preflightAndStart() }
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(24)
        })

        root.addView(TextView(this).apply {
            text = "域名池：${builtinDomains.size} 个 · 基准域名：${Pipeline.BASELINE_DOMAIN}"
            textSize = 12f
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(0, dp(14), 0, 0)
            setTextColor(C_MUTED)
        })

        root.addView(Button(this).apply {
            text = "历史测试"
            textSize = 15f
            setAllCaps(false)
            setTextColor(C_ACCENT)
            background = rounded(C_CARD, 12, C_STROKE)
            setPadding(dp(16), dp(12), dp(16), dp(12))
            setOnClickListener { showHistoryList() }
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(16)
        })

        val homeScroll = ScrollView(this).apply {
            isFillViewport = true
            isVerticalScrollBarEnabled = true
            overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS
            setBackgroundColor(C_BG)
            addView(root, android.view.ViewGroup.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT
            ))
        }
        homeView = homeScroll
    }

    // ================= 测速页 =================
    @SuppressLint("SetTextI18n")
    private fun buildRun() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(40), dp(24), dp(24))
            setBackgroundColor(C_BG)
        }

        root.addView(TextView(this).apply {
            text = "测速进行中…"
            textSize = 20f
            setTypeface(null, Typeface.BOLD)
            setTextColor(C_TEXT)
        })

        val barRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            progressDrawable = thickProgressDrawable()
            progressTintList = ColorStateList.valueOf(C_ACCENT)
            progressBackgroundTintList = ColorStateList.valueOf(Color.parseColor("#1E2A47"))
        }
        barRow.addView(progressBar, LinearLayout.LayoutParams(0, dp(14), 1f))
        percentLabel = TextView(this).apply {
            textSize = 13f
            setTypeface(null, Typeface.BOLD)
            setTextColor(C_ACCENT)
            gravity = Gravity.END
            minWidth = dp(46)
            setPadding(dp(10), 0, 0, 0)
        }
        barRow.addView(percentLabel)
        root.addView(barRow, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(14)
        })

        stageText = TextView(this).apply {
            textSize = 17f
            setTypeface(null, Typeface.BOLD)
            setTextColor(C_TEXT)
        }
        root.addView(stageText, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(10)
        })

        root.addView(Button(this).apply {
            text = "停止测速"
            textSize = 15f
            setAllCaps(false)
            setTextColor(C_TEXT)
            background = rounded(C_CARD, 12, C_STROKE)
            setOnClickListener {
                job?.cancel()
                appendLog(">>> 停止请求已发出")
                android.widget.Toast.makeText(
                    this@MainActivity, "已发出停止请求", android.widget.Toast.LENGTH_SHORT
                ).show()
            }
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(12)
        })

        root.addView(Button(this).apply {
            text = "返回主页"
            textSize = 15f
            setAllCaps(false)
            setTextColor(C_MUTED)
            background = rounded(C_CARD, 12, C_STROKE)
            setOnClickListener {
                job?.cancel()
                stopDots()
                stopSweep()
                switchTo(homeView, "home")
                refreshStatus()
                android.widget.Toast.makeText(
                    this@MainActivity, "已返回主页", android.widget.Toast.LENGTH_SHORT
                ).show()
            }
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(8)
        })

        root.addView(TextView(this).apply {
            text = "运行日志"
            textSize = 13f
            setTypeface(null, Typeface.BOLD)
            setTextColor(C_TEXT)
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(12)
        })

        val scroll = ScrollView(this).apply {
            background = rounded(C_CARD, 12, C_STROKE)
            setPadding(dp(12), dp(12), dp(12), dp(12))
            clipToOutline = true
        }
        logView = TextView(this).apply {
            textSize = 12f
            setTextColor(C_SUB)
            setLineSpacing(dp(4).toFloat(), 1.0f)
            setTextIsSelectable(true)
        }
        scroll.addView(logView)
        root.addView(scroll, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f).apply {
            topMargin = dp(8)
        })

        runView = root
    }

    /** 加粗圆角进度条：背景层灰、进度层蓝，14dp 高。 */
    private fun thickProgressDrawable(): Drawable {
        val bg = GradientDrawable().apply {
            cornerRadius = dp(7).toFloat()
            setColor(Color.parseColor("#1E2A47"))
        }
        val fg = GradientDrawable().apply {
            cornerRadius = dp(7).toFloat()
            setColor(C_ACCENT)
        }
        return LayerDrawable(arrayOf(bg, fg)).apply {
            setId(0, android.R.id.background)
            setId(1, android.R.id.progress)
            setLayerHeight(1, dp(14))
            setLayerGravity(1, Gravity.BOTTOM)
        }
    }

    // ================= 结果页 =================
    @SuppressLint("SetTextI18n")
    private fun buildResult() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(40), dp(20), dp(20))
            setBackgroundColor(C_BG)
        }
        root.addView(TextView(this).apply {
            text = "测速结果"
            textSize = 22f
            setTypeface(null, Typeface.BOLD)
            setTextColor(C_TEXT)
        })
        val scroll = ScrollView(this)
        resultContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(8), 0, dp(8))
        }
        scroll.addView(resultContainer)
        root.addView(scroll, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(Button(this).apply {
            text = "返回首页"
            textSize = 15f
            setAllCaps(false)
            setTextColor(C_ACCENT)
            background = rounded(C_CARD, 10, C_ACCENT)
            setOnClickListener { switchTo(homeView, "home"); refreshStatus() }
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(12)
        })
        resultView = root
    }

    // ================= 辅助 UI =================
    private fun sectionLabel(t: String): TextView =
        TextView(this).apply {
            text = t
            textSize = 14f
            setTypeface(null, Typeface.BOLD)
            setTextColor(C_TEXT)
            setPadding(0, dp(18), 0, dp(6))
        }

    @SuppressLint("SetTextI18n")
    private fun buildSegmented(
        values: List<String>,
        labels: List<String> = values,
        initial: String? = null,
        onSelect: (String) -> Unit
    ): LinearLayout {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val buttons = mutableMapOf<String, Button>()
        for ((i, value) in values.withIndex()) {
            val b = Button(this).apply {
                text = labels.getOrElse(i) { value }
                textSize = 13f
                setAllCaps(false)
                setTextColor(C_SUB)
                background = rounded(C_BTN_OFF, 10)
                setOnClickListener {
                    onSelect(value)
                    for ((v, btn) in buttons) styleSegment(btn, v == value)
                }
            }
            buttons[value] = b
            row.addView(b, LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                if (i > 0) leftMargin = dp(8)
            })
        }
        if (initial != null) buttons[initial]?.let { styleSegment(it, true) }
        return row
    }

    private fun styleSegment(btn: Button, selected: Boolean) {
        btn.background = rounded(if (selected) C_ACCENT else C_BTN_OFF, 10)
        btn.setTextColor(if (selected) Color.WHITE else C_SUB)
    }

    // ================= 状态 =================
    @SuppressLint("SetTextI18n")
    private fun refreshStatus() {
        val info = NetEnv.detect(this)
        val line = effectiveLineLabel(info)
        statusText.text = "网络：${info.label} · 模式：$profileMode · 线路：$line"
        protoLabel.text = "已选：$protocolMode"
    }

    private fun effectiveLineLabel(info: NetEnv.NetInfo): String = when (lineLabelMode) {
        "中国移动", "中国电信", "中国联通" -> lineLabelMode
        else -> info.carrier.ifEmpty { "未标记" }
    }

    private fun loadDomains(): List<String> {
        return try {
            assets.open("domains.txt").bufferedReader().readLines()
                .map { it.trim() }
                .filter { it.isNotEmpty() && !it.startsWith("#") }
                .distinct()
        } catch (e: Exception) { emptyList() }
    }

    // ================= 日志节流（卡机修复核心） =================
    @SuppressLint("SetTextI18n")
    private fun appendLog(line: String) {
        logQueue.add(line)
        if (!flushScheduled) {
            flushScheduled = true
            flushHandler.postDelayed({ flushLogs() }, 200)
        }
    }

    private fun flushLogs() {
        flushScheduled = false
        var n = 0
        while (n < 200) {
            val line = logQueue.poll() ?: break
            logLines.addLast(line)
            n++
        }
        while (logLines.size > 150) logLines.removeFirst()
        if (::logView.isInitialized) {
            logView.text = logLines.joinToString("\n")
        }
        if (logQueue.isNotEmpty() && !flushScheduled) {
            flushScheduled = true
            flushHandler.postDelayed({ flushLogs() }, 200)
        }
    }

    @SuppressLint("SetTextI18n")
    private fun setStage(text: String) {
        runOnUiThread { stageText.text = text }
    }

    // 进度动画：平滑过渡 + 阶段文字省略号动态 + 无确定进度时滚动条
    @SuppressLint("SetTextI18n")
    // 蓝光扫动（测速全程持续动画）
    private var sweepAnim: ObjectAnimator? = null

    @SuppressLint("SetTextI18n")
    private fun startSweep() {
        runOnUiThread {
            if (sweepAnim?.isRunning == true) return@runOnUiThread
            progressBar.secondaryProgress = 0
            sweepAnim = ObjectAnimator.ofInt(progressBar, "secondaryProgress", 0, 100)
                .setDuration(1600)
                .apply {
                    repeatCount = ValueAnimator.INFINITE
                    interpolator = LinearInterpolator()
                    start()
                }
        }
    }

    private fun stopSweep() {
        runOnUiThread {
            sweepAnim?.cancel()
            sweepAnim = null
            progressBar.secondaryProgress = 0
        }
    }

    private fun setStageProgress(pct: Int) {
        val p = pct.coerceIn(0, 100)
        runOnUiThread {
            val from = progressBar.progress
            progressBar.isIndeterminate = false
            ObjectAnimator.ofInt(progressBar, "progress", from, p)
                .setDuration(800)
                .apply {
                    interpolator = DecelerateInterpolator()
                    addUpdateListener { percentLabel.text = "${(it.animatedValue as Int).coerceIn(0, 100)}%" }
                    start()
                }
        }
    }

    @SuppressLint("SetTextI18n")
    private fun setProgressBusy() {
        runOnUiThread {
            progressBar.isIndeterminate = true
            percentLabel.text = "…"
        }
    }

    // 阶段文字动态省略号（0/1/2/3 个点循环）
    private val dotsJob = AtomicBoolean(false)
    private fun animateDots(base: String) {
        if (!dotsJob.compareAndSet(false, true)) return
        Thread {
            var n = 0
            while (dotsJob.get() && job?.isActive == true) {
                runOnUiThread { stageText.text = base + ".".repeat(n) }
                n = (n + 1) % 4
                Thread.sleep(500)
            }
        }.start()
    }

    private fun stopDots() {
        dotsJob.set(false)
    }

    // ================= 流程 =================
    private fun preflightAndStart() {
        val info = NetEnv.detect(this)
        if (info.vpnActive) {
            showVpnDialog { launchRun(info) }
        } else {
            launchRun(info)
        }
    }

    // DMIT 风格自定义 VPN 弹窗（深色卡片 + 品牌蓝按钮）
    @SuppressLint("SetTextI18n")
    private fun showVpnDialog(onContinue: () -> Unit) {
        val dlg = Dialog(this)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(24), dp(24), dp(20))
            background = rounded(C_CARD, 18, C_STROKE)
        }
        // 标题行：警示图标 + 标题
        val titleRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        titleRow.addView(TextView(this).apply {
            text = "⚠"
            textSize = 24f
        })
        titleRow.addView(TextView(this).apply {
            text = "检测到 VPN"
            textSize = 19f
            setTypeface(null, Typeface.BOLD)
            setTextColor(C_TEXT)
            setPadding(dp(10), 0, 0, 0)
        })
        root.addView(titleRow)

        root.addView(TextView(this).apply {
            text = "当前结果可能不代表移动/Wi-Fi 直连网络。\n\n可强制继续，但本轮记录将标记 VPN=是，结果默认不进入直连长期排行榜。"
            textSize = 14f
            setTextColor(C_SUB)
            setLineSpacing(dp(2).toFloat(), 1f)
            setPadding(0, dp(16), 0, dp(20))
        })

        // 按钮行
        val btnRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
        }
        val cancel = Button(this).apply {
            text = "取消"
            setAllCaps(false)
            setTextColor(C_SUB)
            background = rounded(C_BTN_OFF, 12)
            setOnClickListener { dlg.dismiss() }
        }
        btnRow.addView(cancel, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            rightMargin = dp(12)
        })
        val cont = Button(this).apply {
            text = "强制继续"
            setAllCaps(false)
            setTextColor(Color.WHITE)
            background = rounded(C_ACCENT, 12)
            setOnClickListener { dlg.dismiss(); onContinue() }
        }
        btnRow.addView(cont)
        root.addView(btnRow)
        dlg.setContentView(root)
        dlg.window?.setBackgroundDrawableResource(android.R.color.transparent)
        dlg.show()
    }

    @SuppressLint("SetTextI18n")
    private fun launchRun(info: NetEnv.NetInfo) {
        val asiaHunt = profileMode == "亚洲入口狩猎"
        val params = if (asiaHunt) Pipeline.ASIA_HUNT else Pipeline.BALANCED
        val families = when (protocolMode) {
            "IPv4" -> listOf("IPv4")
            "IPv6" -> listOf("IPv6")
            else -> listOf("IPv4", "IPv6")
        }

        job?.cancel()
        logQueue.clear()
        logLines.clear()
        switchTo(runView, "run")
        logView.text = ""
        stageText.text = "准备中…"
        startSweep()
        percentLabel.text = "0%"
        progressBar.progress = 0

        val networkChanged = AtomicBoolean(false)
        unregisterNetWatch?.invoke()
        val startFp = NetEnv.fingerprint(this)
        unregisterNetWatch = NetEnv.watchChanges(this, startFp) { old, now ->
            networkChanged.set(true)
            appendLog("!! 网络指纹变化（$old → $now）→ INVALID_NETWORK_CHANGED")
            job?.cancel()
        }

        job = scope.launch {
            try {
            appendLog("=== 开始（$profileMode / ${families.joinToString("+")} / 线路=${effectiveLineLabel(info)} / VPN=${if (info.vpnActive) "是" else "否"}）===")
            setStage("准备中")
            CfRanges.refresh()
            appendLog("Cloudflare 网段：IPv4=${if (CfRanges.v4FromOnline) "在线" else "内置备用"} IPv6=${if (CfRanges.v6FromOnline) "在线" else "内置备用"}")

            // IPv6 真实 Probe + DNS Snapshot（开始后立即执行，估算仅作日志提示不再弹窗）
            val activeFamilies = families.toMutableList()
            if ("IPv6" in activeFamilies && !info.ipv6Available) {
                activeFamilies.remove("IPv6")
                appendLog("本机无 IPv6 链路地址，跳过 IPv6")
            } else if ("IPv6" in activeFamilies) {
                appendLog("IPv6 链路存在，执行真实 IPv6 HTTPS Probe…")
                if (!Pipeline.ipv6InternetAvailable { appendLog("  $it") }) {
                    activeFamilies.remove("IPv6")
                    appendLog("⚠ IPv6 Internet 不可用，移出本轮测试")
                }
            }
            val snapshots = mutableMapOf<String, Pipeline.Snapshot>()
            for (f in activeFamilies) {
                setStage("解析 $f DNS 快照")
                val snap = Pipeline.buildSnapshot(
                    builtinDomains, f,
                    log = { appendLog("  $it") },
                    onProgress = { done, total ->
                        if (done == total || done % 25 == 0) setStage("解析 $f DNS $done/$total")
                    }
                )
                snapshots[f] = snap
                val mb = Pipeline.estimateTrafficUpperBoundMb(snap, params)
                appendLog("$f 预计最大流量 ≈ ${"%.0f".format(mb)} MB")
            }

            val allResults = HashMap<String, List<Ranker.DomainMetric>>()
            val allAsiaResults = HashMap<String, List<Ranker.DomainMetric>>()
            val allDiscoveries = HashMap<String, Pipeline.PopDiscovery?>()
            var anyInvalid = false
            var familyIdx = 0
            for (family in activeFamilies) {
                appendLog("--- $family 测速流程 ---")
                val familyResult = Pipeline.runFamily(
                    snapshot = snapshots[family]!!,
                    params = params,
                    networkInvalid = { networkChanged.get() },
                    onStage = { s ->
                        if (s.total > 0) {
                            stopDots()
                            setStage("正在${s.name} ${s.current}/${s.total}")
                            val familySpan = if (activeFamilies.size <= 1) 90 else 45
                            val base = familyIdx * familySpan
                            setStageProgress(base + (s.current * familySpan / s.total))
                        } else {
                            setStage(s.name)
                            animateDots(s.name)
                            setProgressBusy()
                        }
                    },
                    log = { appendLog("  $it") },
                    asiaHunt = asiaHunt
                )
                if (familyResult.invalid) anyInvalid = true
                allResults[family] = familyResult.ranked
                allAsiaResults[family] = familyResult.asiaRanked
                allDiscoveries[family] = familyResult.discovery
                familyIdx++
            }

            stopDots()
            stopSweep()
            // 2.6.1：取消兜底——runFamily 内部以 invalid 正常返回时，
            // 这里强制抛 CancellationException 走停止收尾，不显示结果页
            if (!kotlin.coroutines.coroutineContext.isActive) {
                throw kotlinx.coroutines.CancellationException("已停止")
            }
            setStageProgress(100)
            setStage("完成")
            appendLog("=== 完成 ===")
            if (anyInvalid) appendLog("⚠ 本轮含 INVALID_NETWORK_CHANGED，不进入直连长期排行榜")
            saveHistory(allResults, activeFamilies, anyInvalid)
            runOnUiThread { showResults(allResults, allAsiaResults, allDiscoveries, activeFamilies, anyInvalid, asiaHunt) }
            unregisterNetWatch?.invoke()
            unregisterNetWatch = null
            } catch (e: kotlinx.coroutines.CancellationException) {
                // 2.6.0：停止测速收尾——清理动画、回到首页、明确提示
                stopDots()
                stopSweep()
                appendLog("=== 测速已停止 ===")
                unregisterNetWatch?.invoke()
                unregisterNetWatch = null
                runOnUiThread {
                    switchTo(homeView, "home")
                    refreshStatus()
                    android.widget.Toast.makeText(
                        this@MainActivity, "测速已停止", android.widget.Toast.LENGTH_SHORT
                    ).show()
                }
                throw e
            }
        }
    }

    // 2.6.0：视图切换包装 + 手势/系统返回统一处理
    private fun switchTo(v: android.view.View, page: String) {
        currentPage = page
        setContentView(v)
    }

    private fun goBack(): Boolean {
        return when (currentPage) {
            "run" -> {
                job?.cancel()
                stopDots()
                stopSweep()
                switchTo(homeView, "home")
                refreshStatus()
                android.widget.Toast.makeText(
                    this, "测速已停止", android.widget.Toast.LENGTH_SHORT
                ).show()
                true
            }
            "result", "history_list" -> {
                switchTo(homeView, "home")
                refreshStatus()
                true
            }
            "history_detail" -> {
                showHistoryList()
                true
            }
            else -> false  // home：交系统（退出应用）
        }
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (!goBack()) super.onBackPressed()
    }

    // ================= 结果渲染（一次性构建，不重绘） =================
    @SuppressLint("SetTextI18n")
    private fun showResults(
        all: Map<String, List<Ranker.DomainMetric>>,
        asiaAll: Map<String, List<Ranker.DomainMetric>>,
        discoveries: Map<String, Pipeline.PopDiscovery?>,
        families: List<String>,
        invalid: Boolean,
        asiaHunt: Boolean
    ) {
        resultContainer.removeAllViews()
        if (invalid) {
            resultContainer.addView(TextView(this).apply {
                text = "⚠ 本轮网络中途变化，结果标记 INVALID，仅供参考"
                setTextColor(Color.parseColor("#CC5500"))
            })
        }
        for (family in families) {
            val ranked = all[family] ?: continue
            val asiaRanked = asiaAll[family] ?: ranked
            val discovery = discoveries[family]

            resultContainer.addView(TextView(this).apply {
                text = if (asiaHunt) "$family · 亚洲入口狩猎" else "$family 排行榜"
                textSize = 18f
                setTypeface(null, Typeface.BOLD)
                setTextColor(C_ACCENT)
                setPadding(0, dp(20), 0, dp(8))
            })

            if (asiaHunt && discovery != null) {
                addPopDiscoverySummary(discovery)
                val targetPops = listOf("HKG", "NRT", "SIN", "ICN", "TPE")
                for (pop in targetPops) {
                    val matches = asiaRanked.filter { it.primaryPop == pop }
                    if (matches.isNotEmpty()) addMetricSection("$pop 榜", matches.take(10), ranked)
                }
                val mixed = asiaRanked.filter { it.primaryPop.startsWith("混合") }
                if (mixed.isNotEmpty()) addMetricSection("混合 POP", mixed.take(10), ranked)
                addMetricSection("亚洲入口综合榜", asiaRanked.take(20), ranked)
                addMetricSection("全局速度榜", ranked.take(20), ranked)
                addDiscoveryIpList(discovery)
            } else {
                if (ranked.isEmpty()) {
                    resultContainer.addView(TextView(this).apply {
                        text = "（无有效结果）"
                        setTextColor(C_MUTED)
                    })
                    continue
                }
                addMetricSection("完整排行榜", ranked.take(20), ranked)
            }

            val baseline = ranked.firstOrNull { it.domain == Pipeline.BASELINE_DOMAIN }
            if (baseline != null) {
                val champ = ranked.firstOrNull()
                val verdict = verdictText(champ, baseline)
                resultContainer.addView(TextView(this).apply {
                    text = verdict
                    textSize = 14f
                    setTypeface(null, Typeface.BOLD)
                    setTextColor(if (verdict.contains("建议替换")) C_GREEN else C_TEXT)
                    setPadding(dp(16), dp(18), dp(16), dp(4))
                })
            }
        }
        switchTo(resultView, "result")
    }

    private fun addMetricSection(
        title: String,
        metrics: List<Ranker.DomainMetric>,
        globalRanked: List<Ranker.DomainMetric>
    ) {
        resultContainer.addView(TextView(this).apply {
            text = title
            textSize = 15f
            setTypeface(null, Typeface.BOLD)
            setTextColor(C_TEXT)
            setPadding(0, dp(14), 0, dp(7))
        })
        if (metrics.isEmpty()) {
            resultContainer.addView(dataLine("（无结果）", 12f, C_MUTED))
            return
        }
        val baseline = globalRanked.firstOrNull { it.domain == Pipeline.BASELINE_DOMAIN }
        metrics.forEachIndexed { i, m ->
            resultContainer.addView(
                resultCard(i, m, baseline),
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { bottomMargin = dp(8) }
            )
        }
    }

    @SuppressLint("SetTextI18n")
    private fun addPopDiscoverySummary(discovery: Pipeline.PopDiscovery) {
        val target = listOf("HKG", "NRT", "SIN", "ICN", "TPE")
        val targetCount = target.sumOf { discovery.counts[it] ?: 0 }
        val unknown = discovery.counts["UNKNOWN"] ?: 0
        val other = (discovery.candidates.size - targetCount - unknown).coerceAtLeast(0)
        val box = cardContainer {
            addView(dataLine("亚洲 POP 发现", 15f, C_TEXT, true))
            addView(dataLine(
                target.joinToString(" · ") { "$it ${discovery.counts[it] ?: 0}" },
                13f, C_SUB, true
            ))
            addView(dataLine("其他 $other · 未知 $unknown · 总去重 IP ${discovery.candidates.size}", 12f, C_MUTED))
            if ((discovery.counts["HKG"] ?: 0) == 0) {
                addView(dataLine("本轮未发现 HKG Cloudflare 入口", 12.5f, C_RED, true))
            } else {
                addView(dataLine("已发现 HKG，Full 阶段会再次 trace 验证是否发生 POP 漂移", 12f, C_GREEN))
            }
        }
        resultContainer.addView(box, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { bottomMargin = dp(10) })
    }

    @SuppressLint("SetTextI18n")
    private fun addDiscoveryIpList(discovery: Pipeline.PopDiscovery) {
        resultContainer.addView(TextView(this).apply {
            text = "POP 发现 IP（前 50）"
            textSize = 15f
            setTypeface(null, Typeface.BOLD)
            setTextColor(C_TEXT)
            setPadding(0, dp(16), 0, dp(7))
        })
        discovery.candidates.take(50).forEachIndexed { i, c ->
            val domains = c.domains.take(3).joinToString(", ")
            val row = dataLine(
                "${i + 1}. ${c.pop} · ${c.ip} · ${c.prefix}${if (domains.isNotEmpty()) "\n   $domains" else ""}",
                11.5f,
                if (c.priority > 0) C_SUB else C_MUTED
            )
            row.setPadding(dp(8), dp(5), dp(8), dp(5))
            row.setOnClickListener { copyText(c.ip, "IP") }
            resultContainer.addView(row)
        }
    }

    // ================= 历史记录（Phase 2.4） =================
    private fun saveHistory(all: Map<String, List<Ranker.DomainMetric>>, families: List<String>, invalid: Boolean) {
        try {
            val results = mutableListOf<HistoryStore.ResultLine>()
            var champ = ""
            var champMbps = ""
            var verdict = "无基准"
            val fam0 = all[families.firstOrNull() ?: "IPv4"] ?: emptyList()
            if (fam0.isNotEmpty()) {
                val c = fam0.first()
                champ = c.domain
                champMbps = "%.1f".format(c.avgCompleteMbps)
                val baseline = fam0.firstOrNull { it.domain == Pipeline.BASELINE_DOMAIN }
                verdict = if (baseline != null) verdictText(c, baseline) else "无基准"
                fam0.take(50).forEachIndexed { i, m ->
                    results.add(
                        HistoryStore.ResultLine(
                            rank = i + 1,
                            domain = m.domain,
                            avg = "%.1f".format(m.avgCompleteMbps),
                            min = "%.1f".format(m.minCompleteMbps),
                            floor = "%.1f".format(m.addressFloorMbps),
                            sr = "%.0f%%".format(m.addressSuccessRatePct),
                            variation = "%.1f%%".format(m.variationPct),
                            ttfb = if (m.medianTtfbMs < 0) "" else "%.0f".format(m.medianTtfbMs),
                            stability = Ranker.stabilityLabel(m.variationPct, m.successRatePct),
                            sampled = m.sampled,
                            pops = m.ipPops.joinToString(" ")
                        )
                    )
                }
            }
            val info = NetEnv.detect(this)
            HistoryStore.save(
                filesDir,
                HistoryStore.HistoryEntry(
                    id = System.currentTimeMillis(),
                    ts = System.currentTimeMillis(),
                    modeLabel = profileMode,
                    families = families.joinToString("+"),
                    networkLabel = info.label,
                    vpn = info.vpnActive,
                    invalid = invalid,
                    wifiSsid = info.wifiSsid,
                    carrier = effectiveLineLabel(info),
                    phoneModel = info.phoneModel,
                    champ = champ,
                    champMbps = champMbps,
                    verdict = verdict,
                    results = results
                )
            )
            appendLog("本轮结果已保存到历史")
        } catch (e: Exception) {
            appendLog("历史保存失败：${e.message}")
        }
    }

    @SuppressLint("SetTextI18n")
    private fun showHistoryList() {
        val entries = HistoryStore.loadAll(filesDir)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(40), dp(20), dp(20))
            setBackgroundColor(C_BG)
        }
        val titleRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        titleRow.addView(TextView(this).apply {
            text = "历史测试（最多 50 条）"
            textSize = 20f
            setTypeface(null, Typeface.BOLD)
            setTextColor(C_TEXT)
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        if (entries.isNotEmpty()) {
            titleRow.addView(Button(this).apply {
                text = "清空"
                setAllCaps(false)
                textSize = 12f
                setTextColor(C_MUTED)
                background = rounded(C_BTN_OFF, 10)
                setPadding(dp(10), dp(2), dp(10), dp(2))
                setOnClickListener {
                    showConfirm("清空全部历史记录？") {
                        HistoryStore.clearAll(filesDir)
                        showHistoryList()
                    }
                }
            })
        }
        root.addView(titleRow)
        if (entries.isEmpty()) {
            root.addView(TextView(this).apply {
                text = "还没有历史记录。跑一次测速后会自动保存。"
                textSize = 14f
                setTextColor(C_MUTED)
                setPadding(0, dp(24), 0, 0)
            })
        }
        val scroll = ScrollView(this)
        val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        for (e in entries) {
            list.addView(historyCard(e), LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { bottomMargin = dp(10) })
        }
        scroll.addView(list)
        root.addView(scroll, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(TextView(this).apply {
            text = "提示：长按记录可删除单条"
            textSize = 12f
            setTextColor(C_MUTED)
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(0, dp(8), 0, 0)
        })
        root.addView(Button(this).apply {
            text = "返回首页"
            textSize = 15f
            setAllCaps(false)
            setTextColor(Color.WHITE)
            background = rounded(C_ACCENT, 12)
            setOnClickListener { switchTo(homeView, "home"); refreshStatus() }
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(12)
        })
        switchTo(root, "history_list")
    }

    @SuppressLint("SetTextI18n", "SimpleDateFormat")
    private fun historyCard(e: HistoryStore.HistoryEntry): View {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(14))
            background = rounded(C_CARD, 14, C_STROKE)
            elevation = dp(2).toFloat()
        }
        val fmt = java.text.SimpleDateFormat("MM-dd HH:mm")
        val time = fmt.format(java.util.Date(e.ts))
        val badges = buildString {
            if (e.invalid) append(" [无效]")
        }
        card.addView(dataLine("$time · ${e.modeLabel} · ${e.families} · ${e.networkLabel}$badges", 13f, C_SUB, true))
        val env = buildString {
            if (e.wifiSsid.isNotEmpty()) append("WiFi：${e.wifiSsid}")
            if (e.carrier.isNotEmpty()) { if (isNotEmpty()) append(" · "); append("运营商：${e.carrier}") }
            if (e.phoneModel.isNotEmpty()) { if (isNotEmpty()) append(" · "); append("机型：${e.phoneModel}") }
        }
        if (env.isNotEmpty()) card.addView(dataLine(env, 12f, C_MUTED))
        if (e.champ.isNotEmpty()) {
            card.addView(dataLine("冠军：${e.champ}（${e.champMbps} Mbps）", 14f, C_TEXT))
            card.addView(dataLine("结论：${e.verdict}", 12f, C_MUTED))
        }
        card.setOnClickListener { showHistoryDetail(e) }
        card.setOnLongClickListener {
            showConfirm("删除这条历史记录？") {
                HistoryStore.delete(filesDir, e.id)
                showHistoryList()
            }
            true
        }
        return card
    }

    // DMIT 风格确认弹窗
    @SuppressLint("SetTextI18n")
    private fun showConfirm(message: String, onOk: () -> Unit) {
        val dlg = Dialog(this)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(22), dp(24), dp(18))
            background = rounded(C_CARD, 18, C_STROKE)
        }
        root.addView(TextView(this).apply {
            text = message
            textSize = 15f
            setTextColor(C_TEXT)
            setPadding(0, 0, 0, dp(18))
        })
        val btnRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
        }
        btnRow.addView(Button(this).apply {
            text = "取消"
            setAllCaps(false)
            setTextColor(C_SUB)
            background = rounded(C_BTN_OFF, 12)
            setOnClickListener { dlg.dismiss() }
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            rightMargin = dp(12)
        })
        btnRow.addView(Button(this).apply {
            text = "确定"
            setAllCaps(false)
            setTextColor(Color.WHITE)
            background = rounded(C_ACCENT, 12)
            setOnClickListener { dlg.dismiss(); onOk() }
        })
        root.addView(btnRow)
        dlg.setContentView(root)
        dlg.window?.setBackgroundDrawableResource(android.R.color.transparent)
        dlg.show()
    }

    @SuppressLint("SetTextI18n")
    private fun showHistoryDetail(e: HistoryStore.HistoryEntry) {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(40), dp(20), dp(20))
            setBackgroundColor(C_BG)
        }
        val fmt = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm")
        val time = fmt.format(java.util.Date(e.ts))
        root.addView(TextView(this).apply {
            text = "测速详情 · $time"
            textSize = 18f
            setTypeface(null, Typeface.BOLD)
            setTextColor(C_TEXT)
        })
        root.addView(dataLine(
            "${e.families} · ${e.networkLabel}${if (e.vpn) " · VPN" else ""}${if (e.invalid) " · 无效" else ""}",
            13f, C_SUB))
        val env = buildString {
            if (e.wifiSsid.isNotEmpty()) append("WiFi：${e.wifiSsid}")
            if (e.carrier.isNotEmpty()) { if (isNotEmpty()) append(" · "); append("运营商：${e.carrier}") }
            if (e.phoneModel.isNotEmpty()) { if (isNotEmpty()) append(" · "); append("机型：${e.phoneModel}") }
        }
        if (env.isNotEmpty()) root.addView(dataLine(env, 13f, C_SUB))
        if (e.champ.isNotEmpty()) {
            root.addView(dataLine("冠军：${e.champ}（${e.champMbps} Mbps）", 15f, C_TEXT, true))
            root.addView(dataLine("结论：${e.verdict}", 13f, C_MUTED))
        }
        val scroll = ScrollView(this)
        val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        for (r in e.results) {
            list.addView(historyResultCard(r), LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { bottomMargin = dp(8) })
        }
        scroll.addView(list)
        root.addView(scroll, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(Button(this).apply {
            text = "返回历史列表"
            textSize = 15f
            setAllCaps(false)
            setTextColor(Color.WHITE)
            background = rounded(C_ACCENT, 12)
            setOnClickListener { showHistoryList() }
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(12)
        })
        switchTo(root, "history_detail")
    }

    private fun historyResultCard(r: HistoryStore.ResultLine): View {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(14))
            background = rounded(if (r.rank <= 3) C_CARD_TOP else C_CARD, 14, C_STROKE)
            elevation = dp(2).toFloat()
        }
        val medal = when (r.rank) { 1 -> "🥇"; 2 -> "🥈"; 3 -> "🥉"; else -> "${r.rank}" }
        val domainLine = dataLine("$medal ${r.domain}  ⧉", 15f, C_TEXT, true)
        domainLine.setOnClickListener { copyDomain(r.domain) }
        card.addView(domainLine)
        val parts = mutableListOf<String>()
        parts.add("平均 ${r.avg} Mbps")
        if (r.min.isNotEmpty()) parts.add("最低 ${r.min} Mbps")
        parts.add("地址下限 ${r.floor}${if (r.sampled) "（抽样）" else ""}")
        card.addView(dataLine(parts.joinToString(" · "), 13f, C_SUB))
        val parts2 = mutableListOf<String>()
        parts2.add("成功率 ${r.sr}")
        if (r.variation.isNotEmpty()) parts2.add("波动 ${r.variation}")
        if (r.ttfb.isNotEmpty()) parts2.add("中位 TTFB ${r.ttfb} ms")
        if (r.stability.isNotEmpty()) parts2.add(r.stability)
        card.addView(dataLine(parts2.joinToString(" · "), 12f, C_SUB))
        if (r.pops.isNotEmpty()) card.addView(dataLine("节点：${r.pops}", 11f, C_MUTED))
        return card
    }

    private fun copyText(value: String, label: String) {
        try {
            val cm = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
            cm.setPrimaryClip(android.content.ClipData.newPlainText(label, value))
            android.widget.Toast.makeText(this, "已复制：$value", android.widget.Toast.LENGTH_SHORT).show()
        } catch (_: Exception) {
            android.widget.Toast.makeText(this, "复制失败", android.widget.Toast.LENGTH_SHORT).show()
        }
    }

    // 复制域名到剪贴板
    private fun copyDomain(domain: String) {
        try {
            val cm = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
            cm.setPrimaryClip(android.content.ClipData.newPlainText("domain", domain))
            android.widget.Toast.makeText(this, "已复制：$domain", android.widget.Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
            android.widget.Toast.makeText(this, "复制失败", android.widget.Toast.LENGTH_SHORT).show()
        }
    }

    @SuppressLint("SetTextI18n")
    private fun resultCard(index: Int, m: Ranker.DomainMetric, baseline: Ranker.DomainMetric?): View {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(14))
            background = rounded(if (index < 3) C_CARD_TOP else C_CARD, 14, C_STROKE)
            elevation = dp(2).toFloat()
        }
        val medal = when (index) { 0 -> "🥇"; 1 -> "🥈"; 2 -> "🥉"; else -> "${index + 1}" }
        val isBase = m.domain == Pipeline.BASELINE_DOMAIN
        card.addView(TextView(this).apply {
            text = "$medal  ${m.domain}${if (isBase) "（基准）" else ""}  ⧉"
            textSize = 15f
            setTypeface(null, Typeface.BOLD)
            setTextColor(C_TEXT)
            setOnClickListener { copyDomain(m.domain) }
        })
        card.addView(dataLine(
            "平均 ${"%.1f".format(m.avgCompleteMbps)} Mbps · 最低 ${"%.1f".format(m.minCompleteMbps)} Mbps · " +
                "地址下限 ${"%.1f".format(m.addressFloorMbps)} Mbps${if (m.sampled) "（抽样）" else ""}",
            13f, C_SUB
        ))
        card.addView(dataLine(
            "成功率 ${m.addressSuccessRatePct}% · 波动 ${m.variationPct}% · " +
                "中位 TTFB ${if (m.medianTtfbMs < 0) "n/a" else "%.0f ms".format(m.medianTtfbMs)} · " +
                "稳定性 ${Ranker.stabilityLabel(m.variationPct, m.successRatePct)}",
            12.5f, C_SUB
        ))
        if (m.primaryPop.isNotEmpty()) {
            card.addView(dataLine(
                "入口：${m.primaryPop} · Edge Score ${m.edgeScore}${if (m.popDrift) " · ⚠ POP 漂移" else ""}",
                12f,
                if (m.edgeScore > 0 && !m.popDrift) C_GREEN else C_SUB,
                bold = m.edgeScore > 0
            ))
        }
        if (m.ipPops.isNotEmpty()) {
            card.addView(dataLine("节点 POP：${m.ipPops.joinToString("  ")}", 12f, C_SUB))
        }
        if (m.bestIp.isNotEmpty() && m.worstIp.isNotEmpty()) {
            card.addView(dataLine("最佳IP：${m.bestIp}   最差IP：${m.worstIp}", 11.5f, C_MUTED))
        }
        if (baseline != null && !isBase) {
            card.addView(dataLine(
                "对比基准：平均 ${m.pctVs(baseline.avgCompleteMbps)} · 地址下限 ${m.pctVsFloor(baseline.addressFloorMbps)}",
                12.5f,
                if (m.addressFloorMbps >= baseline.addressFloorMbps) C_GREEN else C_MUTED,
                bold = true
            ))
        }
        return card
    }

    private fun verdictText(champ: Ranker.DomainMetric?, baseline: Ranker.DomainMetric): String {
        if (champ == null || champ.domain == Pipeline.BASELINE_DOMAIN) {
            return "结论：基准 ${Pipeline.BASELINE_DOMAIN} 守擂成功，继续保留"
        }
        val allBeat = champ.addressFloorMbps >= baseline.addressFloorMbps * 1.10 &&
            champ.minCompleteMbps >= baseline.minCompleteMbps * 1.10 &&
            champ.avgCompleteMbps >= baseline.avgCompleteMbps * 1.10
        val stabilityOk = champ.variationPct <= baseline.variationPct + 5.0 &&
            champ.addressSuccessRatePct >= baseline.addressSuccessRatePct - 5.0
        return if (allBeat && stabilityOk) {
            "结论：建议替换当前基准 → ${champ.domain}"
        } else if (champ.addressFloorMbps >= baseline.addressFloorMbps) {
            "结论：挑战者小幅领先，继续观察（暂不替换）"
        } else {
            "结论：继续保留当前基准 ${Pipeline.BASELINE_DOMAIN}"
        }
    }

    override fun onDestroy() {
        unregisterNetWatch?.invoke()
        flushHandler.removeCallbacksAndMessages(null)
        scope.cancel()
        super.onDestroy()
    }
}

// vs 基准百分比扩展（Ranker 未内置 Floor/TTFB 对比）
fun Ranker.DomainMetric.pctVsFloor(against: Double): String =
    if (against > 0) "${if (addressFloorMbps >= against) "+" else ""}${"%.1f".format((addressFloorMbps - against) * 100 / against)}%" else "n/a"
