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
 * 与 Android 版 CF Optimizer 的关系：
 *   Android = IP 精准探测版（FixedDns + 指定 IP）
 *   Web     = 浏览器本地 CF Edge 优选版（真实用户网络环境测试）
 */

const OptimizerState = {
  running: false,
  aborted: false,
  controller: null,
  domains: [],           // 候选 CF 域名列表（内嵌，无需请求服务器）
  results: [],           // 每域名聚合结果
  egressIp: "",          // 首次 trace 检测到的出口 IP
  egressChanged: false,  // 测速过程中出口 IP 是否变化
  vpnDetected: false,    // 是否检测到 VPN/代理特征
  networkType: "",       // WiFi / Mobile / ...
  rounds: 3,             // 每域名测速轮次
};

// POP 权重：亚洲入口偏好，仅作软偏好，最终由实际测速结果主导。
const POP_WEIGHT = {
  HKG: 1.00, NRT: 0.95, SIN: 0.95, ICN: 0.90, TPE: 0.88,
  KIX: 0.85, NGO: 0.85, FUK: 0.85, SEA: 0.75, LAX: 0.70, SJC: 0.70,
};
const POP_WEIGHT_DEFAULT = 0.65;

// 下载测速字节数（可选档位：流量预估提示用）
const DOWNLOAD_BYTES = 2 * 1024 * 1024; // 2MB
const PROBE_TIMEOUT_MS = 8000;
const CONCURRENCY = 8;

const STORAGE_KEY = "rr_edge_optimizer";

// 候选 CF 域名池（内嵌在工具文件中，服务器仅静态托管此文件，域名池随之分发）
const OPTIMIZER_DOMAINS = [
  "speed.cloudflare.com", "www.cloudflare.com", "blog.cloudflare.com",
  "developers.cloudflare.com", "radar.cloudflare.com", "www.nexusmods.com",
  "www.4chan.org", "www.canva.com", "www.fiverr.com", "www.indeed.com",
  "www.shopify.com", "www.chess.com", "www.codepen.io", "www.dribbble.com",
  "www.deepl.com", "www.sentry.io", "www.ngrok.com", "www.digitalocean.com",
  "www.vultr.com", "www.docker.com", "www.gitlab.com", "www.medium.com",
  "www.namecheap.com", "www.discourse.org", "www.producthunt.com",
  "www.behance.net", "www.unsplash.com", "www.imgur.com", "www.fandom.com",
  "www.speedtest.net", "www.mozilla.org", "www.python.org", "www.npmjs.com",
  "www.jsdelivr.com", "discord.com", "www.patreon.com", "www.quora.com",
  "www.coinmarketcap.com", "www.grammarly.com", "www.cloudflare-ipfs.com",
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
  try {
    const timeoutId = setTimeout(() => signal?.abort ? null : null, 0);
    const resp = await fetch(url, { signal, cache: "no-store" });
    const ttfb = performance.now() - start;
    const text = await resp.text();
    const total = performance.now() - start;
    // 解析 colo / loc / ip
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
  }
}

/* ------------------------------------------------------------------ */
/* DNS-over-HTTPS 解析域名的 Edge IP（浏览器本地发起，服务器不参与）      */
/* ------------------------------------------------------------------ */
async function resolveEdgeIp(domain, signal) {
  const url = `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(domain)}&type=A`;
  try {
    const resp = await fetch(url, { headers: { accept: "application/dns-json" }, cache: "no-store", signal });
    if (!resp.ok) return "";
    const data = await resp.json();
    const a = (data.Answer || []).filter((x) => x.type === 1).map((x) => x.data);
    return a[0] || "";
  } catch (_e) {
    return "";
  }
}

