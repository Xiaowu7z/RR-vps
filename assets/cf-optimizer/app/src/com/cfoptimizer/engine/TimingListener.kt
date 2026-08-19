package com.cfoptimizer.engine

import okhttp3.Call
import okhttp3.EventListener
import java.net.InetAddress
import java.net.InetSocketAddress

/**
 * 逐阶段计时监听器（毫秒）。
 * 捕获真实 TCP remote InetSocketAddress（connectStart），供字节级等价判断。
 */
class ProbeTimingListener(
    private val onEvent: (String) -> Unit,
    private val onTimings: (Timings) -> Unit
) : EventListener() {

    data class Timings(
        var callStartNs: Long = 0L,
        var dnsStartNs: Long = 0L,
        var dnsEndNs: Long = 0L,
        var connectStartNs: Long = 0L,
        var connectEndNs: Long = 0L,
        var secureConnectStartNs: Long = 0L,
        var secureConnectEndNs: Long = 0L,
        var responseHeadersStartNs: Long = 0L,
        var responseBodyEndNs: Long = 0L,
        var actualRemoteAddress: String = "",   // connectStart 真实远端字符串
        var actualRemoteAddr: InetAddress? = null // connectStart 真实远端 InetAddress（字节级比较用）
    ) {
        fun dnsMs(): Double = ms(dnsStartNs, dnsEndNs)
        fun tcpMs(): Double = ms(connectStartNs, connectEndNs)
        fun tlsMs(): Double = ms(secureConnectStartNs, secureConnectEndNs)
        fun ttfbMs(): Double = ms(connectStartNs, responseHeadersStartNs)
        /** 纯 Body 时间：responseHeadersStart → responseBodyEnd */
        fun bodyMs(): Double = ms(responseHeadersStartNs, responseBodyEndNs)
        /** 完整传输时间：connectStart → responseBodyEnd */
        fun totalMs(): Double = ms(connectStartNs, responseBodyEndNs)
        /** Call 总时长：callStart → responseBodyEnd（含 DNS 解析，最接近端到端耗时） */
        fun callTotalMs(): Double = ms(callStartNs, responseBodyEndNs)

        private fun ms(start: Long, end: Long): Double =
            if (start > 0L && end > 0L) (end - start) / 1_000_000.0 else -1.0
    }

    private val t = Timings()

    override fun callStart(call: Call) {
        t.callStartNs = System.nanoTime()
        onEvent("callStart")
    }

    override fun dnsStart(call: Call, domainName: String) {
        t.dnsStartNs = System.nanoTime()
        onEvent("dnsStart $domainName")
    }

    override fun dnsEnd(call: Call, domainName: String, inetAddressList: List<InetAddress>) {
        t.dnsEndNs = System.nanoTime()
        onEvent("dnsEnd $domainName -> ${inetAddressList.joinToString { it.hostAddress ?: "?" }}")
    }

    override fun connectStart(call: Call, inetSocketAddress: InetSocketAddress, proxy: java.net.Proxy) {
        t.connectStartNs = System.nanoTime()
        t.actualRemoteAddr = inetSocketAddress.address
        t.actualRemoteAddress = inetSocketAddress.address?.hostAddress ?: ""
        onEvent("connectStart ${t.actualRemoteAddress}:${inetSocketAddress.port}")
    }

    override fun connectEnd(call: Call, inetSocketAddress: InetSocketAddress, proxy: java.net.Proxy, protocol: okhttp3.Protocol?) {
        t.connectEndNs = System.nanoTime()
        onEvent("connectEnd proto=$protocol")
    }

    override fun secureConnectStart(call: Call) {
        t.secureConnectStartNs = System.nanoTime()
        onEvent("secureConnectStart")
    }

    override fun secureConnectEnd(call: Call, handshake: okhttp3.Handshake?) {
        t.secureConnectEndNs = System.nanoTime()
        val cert = handshake?.peerCertificates?.firstOrNull()
        onEvent("secureConnectEnd SNI=${call.request().url.host} peerCN=${(cert as? java.security.cert.X509Certificate)?.subjectX500Principal?.name?.take(60)}")
    }

    override fun responseHeadersStart(call: Call) {
        t.responseHeadersStartNs = System.nanoTime()
        onEvent("responseHeadersStart")
    }

    override fun responseBodyEnd(call: Call, byteCount: Long) {
        t.responseBodyEndNs = System.nanoTime()
        onEvent("responseBodyEnd bytes=$byteCount")
        onTimings(t)
    }
}
