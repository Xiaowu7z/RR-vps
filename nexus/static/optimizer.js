"use strict";

/*
 * RR Edge Optimizer — Browser Local CF Edge 优选（浏览器本地测速引擎）
 *
 * 原则：
 *   1. 所有测速运行在用户浏览器本地；服务器只静态托管工具与候选域名池，不参与任何计算。
 *   2. 服务器不参与测速、不收集用户网络数据。
 *   3. 结果仅存 localStorage（用户自己设备上）。
 *   4. 测速对象是 CF 域名（间接测其命中的 Cloudflare Edge IP 段），
 *      不宣称"浏览器绑定指定 IP 测速"。Edge IP 由浏览器通过 DNS-over-HTTPS 实时解析。
 *
 * 与 Android 版 CF Optimizer 的关系（对齐其分层测速思想）：
 *   Android = IP 精准探测版（FixedDns + 指定 IP）
 *   Web     = 浏览器本地 CF Edge 优选版（真实用户网络环境测试）
 *   分层策略对齐 Pipeline.kt：候选池（1000 域名）→ 小流量筛选 → 决赛名单 → 完整测速。
 */

const OptimizerState = {
  running: false,
  aborted: false,
  controller: null,
  domains: [],           // 候选 CF 域名列表（内嵌，无需请求服务器）
  results: [],           // 全局排名结果
  asiaResults: [],       // 亚洲入口狩猎榜结果
  egressIp: "",          // 首次 trace 检测到的出口 IP
  egressChanged: false,  // 测速过程中出口 IP 是否变化
  vpnDetected: false,    // 是否检测到 VPN/代理特征
  networkType: "",       // WiFi / Mobile / ...
  operator: "",          // 运营商（IP 反查或手动指定）
  operatorManual: "",    // 手动运营商（"auto"=自动检测）
  protocol: "dual",      // ipv4 / ipv6 / dual
  use: "proxy",          // web 网页 / proxy 代理 / download 下载
  mode: "balanced",      // balanced 均衡 / asia_hunt 亚洲入口狩猎
  ipv4Results: [],       // 双栈：IPv4 候选榜（独立排名）
  ipv6Results: [],       // 双栈：IPv6 候选榜（独立排名）
  popCount: {},          // 实时 POP 统计 {HKG: n, LAX: n, ...}
};

// 亚洲入口优先级：POP 距离/亚洲入口（隐藏辅助因子，仅同分 tiebreak）
const ASIA_POP_PRIORITY = { HKG: 5, NRT: 4, SIN: 3, ICN: 2, TPE: 1 };
// 运营商 POP 优先级（隐藏修正，不覆盖测速结果，仅同分排序）
const OPERATOR_POP = {
  "中国移动": ["HKG", "NRT", "SIN", "ICN", "TPE", "LAX"],
  "中国电信": ["HKG", "NRT", "LAX", "SIN"],
  "中国联通": ["HKG", "NRT", "LAX"],
};
function popPriority(pop) { return ASIA_POP_PRIORITY[pop] || 0; }
function isAsiaTarget(pop) { return popPriority(pop) > 0; }

// 三级筛选常量
const BATCH_SIZE = 50;            // Stage 1 每批并发（避免浏览器卡死）
const STAGE1_TIMEOUT_MS = 3500;   // Stage 1 轻量探测短超时
const STAGE2_TIMEOUT_MS = 6000;   // Stage 2 小流量测速超时
const STAGE2_COUNT = 200;         // Stage 2 保留数量（100~200）
const FINAL_COUNT = 20;           // Stage 3 深度测试数量
const CONCURRENCY = 8;            // Stage 2/3 并发
const PROBE_TIMEOUT_MS = 8000;    // Stage 3 深度测试超时
const ROUNDS = 3;                 // Stage 3 每域名累计轮数
const EDGE_STABILITY_ROUNDS = 5;  // Edge 复用稳定性连续 trace 轮数（仅 proxy 模式）
const DOWNLOAD_BYTES = 2 * 1024 * 1024;
const STORAGE_KEY = "rr_edge_optimizer";
const BLACKLIST_KEY = "rr_edge_optimizer_blacklist";
const CUSTOM_DOMAINS_KEY = "rr_edge_optimizer_custom_domains";
const HISTORY_KEY = "rr_edge_optimizer_history";   // 每域名历史测速记录（供「历史表现」维度 + 时间衰减）
const HISTORY_N = 7;                               // 历史表现：最近 7 次滑动平均
const HISTORY_HALFLIFE_MS = 7 * 24 * 3600 * 1000;  // 时间衰减半衰期 7 天
const BENCHMARK_DOMAINS = ["openai.com", "deepl.com", "cloudflare.com"];  // 黄金参考（不参与排名）
const BENCHMARK_GATE = 0.7;                        // 门禁：candidateCore < benchmarkMedian × 0.7 禁止推荐
// 用途评分权重（v4 最终确认版，按用途动态切换，模块化：加用途只需加一个 key）
// web 网页访问：可用性40 / TTFB30 / 稳定20 / DNS10
// proxy 代理节点（默认，v4 重定位 = 代理入口稳定性，非网页速度）：
//   稳定连接35 / 成功率20 / CF环境吞吐参考15 / POP质量10 / 历史表现10 / TTFB5 / DNS5
// download 下载：可用性30 / 吞吐40 / 稳定20 / 延迟10
const SCORE_PRESETS = {
  web:      { availability: 40, ttfb: 30, stability: 20, dns: 10 },
  proxy:    { connStability: 35, successRate: 20, envThroughput: 15, popQuality: 10, history: 10, ttfb: 5, dns: 5 },
  download: { availability: 30, throughput: 40, stability: 20, latency: 10 },
};
const USE_LABELS = { web: "网页访问", proxy: "代理节点", download: "大流量下载" };
const USE_WEIGHT_TEXT = {
  web: "可用性40% · TTFB30% · 稳定20% · DNS10%",
  proxy: "稳定连接35% · 成功率20% · 环境吞吐15% · POP10% · 历史10% · TTFB5% · DNS5%",
  download: "可用性30% · 吞吐40% · 稳定20% · 延迟10%",
};

// 评分维度计算器（纯函数，返回 0-1 归一化值；加维度只需加一个 key）
const SCORE_DIMENSIONS = {
  // 可用性：多轮 trace 成功率（web/download）
  availability: (m) => m.successRate,
  // TTFB（网页访问）：中位首字节，50ms 满分，800ms 归零
  ttfb: (m) => (m.medianTtfb >= 0 ? Math.max(0, 1 - m.medianTtfb / 800) : 0),
  // 延迟（下载）：同 TTFB，语义为连接延迟
  latency: (m) => (m.medianTtfb >= 0 ? Math.max(0, 1 - m.medianTtfb / 800) : 0),
  // 稳定/波动（web/download）：多轮 TTFB 的 CV（波动小=稳定）
  stability: (m) => (1 - Math.min(1, m.cv)),
  // DNS：DoH 解析耗时，2000ms 归零
  dns: (m) => (m.dnsMs >= 0 ? Math.max(0, 1 - m.dnsMs / 2000) : 0.5),
  // 吞吐（下载）：同 CF 环境吞吐
  throughput: (m, ctx) => (ctx && ctx.dl && ctx.dl.ok ? Math.min(1, ctx.dl.mbps / 100) : 0),

  // ===== v4 proxy 维度 =====
  // 稳定连接（35%）：连续 trace 复用连接，连续成功率 70% + TTFB 波动 30%
  connStability: (m) => {
    const es = m.edgeStability;
    if (!es || !es.samples) return 0;
    return es.successRate * 0.7 + (1 - Math.min(1, es.ttfbCV)) * 0.3;
  },
  // 成功率（20%）：多轮 trace 成功率
  successRate: (m) => m.successRate,
  // CF 环境吞吐参考（15%）：speed.cloudflare.com/__down 实测（全局共享，不区分候选，只反映环境）
  envThroughput: (m, ctx) => (ctx && ctx.dl && ctx.dl.ok ? Math.min(1, ctx.dl.mbps / 60) : 0),
  // POP 质量（10%）：路由落点 colo 的运营商优先级（亚洲 POP 高分，美国 POP 低分）
  popQuality: (m) => popQualityScore(m.colo),
  // 历史表现（10%）：localStorage 历史测速（最近 7 次滑动平均 + 时间衰减，无历史 0.5）
  history: (m) => historyScore(m.domain),
};

