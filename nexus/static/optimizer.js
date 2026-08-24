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
  results: [],           // 决赛域名聚合结果
  egressIp: "",          // 首次 trace 检测到的出口 IP
  egressChanged: false,  // 测速过程中出口 IP 是否变化
  vpnDetected: false,    // 是否检测到 VPN/代理特征
  networkType: "",       // WiFi / Mobile / ...
  rounds: 3,             // 决赛域名精确测速轮次
};

// POP 权重：亚洲入口偏好，仅作软偏好，最终由实际测速结果主导。
const POP_WEIGHT = {
  HKG: 1.00, NRT: 0.95, SIN: 0.95, ICN: 0.90, TPE: 0.88,
  KIX: 0.85, NGO: 0.85, FUK: 0.85, SEA: 0.75, LAX: 0.70, SJC: 0.70,
};
const POP_WEIGHT_DEFAULT = 0.65;

// 分层测速常量（对齐 Android Pipeline.kt 的 micro → full）
const BASELINE_DOMAIN = "www.nexusmods.com"; // 基准域名（必进决赛）
const FINAL_DOMAINS = 20;      // 决赛域名数（对齐 Android finalDomains 慢档）
const MICRO_CONCURRENCY = 25;  // 筛选阶段并发
const MICRO_TIMEOUT_MS = 3500; // 筛选阶段短超时（快速淘汰慢域名）
const CONCURRENCY = 8;         // 精确测速阶段并发
const PROBE_TIMEOUT_MS = 8000; // 精确测速超时
const DOWNLOAD_BYTES = 2 * 1024 * 1024; // 下载测速 2MB
const STORAGE_KEY = "rr_edge_optimizer";

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
async function resolveEdgeIp(domain, signal) {
  const url = `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(domain)}&type=A`;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 8000);
  const onAbort = () => ctrl.abort();
  if (signal) {
    if (signal.aborted) ctrl.abort();
    else signal.addEventListener("abort", onAbort);
  }
  try {
    const resp = await fetch(url, { headers: { accept: "application/dns-json" }, cache: "no-store", signal: ctrl.signal });
    if (!resp.ok) return "";
    const data = await resp.json();
    const a = (data.Answer || []).filter((x) => x.type === 1).map((x) => x.data);
    return a[0] || "";
  } catch (_e) {
    return "";
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

// Edge Score = Speed × Stability × Success Rate × POP Weight
function computeEdgeScore(metrics) {
  const ttfb = metrics.medianTtfb;
  const speedScore = ttfb < 0 ? 0.05 : Math.max(0.05, Math.min(1, 1 - ttfb / 800));
  const stabilityScore = Math.max(0.05, Math.min(1, 1 - metrics.cv));
  const successRate = Math.max(0.05, metrics.successRate);
  const popWeight = metrics.colo ? (POP_WEIGHT[metrics.colo] || POP_WEIGHT_DEFAULT) : POP_WEIGHT_DEFAULT;
  return speedScore * stabilityScore * successRate * popWeight;
}

/* ------------------------------------------------------------------ */
/* 主流程                                                               */
/* ------------------------------------------------------------------ */
function loadDomains() {
  OptimizerState.domains = OPTIMIZER_DOMAINS.slice();
  return OptimizerState.domains;
}

async function optimizerStart() {
  if (OptimizerState.running) return;
  OptimizerState.running = true;
  OptimizerState.aborted = false;
  OptimizerState.controller = new AbortController();
  OptimizerState.results = [];
  OptimizerState.egressChanged = false;
  OptimizerState.vpnDetected = false;
  OptimizerState.networkType = detectNetworkType();

  const startBtn = $o("#optimizer-start");
  const stopBtn = $o("#optimizer-stop");
  startBtn.disabled = true;
  stopBtn.classList.remove("hidden");
  hideEl("#optimizer-best");
  hideEl("#optimizer-results");
  showEl("#optimizer-progress-wrap");
  $o("#optimizer-net-banner").classList.add("hidden");
  setProgress(0, "准备中…");

  try {
    // 0) 加载候选域名池（内嵌，无需请求服务器）
    if (!OptimizerState.domains.length) {
      loadDomains();
    }
    if (!OptimizerState.domains.length) {
      setProgress(100, "无可用候选域名");
      toast("未获取到候选域名，请检查网络后重试。", true);
      return;
    }
    const total = OptimizerState.domains.length;

    // 1) 出口 IP 基线 + VPN 启发式检测
    setProgress(4, "检测网络环境…");
    const baseline = await probeTrace(BASELINE_DOMAIN, PROBE_TIMEOUT_MS, OptimizerState.controller.signal);
    OptimizerState.egressIp = baseline.ip || "";
    const localIps = await detectLocalIps();
    const publicLocal = localIps.filter((ip) => !isPrivateIp(ip));
    if (publicLocal.length && baseline.ip && !publicLocal.includes(baseline.ip)) {
      OptimizerState.vpnDetected = true;
    }
    if (OptimizerState.vpnDetected) {
      showVpnBanner();
    }

    // 2) 第一阶段：小流量快速筛选（全部候选域名 × 1 轮）
    setProgress(8, `第一阶段 · 快速筛选 0/${total} 域名…`);
    const micro = {}; // domain -> { ttfb, colo }
    await runConcurrent(OptimizerState.domains, MICRO_CONCURRENCY, async (domain) => {
      const res = await probeTrace(domain, MICRO_TIMEOUT_MS, OptimizerState.controller.signal);
      if (res.ok && res.ttfb >= 0) {
        micro[domain] = { ttfb: res.ttfb, colo: res.colo };
      }
      if (res.ok && res.ip && OptimizerState.egressIp && res.ip !== OptimizerState.egressIp) {
        OptimizerState.egressChanged = true;
      }
    }, (n) => {
      setProgress(8 + Math.floor((n / total) * 47), `第一阶段 · 快速筛选 ${n}/${total} 域名…`);
    });

    if (OptimizerState.aborted) {
      setProgress(100, "已停止");
      toast("测速已停止。");
      return;
    }

    // 3) 精选决赛域名（TTFB 最快 top FINAL_DOMAINS，含基准域名）
    setProgress(56, "精选决赛域名…");
    const microList = Object.entries(micro)
      .sort((a, b) => a[1].ttfb - b[1].ttfb)
      .map(([d]) => d);
    const finalists = [];
    if (micro[BASELINE_DOMAIN]) finalists.push(BASELINE_DOMAIN);
    for (const d of microList) {
      if (finalists.length >= FINAL_DOMAINS) break;
      if (!finalists.includes(d)) finalists.push(d);
    }
    if (!finalists.length) {
      setProgress(100, "筛选阶段无有效结果");
      toast("快速筛选未获取到有效结果，请检查网络后重试。", true);
      return;
    }

    // 4) 第二阶段：决赛域名精确测速（多轮 + DoH 解析 Edge IP）
    const perDomain = {};
    setProgress(60, `第二阶段 · 精确测速 0/${finalists.length} 域名…`);
    await runConcurrent(finalists, CONCURRENCY, async (domain) => {
      const edgeIp = await resolveEdgeIp(domain, OptimizerState.controller.signal);
      const rounds = [];
      for (let r = 0; r < OptimizerState.rounds; r++) {
        if (OptimizerState.aborted) break;
        const res = await probeTrace(domain, PROBE_TIMEOUT_MS, OptimizerState.controller.signal);
        rounds.push(res);
        if (res.ok && res.ip && OptimizerState.egressIp && res.ip !== OptimizerState.egressIp) {
          OptimizerState.egressChanged = true;
        }
      }
      const okRounds = rounds.filter((r) => r.ok);
      const ttfbs = okRounds.map((r) => r.ttfb);
      const colo = okRounds.find((r) => r.colo)?.colo || "";
      const successRate = rounds.length ? okRounds.length / rounds.length : 0;
      perDomain[domain] = {
        domain,
        colo,
        ips: edgeIp ? [edgeIp] : [],
        medianTtfb: median(ttfbs),
        cv: coefficientOfVariation(ttfbs),
        successRate,
        rounds: rounds.length,
      };
    }, (n) => {
      setProgress(60 + Math.floor((n / finalists.length) * 20), `第二阶段 · 精确测速 ${n}/${finalists.length} 域名…`);
    });

    if (OptimizerState.aborted) {
      setProgress(100, "已停止");
      toast("测速已停止。");
      return;
    }

    // 5) 下载吞吐（整体参考）
    setProgress(82, "测试下载吞吐…");
    const dl = await probeDownload(OptimizerState.controller.signal);

    // 6) 计算 Edge Score + 排序
    setProgress(88, "计算 Edge Score…");
    OptimizerState.results = Object.values(perDomain)
      .filter((m) => m.rounds > 0)
      .map((m) => {
        m.edgeScore = computeEdgeScore(m);
        return m;
      })
      .sort((a, b) => b.edgeScore - a.edgeScore);

    // 7) 渲染 + 保存
    renderBest(OptimizerState.results[0], dl);
    renderResults(OptimizerState.results, dl, total, finalists.length);
    saveLocal(OptimizerState.results[0], dl);
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

function renderBest(best, dl) {
  if (!best) return;
  const box = $o("#optimizer-best");
  box.classList.remove("hidden");
  const bestIp = best.ips && best.ips[0] ? best.ips[0] : "—";
  const ttfb = best.medianTtfb >= 0 ? `${best.medianTtfb.toFixed(0)} ms` : "—";
  const speed = dl && dl.ok ? `${dl.mbps.toFixed(1)} Mbps` : "—";
  const stability = best.cv >= 0 ? `${(100 - Math.min(100, best.cv * 100)).toFixed(0)}%` : "—";
  const unstable = OptimizerState.egressChanged ? " · 网络不稳定" : "";
  box.innerHTML = `
    <div class="opt-best-head"><span class="eyebrow">BEST EDGE</span><span class="opt-best-unstable">${unstable}</span></div>
    <div class="opt-best-grid">
      <div class="opt-best-main"><label>Best Domain</label><strong>${escapeHtmlO(best.domain)}</strong></div>
      <div class="opt-best-main"><label>Best Edge IP</label><strong class="opt-ip">${escapeHtmlO(bestIp)}</strong></div>
      <div class="opt-best-item"><label>POP</label><strong>${escapeHtmlO(best.colo || "—")}</strong></div>
      <div class="opt-best-item"><label>TTFB</label><strong>${ttfb}</strong></div>
      <div class="opt-best-item"><label>Speed</label><strong>${speed}</strong></div>
      <div class="opt-best-item"><label>Stability</label><strong>${stability}</strong></div>
    </div>`;
}

function renderResults(results, dl, totalDomains, finalistCount) {
  const wrap = $o("#optimizer-results");
  wrap.classList.remove("hidden");
  const tbody = results.slice(0, FINAL_DOMAINS).map((m, i) => {
    const ip = m.ips && m.ips[0] ? m.ips[0] : "—";
    const ttfb = m.medianTtfb >= 0 ? `${m.medianTtfb.toFixed(0)} ms` : "—";
    const sr = `${(m.successRate * 100).toFixed(0)}%`;
    const cv = `${(Math.min(100, m.cv * 100)).toFixed(0)}%`;
    return `<tr>
      <td>${i + 1}</td>
      <td>${escapeHtmlO(m.domain)}</td>
      <td class="opt-mono">${escapeHtmlO(ip)}</td>
      <td>${escapeHtmlO(m.colo || "—")}</td>
      <td>${ttfb}</td>
      <td>${sr}</td>
      <td>${cv}</td>
    </tr>`;
  }).join("");
  const scope = `从 ${totalDomains} 个候选域名中筛选 ${finalistCount} 个决赛域名精确测速`;
  wrap.innerHTML = `
    <article class="panel glass">
      <div class="panel-head"><div><span class="eyebrow">RANKING</span><h3>决赛域名排名（按 Edge Score）</h3><p>${escapeHtmlO(scope)}</p></div><small>下载参考：${dl && dl.ok ? dl.mbps.toFixed(1) + " Mbps" : "—"}</small></div>
      <div class="table-scroll"><table class="data-table">
        <thead><tr><th>#</th><th>域名</th><th>Edge IP</th><th>POP</th><th>TTFB</th><th>成功率</th><th>波动</th></tr></thead>
        <tbody>${tbody || '<tr><td colspan="7">无有效结果</td></tr>'}</tbody>
      </table></div>
    </article>`;
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
    latency: best.medianTtfb >= 0 ? Math.round(best.medianTtfb) : -1,
    speed: dl && dl.ok ? Math.round(dl.mbps * 10) / 10 : -1,
    timestamp: new Date().toISOString(),
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
  const when = rec.timestamp ? new Date(rec.timestamp).toLocaleString("zh-CN", { hour12: false }) : "—";
  const lat = rec.latency >= 0 ? `${rec.latency} ms` : "—";
  const spd = rec.speed >= 0 ? `${rec.speed} Mbps` : "—";
  box.innerHTML = `
    <article class="panel glass">
      <div class="panel-head"><div><span class="eyebrow">LAST RESULT</span><h3>上次优选结果（本机保存）</h3></div><small>${escapeHtmlO(when)}</small></div>
      <div class="opt-hist-grid">
        <div class="opt-hist-item"><label>Best Domain</label><strong>${escapeHtmlO(rec.best_domain || "—")}</strong></div>
        <div class="opt-hist-item"><label>Best Edge IP</label><strong class="opt-mono">${escapeHtmlO(rec.best_ip || "—")}</strong></div>
        <div class="opt-hist-item"><label>POP</label><strong>${escapeHtmlO(rec.pop || "—")}</strong></div>
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
    const pool = OptimizerState.domains.length || OPTIMIZER_DOMAINS.length;
    box.innerHTML = `测速分两阶段：先对 <b>${pool} 个候选域名</b>做 1 轮快速筛选，再对 <b>${FINAL_DOMAINS} 个决赛域名</b>做 ${OptimizerState.rounds} 轮精确测速 + 一次约 ${(DOWNLOAD_BYTES / 1024 / 1024).toFixed(0)} MB 下载测速。全程在浏览器本地完成，服务器不参与测速、不上传任何数据。`;
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
