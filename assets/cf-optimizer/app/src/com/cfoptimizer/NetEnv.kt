package com.cfoptimizer

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities

/**
 * 网络环境检测（Phase 2.2）。
 *
 * 只使用 ACCESS_NETWORK_STATE；不申请手机号/定位等敏感权限。
 * NetworkFingerprint 用于过滤 NetworkCallback 的“状态通知噪声”：
 * 只有 activeNetwork / transport / VPN / IPv4/IPv6 核心状态真正变化才判 INVALID。
 */
object NetEnv {

    data class NetInfo(
        val networkType: String,
        val vpnActive: Boolean,
        val ipv4Available: Boolean,
        val ipv6Available: Boolean,
        val networkId: String,
        val wifiSsid: String = "",   // WiFi 名称（无权限时为空）
        val carrier: String = "",    // 运营商名称
        val phoneModel: String = ""  // 手机型号
    ) {
        val label: String
            get() = "$networkType + IPv4${if (ipv4Available) "✓" else "✗"} / IPv6${if (ipv6Available) "✓" else "✗"}" +
                if (vpnActive) " ⚠VPN" else ""

        fun fingerprint(): NetworkFingerprint = NetworkFingerprint(
            networkId = networkId,
            networkType = networkType,
            vpnActive = vpnActive,
            ipv4Available = ipv4Available,
            ipv6Available = ipv6Available
        )
    }

    data class NetworkFingerprint(
        val networkId: String,
        val networkType: String,
        val vpnActive: Boolean,
        val ipv4Available: Boolean,
        val ipv6Available: Boolean
    )

    fun detect(context: Context): NetInfo {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val active = cm.activeNetwork
        val caps = cm.getNetworkCapabilities(active)
        val linkProps = cm.getLinkProperties(active)

        var type = "未知"
        var vpn = false
        var v4 = false
        var v6 = false

        if (caps != null) {
            vpn = caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            type = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "Mobile"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
                vpn -> "VPN"
                else -> "其他"
            }
        }

        if (linkProps != null) {
            v4 = linkProps.linkAddresses.any { it.address is java.net.Inet4Address }
            v6 = linkProps.linkAddresses.any {
                val a = it.address
                a is java.net.Inet6Address && !a.isLinkLocalAddress
            }
        }

        return NetInfo(
            networkType = type,
            vpnActive = vpn,
            ipv4Available = v4,
            ipv6Available = v6,
            networkId = active?.toString() ?: "none",
            wifiSsid = if (type == "Wi-Fi") wifiSsid(context) else "",
            carrier = carrierName(context),
            phoneModel = phoneModel()
        )
    }

    fun fingerprint(context: Context): NetworkFingerprint = detect(context).fingerprint()

    /** 纯比较函数，便于 JVM/单元测试。 */
    fun materiallyChanged(before: NetworkFingerprint, after: NetworkFingerprint): Boolean = before != after

    /**
     * 监听默认网络。注册后收到 onAvailable/onCapabilitiesChanged 并不等于“网络真的变了”；
     * 每次回调重新计算 fingerprint，仅 fingerprint 改变才回调 onRealChange。
     */
    fun watchChanges(
        context: Context,
        baseline: NetworkFingerprint,
        onRealChange: (NetworkFingerprint, NetworkFingerprint) -> Unit
    ): () -> Unit {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        var last = baseline

        fun evaluate() {
            val now = fingerprint(context)
            if (materiallyChanged(last, now)) {
                val old = last
                last = now
                onRealChange(old, now)
            }
        }

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = evaluate()
            override fun onLost(network: Network) = evaluate()
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = evaluate()
            override fun onLinkPropertiesChanged(network: Network, linkProperties: android.net.LinkProperties) = evaluate()
        }
        cm.registerDefaultNetworkCallback(callback)
        return { try { cm.unregisterNetworkCallback(callback) } catch (_: Exception) {} }
    }
}


// ================= 附加环境采集（Phase 2.4.7） =================

/** WiFi 名称（Android 10+ 需要定位权限；无权限/不可用时返回空串） */
fun wifiSsid(context: Context): String {
    return try {
        @Suppress("DEPRECATION")
        val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
        val info = wm.connectionInfo
        val raw = info?.ssid ?: return ""
        if (raw == "<unknown ssid>" || raw.isBlank()) return ""
        raw.trim('"')
    } catch (_: Exception) { "" }
}

/** 手机卡运营商名称（TelephonyManager，无需权限）；英文名统一映射为中文 */
fun carrierName(context: Context): String {
    return try {
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as android.telephony.TelephonyManager
        val raw = tm.networkOperatorName?.trim()?.takeIf { it.isNotBlank() } ?: return ""
        carrierToCn(raw)
    } catch (_: Exception) { "" }
}

/** 运营商英文/缩写 → 中文（已中文或无法识别则原样返回） */
fun carrierToCn(raw: String): String {
    val r = raw.uppercase()
    return when {
        r.contains("MOBILE") || r == "CMCC" || r == "CHINA MOBILE" || raw.contains("移动") -> "中国移动"
        r.contains("UNICOM") || r == "CUCC" || r == "CHINA UNICOM" || raw.contains("联通") -> "中国联通"
        r.contains("TELECOM") || r == "CTCC" || r == "CHINA TELECOM" || raw.contains("电信") -> "中国电信"
        else -> raw
    }
}

/** 手机型号（制造商 + 型号） */
fun phoneModel(): String {
    return try {
        "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim()
    } catch (_: Exception) { "" }
}