// 候选 CF 域名池（内嵌在工具文件中，服务器仅静态托管此文件，域名池随之分发）
const OPTIMIZER_DOMAINS = [
  "www.nexusmods.com", "nexusmods.com", "www.cloudflare.com", "cloudflare.com", "blog.cloudflare.com",
  "developers.cloudflare.com", "speed.cloudflare.com", "radar.cloudflare.com", "community.cloudflare.com", "dash.cloudflare.com",
  "pages.cloudflare.com", "workers.cloudflare.com", "www.cloudflarestatus.com", "cloudflarestatus.com", "cloudflare-dns.com",
  "www.cloudflare-dns.com", "one.one.one.one", "1dot1dot1dot1.cloudflare-dns.com", "www.trycloudflare.com", "trycloudflare.com",
  "pages.dev", "workers.dev", "warp.dev", "cloudflareclient.com", "www.cloudflareclient.com",
  "cloudflareinsights.com", "www.cloudflareinsights.com", "www.4chan.org", "4chan.org", "www.canva.com",
  "canva.com", "www.fiverr.com", "fiverr.com", "www.indeed.com", "indeed.com",
  "www.pexels.com", "pexels.com", "www.shopify.com", "shopify.com", "www.chess.com",
  "chess.com", "www.itch.io", "itch.io", "www.codepen.io", "codepen.io",
  "www.dribbble.com", "dribbble.com", "www.deepl.com", "deepl.com", "www.sentry.io",
  "sentry.io", "www.bitly.com", "bitly.com", "www.ngrok.com", "ngrok.com",
  "www.digitalocean.com", "digitalocean.com", "www.vultr.com", "vultr.com", "www.linode.com",
  "linode.com", "www.docker.com", "docker.com", "www.gitlab.com", "gitlab.com",
  "www.medium.com", "medium.com", "www.genius.com", "genius.com", "www.tawk.to",
  "tawk.to", "www.namecheap.com", "namecheap.com", "www.cloudflare.net", "cloudflare.net",
  "www.discourse.org", "discourse.org", "www.letterboxd.com", "letterboxd.com", "www.producthunt.com",
  "producthunt.com", "www.behance.net", "behance.net", "www.unsplash.com", "unsplash.com",
  "www.imgur.com", "imgur.com", "www.fandom.com", "fandom.com", "www.archiveofourown.org",
  "archiveofourown.org", "www.curseforge.com", "curseforge.com", "www.speedtest.net", "speedtest.net",
  "www.mozilla.org", "mozilla.org", "www.python.org", "python.org", "www.rust-lang.org",
  "rust-lang.org", "www.npmjs.com", "npmjs.com", "www.npmjs.org", "npmjs.org",
  "www.jsdelivr.com", "jsdelivr.com", "www.stackshare.io", "stackshare.io", "www.cloudflare-ipfs.com",
  "cf-ipfs.com", "discord.com", "www.discord.com", "www.patreon.com", "patreon.com",
  "www.quora.com", "quora.com", "www.coinmarketcap.com", "coinmarketcap.com", "www.grammarly.com",
  "grammarly.com", "www.notion.so", "notion.so", "www.openai.com", "openai.com",
  "www.reddit.com", "reddit.com", "www.twitch.tv", "twitch.tv", "www.udemy.com",
  "udemy.com", "www.coursera.org", "coursera.org", "www.khanacademy.org", "khanacademy.org",
  "wbinsights.com", "yuanshen.com", "goodreads.com", "rt.ru", "l-err.biz",
  "sky.com", "b2clogin.com", "vk.com", "goodsync.com", "nuancemobility.net",
  "myip.com", "razorpay.com", "impact-ad.jp", "google.com.mx", "rambler.ru",
  "gotolstoy.com", "discogs.com", "360.cn", "amap.com", "awswaf.com",
  "sndcdn.com", "krisp.ai", "disquscdn.com", "xero.com", "pendo.io",
  "189.cn", "me.com", "exponea.com", "brightcove.net", "bidswitch.net",
  "atmtd.com", "tq-tungsten.com", "gdms.cloud", "drdrab.com", "conversionsapigateway.com",
  "zdbb.net", "pop-convert.com", "force.com", "google.ge", "gnezdo.ru",
  "ruckus.cloud", "securly.com", "fireoscaptiveportal.com", "tnt-ea.com", "mgslb.com",
  "redditspace.com", "ubnt.com", "latamairlines.com", "dmrtb.com", "snarutox.com",
  "google.kz", "mjedge.net", "wps.com", "wondershare.cc", "mmechocaptiveportal.com",
  "dattobackup.com", "packetstream.io", "nintendo.com", "kumulos.com", "t-static.ru",
  "warnermediacdn.com", "yandex.fi", "qianwen.com", "litatom.com", "reson8.com",
  "blockchain.info", "infocyte.com", "myfitnesspal.com", "google.org", "haplat.net",
  "belkin.com", "google.at", "ns1p.net", "parastorage.com", "nytimes.com",
  "appnexusgslb.com", "online-metrix.net", "comfylink.com", "gcore.com", "hepsiburada.com",
  "byte008.com", "docusign.com", "adsensecustomsearchads.com", "usgovcloudapi.net", "depositphotos.com",
  "yeastar.com", "ldmnq.com", "aviasales.com", "ttvnw.net", "365scores.com",
  "ixigua.com", "solaredge.com", "calendly.com", "refinery89.com", "7tv.io",
  "amplitude.com", "opera-api.com", "cdn-fileserver.com", "bcbd123.com", "lunalabs.io",
  "hola.org", "languagetoolplus.com", "nflxext.com", "adpushup.com", "bol.com",
  "wfcdn.com", "adobeccstatic.com", "omnisendlink.com", "mercadolibre.com.mx", "apibay.org",
  "ghost.io", "soundcloud.com", "elasticbeanstalk.com", "huobi.pro", "loox.io",
  "appdome.com", "colnsedge.com", "mist.com", "opera.technology", "emc.com",
  "crpt.ru", "cars.com", "tdatamaster.com", "fedoraproject.org", "live-video.net",
  "bricks-co.com", "oracleinfinity.io", "coolzcloud.com", "sleepnumber.com", "cloud.globo",
  "digitalaudience.io", "ladesk.com", "aidata.io", "mdpi.com", "tpmn.io",
  "ebayimg.com", "corel.com", "ask.com", "cloudflare-gateway.com", "adstk.io",
  "indriverapp.com", "shallspark.com", "mediav.com", "kwai-pay.com", "toast.com",
  "voltaxservices.io", "clover.com", "cbssports.com", "conviva.com", "zg-api.com",
  "docker.io", "vps-vids.com", "lgtvcommon.com", "1905.com", "homeconnecthca.com",
  "clarocdn.com.br", "yandex.com.tr", "lenovomm.com", "adp.com", "casasbahia.com.br",
  "tildacdn.com", "grofers.com", "railway.app", "netgear.com", "okx.cab",
  "verkada.com", "tdnsstic1.cn", "sendbird.com", "google.bt", "changeip.com",
  "adobestats.io", "douyinstatic.com", "activision.com", "dialmyapp.com", "apkpure.com",
  "a-b-c-8.com", "noaa.gov", "zaloapp.com", "adobeprimetime.com", "ele.me",
  "web.id", "outlook.com", "everesttech.net", "ebaydesc.com", "itbakit.com",
  "rbstsystems.live", "fandango.com", "puicdn.com", "tubi.video", "gotomeeting.com",
  "quillbot.com", "pb.com", "weglot.com", "dalyfeds.com", "printercloud.com",
  "zillowstatic.com", "scribd.com", "zscloud.net", "sweatco.in", "idealmedia.io",
  "gototraining.com", "iubenda.com", "jumpcloud.com", "nexthink.cloud", "google.com.py",
  "instabug.com", "assets-yammer.com", "sportradarserving.com", "oaiusercontent.com", "salesforce-scrt.com",
  "google.com.jm", "country.is", "onetag-sys.com", "chewy.com", "cloudsink.net",
  "priceline.com", "mygaru.com", "ca.gov", "eufylife.com", "tiktokw.eu",
  "espncricinfo.com", "marriott.com", "typeform.com", "google.hr", "google.al",
  "esportesdasorte.bet.br", "pastebin.com", "zeronaught.com", "alfabank.ru", "mova-tech.com",
  "genieesspv.jp", "affirm.com", "myip.link", "etahub.com", "google.cg",
  "ivi.ru", "zscaler.net", "deviantart.com", "metricswpsh.com", "qantas.com",
  "wareztv.io", "olx.com.br", "accuweather.com", "bradesco.com.br", "ttdns2.com",
  "quago.io", "pinterest.com", "hexagon-analytics.com", "disney-plus.net", "openxcdn.net",
  "protonmail.ch", "fbsbx.com", "googleapis.cn", "wwstat.com", "ipleak.net",
  "bilibili.com", "codedish.co", "centrastage.net", "bcebos.com", "usercentrics.eu",
  "tivo.com", "dreame.tech", "ac.in", "intsig.net", "go.com",
  "lenovo.com", "signal.org", "google.sr", "samsungcloudsolution.net", "zohopublic.com",
  "im-apps.net", "biahosted.com", "skinnycrawlinglax.com", "windows.com", "netcoresmartech.com",
  "google.lk", "mcas.ms", "dzeninfra.ru", "ttwstatic.com", "vorwerk-digital.com",
  "kinopoisk.ru", "urban-vpn.com", "unmsapp.com", "volcgtm.com", "cambaddies.com",
  "like-video.com", "wandera.com", "tatum.io", "bromium-online.com", "archlinux.org",
  "samsung.com", "viafoura.co", "listdl.com", "tailscale.io", "richaudience.com",
  "cpanel.net", "pcloud.com", "eyeota.net", "adx.ws", "sophosupd.com",
  "loom.com", "glance.com", "gofastchat.com", "samsungosp.com", "monitoring360.io",
  "nereserv.com", "saygames.io", "ad4m.at", "zdn.vn", "intelbrasp2p.com.br",
  "oracle.com", "apollo.io", "amazon.pl", "joinwebinar.com", "sgsnssdk.com",
  "imgsmail.ru", "discord.gg", "optimizely.com", "scw.cloud", "nbc.com",
  "freepik.com", "opera.software", "zzpxy.top", "kwaipros.com", "advertising.com",
  "ampproject.org", "flirtify.com", "wiley.com", "octobrowser.net", "kontur.ru",
  "tpmn.co.kr", "zoom.us", "zencdn.net", "tianwenca.com", "fbcdn.net",
  "youngle.tech", "ecobee.com", "certum.pl", "weathercn.com", "google.com.tw",
  "apitd.net", "jetbrains.com", "myfoscam.com", "intercom.io", "pbs.org",
  "doppiocdn.net", "smartthings.com", "usercontent.goog", "capitaloneshopping.com", "allawnos.com",
  "resetdigital.co", "indazn.com", "sng.link", "uuidksinc.net", "mediaplex.com",
  "testmy.net", "msftauthimages.net", "alidns.com", "redbubble.com", "syndicatedsearch.goog",
  "4wps.net", "wallapop.com", "mtgglobals.com", "cloudbackup.management", "google.ch",
  "myclientip.com", "cpx.to", "lifeaiot.com", "edgecdn.ru", "mintegral.net",
  "nuget.org", "deepernetworks.org", "schwab.com", "google.com.co", "shopifycdn.com",
  "superbet.bet.br", "tokopedia.com", "nba.com", "outboundproxy.com", "ticketmaster.com",
  "nextdns.io", "qwps.cn", "anonymised.io", "cookiebot.com", "microsoftonline.com",
  "mfadsrvr.com", "ueiwsp.com", "sohu.com", "wistia.com", "volcvod.com",
  "xml-redirect.online", "zscalerthree.net", "aniview.com", "google.as", "gmail.com",
  "addtoany.com", "yotpoapi.com", "demonware.net", "idexx.com", "selcdn.net",
  "travel-assets.com", "qiyukf.com", "gtld-servers.net", "appbaqend.com", "booking.com",
  "mediavine.com", "aliyun.com", "izatcloud.net", "nocookie.net", "channelcom.tech",
  "google.la", "vkvideo.ru", "google.com.ai", "onkakao.net", "vonedge.com",
  "zing.vn", "apkpure.net", "siteimproveanalytics.io", "powerschool.com", "doppiocdn.com",
  "coupert.com", "tiktokcdn.com", "mgtv.com", "hpsmart.com", "mopub.com",
  "devicetrust.com", "ndcpp-os.com", "drom.ru", "givefreely.com", "qustodio.com",
  "speedtestcustom.com", "hsforms.net", "sina.com.cn", "serving-sys.ru", "opt360.net",
  "bytepluscdn.com", "webengage.com", "prebid-server.com", "paytm.com", "spribegaming.com",
  "dutils.com", "newsbreak.com", "ad-delivery.net", "opentrackr.org", "honeygain.com",
  "remote-service-pf.com", "wpengine.com", "p-cdn.us", "netlify.com", "tapad.com",
  "poly-ai.chat", "kinescopecdn.net", "google.co.ug", "wego.com", "iotcplatform.com",
  "futbin.com", "tubemogul.com", "linkplay.com", "santander.com.br", "appboy.com",
  "zippypongbee.com", "wordwall.net", "revjet.com", "bytefcdn.com", "octo25.me",
  "ebay.com", "sonarr.tv", "npttech.com", "tribunnews.com", "dotomi.com",
  "bytelb.com", "azure-dns.net", "dramaverses.com", "safedk.com", "bloomreach.co",
  "bluestacks.com", "make.com", "smile.io", "rtbwise.com", "cnzz.com",
  "samokat.ru", "capcutcdn-us.com", "semanticscholar.org", "opentracker.io", "pdst.fm",
  "tinypass.com", "grammarly.net", "trvdp.com", "geniex.com", "popcash.net",
  "configcat.com", "keplr.app", "nypost.com", "fhgte.com", "fastly-insights.com",
  "cloudflareok.com", "shopee.vn", "adapty.io", "nordpass.com", "hsadspixel.net",
  "v2z.ru", "r7ops.com", "phonefactor.net", "yandex.ru", "onrender.com",
  "google.bs", "kayzen.io", "susercontent.com", "wixmp.com", "hulustream.com",
  "ospserver.net", "delta.com", "apnews.com", "usepylon.com", "sanity.io",
  "navdmp.com", "heytapimage.com", "webshare.io", "eqtv.io", "qualtrics.com",
  "media-amazon.com", "mercadolibre.com", "ifood.com.br", "aiv-cdn.net", "eu-1-id5-sync.com",
  "postrelease.com", "google.lv", "alibaba-inc.com", "f-sos.net", "pvvstream.pro",
  "ccgateway.net", "appiersig.com", "intsmarthub.com", "kameleoon.eu", "adroll.com",
  "8slp.net", "acrobat.com", "tencentmusic.com", "dotnxdomain.net", "sicoob.com.br",
  "trustedstack.com", "packetsdk.io", "disney.co.jp", "onefootball.com", "sourshaped.com",
  "prodregistryv2.org", "bancointer.com.br", "kslawin.com", "roeyecdn.com", "e-msedge.net",
  "txlivecdn.com", "deviantart.net", "minecraft-services.net", "google.nu", "weatherbug.net",
  "storagejsstrategiesfabulous.com", "anuytzc.xyz", "galaxy-cdn.com", "feishu.cn", "wwsga.me",
  "brevo.com", "quad9.net", "google.com.br", "artstation.com", "dnsv1.com",
  "mktoresp.com", "sm.cn", "ipip.net", "system-monitor.com", "qidi3dprinter.com",
  "wetransfer.net", "salesforceliveagent.com", "fontawesome.com", "superproxy.io", "apicgate.com",
  "go-mpulse.net", "adsbynimbus.com", "browsiprod.com", "bugsnag.com", "glassdoor.com",
  "mypikpak.com", "localytics.com", "adspower.net", "lge.com", "cdninstagram.com",
  "google.com.sv", "redbubble.net", "aliapp.org", "pubmnet.com", "ac.kr",
  "saawsedge.com", "gonet-ads.com", "mxptint.net", "getgrass.io", "nextersglobal.com",
  "jsmsat.com", "akahost.net", "cisco.com", "eeroup.com", "amazonsilk.com",
  "pixiv.net", "mega.nz", "nest.com", "tenjin.com", "amzn.eu",
  "jito.wtf", "lookout.com", "highspeedinternet.com", "elastic.co", "mi.com",
  "dnse0.com", "1drv.com", "aliyuncs.com", "google.com.ar", "banco.bradesco",
  "hik-connect.com", "gcdn.co", "unioneeu.com", "volcmcdn3.com", "logitech.com",
  "bytegle.site", "best61.com", "best82.com", "fluidplayer.com", "cloudscdn.net",
  "aidemsrv.com", "stnvideo.com", "nhs.uk", "vercel.app", "xdrtc.com",
  "signalr.net", "queue-it.net", "thinkingdata.cn", "hereapi.com", "google.com.et",
  "airtable.com", "windy.com", "tenable.com", "apptracer.ru", "tesla.services",
  "samsungcloud.com", "aliyuncsslbintl.com", "google.com.vn", "gameanalytics.com", "linke.ai",
  "sspnet.tech", "dtscout.com", "isharing-gps.com", "crowdstrike.com", "ably.io",
  "plista.com", "flickr.com", "webflow.com", "axs.com", "jd.com",
  "redhat.com", "edgedns-tm.info", "tradplusad.com", "mobile.de", "geoipcheck.com",
  "megaphone.fm", "t-ru.org", "libsyn.com", "ruckuswireless.com", "voodoo-tech.io",
  "fpjs.io", "otto.de", "nabu.casa", "bdydns.com", "fuseplatform.net",
  "atidevs.com", "tru.am", "roku.com", "squarespace.com", "bumlam.com",
  "chimpstatic.com", "x.ai", "xhtotal.com", "streamrail.com", "mathworks.com",
  "mi-fds.com", "blogspot.com", "airbrake.io", "quantcount.com", "alipayobjects.com",
  "jiveip.net", "goo.gl", "bringads.ru", "kunlunsl.com", "garena.com",
  "samsunghealth.com", "douyinpic.com", "navercorp.com", "vidazoo.services", "gouv.fr",
  "samba.tv", "google.co.kr", "thecatmachine.com", "alarmnet.com", "affec.tv",
  "instana.io", "vesync.com", "pushd.com", "erne.co", "bidmatic.io",
  "olxcdn.com", "sap.com", "google.co.nz", "boomplaymusic.com", "gtranslate.net",
  "rs-online.com", "bytetcdn.com", "google.mk", "opensea.io", "pbbl.co",
  "zmaticoo.com", "wb.ru", "mediarithmics.com", "s-onetag.com", "volcfcdndvs.com",
  "hcaptcha.com", "hath.network", "e5.sk", "f2pool.com", "google.mn",
  "tbcache.com", "bb.com.br", "dramaboxdb.com", "sc-static.net", "lsapp.eu",
  "quicksetcloud.com", "paloaltonetworks.com", "b-msedge.net", "demdex.net", "vsco.co",
  "binance.org", "minecraft.net", "socdm.com", "livesport.services", "android.com",
  "worldoftanks.eu", "scene7.com", "admixer.net", "concursolutions.com", "google.co.zw",
  "acobt.tech", "celtra.com", "holadns.com", "ip-api.com", "ovrc.com",
  "primis.tech", "zeotap.com", "nflximg.com", "pstatp.com", "veeam.com",
  "biz.id", "nexon.com", "google.az", "bezeqint.net", "qianxun.com",
  "otclick-adv.ru", "ml314.com", "judge.me", "mercadoclics.com", "netlify.app",
  "midasplayer.net", "lgthinq.com", "muscache.com", "seek.com.au", "smilewanted.com",
  "decibelinsight.net", "captioncall.com", "fc2.com", "totalbattle.com", "edgesuite.net",
  "google.com.gh", "msftstatic.com", "clarip.com", "ttdns3.com", "pokeapi.co",
  "google.gp", "media6degrees.com", "bytedance.com", "youtu.be", "nextlgsdp.com",
  "jwplatform.com", "kargo.com", "dbankcloud.eu", "bluetrafficstream.com", "porsche.com",
  "tsyndicate.com", "libero.it", "ipv6-test.com", "bdstatic.com", "monday.com",
  "srmdata-us.com", "aqara.com", "nearme.com.cn", "bilivideo.com", "ripe.net",
  "nflxso.net", "app-measurement.com", "wp.pl", "apptentive.com", "p-n.io",
  "xbox-dns.ru", "overwolf.com", "autonavi.com", "dmv.org", "kwaicdn.com",
  "powerplatform.com", "falconnet.app", "permutive.com", "azurerms.com", "clean.gg",
  "aylanetworks.com", "gaijin.net", "hubspot.com", "hot.net.il", "glotgrx.com",
  "presage.io", "okx.com", "csfloat.com", "pipopay.com", "google.vg",
  "rockylinux.org", "rollbar.com", "dual-s-dc-msedge.net", "uservoice.com", "liveperson.net",
  "pinduoduo.com", "tile-api.com", "allegrostatic.com", "cloudinary.com", "avada.io",
  "jfrog.io", "yclients.com", "lnkdns.net", "zoho.in", "sfx.ms",
  "gstatic.com", "ipinfo.io", "acrobits.cz", "azure-dns.com", "xerox.com",
  "op.gg", "zhihu.com", "infinitepay.io", "blastapi.io", "zyxel.com",
  "tribalfusion.com", "coinall.ltd", "avito.st", "amspbs.com", "nih.gov",
  "fizzopic.org", "instagram.com", "spbycdn.com", "ietf.org", "comodoca.com",
  "sgmbocast.com", "dtignite.com", "office.com", "xwz.ovh", "cudaops.com",
];

