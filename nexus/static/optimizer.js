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
  rounds: 3,             // 决赛域名精确测速轮次
};

// 亚洲入口狩猎：亚洲 POP 优先级（对齐 Android Pipeline.popPriority）
const ASIA_POP_PRIORITY = { HKG: 5, NRT: 4, SIN: 3, ICN: 2, TPE: 1 };
function popPriority(pop) { return ASIA_POP_PRIORITY[pop] || 0; }
function isAsiaTarget(pop) { return popPriority(pop) > 0; }

// 候选 ARGO 入口域名：预设公共域名池（对齐 RR-vps 安装向导同款预设 CDN）
const PRESET_DOMAINS = ["cloudflare-ech.com", "www.visa.com.sg", "www.wto.org", "www.web.com"];

const CONCURRENCY = 6;           // 候选域名并发
const PROBE_TIMEOUT_MS = 8000;   // trace 超时
const WS_TIMEOUT_MS = 6000;      // WebSocket 握手超时
const DOWNLOAD_BYTES = 2 * 1024 * 1024; // 下载测速 2MB
const ROUNDS = 3;                // 每个候选域名多轮测试
const STORAGE_KEY = "rr_edge_optimizer";
const BLACKLIST_KEY = "rr_edge_optimizer_blacklist";
const CUSTOM_DOMAINS_KEY = "rr_edge_optimizer_custom_domains";
// 综合评分权重（五哥最终确认版）
// 成功率 40 / 真实 ARGO 连通 30 / 稳定传输 20 / 延迟 10
const SCORE_W = { success: 40, argo: 30, stability: 20, latency: 10 };

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
  const start = performance.now();
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 8000);
  const onAbort = () => ctrl.abort();
  if (signal) {
    if (signal.aborted) ctrl.abort();
    else signal.addEventListener("abort", onAbort);
  }
  try {
    const resp = await fetch(url, { headers: { accept: "application/dns-json" }, cache: "no-store", signal: ctrl.signal });
    const dnsMs = performance.now() - start;
    if (!resp.ok) return { ip: "", dnsMs: -1 };
    const data = await resp.json();
    const a = (data.Answer || []).filter((x) => x.type === 1).map((x) => x.data);
    return { ip: a[0] || "", dnsMs };
  } catch (_e) {
    return { ip: "", dnsMs: -1 };
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

// 综合评分（0-100 加权和）：可用性 40 + 下载 30 + 稳定 15 + 延迟 10 + DNS 5
// 核心思想（迁移安卓 2.7.1）：稳定高速 > 低延迟但晚上炸；延迟不是唯一指标。
function computeScore(metrics, dl) {
  // 成功率 40：trace 成功轮次 / 总轮次（可用性，最高权重）
  const success = metrics.successRate * SCORE_W.success;

  // 真实 ARGO 连通 30：ws 真实路径（/UUID-vm）成功=满分，仅根路径=降权，均失败=0
  let argo = 0;
  const wsRealOk = metrics.wsReal && metrics.wsReal.ok;
  const wsRootOk = metrics.wsRoot && metrics.wsRoot.ok;
  if (wsRealOk) argo = SCORE_W.argo;
  else if (wsRootOk) argo = SCORE_W.argo * 0.4;

  // 稳定传输 20：下载速度 10 + 波动稳定 10（波动小=稳定，晚上不炸）
  const dlMbps = dl && dl.ok ? dl.mbps : 0;
  const speedPart = Math.min(1, dlMbps / 100) * 10;
  const stabilityPart = (1 - Math.min(1, metrics.cv)) * 10;

  // 延迟 10：TTFB（50ms 满分，800ms 归零，权重最低）
  const latency = metrics.medianTtfb >= 0
    ? Math.max(0, 1 - metrics.medianTtfb / 800) * SCORE_W.latency : 0;

  return success + argo + speedPart + stabilityPart + latency;
}

// 亚洲入口价值：综合评分 × 亚洲 POP 加权（HKG/NRT/SIN/ICN/TPE 放大，非亚洲减半）
function computeAsiaScore(metrics, dl) {
  const base = computeScore(metrics, dl);
  const pop = popPriority(metrics.colo);
  const popWeight = pop > 0 ? (1 + pop * 0.1) : 0.5;
  return base * popWeight;
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

// 读取 RR-vps 当前节点 ARGO 隧道配置（域名/端口/ws 路径）
async function fetchArgoConfig() {
  try {
    const resp = await fetch("/api/argo/config", { cache: "no-store" });
    if (!resp.ok) return null;
    return await resp.json();
  } catch (_e) { return null; }
}

// 收集候选 ARGO 域名：用户节点 ARGO 域名（API）> 预设域名池 > 用户自定义
async function collectCandidates() {
  const list = [];
  const seen = new Set();
  const cfg = await fetchArgoConfig();
  if (cfg && cfg.domain) {
    OptimizerState.argoConfig = cfg;
    if (!seen.has(cfg.domain)) { list.push({ domain: cfg.domain, source: "argo", config: cfg }); seen.add(cfg.domain); }
  }
  PRESET_DOMAINS.forEach((d) => {
    if (!seen.has(d)) { list.push({ domain: d, source: "preset" }); seen.add(d); }
  });
  loadCustomDomains().forEach((d) => {
    if (d && !seen.has(d)) { list.push({ domain: d, source: "custom" }); seen.add(d); }
  });
  return list;
}

// WebSocket 握手检测（真实 ARGO 业务承载）：onopen = Upgrade: websocket 成功
function probeWebSocket(domain, path, timeoutMs, signal) {
  return new Promise((resolve) => {
    const scheme = location.protocol === "https:" ? "wss" : "ws";
    let ws;
    try {
      ws = new WebSocket(`${scheme}://${domain}${path}`);
    } catch (_e) {
      resolve({ ok: false, upgraded: false, error: "构造失败" });
      return;
    }
    let settled = false;
    const timer = setTimeout(() => finish(false, false, "timeout"), timeoutMs || WS_TIMEOUT_MS);
    const finish = (ok, upgraded, error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (signal) signal.removeEventListener("abort", onAbort);
      try { ws.close(); } catch (_e) {}
      resolve({ ok, upgraded, error });
    };
    const onAbort = () => finish(false, false, "aborted");
    if (signal) {
      if (signal.aborted) { onAbort(); return; }
      signal.addEventListener("abort", onAbort);
    }
    ws.onopen = () => finish(true, true, "");
    ws.onerror = () => finish(false, false, "ws_error");
  });
}

async function optimizerStart() {
  if (OptimizerState.running) return;
  OptimizerState.running = true;
  OptimizerState.aborted = false;
  OptimizerState.controller = new AbortController();
  OptimizerState.results = [];
  OptimizerState.asiaResults = [];
  OptimizerState.egressChanged = false;
  OptimizerState.vpnDetected = false;
  OptimizerState.networkType = detectNetworkType();

  const startBtn = $o("#optimizer-start");
  const stopBtn = $o("#optimizer-stop");
  startBtn.disabled = true;
  stopBtn.classList.remove("hidden");
  hideEl("#optimizer-best");
  hideEl("#optimizer-asia");
  hideEl("#optimizer-results");
  showEl("#optimizer-progress-wrap");
  $o("#optimizer-net-banner").classList.add("hidden");
  setProgress(0, "准备中…");

  try {
    // 1) 收集候选 ARGO 域名（用户节点 ARGO 域名 + 预设域名池 + 自定义）
    setProgress(6, "读取候选 ARGO 域名…");
    const allCandidates = await collectCandidates();
    const blacklist = new Set(loadBlacklist());
    const candidates = allCandidates.filter((c) => !blacklist.has(c.domain));
    if (!candidates.length) {
      setProgress(100, "无可用候选域名");
      toast("未获取到候选 ARGO 域名，请检查节点配置或手动添加。", true);
      return;
    }
    const total = candidates.length;

    // 2) 出口 IP 基线 + VPN 启发式检测
    setProgress(10, "检测网络环境…");
    const baseline = await probeTrace(candidates[0].domain, PROBE_TIMEOUT_MS, OptimizerState.controller.signal);
    OptimizerState.egressIp = baseline.ip || "";
    const localIps = await detectLocalIps();
    const publicLocal = localIps.filter((ip) => !isPrivateIp(ip));
    if (publicLocal.length && baseline.ip && !publicLocal.includes(baseline.ip)) {
      OptimizerState.vpnDetected = true;
    }
    if (OptimizerState.vpnDetected) {
      showVpnBanner();
    }

    // 3) 对每个候选域名：多轮 trace + DoH + WebSocket 握手（真实 ARGO 业务）
    const perDomain = {};
    setProgress(15, `测速 0/${total} 候选域名…`);
    await runConcurrent(candidates, CONCURRENCY, async (cand) => {
      const domain = cand.domain;
      const dnsRes = await resolveEdgeIp(domain, OptimizerState.controller.signal);
      const edgeIp = dnsRes.ip || "";
      const dnsMs = dnsRes.dnsMs;
      const rounds = [];
      for (let r = 0; r < ROUNDS; r++) {
        if (OptimizerState.aborted) break;
        const res = await probeTrace(domain, PROBE_TIMEOUT_MS, OptimizerState.controller.signal);
        rounds.push(res);
        if (res.ok && res.ip && OptimizerState.egressIp && res.ip !== OptimizerState.egressIp) {
          OptimizerState.egressChanged = true;
        }
      }
      // WebSocket 握手：A 根路径（快速筛选）+ B 真实路径 /UUID-vm（100% 模拟 RR-vps）
      const wsRoot = await probeWebSocket(domain, "/", WS_TIMEOUT_MS, OptimizerState.controller.signal);
      let wsReal = null;
      if (OptimizerState.argoConfig && OptimizerState.argoConfig.path) {
        wsReal = await probeWebSocket(domain, OptimizerState.argoConfig.path, WS_TIMEOUT_MS, OptimizerState.controller.signal);
      }
      const okRounds = rounds.filter((r) => r.ok);
      const ttfbs = okRounds.map((r) => r.ttfb);
      const colo = okRounds.find((r) => r.colo)?.colo || "";
      const loc = okRounds.find((r) => r.loc)?.loc || "";
      const successRate = rounds.length ? okRounds.length / rounds.length : 0;
      perDomain[domain] = {
        domain,
        colo,
        loc,
        source: cand.source,
        ips: edgeIp ? [edgeIp] : [],
        medianTtfb: median(ttfbs),
        cv: coefficientOfVariation(ttfbs),
        successRate,
        rounds: rounds.length,
        dnsMs,
        wsRoot,
        wsReal,
      };
    }, (n) => {
      setProgress(15 + Math.floor((n / total) * 55), `测速 ${n}/${total} 候选域名…`);
    });

    if (OptimizerState.aborted) {
      setProgress(100, "已停止");
      toast("测速已停止。");
      return;
    }

    // 4) 下载吞吐（整体参考，稳定传输的一部分）
    setProgress(72, "测试下载吞吐…");
    const dl = await probeDownload(OptimizerState.controller.signal);

    // 5) 综合评分（成功率40 + 真实ARGO连通30 + 稳定传输20 + 延迟10）+ 失败惩罚 + 双榜排序
    setProgress(80, "计算综合评分…");
    const metrics = Object.values(perDomain)
      .filter((m) => m.rounds > 0)
      .map((m) => {
        m.score = computeScore(m, dl);
        m.asiaScore = computeAsiaScore(m, dl);
        return m;
      });
    // 失败惩罚：trace 全失败 且 ws 均失败 → 加入黑名单，下次跳过
    const blist = loadBlacklist();
    metrics.forEach((m) => {
      const wsDead = !(m.wsReal && m.wsReal.ok) && !(m.wsRoot && m.wsRoot.ok);
      if (m.successRate === 0 && wsDead && !blist.includes(m.domain)) blist.push(m.domain);
    });
    saveBlacklist(blist);
    OptimizerState.results = metrics.slice().sort((a, b) => b.score - a.score);
    OptimizerState.asiaResults = metrics
      .filter((m) => isAsiaTarget(m.colo))
      .sort((a, b) => b.asiaScore - a.asiaScore);

    // 6) 渲染 + 推荐理由 + 保存
    renderBest(OptimizerState.results[0], dl);
    renderRecommendation(OptimizerState.results[0], dl);
    renderAsiaHunt(OptimizerState.asiaResults);
    renderResults(OptimizerState.results, dl, total);
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
  const score = best.score != null ? `${best.score.toFixed(1)}` : "—";
  const availability = `${(best.successRate * 100).toFixed(0)}%`;
  const wsRealOk = best.wsReal && best.wsReal.ok;
  const wsRootOk = best.wsRoot && best.wsRoot.ok;
  const wsLabel = wsRealOk ? "真实路径 ✓" : (wsRootOk ? "根路径 ✓" : "✗");
  const sourceLabel = best.source === "argo" ? "你的节点" : (best.source === "preset" ? "预设" : "自定义");
  const unstable = OptimizerState.egressChanged ? " · 网络不稳定" : "";
  box.innerHTML = `
    <div class="opt-best-head"><span class="eyebrow">BEST ARGO ENTRY</span><span class="opt-best-unstable">${unstable}</span></div>
    <div class="opt-best-grid">
      <div class="opt-best-main"><label>最佳入口域名</label><strong>${escapeHtmlO(best.domain)}</strong></div>
      <div class="opt-best-main"><label>综合评分</label><strong class="opt-score">${score}<small class="opt-score-max">/100</small></strong></div>
      <div class="opt-best-item"><label>来源</label><strong>${sourceLabel}</strong></div>
      <div class="opt-best-item"><label>WebSocket</label><strong>${wsLabel}</strong></div>
      <div class="opt-best-item"><label>Edge IP</label><strong class="opt-mono opt-ip">${escapeHtmlO(bestIp)}</strong></div>
      <div class="opt-best-item"><label>成功率</label><strong>${availability}</strong></div>
      <div class="opt-best-item"><label>POP</label><strong>${escapeHtmlO(best.colo || "—")}</strong></div>
      <div class="opt-best-item"><label>TTFB</label><strong>${ttfb}</strong></div>
      <div class="opt-best-item"><label>Speed</label><strong>${speed}</strong></div>
      <div class="opt-best-item"><label>Stability</label><strong>${stability}</strong></div>
    </div>`;
}

function renderRecommendation(best, dl) {
  if (!best) return;
  const box = $o("#optimizer-recommendation");
  if (!box) return;
  box.classList.remove("hidden");
  const wsRealOk = best.wsReal && best.wsReal.ok;
  const wsRootOk = best.wsRoot && best.wsRoot.ok;
  const wsDesc = wsRealOk ? "WebSocket 真实路径握手成功（100% 模拟 RR-vps 节点）" : (wsRootOk ? "WebSocket 根路径握手成功（快速筛选通过）" : "WebSocket 握手失败，建议谨慎使用");
  const ttfb = best.medianTtfb >= 0 ? `${best.medianTtfb.toFixed(0)} ms` : "—";
  const successN = Math.round(best.successRate * (best.rounds || ROUNDS));
  const reasons = [
    wsDesc,
    `TTFB ${ttfb}`,
  ];
  if (dl && dl.ok) reasons.push(`下载速度 ${dl.mbps.toFixed(1)} Mbps`);
  reasons.push(`连续测试 ${successN}/${best.rounds || ROUNDS} 成功`);
  box.innerHTML = `
    <article class="panel glass">
      <div class="panel-head"><div><span class="eyebrow">WHY</span><h3>推荐理由</h3><p>为什么推荐这个入口</p></div></div>
      <div class="opt-reason-list">
        ${reasons.map((r) => `<div class="opt-reason-item">${escapeHtmlO(r)}</div>`).join("")}
      </div>
    </article>`;
}

function renderResults(results, dl, totalDomains) {
  const wrap = $o("#optimizer-results");
  wrap.classList.remove("hidden");
  const tbody = results.map((m, i) => {
    const ip = m.ips && m.ips[0] ? m.ips[0] : "—";
    const ttfb = m.medianTtfb >= 0 ? `${m.medianTtfb.toFixed(0)} ms` : "—";
    const sr = `${(m.successRate * 100).toFixed(0)}%`;
    const ws = (m.wsReal && m.wsReal.ok) ? "真实✓" : ((m.wsRoot && m.wsRoot.ok) ? "根✓" : "✗");
    const sc = m.score != null ? m.score.toFixed(1) : "—";
    const src = m.source === "argo" ? "节点" : (m.source === "preset" ? "预设" : "自定义");
    return `<tr>
      <td>${i + 1}</td>
      <td>${escapeHtmlO(m.domain)}</td>
      <td>${src}</td>
      <td>${ws}</td>
      <td class="opt-mono">${escapeHtmlO(ip)}</td>
      <td>${escapeHtmlO(m.colo || "—")}</td>
      <td>${ttfb}</td>
      <td>${sr}</td>
      <td><strong>${sc}</strong></td>
    </tr>`;
  }).join("");
  const scope = `共 ${totalDomains} 个候选 ARGO 入口域名，按综合评分排序（成功率 40% · 真实 ARGO 连通 30% · 稳定传输 20% · 延迟 10%）`;
  wrap.innerHTML = `
    <article class="panel glass">
      <div class="panel-head"><div><span class="eyebrow">RANKING</span><h3>ARGO 入口域名排名</h3><p>${escapeHtmlO(scope)}</p></div><small>下载参考：${dl && dl.ok ? dl.mbps.toFixed(1) + " Mbps" : "—"}</small></div>
      <div class="table-scroll"><table class="data-table">
        <thead><tr><th>#</th><th>域名</th><th>来源</th><th>WS</th><th>Edge IP</th><th>POP</th><th>TTFB</th><th>成功率</th><th>评分</th></tr></thead>
        <tbody>${tbody || '<tr><td colspan="9">无有效结果</td></tr>'}</tbody>
      </table></div>
    </article>`;
}

/* ------------------------------------------------------------------ */
/* 亚洲入口狩猎榜                                                       */
/* ------------------------------------------------------------------ */
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
    box.innerHTML = `测速会优先读取你节点当前的 <b>ARGO 域名</b>，再补充预设域名和自定义域名，对每个候选域名做多轮 trace + <b>WebSocket 握手</b>（真实 ARGO 业务承载）+ 下载测速。全程在浏览器本地完成，服务器不参与测速、不上传任何数据。`;
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