/* ------------------------------------------------------------------ */
/* 测速：下载吞吐（统一走 speed.cloudflare.com，代表到 CF 边缘的整体吞吐） */
/* ------------------------------------------------------------------ */
async function probeDownload(signal) {
  const url = `https://speed.cloudflare.com/__down?bytes=${DOWNLOAD_BYTES}`;
  const start = performance.now();
  try {
    const resp = await fetch(url, { signal, cache: "no-store" });
    if (!resp.ok) return { ok: false, mbps: 0, bytes: 0 };
    const buf = await resp.arrayBuffer();
    const ms = performance.now() - start;
    const bytes = buf.byteLength;
    const mbps = ms > 0 ? (bytes * 8) / (ms * 1000) : 0; // 字节*8/毫秒/1000 = Mbps
    return { ok: true, mbps, bytes, ms };
  } catch (_e) {
    return { ok: false, mbps: 0, bytes: 0 };
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

    // 1) 出口 IP 基线 + VPN 启发式检测
    setProgress(4, "检测网络环境…");
    const baseline = await probeTrace("speed.cloudflare.com", PROBE_TIMEOUT_MS, OptimizerState.controller.signal);
    OptimizerState.egressIp = baseline.ip || "";
    const localIps = await detectLocalIps();
    const publicLocal = localIps.filter((ip) => !isPrivateIp(ip));
    if (publicLocal.length && baseline.ip && !publicLocal.includes(baseline.ip)) {
      OptimizerState.vpnDetected = true;
    }
    if (OptimizerState.vpnDetected) {
      showVpnBanner();
    }

    // 2) 并发测速：每域名多轮 trace + DoH 解析 Edge IP
    const domains = OptimizerState.domains;
    const total = domains.length;
    let done = 0;
    const perDomain = {};

    setProgress(8, `并发测速 0/${total} 域名…`);
    await runConcurrent(domains, CONCURRENCY, async (domain) => {
      // DoH 实时解析该域名当前命中的 CF Edge IP（浏览器本地发起）
      const edgeIp = await resolveEdgeIp(domain, OptimizerState.controller.signal);
      const rounds = [];
      for (let r = 0; r < OptimizerState.rounds; r++) {
        if (OptimizerState.aborted) break;
        const res = await probeTrace(domain, PROBE_TIMEOUT_MS, OptimizerState.controller.signal);
        rounds.push(res);
        // 出口变化检测
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
      done = n;
      setProgress(8 + Math.floor((n / total) * 60), `并发测速 ${n}/${total} 域名…`);
    });

    if (OptimizerState.aborted) {
      setProgress(100, "已停止");
      toast("测速已停止。");
      return;
    }

    // 3) 下载吞吐（整体参考）
    setProgress(72, "测试下载吞吐…");
    const dl = await probeDownload(OptimizerState.controller.signal);

    // 4) 计算 Edge Score + 排序
    setProgress(82, "计算 Edge Score…");
    OptimizerState.results = Object.values(perDomain)
      .filter((m) => m.rounds > 0)
      .map((m) => {
        m.edgeScore = computeEdgeScore(m);
        return m;
      })
      .sort((a, b) => b.edgeScore - a.edgeScore);

    // 5) 渲染 + 保存
    renderBest(OptimizerState.results[0], dl);
    renderResults(OptimizerState.results, dl);
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

function renderResults(results, dl) {
  const wrap = $o("#optimizer-results");
  wrap.classList.remove("hidden");
  const tbody = results.slice(0, 15).map((m, i) => {
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
  wrap.innerHTML = `
    <article class="panel glass">
      <div class="panel-head"><div><span class="eyebrow">RANKING</span><h3>候选域名排名（按 Edge Score）</h3></div><small>下载参考：${dl && dl.ok ? dl.mbps.toFixed(1) + " Mbps" : "—"}</small></div>
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
    box.innerHTML = `本次测速约消耗 <b>${(DOWNLOAD_BYTES / 1024 / 1024).toFixed(0)} MB</b> 下载流量（${OptimizerState.rounds} 轮 × ${OptimizerState.domains.length || OPTIMIZER_DOMAINS.length} 个域名 trace + 一次下载测速），全程在浏览器本地完成，服务器不参与测速、不上传任何数据。`;
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