const $o = (sel, root = document) => root.querySelector(sel);

function escapeHtmlO(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[c]);
}

/* ------------------------------------------------------------------ */
/* 工具：网络类型识别                                                    */
/* ------------------------------------------------------------------ */
function detectNetworkType() {
  const conn = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
  if (!conn) return "未知";
  if (conn.type === "wifi") return "Wi-Fi";
  if (conn.type === "cellular") return "Mobile";
  if (conn.type === "ethernet") return "Ethernet";
  if (conn.effectiveType) return `网络（${conn.effectiveType}）`;
  return "未知";
}

/* ------------------------------------------------------------------ */
/* 工具：WebRTC 本地 IP 探测（用于 VPN/代理启发式检测）                   */
/* ------------------------------------------------------------------ */
function detectLocalIps() {
  return new Promise((resolve) => {
    const ips = [];
    let pc;
    try {
      pc = new RTCPeerConnection({ iceServers: [] });
    } catch (_e) { resolve(ips); return; }
    try { pc.createDataChannel(""); } catch (_e) {}
    pc.createOffer().then((o) => pc.setLocalDescription(o)).catch(() => {});
    pc.onicecandidate = (e) => {
      if (!e.candidate) { try { pc.close(); } catch (_x) {} resolve(ips); return; }
      const m = /([0-9]{1,3}(?:\.[0-9]{1,3}){3})/.exec(e.candidate.candidate || "");
      if (m && !ips.includes(m[1])) ips.push(m[1]);
    };
    setTimeout(() => { try { pc.close(); } catch (_x) {} resolve(ips); }, 1500);
  });
}

