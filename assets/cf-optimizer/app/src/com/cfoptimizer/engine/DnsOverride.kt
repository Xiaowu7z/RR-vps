package com.cfoptimizer.engine

import okhttp3.Dns
import java.net.InetAddress

/**
 * 自定义 Dns：对指定 hostname 返回固定的测试 IP。
 * URL 恒为 https://speed.cloudflare.com/...，TLS SNI / Host / 证书校验保持该域名，
 * 只有 TCP 实际连接的目标被替换为指定测试 IP。
 *
 * 要求：指定 IPv4 时 mapping 存 IPv4 地址（AF_INET），IPv6 时存 IPv6（AF_INET6），
 * 连接不经过 Happy Eyeballs 自动选择——OkHttp 直接使用本 Dns 返回的唯一地址。
 */
class FixedDns(private val mapping: Map<String, InetAddress>) : Dns {

    override fun lookup(hostname: String): List<InetAddress> {
        mapping[hostname]?.let { return listOf(it) }
        // 未指定的 hostname 走系统解析
        return Dns.SYSTEM.lookup(hostname)
    }

    companion object {
        /** 便捷构造：speed.cloudflare.com -> 指定 IP */
        fun forCloudflare(ip: String): FixedDns {
            val addr = InetAddress.getByName(ip)
            return FixedDns(mapOf("speed.cloudflare.com" to addr))
        }
    }
}