function isPrivateIp(ip) {
  const parts = ip.split(".").map(Number);
  if (parts.length !== 4) return false;
  return (
    parts[0] === 10 ||
    (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
    (parts[0] === 192 && parts[1] === 168) ||
    parts[0] === 127 ||
    (parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127) // CGNAT
  );
}

/* ------------------------------------------------------------------ */
/* 测速：单次 trace 探测                                                */
/* ------------------------------------------------------------------ */
async function probeTrace(domain, timeoutMs, signal) {
  const url = `https://${domain}/cdn-cgi/trace`;
  const start = performance.now();
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs || PROBE_TIMEOUT_MS);
  const onAbort = () => ctrl.abort();
  if (signal) {
    if (signal.aborted) ctrl.abort();
    else signal.addEventListener("abort", onAbort);
  }
  try {
    const resp = await fetch(url, { signal: ctrl.signal, cache: "no-store" });
    const ttfb = performance.now() - start;
    const text = await resp.text();
    const total = performance.now() - start;
    let colo = "", loc = "", ip = "";
    for (const line of text.split("\n")) {
      if (line.startsWith("colo=")) colo = line.slice(5).trim().toUpperCase();
      else if (line.startsWith("loc=")) loc = line.slice(4).trim().toUpperCase();
      else if (line.startsWith("ip=")) ip = line.slice(3).trim();
    }
    return { ok: resp.ok, domain, ttfb, total, colo, loc, ip };
  } catch (e) {
    const total = performance.now() - start;
    return { ok: false, domain, ttfb: -1, total, colo: "", loc: "", ip: "", error: e.name || "error" };
  } finally {
    clearTimeout(timer);
    if (signal) signal.removeEventListener("abort", onAbort);
  }
}

/* ------------------------------------------------------------------ */
/* DNS-over-HTTPS 解析域名的 Edge IP（浏览器本地发起，服务器不参与）      */
/* ------------------------------------------------------------------ */
// DoH 解析：按协议查 A(IPv4) / AAAA(IPv6) / 双栈
async function resolveEdgeIps(domain, protocol, signal) {
  const types = protocol === "ipv6" ? ["AAAA"] : (protocol === "dual" ? ["A", "AAAA"] : ["A"]);
  const start = performance.now();
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 8000);
  const onAbort = () => ctrl.abort();
  if (signal) {
    if (signal.aborted) ctrl.abort();
    else signal.addEventListener("abort", onAbort);
  }
  const result = { ipv4: "", ipv6: "", ip: "", dnsMs: -1 };
  try {
    for (const t of types) {
      const url = `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(domain)}&type=${t}`;
      const resp = await fetch(url, { headers: { accept: "application/dns-json" }, cache: "no-store", signal: ctrl.signal });
      if (!resp.ok) continue;
      const data = await resp.json();
      const recs = (data.Answer || []).filter((x) => (t === "A" ? x.type === 1 : x.type === 28)).map((x) => x.data);
      if (t === "A" && recs.length) result.ipv4 = recs[0];
      if (t === "AAAA" && recs.length) result.ipv6 = recs[0];
    }
    result.dnsMs = performance.now() - start;
    result.ip = result.ipv4 || result.ipv6;
    return result;
  } catch (_e) {
    return { ipv4: "", ipv6: "", ip: "", dnsMs: -1 };
  } finally {
    clearTimeout(timer);
    if (signal) signal.removeEventListener("abort", onAbort);
  }
}

/* ------------------------------------------------------------------ */
/* 测速：下载吞吐（统一走 speed.cloudflare.com，代表到 CF 边缘的整体吞吐） */
/* ------------------------------------------------------------------ */
async function probeDownload(signal) {
  const url = `https://speed.cloudflare.com/__down?bytes=${DOWNLOAD_BYTES}`;
  const start = performance.now();
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 15000);
  const onAbort = () => ctrl.abort();
  if (signal) {
    if (signal.aborted) ctrl.abort();
    else signal.addEventListener("abort", onAbort);
  }
  try {
    const resp = await fetch(url, { signal: ctrl.signal, cache: "no-store" });
    if (!resp.ok) return { ok: false, mbps: 0, bytes: 0 };
    const buf = await resp.arrayBuffer();
    const ms = performance.now() - start;
    const bytes = buf.byteLength;
    const mbps = ms > 0 ? (bytes * 8) / (ms * 1000) : 0;
    return { ok: true, mbps, bytes, ms };
  } catch (_e) {
    return { ok: false, mbps: 0, bytes: 0 };
  } finally {
    clearTimeout(timer);
    if (signal) signal.removeEventListener("abort", onAbort);
  }
}

/* ------------------------------------------------------------------ */
/* 并发执行器                                                           */
/* ------------------------------------------------------------------ */
async function runConcurrent(items, concurrency, fn, onProgress) {
  let idx = 0;
  const workers = Array.from({ length: Math.min(concurrency, items.length || 1) }, async () => {
    while (idx < items.length) {
      if (OptimizerState.aborted) break;
      const i = idx++;
      await fn(items[i], i);
      if (onProgress) onProgress(idx);
    }
  });
  await Promise.all(workers);
}

/* ------------------------------------------------------------------ */
/* 指标计算                                                             */
/* ------------------------------------------------------------------ */
function median(values) {
  const v = values.filter((x) => Number.isFinite(x) && x >= 0).sort((a, b) => a - b);
  if (!v.length) return -1;
  const n = v.length;
  return n % 2 ? v[(n - 1) / 2] : (v[n / 2 - 1] + v[n / 2]) / 2;
}

function coefficientOfVariation(values) {
  const v = values.filter((x) => Number.isFinite(x) && x >= 0);
  if (v.length < 2) return 0;
  const avg = v.reduce((a, b) => a + b, 0) / v.length;
  if (avg <= 0) return 1;
  const sd = Math.sqrt(v.reduce((a, b) => a + (b - avg) * (b - avg), 0) / v.length);
  return sd / avg;
}

// 综合评分（0-100 加权和）：模块化引擎，按用途(mode)查权重，逐维度计算。
// 核心思想（迁移安卓 2.7.1）：稳定高速 > 低延迟但晚上炸；延迟不是唯一指标。
function computeScore(result, mode, ctx) {
  const w = SCORE_PRESETS[mode] || SCORE_PRESETS.proxy;
  let score = 0;
  for (const dim of Object.keys(w)) {
    const calc = SCORE_DIMENSIONS[dim];
    if (calc) score += calc(result, ctx) * w[dim];
  }
  return score;
}

// POP 质量评分：路由落点 colo 的运营商优先级（亚洲 POP 高分，美国 POP 低分）
function popQualityScore(pop) {
  if (!pop) return 0.2;
  const pri = popPriority(pop);
  if (pri > 0) return 0.2 + (pri / 5) * 0.8;  // HKG=1.0 / NRT=0.84 / SIN=0.68 / ICN=0.52 / TPE=0.36
  return 0.2;  // 非亚洲 POP（LAX 等）：0.2
}

// 历史表现（方案B）：最近 7 次滑动平均 + 时间衰减（7 天半衰期）；无历史 = 0.5 中性
function historyScore(domain) {
  const arr = loadHistory()[domain] || [];
  if (!arr.length) return 0.5;
  const now = Date.now();
  const recent = arr.slice(-HISTORY_N);
  let wsum = 0, sum = 0;
  for (const rec of recent) {
    const age = Math.max(0, now - (rec.t || 0));
    const w = Math.pow(0.5, age / HISTORY_HALFLIFE_MS);
    sum += (rec.s / 100) * w;
    wsum += w;
  }
  return wsum > 0 ? Math.max(0, Math.min(1, sum / wsum)) : 0.5;
}

// 历史记录：读 / 写（每域名存 {s: 评分0-100, t: 时间戳}，最多保留 20 次）
function loadHistory() {
  try { return JSON.parse(localStorage.getItem(HISTORY_KEY) || "{}"); } catch (_e) { return {}; }
}
function saveHistoryScores(results) {
  if (!results || !results.length) return;
  const hist = loadHistory();
  const now = Date.now();
  for (const m of results) {
    if (!m || !m.domain) continue;
    if (!hist[m.domain]) hist[m.domain] = [];
    hist[m.domain].push({ s: m.score != null ? m.score : 0, t: now });
    if (hist[m.domain].length > 20) hist[m.domain] = hist[m.domain].slice(-20);
  }
  try { localStorage.setItem(HISTORY_KEY, JSON.stringify(hist)); } catch (_e) {}
}

// Benchmark 核心得分（稳定连接 35 + 成功率 20，归一化到 0-1；门禁对比用）
function benchmarkCore(bm) {
  return (SCORE_DIMENSIONS.connStability(bm) * 35 + SCORE_DIMENSIONS.successRate(bm) * 20) / 55;
}

// Benchmark 测速：测 3 个黄金参考（openai/deepl/cloudflare）的连通性 + 稳定连接（不参与候选排名）
async function probeBenchmark(signal) {
  const list = [];
  for (const domain of BENCHMARK_DOMAINS) {
    if (OptimizerState.aborted) break;
    const rounds = [];
    for (let r = 0; r < ROUNDS; r++) {
      if (OptimizerState.aborted) break;
      const res = await probeTrace(domain, PROBE_TIMEOUT_MS, signal);
      rounds.push(res);
    }
    const m = buildMetrics(domain, rounds, null, "benchmark");
    m.edgeStability = await probeEdgeStability(domain, EDGE_STABILITY_ROUNDS, signal);
    m.benchmarkCore = benchmarkCore(m);
    list.push(m);
  }
  return list;
}

// 读取选择器值（带默认值兜底）
function readSelect(sel, fallback) {
  const el = $o(sel);
  return (el && el.value) ? el.value : fallback;
}

function optSleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

// Edge 复用稳定性：连续短间隔 trace（串行，100ms 间隔，复用 TCP/TLS 连接）
// 关键：不能并发，必须串行，否则浏览器会创建多个连接、无法观察连接复用效果。
async function probeEdgeStability(domain, rounds, signal) {
  const ttfbs = [];
  let success = 0;
  for (let i = 0; i < rounds; i++) {
    if (OptimizerState.aborted) break;
    const res = await probeTrace(domain, PROBE_TIMEOUT_MS, signal);
    if (res.ok && res.ttfb >= 0) { success++; ttfbs.push(res.ttfb); }
    if (i < rounds - 1) await optSleep(100);
  }
  const successRate = rounds ? success / rounds : 0;
  const avgTTFB = ttfbs.length ? ttfbs.reduce((a, b) => a + b, 0) / ttfbs.length : -1;
  return {
    successRate,
    avgTTFB,
    ttfbCV: coefficientOfVariation(ttfbs),
    samples: ttfbs.length,
  };
}

// 运营商 POP 优先级（隐藏辅助因子，仅同分 tiebreak，不覆盖测速结果）
function popRank(pop) {
  const order = OPERATOR_POP[OptimizerState.operator];
  if (order) {
    const idx = order.indexOf(pop);
    if (idx >= 0) return order.length - idx;
  }
  return popPriority(pop);
}

/* ------------------------------------------------------------------ */
/* 主流程                                                               */
/* ------------------------------------------------------------------ */
function loadCustomDomains() {
  try { return JSON.parse(localStorage.getItem(CUSTOM_DOMAINS_KEY) || "[]"); } catch (_e) { return []; }
}
function saveCustomDomains(list) {
  try { localStorage.setItem(CUSTOM_DOMAINS_KEY, JSON.stringify(list)); } catch (_e) {}
}

// 运营商检测：出口 IP 反查（浏览器本地发起，失败为"未知"）
async function detectOperator() {
  try {
    const resp = await fetch("https://ipapi.co/json/", { cache: "no-store" });
    if (!resp.ok) return "未知";
    const data = await resp.json();
    const org = data.org || "";
    if (/China Mobile|中国移动|ChinaMobile/i.test(org)) return "中国移动";
    if (/China Telecom|中国电信|ChinaTelecom/i.test(org)) return "中国电信";
    if (/China Unicom|中国联通|ChinaUnicom/i.test(org)) return "中国联通";
    return data.country_name || "未知";
  } catch (_e) { return "未知"; }
}

// 分批并发：每批 batchSize 个，批间释放资源，避免浏览器一次 1000 并发卡死
async function runBatches(items, batchSize, fn, onBatchProgress) {
  for (let i = 0; i < items.length; i += batchSize) {
    if (OptimizerState.aborted) break;
    const batch = items.slice(i, i + batchSize);
    await Promise.all(batch.map((item, j) => fn(item, i + j)));
    if (onBatchProgress) onBatchProgress(Math.min(i + batchSize, items.length));
  }
}

// 由多轮 trace 结果构造 metrics（成功率/中位 TTFB/中位响应/波动/DNS）
function buildMetrics(domain, roundsData, dnsRes, source) {
  const okRounds = roundsData.filter((r) => r.ok);
  const ttfbs = okRounds.map((r) => r.ttfb);
  const totals = okRounds.map((r) => r.total);
  const colo = okRounds.find((r) => r.colo)?.colo || "";
  const loc = okRounds.find((r) => r.loc)?.loc || "";
  const ip = dnsRes && dnsRes.ip ? dnsRes.ip : (okRounds.find((r) => r.ip)?.ip || "");
  return {
    domain,
    colo,
    loc,
    source,
    ips: ip ? [ip] : [],
    ipv4: dnsRes ? (dnsRes.ipv4 || "") : "",
    ipv6: dnsRes ? (dnsRes.ipv6 || "") : "",
    roundsData,
    rounds: roundsData.length,
    medianTtfb: median(ttfbs),
    medianTotal: median(totals),
    cv: coefficientOfVariation(ttfbs),
    successRate: roundsData.length ? okRounds.length / roundsData.length : 0,
    dnsMs: dnsRes ? dnsRes.dnsMs : -1,
  };
}

// 实时 POP 统计（Stage 1 探测中显示，避免用户误认为卡死）
function updatePopLive() {
  const el = $o("#optimizer-pop-live");
  if (!el) return;
  const entries = Object.entries(OptimizerState.popCount || {})
    .sort((a, b) => b[1] - a[1])
    .slice(0, 8);
  el.textContent = entries.length
    ? entries.map(([pop, n]) => `${pop} ${n}`).join(" · ")
    : "探测中…";
}


async function optimizerStart() {
  if (OptimizerState.running) return;
  OptimizerState.running = true;
  OptimizerState.aborted = false;
  OptimizerState.controller = new AbortController();
  OptimizerState.results = [];
  OptimizerState.asiaResults = [];
  OptimizerState.ipv4Results = [];
  OptimizerState.ipv6Results = [];
  OptimizerState.egressChanged = false;
  OptimizerState.vpnDetected = false;
  OptimizerState.networkType = detectNetworkType();
  OptimizerState.popCount = {};

  // 读用户选择：用途 / 协议 / 测速模式 / 运营商
  const mode = readSelect("#optimizer-use", "proxy");
  const protocol = readSelect("#optimizer-protocol", "dual");
  const huntMode = readSelect("#optimizer-mode", "balanced");
  const operatorManual = readSelect("#optimizer-operator", "auto");
  OptimizerState.use = mode;
  OptimizerState.protocol = protocol;
  OptimizerState.mode = huntMode;
  OptimizerState.operatorManual = operatorManual;

  const startBtn = $o("#optimizer-start");
  const stopBtn = $o("#optimizer-stop");
  startBtn.disabled = true;
  stopBtn.classList.remove("hidden");
  hideEl("#optimizer-best");
  hideEl("#optimizer-recommendation");
  hideEl("#optimizer-benchmark");
  hideEl("#optimizer-asia");
  hideEl("#optimizer-results");
  showEl("#optimizer-progress-wrap");
  $o("#optimizer-net-banner").classList.add("hidden");
  setProgress(0, "准备中…");

  try {
    // 0) 候选域名 = 内置 1000 域名池 + 用户扩展池
    setProgress(4, "读取候选域名池…");
    const custom = loadCustomDomains();
    const allDomains = [];
    const seen = new Set();
    OPTIMIZER_DOMAINS.forEach((d) => { if (!seen.has(d)) { allDomains.push({ domain: d, source: "pool" }); seen.add(d); } });
    custom.forEach((d) => { if (d && !seen.has(d)) { allDomains.push({ domain: d, source: "custom" }); seen.add(d); } });
    const blacklist = new Set(loadBlacklist());
    const candidates = allDomains.filter((c) => !blacklist.has(c.domain));
    if (!candidates.length) {
      setProgress(100, "无可用候选域名");
      toast("候选域名池为空，请检查后重试。", true);
      return;
    }
    const total = candidates.length;

    // 1) 出口 IP 基线 + 运营商（自动或手动）+ VPN 启发式检测
    setProgress(6, "检测网络环境…");
    const baseline = await probeTrace(candidates[0].domain, PROBE_TIMEOUT_MS, OptimizerState.controller.signal);
    OptimizerState.egressIp = baseline.ip || "";
    OptimizerState.operator = operatorManual === "auto" ? await detectOperator() : operatorManual;
    const localIps = await detectLocalIps();
    const publicLocal = localIps.filter((ip) => !isPrivateIp(ip));
    if (publicLocal.length && baseline.ip && !publicLocal.includes(baseline.ip)) {
      OptimizerState.vpnDetected = true;
    }
    if (OptimizerState.vpnDetected) showVpnBanner();

    // 1.5) CF 环境吞吐基准：一次测速，所有候选共享（proxy/download 需要，避免 1000 域名×下载耗流量）
    let dl = { ok: false, mbps: 0, bytes: 0 };
    if (mode === "proxy" || mode === "download") {
      setProgress(7, "测试 CF 环境吞吐基准…");
      dl = await probeDownload(OptimizerState.controller.signal);
    }
    // 1.6) Benchmark 黄金参考（仅 proxy 模式，用于门禁对比，不参与候选排名）
    let benchmarks = [];
    if (mode === "proxy") {
      setProgress(7, "测试黄金参考 openai/deepl/cloudflare…");
      benchmarks = await probeBenchmark(OptimizerState.controller.signal);
    }

    // 2) Stage 1：轻量探测（batch 50/批，/cdn-cgi/trace 短超时，过滤失败）
    setProgress(8, `Stage 1 轻量探测 0/${total}…`);
    const stage1 = [];
    await runBatches(candidates, BATCH_SIZE, async (cand) => {
      const res = await probeTrace(cand.domain, STAGE1_TIMEOUT_MS, OptimizerState.controller.signal);
      if (res.ok && res.ttfb >= 0) {
        stage1.push({ domain: cand.domain, source: cand.source, ttfb: res.ttfb, total: res.total, colo: res.colo, loc: res.loc, ip: res.ip });
        const pop = res.colo || "OTHER";
        OptimizerState.popCount[pop] = (OptimizerState.popCount[pop] || 0) + 1;
      }
    }, (done) => {
      setProgress(8 + Math.floor((done / total) * 37), `Stage 1 轻量探测 ${done}/${total}`);
      updatePopLive();
    });

    if (OptimizerState.aborted) { setProgress(100, "已停止"); toast("测速已停止。"); return; }
    if (!stage1.length) {
      setProgress(100, "无有效域名");
      toast("Stage 1 探测无有效域名，请检查网络后重试。", true);
      return;
    }

    // 存活域名按 TTFB 排序，取 TOP STAGE2_COUNT（100~200）
    stage1.sort((a, b) => a.ttfb - b.ttfb);
    const stage2List = stage1.slice(0, STAGE2_COUNT);

    // 3) Stage 2：小流量测速（每域名自身资源多次请求 + DoH 按协议解析 IPv4/IPv6）
    const perDomain = {};
    setProgress(46, `Stage 2 小流量测速 0/${stage2List.length}…`);
    await runConcurrent(stage2List, CONCURRENCY, async (item) => {
      const domain = item.domain;
      const dnsRes = await resolveEdgeIps(domain, protocol, OptimizerState.controller.signal);
      const roundsData = [item]; // Stage 1 结果作为第 1 轮
      for (let r = 1; r < 2; r++) { // 再测 1 次，共 2 次
        if (OptimizerState.aborted) break;
        const res = await probeTrace(domain, STAGE2_TIMEOUT_MS, OptimizerState.controller.signal);
        roundsData.push(res);
      }
      perDomain[domain] = buildMetrics(domain, roundsData, dnsRes, item.source);
    }, (n) => {
      setProgress(46 + Math.floor((n / stage2List.length) * 20), `Stage 2 小流量测速 ${n}/${stage2List.length}…`);
    });

    if (OptimizerState.aborted) { setProgress(100, "已停止"); toast("测速已停止。"); return; }

    // Stage 2 粗评分 → TOP FINAL_COUNT
    const stage2Scored = Object.values(perDomain)
      .filter((m) => m.rounds > 0)
      .map((m) => { m.score = computeScore(m, mode, { dl }); return m; })
      .sort((a, b) => b.score - a.score);
    const finalists = stage2Scored.slice(0, FINAL_COUNT);
    if (!finalists.length) {
      setProgress(100, "Stage 2 无有效结果");
      toast("Stage 2 未筛选出有效域名。", true);
      return;
    }

    // 4) Stage 3：深度测试（TOP 20 补测到 ROUNDS 次；仅 proxy 模式额外做 Edge 稳定性）
    setProgress(68, `Stage 3 深度测试 0/${finalists.length}…`);
    await runConcurrent(finalists, CONCURRENCY, async (m) => {
      while (m.rounds < ROUNDS) {
        if (OptimizerState.aborted) break;
        const res = await probeTrace(m.domain, PROBE_TIMEOUT_MS, OptimizerState.controller.signal);
        m.roundsData.push(res);
        m.rounds++;
        if (res.ok && res.ip && OptimizerState.egressIp && res.ip !== OptimizerState.egressIp) {
          OptimizerState.egressChanged = true;
        }
      }
      // proxy 模式：Edge 复用稳定性（连续串行 trace，不复用 roundsData，避免覆盖原 trace）
      if (mode === "proxy") {
        m.edgeStability = await probeEdgeStability(m.domain, EDGE_STABILITY_ROUNDS, OptimizerState.controller.signal);
      }
      const es = m.edgeStability;
      const rebuilt = buildMetrics(m.domain, m.roundsData, { ip: m.ips[0] || "", ipv4: m.ipv4, ipv6: m.ipv6, dnsMs: m.dnsMs }, m.source);
      Object.assign(m, rebuilt);
      m.edgeStability = es;
    }, (n) => {
      setProgress(68 + Math.floor((n / finalists.length) * 14), `Stage 3 深度测试 ${n}/${finalists.length}…`);
    });

    if (OptimizerState.aborted) { setProgress(100, "已停止"); toast("测速已停止。"); return; }

    // 5) 最终评分 + 失败惩罚 + tiebreak 排序
    setProgress(90, "计算综合评分…");
    const results = finalists.map((m) => { m.score = computeScore(m, mode, { dl }); return m; });
    const blist = loadBlacklist();
    results.forEach((m) => {
      if (m.successRate === 0 && !blist.includes(m.domain)) blist.push(m.domain);
    });
    saveBlacklist(blist);
    // 主评分排序；同分时按运营商 POP 优先级 tiebreak（隐藏辅助因子，不覆盖测速结果）
    results.sort((a, b) => {
      const diff = b.score - a.score;
      if (Math.abs(diff) > 0.01) return diff;
      return popRank(b.colo) - popRank(a.colo);
    });
    OptimizerState.results = results;
    // 双栈：按 DNS 记录分类，IPv4/IPv6 各自独立排名，互不覆盖
    OptimizerState.ipv4Results = results.filter((m) => m.ipv4);
    OptimizerState.ipv6Results = results.filter((m) => m.ipv6);
    OptimizerState.asiaResults = results.filter((m) => isAsiaTarget(m.colo));

    // 5.5) Benchmark 门禁：推荐核心 vs 黄金参考中位数（仅 proxy 模式）
    let benchmarkMedian = -1;
    let gateAllowed = true;
    if (mode === "proxy" && benchmarks.length) {
      const cores = benchmarks.map((bm) => bm.benchmarkCore).filter((c) => Number.isFinite(c) && c >= 0);
      if (cores.length) {
        benchmarkMedian = median(cores);
        const candidateCore = benchmarkCore(results[0]);
        gateAllowed = benchmarkMedian < 0 || candidateCore >= benchmarkMedian * BENCHMARK_GATE;
      }
    }

    // 6) 渲染 + 推荐理由 + 保存
    renderBest(results[0], dl);
    renderBenchmarkCompare(results[0], benchmarks, benchmarkMedian, gateAllowed);
    renderRecommendation(results[0], dl, gateAllowed);
    renderAsiaHunt(OptimizerState.asiaResults);
    renderResults(results, dl, total, stage1.length, stage2List.length);
    saveLocal(results[0], dl);
    saveHistoryScores(results);
    setProgress(100, "完成");

    if (OptimizerState.egressChanged) {
      toast("⚠ 测速过程中出口 IP 发生变化（网络不稳定），结果仅供参考。", true);
    }
  } catch (e) {
    if (OptimizerState.aborted || (e && e.name === "AbortError")) {
      setProgress(100, "已停止");
      toast("测速已停止。");
    } else {
      setProgress(100, "出错");
      toast("测速出错：" + (e && e.message ? e.message : "未知错误"), true);
    }
  } finally {
    OptimizerState.running = false;
    OptimizerState.controller = null;
    startBtn.disabled = false;
    stopBtn.classList.add("hidden");
  }
}

function optimizerStop() {
  if (!OptimizerState.running) return;
  OptimizerState.aborted = true;
  if (OptimizerState.controller) {
    try { OptimizerState.controller.abort(); } catch (_e) {}
  }
}

/* ------------------------------------------------------------------ */
/* 渲染                                                                */
/* ------------------------------------------------------------------ */
function setProgress(pct, text) {
  const fill = $o("#optimizer-progress-fill");
  const txt = $o("#optimizer-progress-text");
  if (fill) fill.style.width = `${Math.max(0, Math.min(100, pct))}%`;
  if (txt) txt.textContent = text;
}

function showEl(sel) { const el = $o(sel); if (el) el.classList.remove("hidden"); }
function hideEl(sel) { const el = $o(sel); if (el) el.classList.add("hidden"); }

function showVpnBanner() {
  const banner = $o("#optimizer-net-banner");
  banner.classList.remove("hidden");
  banner.className = "optimizer-banner warning";
  banner.innerHTML = `
    <span class="bf-icon">⚠</span>
    <div>
      <b>检测到 VPN 或代理环境。</b>
      <p>为了获得准确的 Cloudflare Edge 优选结果，请关闭 VPN / V2ray / Clash / 系统代理 / 加速器后重新测试。当前结果可能无效。</p>
      <button id="optimizer-redetect" class="button ghost">重新检测</button>
    </div>`;
  const btn = $o("#optimizer-redetect");
  if (btn) btn.addEventListener("click", () => optimizerStart());
}

// 渲染单个候选卡（IPv4 / IPv6）
function renderCandidateCard(label, m) {
  if (!m) return `<div class="opt-candidate-empty">${label}：无可用候选（DNS 无对应记录）</div>`;
  const ip = label === "IPv6" ? (m.ipv6 || "—") : (m.ipv4 || "—");
  const ttfb = m.medianTtfb >= 0 ? `${m.medianTtfb.toFixed(0)} ms` : "—";
  const stability = m.cv >= 0 ? `${(100 - Math.min(100, m.cv * 100)).toFixed(0)}%` : "—";
  const score = m.score != null ? `${m.score.toFixed(1)}` : "—";
  const availability = `${(m.successRate * 100).toFixed(0)}%`;
  const operator = OptimizerState.operator || "未知";
  const sourceLabel = m.source === "custom" ? "扩展池" : "内置池";
  const useLabel = USE_LABELS[OptimizerState.use] || "代理节点";
  return `
    <div class="opt-candidate">
      <div class="opt-candidate-head"><span class="eyebrow">BEST ${label} CANDIDATE</span></div>
      <div class="opt-best-grid">
        <div class="opt-best-main"><label>入口域名</label><strong>${escapeHtmlO(m.domain)}</strong></div>
        <div class="opt-best-main"><label>综合评分</label><strong class="opt-score">${score}<small class="opt-score-max">/100</small></strong></div>
        <div class="opt-best-item"><label>${label} 地址</label><strong class="opt-mono opt-ip">${escapeHtmlO(ip)}</strong></div>
        <div class="opt-best-item"><label>POP</label><strong>${escapeHtmlO(m.colo || "—")}</strong></div>
        <div class="opt-best-item"><label>用途</label><strong>${useLabel}</strong></div>
        <div class="opt-best-item"><label>运营商</label><strong>${escapeHtmlO(operator)}</strong></div>
        <div class="opt-best-item"><label>来源</label><strong>${sourceLabel}</strong></div>
        <div class="opt-best-item"><label>TTFB</label><strong>${ttfb}</strong></div>
        <div class="opt-best-item"><label>成功率</label><strong>${availability}</strong></div>
        <div class="opt-best-item"><label>稳定性</label><strong>${stability}</strong></div>
      </div>
    </div>`;
}

function renderBest(best, dl) {
  if (!best) return;
  const box = $o("#optimizer-best");
  box.classList.remove("hidden");
  const protocol = OptimizerState.protocol;
  const unstable = OptimizerState.egressChanged ? " · 网络不稳定" : "";
  if (protocol === "dual") {
    const ipv4Best = OptimizerState.ipv4Results[0];
    const ipv6Best = OptimizerState.ipv6Results[0];
    box.innerHTML = `
      <div class="opt-best-head"><span class="eyebrow">BEST CLOUDFLARE EDGE</span><span class="opt-best-unstable">${unstable}</span></div>
      <p class="opt-dual-hint">按 DNS 记录分类，评分来自当前浏览器实际出口；IPv4 与 IPv6 各自独立排名，互不覆盖。</p>
      <div class="opt-dual-grid">
        ${renderCandidateCard("IPv4", ipv4Best)}
        ${renderCandidateCard("IPv6", ipv6Best)}
      </div>`;
  } else {
    const label = protocol === "ipv6" ? "IPv6" : "IPv4";
    const m = protocol === "ipv6" ? (OptimizerState.ipv6Results[0] || best) : (OptimizerState.ipv4Results[0] || best);
    box.innerHTML = `
      <div class="opt-best-head"><span class="eyebrow">BEST CLOUDFLARE EDGE</span><span class="opt-best-unstable">${unstable}</span></div>
      ${renderCandidateCard(label, m)}`;
  }
}

// Benchmark 黄金参考对比 + 门禁结果
function renderBenchmarkCompare(best, benchmarks, benchmarkMedian, gateAllowed) {
  const box = $o("#optimizer-benchmark");
  if (!box) return;
  if (OptimizerState.use !== "proxy") { box.classList.add("hidden"); return; }
  box.classList.remove("hidden");
  const candidateCore = benchmarkCore(best);
  const ratio = benchmarkMedian > 0 ? Math.round((candidateCore / benchmarkMedian) * 100) : -1;
  const rows = benchmarks.map((bm) => {
    const core = bm.benchmarkCore != null ? `${(bm.benchmarkCore * 100).toFixed(0)}%` : "—";
    const sr = `${(bm.successRate * 100).toFixed(0)}%`;
    return `<tr><td>${escapeHtmlO(bm.domain)}</td><td>${escapeHtmlO(bm.colo || "—")}</td><td>${sr}</td><td>${core}</td></tr>`;
  }).join("");
  const gateHtml = gateAllowed
    ? `<div class="opt-gate opt-gate-pass">✓ 推荐入口核心稳定性达到黄金参考基准，可作为代理入口</div>`
    : `<div class="opt-gate opt-gate-fail">✗ 推荐入口核心稳定性低于黄金参考基准（${(benchmarkMedian * 100).toFixed(0)}%），当前网络下不建议作为代理入口</div>`;
  box.innerHTML = `
    <article class="panel glass">
      <div class="panel-head"><div><span class="eyebrow">BENCHMARK</span><h3>黄金参考对比</h3><p>推荐入口 vs openai.com / deepl.com / cloudflare.com 稳定性基准（核心 = 稳定连接 + 成功率）</p></div></div>
      <div class="table-scroll"><table class="data-table">
        <thead><tr><th>参考域名</th><th>POP</th><th>成功率</th><th>核心稳定性</th></tr></thead>
        <tbody>${rows || '<tr><td colspan="4">无黄金参考数据</td></tr>'}</tbody>
      </table></div>
      <div class="opt-bench-summary">
        <div class="opt-bench-item"><label>推荐入口核心</label><strong>${(candidateCore * 100).toFixed(0)}%</strong></div>
        <div class="opt-bench-item"><label>黄金基准中位数</label><strong>${benchmarkMedian >= 0 ? (benchmarkMedian * 100).toFixed(0) + "%" : "—"}</strong></div>
        <div class="opt-bench-item"><label>性能比</label><strong>${ratio >= 0 ? ratio + "%" : "—"}</strong></div>
      </div>
      ${gateHtml}
    </article>`;
}

function renderRecommendation(best, dl, gateAllowed) {
  if (!best) return;
  const box = $o("#optimizer-recommendation");
  if (!box) return;
  box.classList.remove("hidden");
  const mode = OptimizerState.use;
  const ttfb = best.medianTtfb >= 0 ? `${best.medianTtfb.toFixed(0)} ms` : "—";
  const successN = Math.round(best.successRate * (best.rounds || ROUNDS));
  const reasons = [];
  if (best.colo) {
    if (popPriority(best.colo) > 0) reasons.push(`${best.colo} 亚洲入口（${OptimizerState.operator || "默认"}优先级高）`);
    else reasons.push(`${best.colo} 入口`);
  }
  if (mode === "proxy") {
    const es = best.edgeStability;
    if (es && es.samples) {
      reasons.push(`稳定连接 ${(es.successRate * 100).toFixed(0)}%（连续 ${es.samples} 次复用连接）`);
      if (es.ttfbCV < 0.3) reasons.push("TTFB 波动小（连接稳定）");
      else reasons.push("TTFB 波动较大（连接可能频繁重建）");
    }
    if (dl && dl.ok) reasons.push(`CF 环境吞吐 ${dl.mbps.toFixed(1)} Mbps（参考）`);
  } else {
    if (best.medianTtfb >= 0 && best.medianTtfb < 300) reasons.push(`低 TTFB ${ttfb}`);
  }
  reasons.push(`连续测试 ${successN}/${best.rounds || ROUNDS} 成功`);
  if (best.cv >= 0) {
    if (best.cv < 0.3) reasons.push("速度稳定（波动小）");
    else reasons.push("波动较大，晚间可能不稳定");
  }
  const gateWarn = (mode === "proxy" && gateAllowed === false)
    ? `<div class="opt-gate opt-gate-fail">⚠ 该入口核心稳定性低于黄金参考基准，当前网络下不建议作为代理入口（详见「黄金参考对比」）。</div>`
    : "";
  box.innerHTML = `
    <article class="panel glass">
      <div class="panel-head"><div><span class="eyebrow">WHY</span><h3>推荐理由</h3><p>用途：${USE_LABELS[mode] || "代理节点"}</p></div></div>
      ${gateWarn}
      <div class="opt-reason-list">
        ${reasons.map((r) => `<div class="opt-reason-item">${escapeHtmlO(r)}</div>`).join("")}
      </div>
    </article>`;
}

function renderResults(results, dl, totalDomains, aliveCount, stage2Count) {
  const wrap = $o("#optimizer-results");
  wrap.classList.remove("hidden");
  const tbody = results.map((m, i) => {
    const ip = m.ips && m.ips[0] ? m.ips[0] : "—";
    const ttfb = m.medianTtfb >= 0 ? `${m.medianTtfb.toFixed(0)} ms` : "—";
    const speed = m.medianTotal >= 0 ? `${m.medianTotal.toFixed(0)} ms` : "—";
    const sr = `${(m.successRate * 100).toFixed(0)}%`;
    const sc = m.score != null ? m.score.toFixed(1) : "—";
    const src = m.source === "custom" ? "扩展" : "内置";
    return `<tr>
      <td>${i + 1}</td>
      <td>${escapeHtmlO(m.domain)}</td>
      <td>${src}</td>
      <td>${escapeHtmlO(m.colo || "—")}</td>
      <td class="opt-mono">${escapeHtmlO(ip)}</td>
      <td>${ttfb}</td>
      <td>${speed}</td>
      <td>${sr}</td>
      <td><strong>${sc}</strong></td>
    </tr>`;
  }).join("");
  const wtxt = USE_WEIGHT_TEXT[OptimizerState.use] || USE_WEIGHT_TEXT.proxy;
  const scope = `${totalDomains} 个候选 → Stage 1 存活 ${aliveCount} → Stage 2 精选 ${stage2Count} → TOP ${results.length}（${wtxt}）`;
  wrap.innerHTML = `
    <article class="panel glass">
      <div class="panel-head"><div><span class="eyebrow">RANKING</span><h3>CF Edge 入口排名</h3><p>${escapeHtmlO(scope)}</p></div><small>CF 出口吞吐：${dl && dl.ok ? dl.mbps.toFixed(1) + " Mbps" : "—"}</small></div>
      <div class="table-scroll"><table class="data-table">
        <thead><tr><th>#</th><th>入口域名</th><th>来源</th><th>POP</th><th>解析 Edge</th><th>TTFB</th><th>响应速度</th><th>成功率</th><th>评分</th></tr></thead>
        <tbody>${tbody || '<tr><td colspan="9">无有效结果</td></tr>'}</tbody>
      </table></div>
    </article>`;
}

function renderAsiaHunt(asia) {
  const box = $o("#optimizer-asia");
  if (!box) return;
  box.classList.remove("hidden");
  if (!asia.length) {
    box.innerHTML = '<article class="panel glass"><div class="panel-head"><div><span class="eyebrow">ASIA HUNT</span><h3>亚洲入口狩猎</h3></div></div><p class="form-hint">本次未发现命中亚洲入口（HKG/NRT/SIN/ICN/TPE）的候选域名，可能是当前网络环境未就近接入亚洲 Cloudflare 边缘。</p></article>';
    return;
  }
  const rows = asia.slice(0, 12).map((m, i) => {
    const ip = m.ips && m.ips[0] ? m.ips[0] : "—";
    const ttfb = m.medianTtfb >= 0 ? `${m.medianTtfb.toFixed(0)} ms` : "—";
    const pri = popPriority(m.colo);
    return `<tr>
      <td>${i + 1}</td>
      <td><span class="opt-pop opt-pop-${pri}">${escapeHtmlO(m.colo || "—")}</span></td>
      <td>${escapeHtmlO(m.domain)}</td>
      <td class="opt-mono">${escapeHtmlO(ip)}</td>
      <td>${ttfb}</td>
      <td>${(m.successRate * 100).toFixed(0)}%</td>
    </tr>`;
  }).join("");
  box.innerHTML = `
    <article class="panel glass">
      <div class="panel-head"><div><span class="eyebrow">ASIA HUNT</span><h3>亚洲入口狩猎（HKG·NRT·SIN·ICN·TPE）</h3><p>按亚洲入口价值排序，专为亚洲网络环境优选低延迟 Cloudflare 边缘入口</p></div></div>
      <div class="table-scroll"><table class="data-table">
        <thead><tr><th>#</th><th>POP</th><th>域名</th><th>Edge IP</th><th>TTFB</th><th>成功率</th></tr></thead>
        <tbody>${rows}</tbody>
      </table></div>
    </article>`;
}

/* ------------------------------------------------------------------ */
/* 失败惩罚 + 黑名单                                                    */
/* ------------------------------------------------------------------ */
function loadBlacklist() {
  try { return JSON.parse(localStorage.getItem(BLACKLIST_KEY) || "[]"); } catch (_e) { return []; }
}
function saveBlacklist(list) {
  try { localStorage.setItem(BLACKLIST_KEY, JSON.stringify(list)); } catch (_e) {}
}

/* ------------------------------------------------------------------ */
/* localStorage                                                        */
/* ------------------------------------------------------------------ */
function saveLocal(best, dl) {
  if (!best) return;
  const record = {
    best_domain: best.domain,
    best_ip: best.ips && best.ips[0] ? best.ips[0] : "",
    pop: best.colo || "",
    loc: best.loc || "",
    score: best.score != null ? Math.round(best.score * 10) / 10 : -1,
    latency: best.medianTtfb >= 0 ? Math.round(best.medianTtfb) : -1,
    speed: dl && dl.ok ? Math.round(dl.mbps * 10) / 10 : -1,
    last_success: new Date().toISOString(),
    network: OptimizerState.networkType,
    vpn_detected: !!OptimizerState.vpnDetected,
    unstable: !!OptimizerState.egressChanged,
  };
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(record));
  } catch (_e) { /* 隐私模式等场景忽略 */ }
  renderHistory(record);
}

function loadLocal() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch (_e) { return null; }
}

function renderHistory(record) {
  const box = $o("#optimizer-history");
  if (!box) return;
  const rec = record || loadLocal();
  if (!rec) {
    box.innerHTML = '<p class="form-hint">暂无历史优选结果，点击「开始本地测速」生成第一个记录。</p>';
    return;
  }
  const when = (rec.last_success || rec.timestamp) ? new Date(rec.last_success || rec.timestamp).toLocaleString("zh-CN", { hour12: false }) : "—";
  const lat = rec.latency >= 0 ? `${rec.latency} ms` : "—";
  const spd = rec.speed >= 0 ? `${rec.speed} Mbps` : "—";
  const sc = rec.score >= 0 ? `${rec.score}` : "—";
  box.innerHTML = `
    <article class="panel glass">
      <div class="panel-head"><div><span class="eyebrow">LAST RESULT</span><h3>历史最佳入口（本机保存）</h3></div><small>${escapeHtmlO(when)}</small></div>
      <div class="opt-hist-grid">
        <div class="opt-hist-item"><label>Best Domain</label><strong>${escapeHtmlO(rec.best_domain || "—")}</strong></div>
        <div class="opt-hist-item"><label>综合评分</label><strong class="opt-score">${sc}</strong></div>
        <div class="opt-hist-item"><label>Best Edge IP</label><strong class="opt-mono">${escapeHtmlO(rec.best_ip || "—")}</strong></div>
        <div class="opt-hist-item"><label>POP / 地区</label><strong>${escapeHtmlO(rec.pop || "—")}${rec.loc ? " · " + escapeHtmlO(rec.loc) : ""}</strong></div>
        <div class="opt-hist-item"><label>TTFB</label><strong>${lat}</strong></div>
        <div class="opt-hist-item"><label>Speed</label><strong>${spd}</strong></div>
        <div class="opt-hist-item"><label>网络</label><strong>${escapeHtmlO(rec.network || "—")}${rec.vpn_detected ? " · VPN" : ""}${rec.unstable ? " · 不稳定" : ""}</strong></div>
      </div>
    </article>`;
}

/* ------------------------------------------------------------------ */
/* 入口                                                                */
/* ------------------------------------------------------------------ */
function optimizerOnEnter() {
  renderHistory();
  const box = $o("#optimizer-traffic-hint");
  if (box) {
    box.innerHTML = `三级筛选：<b>Stage 1</b> 对约 ${OPTIMIZER_DOMAINS.length} 个内置 CF 域名做轻量探测（${BATCH_SIZE}/批并发），<b>Stage 2</b> 对存活域名测自身资源响应速度，<b>Stage 3</b> 对 TOP ${FINAL_COUNT} 连续深度测试。全程在浏览器本地完成，服务器不参与测速、不上传任何数据。`;
  }
  const input = $o("#optimizer-custom-input");
  if (input) {
    input.value = loadCustomDomains().join("\n");
  }
}

function optimizerOnLeave() {
  if (OptimizerState.running) optimizerStop();
}

function optimizerInit() {
  const startBtn = $o("#optimizer-start");
  const stopBtn = $o("#optimizer-stop");
  if (startBtn) startBtn.addEventListener("click", optimizerStart);
  if (stopBtn) stopBtn.addEventListener("click", optimizerStop);
  const saveBtn = $o("#optimizer-custom-save");
  if (saveBtn) {
    saveBtn.addEventListener("click", () => {
      const input = $o("#optimizer-custom-input");
      if (!input) return;
      const list = input.value.split("\n").map((s) => s.trim()).filter(Boolean);
      saveCustomDomains(list);
      if (typeof toast === "function") toast(`已保存 ${list.length} 个自定义候选域名。`);
    });
  }
}

// 暴露给 app.js 的 setView 调用
window.OptimizerModule = {
  enter: optimizerOnEnter,
  leave: optimizerOnLeave,
  init: optimizerInit,
};

// 页面加载即绑定事件（DOMContentLoaded 后由 app.js 触发，这里兜底）
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", optimizerInit);
} else {
  optimizerInit();
}
