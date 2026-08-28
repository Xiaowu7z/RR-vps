"use strict";

const state = {
  csrf: "", mode: "local", domain: "", port: 7900, sshHost: "服务器IP",
  devices: [], traffic: null, overview: null, activeView: "overview",
  filter: "all", groupFilter: "all", query: "", metricRange: "24h",
  refreshTimer: null, _prevTraffic: {}, serverPlan: null,
};
const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>'"]/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[char]);
}

function errorText(code) {
  const messages = {
    invalid_credentials: "账号、密码或恢复码不正确。",
    too_many_attempts: "失败次数过多，面板已临时锁定。如需立即恢复，可在服务器执行 rr，菜单 14→2 重置面板登录密码。",
    invalid_name: "设备备注需为 1–64 个可见字符。",
    invalid_quota: "额度范围应为 0–10240 GB。",
    invalid_expiry: "到期日期格式不正确。",
    invalid_reset_schedule: "自动重置计划无效：日期不能早于今天，次数应为 1–120。",
    invalid_server_quota: "服务器套餐额度无效。",
    invalid_current_usage: "服务器当前已用流量无效。",
    invalid_traffic_mode: "服务器流量计费方式无效。",
    invalid_network_interface: "所选网卡不存在，请重新选择。",
    invalid_initial_usage: "运营商当前已用流量无效。",
    invalid_request: "请求数据无效，请刷新页面后重试。",
    invalid_enabled: "启停参数无效，请刷新页面后重试。",
    node_sync_failed: "节点配置同步失败，变更已回滚。",
    device_limit_reached: "设备数量已达到 500 台安全上限。",
    duplicate_name: "设备备注已存在，请勿重复添加。若刚才已提交过，请刷新列表查看结果。",
    device_not_found: "未找到该设备（可能已被删除），请刷新列表。",
    empty_update: "没有需要修改的内容。",
    authentication_required: "会话已过期，请重新登录。",
    bad_request: "请求无效，请刷新页面后重试。",
    not_found: "请求的资源不存在。",
    unreachable: "副面板连接失败：目标服务器无法访问（离线、防火墙拦截或证书异常）。",
    remote_unsupported: "副面板版本过旧，不支持此操作，请先远程升级副面板。",
    remote_error: "副面板执行出错，请查看副面板日志。",
    invalid_remote_cred: "接入钥匙无效（伪造、篡改或已被吊销）。",
    invalid_cred_format: "钥匙格式无效（应为 rrmgr1. 开头的一行密文）。",
    already_exists: "该服务器已添加，请勿重复添加。",
    limit_reached: "已达到可管理的服务器数量上限。",
    cred_rejected: "副面板拒绝了这把钥匙，请重新生成接入钥匙。",
    network_error: "网络连接中断：服务器未响应（可能正在同步节点配置）。若刚提交过操作，请刷新页面查看结果，勿重复提交。",
    remote_call_failed: "远程操作失败，请检查副面板状态后重试。",
    two_factor_required: "请输入身份验证器中的 6 位动态码。",
    invalid_two_factor_code: "动态码无效或已过期。",
    invalid_passkey: "Passkey 验证失败。",
    passkey_unavailable: "当前访问地址不支持 Passkey，请使用 HTTPS 域名或本地 127.0.0.1。",
  };
  return messages[code] || "操作未完成，请稍后重试。";
}

async function api(path, options = {}) {
  const headers = { ...(options.headers || {}) };
  if (options.body && !headers["Content-Type"]) headers["Content-Type"] = "application/json";
  if (headers["Content-Type"] === "application/json" && typeof options.body === "object") options.body = JSON.stringify(options.body);
  if (state.csrf && !["GET", "HEAD"].includes(options.method || "GET")) headers["X-CSRF-Token"] = state.csrf;
  let response;
  try {
    response = await fetch(path, { ...options, headers, credentials: "same-origin" });
  } catch (networkError) {
    const error = new Error(errorText("network_error"));
    error.code = "network_error";
    throw error;
  }
  const contentType = response.headers.get("content-type") || "";
  const data = contentType.includes("application/json") ? await response.json() : null;
  if (!response.ok) {
    if (response.status === 401 && path !== "/api/login") showLogin();
    const error = new Error(data?.message || errorText(data?.error));
    error.code = data?.error;
    error.detail = data?.detail;
    error.serverMessage = data?.message || "";
    throw error;
  }
  return data;
}

function toast(message, isError = false) {
  const element = $("#toast");
  element.textContent = message;
  element.classList.toggle("error", isError);
  element.classList.add("show");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => element.classList.remove("show"), 2600);
}

function formatBytes(bytes, decimals = 1) {
  const value = Number(bytes || 0);
  if (value < 1024) return `${Math.round(value)} B`;
  const units = ["KB", "MB", "GB", "TB", "PB"];
  const index = Math.min(Math.floor(Math.log(value) / Math.log(1024)) - 1, units.length - 1);
  const scaled = value / 1024 ** (index + 1);
  return `${scaled.toFixed(scaled >= 100 ? 0 : scaled >= 10 ? 1 : decimals)} ${units[index]}`;
}

function formatRate(bytes) { return `${formatBytes(bytes)}/s`; }

function formatAutoDelete(seconds) {
  if (seconds <= 0) return "即将自动删除";
  if (seconds < 3600) return `${Math.ceil(seconds / 60)} 分钟后自动删除`;
  if (seconds < 86400) return `${Math.ceil(seconds / 3600)} 小时后自动删除`;
  return `${Math.ceil(seconds / 86400)} 天后自动删除`;
}

function relativeTime(value) {
  if (!value) return "尚无数据";
  const seconds = Math.max(0, Math.floor((Date.now() - new Date(value).getTime()) / 1000));
  if (seconds < 10) return "刚刚";
  if (seconds < 60) return `${seconds} 秒前`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟前`;
  return new Date(value).toLocaleString("zh-CN", { hour12: false });
}

function statusLabel(device) {
  return ({ active: "运行中", paused: "已停用", expired: "已过期", quota: "额度用尽" })[device.status_reason] || "不可用";
}

function showLogin() {
  state.csrf = "";
  clearInterval(state.refreshTimer);
  state.refreshTimer = null;
  $("#console").classList.add("hidden");
  $("#login-screen").classList.remove("hidden");
}

function showConsole(session) {
  state.csrf = session.csrf;
  state.mode = session.mode;
  state.domain = session.domain || "";
  state.port = Number(session.port || 7900);
  state.sshHost = session.ssh_host || "服务器IP";
  $("#mode-badge").textContent = state.mode === "public" ? "公网 HTTPS" : "本地隧道";
  $("#login-screen").classList.add("hidden");
  $("#console").classList.remove("hidden");
  setView("overview");
  configureAccessGuide();
  window.RRAdmin?.onConsole?.();
  clearInterval(state.refreshTimer);
  state.refreshTimer = setInterval(() => {
    if (!document.hidden && state.csrf) refreshLive(false);
  }, 5000);
}

async function loadSession() {
  try {
    const session = await api("/api/session");
    if (!session.authenticated) return showLogin();
    showConsole(session);
    await Promise.all([loadOverview(false), loadDevices(false), loadTraffic(false)]);
  } catch { showLogin(); }
}

function setView(name) {
  const titles = {
    overview: ["运行总览", "OVERVIEW"], traffic: ["实时流量", "TRAFFIC"],
    devices: ["设备与用户", "DEVICES"], security: ["访问与安全", "SECURITY"], audit: ["审计日志", "AUDIT"],
    server: ["服务器状态", "SERVER"], firewall: ["防火墙", "FIREWALL"], remote: ["多服务器", "MULTI-SERVER"],
    optimizer: ["Edge 优选", "CF EDGE OPTIMIZER"],
  };
  state.activeView = name;
  $$(".nav-item[data-view]").forEach(item => item.classList.toggle("active", item.dataset.view === name));
  $$(".view").forEach(view => view.classList.toggle("active-view", view.id === `view-${name}`));
  $("#view-title").textContent = titles[name][0];
  $("#view-kicker").textContent = titles[name][1];
  if (name === "audit") loadAudit();
  if (name === "security") { renderSecurity(); rsKeyLoad(); loadLocalVersion(); window.RRAdmin?.loadSecurity?.(); }
  if (name === "server") { startServerStats(); loadMediaUnlock(); } else { stopServerStats(); }
  if (name === "firewall") loadFirewall();
  if (name === "remote" && state.remoteActive === null) loadRemoteServers();
  if (name === "optimizer") { if (window.OptimizerModule) OptimizerModule.enter(); }
  else if (window.OptimizerModule) OptimizerModule.leave();
  requestAnimationFrame(renderCharts);
}

function updateRefreshTime() {
  $("#last-refresh").textContent = `更新于 ${new Date().toLocaleTimeString("zh-CN", { hour12: false })}`;
}

async function loadOverview(notify = true) {
  try {
    const data = await api("/api/overview");
    state.overview = data;
    const speed = Number(data.traffic.upload_rate || 0) + Number(data.traffic.download_rate || 0);
    $("#metric-total").textContent = data.devices.total;
    $("#metric-enabled").textContent = data.devices.enabled;
    $("#metric-enabled-note").textContent = `${data.devices.total - data.devices.enabled} 台未运行`;
    $("#metric-traffic").textContent = formatBytes(data.devices.used);
    $("#metric-speed").textContent = data.traffic.available ? formatRate(speed) : "不可用";
    $("#metric-mode").textContent = data.mode === "public" ? "公网" : "本地";
    $("#metric-domain").textContent = data.domain || `127.0.0.1:${data.port}`;
    renderServices(data);
    renderTrafficHealth(data.traffic);
    renderSecurity();
    renderBruteforceAlert(data.security);
    updateRefreshTime();
  } catch (error) { if (notify) toast(error.message, true); }
}

function renderServices(data) {
  const names = { "sing-box": ["Sing-box 节点核心", "协议与实时计量"], "rr-nexus": ["RR Nexus 控制台", "管理 API 与任务调度"], cloudflared: ["Cloudflare 隧道", "可选订阅入口"] };
  $("#service-list").innerHTML = Object.entries(data.services).map(([name, value]) => {
    const active = value === "active";
    return `<div class="service-row"><span class="service-symbol ${active ? "" : "off"}">${active ? "✓" : "—"}</span><span><b>${escapeHtml(names[name]?.[0] || name)}</b><small>${escapeHtml(names[name]?.[1] || name)}</small></span><span class="service-state ${active ? "" : "off"}">${active ? "运行中" : "未运行"}</span></div>`;
  }).join("");
}

function renderTrafficHealth(traffic) {
  const available = Boolean(traffic?.available);
  const text = available ? `实时 · ${traffic.poll_seconds} 秒` : "统计不可用";
  const badge = $("#traffic-live-badge");
  badge.className = `live-badge ${available ? "live" : "offline"}`;
  badge.innerHTML = `<i></i>${text}`;
  $("#side-health").textContent = available ? "实时计量在线" : "管理面板在线";
  $("#side-health-note").textContent = available ? `${traffic.poll_seconds} 秒刷新设备流量` : "流量统计通道待恢复";
  const banner = $("#traffic-status");
  banner.className = `status-banner ${available ? "live" : "offline"}`;
  banner.innerHTML = `<i></i><span>${available ? `实时统计正常 · 每 ${traffic.poll_seconds} 秒刷新` : `统计暂不可用${traffic?.last_error ? ` · ${escapeHtml(traffic.last_error)}` : ""}`}</span>`;
}

async function loadDevices(notify = true) {
  try {
    const data = await api("/api/devices");
    state.devices = data.devices || [];
    renderDevices();
  } catch (error) { if (notify) toast(error.message, true); }
}

function visibleDevices() {
  const query = state.query.trim().toLowerCase();
  return state.devices.filter(device => {
    const statusMatch = state.filter === "all" || (state.filter === "active" ? device.active : !device.active);
    const groupMatch = state.groupFilter === "all" || String(device.group_id || "") === state.groupFilter;
    const queryMatch = !query || device.name.toLowerCase().includes(query) || device.id.toLowerCase().includes(query);
    return statusMatch && groupMatch && queryMatch;
  });
}

function renderDevices() {
  const devices = visibleDevices();
  const grid = $("#device-grid");
  const noDevices = state.devices.length === 0;
  $("#device-empty").classList.toggle("hidden", !noDevices);
  $("#device-no-result").classList.toggle("hidden", noDevices || devices.length > 0);
  grid.classList.toggle("hidden", noDevices || devices.length === 0);
  $("#device-result-count").textContent = `${devices.length} 个设备`;
  grid.innerHTML = devices.map(device => {
    const quota = Number(device.quota_bytes || 0);
    const used = Number(device.used_bytes || 0);
    const percent = quota ? Math.min(100, used / quota * 100) : 0;
    const expiry = device.expires_at || "长期有效";
    const resetPlan = device.next_reset_at
      ? `${device.next_reset_at} · 剩余 ${device.reset_remaining} 次`
      : Number(device.reset_max || 0) ? "自动重置已完成" : "未设置自动重置";
    const updated = device.traffic_updated_at ? relativeTime(device.traffic_updated_at) : "等待首笔流量";
    const now_ts = Date.now();
    const prev = state._prevTraffic[device.id] || { up: device.uploaded_bytes || 0, down: device.downloaded_bytes || 0, ts: now_ts - 1000 };
    const elapsed = Math.max(1, (now_ts - prev.ts) / 1000);
    const up_rate = Math.max(0, ((device.uploaded_bytes || 0) - prev.up) / elapsed);
    const down_rate = Math.max(0, ((device.downloaded_bytes || 0) - prev.down) / elapsed);
    state._prevTraffic[device.id] = { up: device.uploaded_bytes || 0, down: device.downloaded_bytes || 0, ts: now_ts };
    const quotaLabel = device.status_reason === "quota" && device.auto_delete_seconds_left !== null
      ? `额度用尽 · ${formatAutoDelete(device.auto_delete_seconds_left)}`
      : quota ? `${formatBytes(used)} / ${formatBytes(quota)}` : updated;
    return `<article class="device-card glass" data-device-id="${escapeHtml(device.id)}">
      <div class="device-top"><label class="device-select"><input type="checkbox" data-device-select="${escapeHtml(device.id)}" aria-label="选择 ${escapeHtml(device.name)}"></label><span class="device-avatar">◇</span><span class="status-pill ${device.active ? "" : "off"}"><i></i>${statusLabel(device)}</span></div>
      <h3 class="device-name">${escapeHtml(device.name)}</h3><span class="device-id">${escapeHtml(device.id)}</span>
      ${device.group_name ? `<span class="group-chip" style="--group-color:${escapeHtml(device.group_color || "#4f8cff")}">${escapeHtml(device.group_name)}</span>` : ""}
      <div class="device-traffic"><div><small>上传</small><b>↑ ${formatBytes(device.uploaded_bytes)}</b></div><div><small>下载</small><b>↓ ${formatBytes(device.downloaded_bytes)}</b></div><div class="traffic-total"><small>总流量</small><b>${formatBytes(used)}</b></div></div>
      <div class="device-rate"><small>实时速率</small><span class="r-up">↑ ${formatRate(up_rate)}</span><span class="r-down">↓ ${formatRate(down_rate)}</span></div>
      <div class="quota-block"><div><small>${quota ? "流量额度" : "流量额度不限"}</small><span>${quotaLabel}</span></div>${quota ? `<div class="quota-track"><i data-w="${percent.toFixed(1)}"></i></div>` : ""}</div>
      <div class="device-meta"><span><small>到期时间</small><b>${escapeHtml(expiry)}</b></span><span><small>自动重置</small><b>${escapeHtml(resetPlan)}</b></span><span><small>最近统计</small><b>${escapeHtml(updated)}</b></span></div>
      <div class="device-actions"><button data-action="links">链接与二维码</button><button data-action="rename">改备注</button><button data-action="reset">重置流量</button><button data-action="toggle">${device.enabled ? "暂停" : "启用"}</button><button class="danger" data-action="delete" title="删除">×</button></div>
    </article>`;
  }).join("");
}

async function loadTraffic(notify = true) {
  try {
    const data = await api(`/api/traffic?range=${encodeURIComponent(state.metricRange)}`);
    state.traffic = data;
    $("#traffic-upload").textContent = formatBytes(data.totals.uploaded);
    $("#traffic-download").textContent = formatBytes(data.totals.downloaded);
    $("#traffic-total").textContent = formatBytes(data.totals.used);
    $("#traffic-upload-rate").textContent = `↑ ${formatRate(data.status.upload_rate)}`;
    $("#traffic-download-rate").textContent = `↓ ${formatRate(data.status.download_rate)}`;
    renderTrafficHealth(data.status);
    state.serverPlan = data.server_plan || null;
    renderServerPlan(data.server_plan || {}, "");
    renderRanking(data.devices || []);
    renderCharts();
    window.RRAdmin?.loadMetrics?.(false);
  } catch (error) { if (notify) toast(error.message, true); }
}

function renderServerPlan(plan, prefix = "") {
  const id = name => $(`#${prefix}${name}`);
  const quotaInput = id("server-plan-quota");
  const modeInput = id("server-plan-mode");
  const interfaceInput = id("server-plan-interface");
  const currentInput = id("server-plan-current");
  const form = id("server-traffic-form");
  const editing = form && form.contains(document.activeElement);
  if (!editing) {
    quotaInput.value = Number(plan.quota_bytes || 0) ? (Number(plan.quota_bytes) / 1024 ** 3).toFixed(2) : "0";
    modeInput.value = plan.count_mode || "both";
    const selected = plan.interface_name || "";
    interfaceInput.innerHTML = '<option value="">自动识别公网默认网卡</option>' + (plan.interfaces || []).map(name => `<option value="${escapeHtml(name)}">${escapeHtml(name)}</option>`).join("");
    interfaceInput.value = selected;
    const currentGb = (Number(plan.used_bytes || 0) / 1024 ** 3).toFixed(3);
    currentInput.value = currentGb;
    currentInput.dataset.original = currentGb;
  }
  id("server-plan-rx").textContent = formatBytes(plan.received_bytes || 0);
  id("server-plan-tx").textContent = formatBytes(plan.transmitted_bytes || 0);
  id("server-plan-used").textContent = formatBytes(plan.used_bytes || 0);
  id("server-plan-cycle").textContent = plan.cycle_started_at ? `周期开始：${new Date(plan.cycle_started_at).toLocaleString("zh-CN", { hour12: false })}` : "计费周期尚未开始";
  id("server-plan-remaining").textContent = Number(plan.quota_bytes || 0)
    ? `${plan.exhausted ? "套餐已用尽" : "剩余"} ${formatBytes(plan.remaining_bytes || 0)}`
    : "未设置额度";
  const progress = id("server-plan-progress");
  progress.dataset.w = Number(plan.percent || 0).toFixed(1);
  applyBarWidths(form || document);
  const stateEl = id("server-plan-state");
  stateEl.className = `live-badge ${plan.available ? (plan.exhausted ? "offline" : "live") : "pending"}`;
  stateEl.innerHTML = `<i></i>${plan.available ? `${escapeHtml(plan.active_interface || "网卡")} · ${plan.exhausted ? "额度用尽" : "统计中"}` : "等待网卡采样"}`;
}

async function saveServerPlan(event, remote = false) {
  event.preventDefault();
  const prefix = remote ? "rs-" : "";
  const currentInput = $(`#${prefix}server-plan-current`);
  const currentUsed = Number(currentInput.value);
  if (!Number.isFinite(currentUsed) || currentUsed < 0 || currentUsed > 1048576) {
    toast("当前已用流量应为有效的 GB 数值。", true);
    return;
  }
  const payload = {
    quota_gb: Number($(`#${prefix}server-plan-quota`).value || 0),
    count_mode: $(`#${prefix}server-plan-mode`).value,
    interface_name: $(`#${prefix}server-plan-interface`).value,
  };
  if (currentInput.value !== (currentInput.dataset.original || "")) payload.current_used_gb = currentUsed;
  try {
    const result = remote
      ? await rsRemoteApi("PATCH", "/api/server/traffic-policy", payload)
      : await api("/api/server/traffic-policy", { method: "PATCH", body: payload });
    if (Object.prototype.hasOwnProperty.call(payload, "current_used_gb")) {
      currentInput.dataset.original = currentInput.value;
    }
    renderServerPlan(result.policy || {}, prefix);
    toast(Object.prototype.hasOwnProperty.call(payload, "current_used_gb")
      ? (remote ? "副服务器套餐及当前已用量已校准。" : "服务器套餐及当前已用量已校准。")
      : (remote ? "副服务器套餐设置已保存。" : "服务器套餐设置已保存。"));
  } catch (error) { toast(error.message, true); }
}

async function resetServerPlan(remote = false) {
  const value = prompt("开始新的运营商计费周期。\n若运营商面板已经产生用量，可填写当前已用 GB；否则填 0：", "0");
  if (value === null) return;
  const initial = Number(value);
  if (!Number.isFinite(initial) || initial < 0 || initial > 1048576) {
    toast("当前已用流量应为有效的 GB 数值。", true);
    return;
  }
  try {
    const result = remote
      ? await rsRemoteApi("POST", "/api/server/traffic-policy/reset", { initial_used_gb: initial })
      : await api("/api/server/traffic-policy/reset", { method: "POST", body: { initial_used_gb: initial } });
    renderServerPlan(result.policy || {}, remote ? "rs-" : "");
    toast("新计费周期已经开始。");
  } catch (error) { toast(error.message, true); }
}

function renderRanking(devices) {
  $("#ranking-count").textContent = `${devices.length} 个设备`;
  $("#traffic-ranking-empty").classList.toggle("hidden", devices.length > 0);
  $("#traffic-ranking").innerHTML = devices.map((device, index) => {
    const quota = Number(device.quota_bytes || 0);
    const used = Number(device.used_bytes || 0);
    const ratio = quota ? Math.min(100, used / quota * 100) : 0;
    return `<tr><td><span class="rank">${index + 1}</span><span class="table-device"><b>${escapeHtml(device.name)}</b><small>${escapeHtml(device.id)}</small></span></td><td><span class="table-status ${device.active ? "" : "off"}">${statusLabel(device)}</span></td><td class="upload-text">↑ ${formatBytes(device.uploaded_bytes)}</td><td class="download-text">↓ ${formatBytes(device.downloaded_bytes)}</td><td><b>${formatBytes(used)}</b></td><td>${quota ? `<span>${ratio.toFixed(0)}%</span><div class="mini-progress"><i data-w="${ratio}"></i></div>` : "不限"}</td><td>${escapeHtml(relativeTime(device.traffic_updated_at))}</td></tr>`;
  }).join("");
}

function chartSeries(samples) {
  return (samples || []).map(sample => ({
    time: Number(sample.bucket) * 1000,
    upload: Number(sample.uploaded_bytes || 0),
    download: Number(sample.downloaded_bytes || 0),
  }));
}

function drawTrafficChart(canvas, emptyElement, samples) {
  if (!canvas || canvas.clientWidth < 20) return;
  const series = chartSeries(samples);
  emptyElement.classList.toggle("hidden", series.some(point => point.upload || point.download));
  const ratio = Math.min(window.devicePixelRatio || 1, 2);
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  canvas.width = Math.round(width * ratio);
  canvas.height = Math.round(height * ratio);
  const ctx = canvas.getContext("2d");
  ctx.scale(ratio, ratio);
  ctx.clearRect(0, 0, width, height);
  const pad = { left: 50, right: 16, top: 14, bottom: 28 };
  const chartWidth = width - pad.left - pad.right;
  const chartHeight = height - pad.top - pad.bottom;
  ctx.font = "10px Inter, sans-serif";
  ctx.lineWidth = 1;
  ctx.strokeStyle = "rgba(255,255,255,.065)";
  ctx.fillStyle = "rgba(148,161,180,.7)";
  for (let i = 0; i <= 4; i += 1) {
    const y = pad.top + chartHeight * i / 4;
    ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(width - pad.right, y); ctx.stroke();
  }
  const maxValue = Math.max(1, ...series.flatMap(point => [point.upload, point.download]));
  [0, .5, 1].forEach(fraction => {
    const value = maxValue * (1 - fraction);
    ctx.fillText(formatBytes(value), 2, pad.top + chartHeight * fraction + 3);
  });
  const now = Date.now();
  const start = now - 24 * 3600 * 1000;
  [0, 6, 12, 18, 24].forEach(hour => {
    const x = pad.left + chartWidth * hour / 24;
    const label = new Date(start + hour * 3600 * 1000).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false });
    ctx.fillText(label, Math.min(width - 44, x - 12), height - 7);
  });
  const xFor = time => pad.left + Math.max(0, Math.min(1, (time - start) / (now - start))) * chartWidth;
  const yFor = value => pad.top + chartHeight - value / maxValue * chartHeight;
  const draw = (key, color, fill) => {
    if (!series.length) return;
    const gradient = ctx.createLinearGradient(0, pad.top, 0, pad.top + chartHeight);
    gradient.addColorStop(0, fill); gradient.addColorStop(1, "rgba(0,0,0,0)");
    ctx.beginPath();
    series.forEach((point, index) => index ? ctx.lineTo(xFor(point.time), yFor(point[key])) : ctx.moveTo(xFor(point.time), yFor(point[key])));
    ctx.lineTo(xFor(series.at(-1).time), pad.top + chartHeight); ctx.lineTo(xFor(series[0].time), pad.top + chartHeight); ctx.closePath();
    ctx.fillStyle = gradient; ctx.fill();
    ctx.beginPath();
    series.forEach((point, index) => index ? ctx.lineTo(xFor(point.time), yFor(point[key])) : ctx.moveTo(xFor(point.time), yFor(point[key])));
    ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.stroke();
  };
  draw("download", "#5aa7ff", "rgba(90,167,255,.18)");
  draw("upload", "#6ce6ce", "rgba(108,230,206,.16)");
}

function renderCharts() {
  const samples = state.traffic?.samples || [];
  drawTrafficChart($("#overview-chart"), $("#overview-chart-empty"), samples);
  drawTrafficChart($("#traffic-chart"), $("#traffic-chart-empty"), samples);
}

function configureAccessGuide() {
  let host = state.sshHost;
  if (host.includes(":") && !host.startsWith("[")) host = `[${host}]`;
  const command = `ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o TCPKeepAlive=yes -o ExitOnForwardFailure=yes -N -L ${state.port}:127.0.0.1:${state.port} root@${host}`;
  $("#ssh-command").textContent = command;
  const localUrl = `http://127.0.0.1:${state.port}`;
  $("#local-panel-link").href = localUrl;
  $("#local-panel-link").textContent = localUrl;
  let publicUrl = "#";
  if (state.domain && state.domain !== "ip") { publicUrl = `https://${state.domain}`; }
  else if (state.domain === "ip" && state.sshHost) { publicUrl = `https://${state.sshHost}:${state.port}`; }
  else { publicUrl = localUrl; }
  $("#public-panel-link").href = publicUrl;
  $("#public-panel-link").textContent = publicUrl;
}

function renderBruteforceAlert(sec) {
  const el = $("#bruteforce-alert");
  if (!el) return;
  const lockouts = Number(sec?.recent_lockouts || 0);
  const dismissed = Number(localStorage.getItem("bruteforce-alert-dismissed") || 0);
  if (lockouts > 0 && lockouts !== dismissed) {
    el.classList.remove("hidden");
    $("#bruteforce-alert-text").textContent = `最近 24 小时检测到 ${lockouts} 次登录爆破锁定（涉及 ${sec?.locked_ips || 0} 个来源）。如非本人操作，请检查节点端口并在服务器执行 rr 菜单 14→2 重置密码。`;
    $("#bruteforce-alert-close").onclick = () => {
      el.classList.add("hidden");
      localStorage.setItem("bruteforce-alert-dismissed", String(lockouts));
    };
  } else {
    el.classList.add("hidden");
  }
}

function renderSecurity() {
  const isPublic = state.mode === "public";
  $("#security-current-mode").textContent = `当前：${isPublic ? "公网 HTTPS" : "本地隧道"}`;
  $("#local-mode-card").classList.toggle("active", !isPublic);
  $("#public-mode-card").classList.toggle("active", isPublic);
  $("#ssh-guide").classList.toggle("hidden", isPublic);
  $("#public-guide").classList.remove("hidden");
  configureAccessGuide();
  const coreActive = state.overview?.services?.["sing-box"] === "active";
  const statsActive = Boolean(state.overview?.traffic?.available);
  $("#security-core-state").textContent = coreActive ? "运行中" : "异常";
  $("#security-core-state").className = coreActive ? "safe" : "warning";
  $("#security-core-note").textContent = coreActive ? "Sing-box 服务正常" : "请在服务器运行 rr 检查";
  $("#security-stats-state").textContent = statsActive ? "实时" : "不可用";
  $("#security-stats-state").className = statsActive ? "safe" : "warning";
  $("#security-stats-note").textContent = statsActive ? "设备计数器每 5 秒采集" : "请检查统计内核状态";
}

async function loadAudit() {
  const list = $("#audit-list");
  list.innerHTML = '<p class="form-hint">正在读取…</p>';
  try {
    const data = await api("/api/audit");
    list.innerHTML = data.events.length ? data.events.map(event => `<div class="audit-row"><time>${escapeHtml(new Date(event.created_at).toLocaleString("zh-CN", { hour12: false }))}</time><span class="audit-action">${escapeHtml(event.action)}</span><span><b>${escapeHtml(event.target)}</b><small>${escapeHtml(event.detail || event.actor)}</small></span><small>${escapeHtml(event.remote_ip)}</small></div>`).join("") : '<p class="form-hint">暂无审计事件。</p>';
  } catch (error) { list.innerHTML = `<p class="form-error">${escapeHtml(error.message)}</p>`; }
}

async function refreshLive(notify = false) {
  await Promise.all([loadOverview(notify), loadDevices(notify), loadTraffic(notify)]);
  if (state.activeView === "audit") await loadAudit();
  if (state.activeView === "firewall") await loadFirewall();
  if (state.activeView === "server") await loadServerStats();
  if (state.activeView === "remote" && !state.remoteActive) await loadRemoteServers();
}

function openCreate(remote = false) {
  $("#device-form").reset();
  $("#device-org-fields").classList.toggle("hidden", remote);
  $("#device-form-group").disabled = remote;
  $("#device-form-template").disabled = remote;
  $("#device-dialog").dataset.remote = remote ? "1" : "0";
  $("#device-dialog h2").textContent = remote ? "远程添加设备" : "添加设备";
  $("#device-form-error").textContent = "";
  $("#device-dialog").showModal();
}

async function createDevice(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const submit = form.querySelector("button[type=submit]");
  const values = new FormData(form);
  submit.disabled = true;
  $("#device-form-error").textContent = "";
  try {
    const payload = {
      name: values.get("name"),
      quota_gb: Number(values.get("quota_gb") || 0),
      expires_at: values.get("expires_at") || "",
      reset_at: values.get("reset_at") || "",
      reset_max: Number(values.get("reset_max") || 0),
      group_id: values.get("group_id") || null,
      template_id: values.get("template_id") || null,
      template_values_applied: Boolean(values.get("template_id")),
    };
    const remote = $("#device-dialog").dataset.remote === "1";
    if (remote) await rsRemoteApi("POST", "/api/devices", payload);
    else await api("/api/devices", { method: "POST", body: payload });
    $("#device-dialog").close();
    if (remote) await rsLoadDevices();
    else {
      await refreshLive();
      await window.RRAdmin?.loadOrganization?.();
    }
    toast(remote ? "远程设备已创建，副服务器正在同步。" : "设备已创建，节点配置正在后台同步（不影响现有用户在线）。");
  } catch (error) { $("#device-form-error").textContent = error.detail ? `${error.message} ${error.detail}` : error.message; }
  finally { submit.disabled = false; }
}

async function toggleDevice(device) {
  try {
    await api(`/api/devices/${device.id}`, { method: "PATCH", body: JSON.stringify({ enabled: !device.enabled }) });
    await refreshLive();
    toast(device.enabled ? "设备已暂停。" : "设备已启用。");
  } catch (error) { toast(error.message, true); }
}

function openRenameDialog(device, remote = false) {
  const dialog = $("#rename-dialog");
  dialog.dataset.deviceId = device.id;
  dialog.dataset.remote = remote ? "1" : "0";
  $("#rename-input").value = device.name || "";
  $("#rename-form-error").textContent = "";
  dialog.showModal();
  requestAnimationFrame(() => $("#rename-input").focus());
}

async function submitRename(event) {
  event.preventDefault();
  const dialog = $("#rename-dialog");
  const deviceId = dialog.dataset.deviceId || "";
  const name = $("#rename-input").value.trim();
  if (!deviceId || !name) {
    $("#rename-form-error").textContent = "设备备注不能为空。";
    return;
  }
  const submit = $("#rename-submit");
  submit.disabled = true;
  $("#rename-form-error").textContent = "";
  try {
    if (dialog.dataset.remote === "1") {
      await rsRemoteApi("PATCH", `/api/devices/${deviceId}`, { name });
      await rsLoadDevices();
    } else {
      await api(`/api/devices/${deviceId}`, { method: "PATCH", body: { name } });
      await loadDevices(false);
      await loadTraffic(false);
    }
    dialog.close();
    toast("设备备注已保存，不影响订阅和节点名称。");
  } catch (error) {
    $("#rename-form-error").textContent = error.message || "备注保存失败。";
  } finally { submit.disabled = false; }
}

async function resetDevice(device) {
  $("#reset-device-name").textContent = device.name;
  $("#reset-current").textContent = `${formatBytes(device.used_bytes)} / ${Number(device.quota_bytes || 0) ? formatBytes(device.quota_bytes) : "不限"}`;
  const input = $("#reset-quota-input");
  input.value = device.quota_bytes ? (Number(device.quota_bytes) / 1024 ** 3).toFixed(2) : "0";
  $("#reset-at-input").value = device.next_reset_at || "";
  $("#reset-max-input").value = Number(device.reset_remaining || 0);
  $("#reset-expiry-input").value = device.expires_at || "";
  $("#reset-form-error").textContent = "";
  $("#reset-dialog").showModal();
}

async function submitReset(event) {
  event.preventDefault();
  const dialog = $("#reset-dialog");
  const deviceId = dialog.dataset.deviceId;
  if (!deviceId) return;
  const submit = $("#reset-submit");
  const value = $("#reset-quota-input").value;
  let quotaGb = null;
  if (value !== "") {
    quotaGb = Number(value);
    if (!Number.isFinite(quotaGb) || quotaGb < 0 || quotaGb > 10240) {
      $("#reset-form-error").textContent = "额度需为 0–10240 的数字（支持小数，如 0.1 = 100MB）。";
      return;
    }
  }
  submit.disabled = true;
  $("#reset-form-error").textContent = "";
  try {
    const body = {
      reset_at: $("#reset-at-input").value || "",
      reset_max: Number($("#reset-max-input").value || 0),
      expires_at: $("#reset-expiry-input").value || "",
    };
    if (quotaGb !== null) body.quota_gb = quotaGb;
    const remote = dialog.dataset.remote === "1";
    if (remote) await rsRemoteApi("POST", `/api/devices/${deviceId}/reset`, body);
    else await api(`/api/devices/${deviceId}/reset`, { method: "POST", body });
    dialog.close();
    if (remote) await rsLoadDevices();
    else await refreshLive();
    toast(remote ? "副服务器设备流量及计划已更新。" : "流量已重置，设备恢复可用。");
  } catch (error) {
    $("#reset-form-error").textContent = error.detail ? `${error.message} ${error.detail}` : error.message;
  } finally { submit.disabled = false; }
}

function openResetDialog(device, remote = false) {
  $("#reset-dialog").dataset.deviceId = device.id;
  $("#reset-dialog").dataset.remote = remote ? "1" : "0";
  resetDevice(device);
}

async function deleteDevice(device) {
  if (!confirm(`确定删除“${device.name}”？该设备的凭据和订阅会立即失效。`)) return;
  try {
    await api(`/api/devices/${device.id}`, { method: "DELETE" });
    await refreshLive();
    toast("设备已删除，旧凭据已撤销。");
  } catch (error) { toast(error.message, true); }
}

function protocolName(link) {
  // Naive H2/H3 分享链接分别使用 naive+https / naive+quic。
  const value = link.split(":", 1)[0].toLowerCase().replace(/\+(https|quic)$/, "");
  return ({ vless: "VLESS Reality", vmess: "VMess", hysteria2: "Hysteria2", tuic: "TUIC", anytls: "AnyTLS", naive: "NaiveProxy" })[value] || value.toUpperCase();
}

async function openLinks(device) {
  const list = $("#links-list");
  $("#links-title").textContent = `${device.name} · 连接信息`;
  list.innerHTML = '<p class="form-hint">正在生成…</p>';
  $("#links-dialog").showModal();
  try {
    const data = await api(`/api/devices/${device.id}/links`);
    const statusBar = $("#links-status");
    if (statusBar) {
      const au = data.auto_update || { enabled: false };
      const argo = data.argo || { domain: "" };
      const argoLinks = data.links.filter(link => link.startsWith("vmess://") && link.includes("优选"));
      statusBar.innerHTML = `
        <span class="status-pill ${au.enabled ? "status-on" : "status-off"}">自动优选：${au.enabled ? "已开启" : "已关闭"}</span>
        ${argo.domain ? `<span class="status-pill status-argo">Argo：${escapeHtml(argo.domain)}</span>` : ""}
        ${argoLinks.length ? `<span class="status-pill status-argo">Argo 优选副节点：${argoLinks.length} 个</span>` : ""}`;
    }
    const box = $("#subscription-box");
    const urls = data.subscription_urls || [];
    box.classList.toggle("hidden", urls.length === 0);
    $("#subscription-urls").innerHTML = urls.map((item, idx) => `<div class="sub-url-row"><b>${escapeHtml(item.format)}</b><small>${escapeHtml(item.name)}</small><code>${escapeHtml(item.url)}</code><img class="sub-qr" src="/api/devices/${encodeURIComponent(device.id)}/qr?raw=${encodeURIComponent(item.url)}" alt="订阅二维码"><button class="copy-button" data-copy-sub-url="${escapeHtml(item.url)}">复制</button><button class="copy-button" data-open-sub-qr="/api/devices/${encodeURIComponent(device.id)}/qr?raw=${encodeURIComponent(item.url)}">打开二维码</button></div>`).join("");
    list.innerHTML = data.links.length ? data.links.map((link, index) => `<div class="link-row"><img src="/api/devices/${encodeURIComponent(device.id)}/qr?index=${index}" alt="${escapeHtml(protocolName(link))} 二维码"><div class="link-content"><b>${escapeHtml(protocolName(link))}</b><code>${escapeHtml(link)}</code></div><div class="link-actions"><button data-copy-link="${index}">复制链接</button><button data-open-qr="${index}">打开二维码</button></div></div>`).join("") : '<p class="form-hint">当前没有启用的节点协议。</p>';
    list.dataset.links = JSON.stringify(data.links);
    list.dataset.device = device.id;
  } catch (error) { list.innerHTML = `<p class="form-error">${escapeHtml(error.message)}</p>`; }
}

async function copyText(value) {
  try { await navigator.clipboard.writeText(value); toast("已复制到剪贴板。"); }
  catch { toast("浏览器不允许自动复制，请手动选择文本。", true); }
}

$("#login-form").addEventListener("submit", async event => {
  event.preventDefault();
  const form = event.currentTarget;
  const submit = form.querySelector("button[type=submit]");
  const values = new FormData(form);
  submit.disabled = true;
  $("#login-error").textContent = "";
  try {
    await api("/api/login", { method: "POST", body: JSON.stringify({ username: values.get("username"), password: values.get("password"), otp: values.get("otp") || "" }) });
    const session = await api("/api/session");
    showConsole(session);
    form.reset();
    await refreshLive();
  } catch (error) {
    $("#login-error").textContent = error.message;
    if (error.code === "two_factor_required") {
      $("#login-otp-wrap").classList.remove("hidden");
      form.otp.required = true;
      form.otp.focus();
    }
  }
  finally { submit.disabled = false; }
});

$("#logout-button").addEventListener("click", async () => { try { await api("/api/logout", { method: "POST" }); } finally { showLogin(); } });
$("#refresh-button").addEventListener("click", async () => { await refreshLive(true); toast("数据已刷新。"); });
$("#audit-refresh").addEventListener("click", loadAudit);
$$(".nav-item[data-view]").forEach(button => button.addEventListener("click", () => setView(button.dataset.view)));
$$('[data-jump]').forEach(button => button.addEventListener("click", () => setView(button.dataset.jump)));
$$('[data-open-create]').forEach(button => button.addEventListener("click", () => openCreate(false)));
$("#add-device-button").addEventListener("click", () => openCreate(false));
$("#device-form").addEventListener("submit", createDevice);
$("#server-traffic-form").addEventListener("submit", event => saveServerPlan(event, false));
$("#server-plan-reset").addEventListener("click", () => resetServerPlan(false));
$("#rename-form").addEventListener("submit", submitRename);
$("#reset-form").addEventListener("submit", submitReset);
$$('[data-close-rename]').forEach(button => button.addEventListener("click", () => $("#rename-dialog").close()));
$$('[data-close-reset]').forEach(button => button.addEventListener("click", () => $("#reset-dialog").close()));
$$('[data-close-dialog]').forEach(button => button.addEventListener("click", () => $("#device-dialog").close()));
$$('[data-close-links]').forEach(button => button.addEventListener("click", () => $("#links-dialog").close()));
$("#copy-ssh-command").addEventListener("click", () => copyText($("#ssh-command").textContent));

$("#device-search").addEventListener("input", event => { state.query = event.target.value; renderDevices(); });
$("#device-group-filter")?.addEventListener("change", event => { state.groupFilter = event.target.value; renderDevices(); });
$$(".filter-button").forEach(button => button.addEventListener("click", () => {
  state.filter = button.dataset.filter;
  $$(".filter-button").forEach(item => item.classList.toggle("active", item === button));
  renderDevices();
}));

$("#device-grid").addEventListener("click", event => {
  const action = event.target.closest("[data-action]");
  const card = event.target.closest("[data-device-id]");
  if (!action || !card) return;
  const device = state.devices.find(item => item.id === card.dataset.deviceId);
  if (!device) return;
  if (action.dataset.action === "links") openLinks(device);
  if (action.dataset.action === "rename") openRenameDialog(device);
  if (action.dataset.action === "toggle") toggleDevice(device);
  if (action.dataset.action === "reset") openResetDialog(device);
  if (action.dataset.action === "delete") deleteDevice(device);
});

$("#links-dialog").addEventListener("click", event => {
  const copy = event.target.closest("[data-copy-link]");
  const open = event.target.closest("[data-open-qr]");
  const rOpen = event.target.closest("[data-remote-open-qr]");
  const copySub = event.target.closest("[data-copy-sub-url]");
  const rOpenSub = event.target.closest("[data-remote-open-sub-qr]");
  const links = JSON.parse($("#links-list").dataset.links || "[]");
  if (copy) copyText(links[Number(copy.dataset.copyLink)] || "");
  if (open) window.open(`/api/devices/${encodeURIComponent($("#links-list").dataset.device)}/qr?index=${Number(open.dataset.openQr)}`, "_blank", "noopener");
  if (rOpen) window.open(decodeURIComponent(rOpen.dataset.remoteOpenQr), "_blank", "noopener");
  if (copySub) copyText(copySub.dataset.copySubUrl || "");
  if (rOpenSub) window.open(decodeURIComponent(rOpenSub.dataset.remoteOpenSubQr), "_blank", "noopener");
});
window.addEventListener("resize", () => requestAnimationFrame(renderCharts));
document.addEventListener("visibilitychange", () => { if (!document.hidden && state.csrf) refreshLive(false); });

// 修改密码
$("#change-password-button").addEventListener("click", () => { $("#password-form-error").classList.add("hidden"); $("#password-form").reset(); $("#password-dialog").showModal(); });
$$("[data-close-dialog]").forEach(btn => btn.addEventListener("click", () => { $("#password-dialog").close(); $("#device-dialog").close(); }));
$("#password-form").addEventListener("submit", async event => {
  event.preventDefault();
  const form = event.target;
  const old_pwd = form.old_password.value;
  const new_pwd = form.new_password.value;
  const again = form.password_again.value;
  if (new_pwd !== again) {
    $("#password-form-error").textContent = "两次新密码不一致。";
    $("#password-form-error").classList.remove("hidden");
    return;
  }
  try {
    await api("/api/change-password", { method: "POST", body: { old_password: old_pwd, new_password: new_pwd } });
    toast("密码已更新。");
    form.reset();
    $("#password-dialog").close();
  } catch (err) {
    $("#password-form-error").textContent = err.message;
    $("#password-form-error").classList.remove("hidden");
  }
});

loadSession();


// ---------- 服务器实时状态（每秒刷新） ----------
let serverStatsTimer = null;
const cpuHistory = [];

function formatRateHuman(bps) {
  if (!bps || bps <= 0) return "0 B/s";
  const units = ["B/s", "KB/s", "MB/s", "GB/s"];
  let v = bps, i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(1)} ${units[i]}`;
}

function formatUptime(sec) {
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  return d > 0 ? `${d} 天 ${h}:${String(m).padStart(2, "0")}` : `${h}:${String(m).padStart(2, "0")}:${String(sec % 60).padStart(2, "0")}`;
}

function renderServerStats(data) {
  const el = id => document.getElementById(id);
  el("srv-os").textContent = data.os || "—";
  el("srv-host").textContent = data.hostname || "—";
  el("srv-uptime").textContent = formatUptime(data.uptime_seconds || 0);
  el("srv-load").textContent = (data.loadavg || []).join(" / ");

  const cpu = data.cpu || {};
  el("srv-cpu-pct").textContent = `${cpu.percent ?? 0}%`;
  const d = cpu.detail || {};
  el("srv-cpu-detail").innerHTML = `<span>user ${d.user ?? 0}%</span><span>sys ${d.sys ?? 0}%</span><span>io ${d.io ?? 0}%</span><span>idle ${d.idle ?? 0}%</span>`;
  el("srv-cpu-model").textContent = cpu.model ? `${cpu.model} × ${cpu.cores}` : "—";

  cpuHistory.push(Number(cpu.percent || 0));
  if (cpuHistory.length > 60) cpuHistory.shift();
  drawCpuChart();

  const mem = data.memory || {};
  el("srv-mem-pct").textContent = `${mem.percent ?? 0}%`;
  el("srv-mem-detail").innerHTML = `<span>free ${mem.free_pct ?? 0}%</span><span>avail ${mem.avail_pct ?? 0}%</span>`;
  el("srv-mem-bar").style.width = `${Math.min(100, mem.percent || 0)}%`;
  el("srv-mem-sub").textContent = `共 ${formatBytes(mem.total || 0)} · 已用 ${formatBytes(mem.used || 0)}`;

  const swap = data.swap || {};
  el("srv-swap-pct").textContent = `${swap.percent ?? 0}%`;
  el("srv-swap-detail").innerHTML = `<span>cached ${swap.cached_pct ?? 0}%</span>`;
  el("srv-swap-bar").style.width = `${Math.min(100, swap.percent || 0)}%`;
  el("srv-swap-sub").textContent = `共 ${formatBytes(swap.total || 0)} · 已用 ${formatBytes(swap.used || 0)}`;

  el("srv-disk-list").innerHTML = (data.disks || []).map(dk => `
    <div class="srv-device-row">
      <svg viewBox="0 0 40 40" class="srv-ring"><circle cx="20" cy="20" r="16" class="ring-bg"/><circle cx="20" cy="20" r="16" class="ring-fg" data-dash="${(dk.percent||0).toFixed(1)}" transform="rotate(-90 20 20)"/><text x="20" y="25" class="ring-text">${dk.percent}%</text></svg>
      <div class="srv-device-info"><b>${escapeHtml(dk.device)} (${escapeHtml(dk.mount)})</b><small>已用 ${formatBytes(dk.used)} / ${formatBytes(dk.total)}</small><small>读 ${formatRateHuman(dk.read_bps)} | 写 ${formatRateHuman(dk.write_bps)}</small></div>
    </div>`).join("") || '<p class="form-hint">无磁盘信息</p>';

  el("srv-net-list").innerHTML = (data.networks || []).map(n => `
    <div class="srv-device-row">
      <div class="srv-device-info"><b>${escapeHtml(n.interface)}</b><small>↓ ${formatBytes(n.rx_bytes)} | ↑ ${formatBytes(n.tx_bytes)}</small><small class="srv-net-rate">↓ ${formatRateHuman(n.rx_bps)} · ↑ ${formatRateHuman(n.tx_bps)}</small></div>
    </div>`).join("") || '<p class="form-hint">无网络信息</p>';
}

function drawCpuChart() {
  const canvas = document.getElementById("srv-cpu-chart");
  if (!canvas || !canvas.parentElement.closest(".active-view")) return;
  const ctx = canvas.getContext("2d");
  const w = canvas.width, h = canvas.height;
  ctx.clearRect(0, 0, w, h);
  ctx.strokeStyle = "rgba(255,255,255,.08)";
  ctx.fillStyle = "#8d96aa";
  ctx.font = "10px Inter, sans-serif";
  for (let g = 0; g <= 4; g++) {
    const y = 8 + g * ((h - 16) / 4);
    ctx.beginPath(); ctx.moveTo(28, y); ctx.lineTo(w - 6, y); ctx.stroke();
    ctx.fillText(String(g * 25), 4, y + 3);
  }
  if (cpuHistory.length < 2) return;
  const grad = ctx.createLinearGradient(0, 0, 0, h);
  grad.addColorStop(0, "rgba(150,124,255,.35)");
  grad.addColorStop(1, "rgba(150,124,255,.02)");
  const step = (w - 34) / 59;
  ctx.beginPath();
  cpuHistory.forEach((v, i) => {
    const x = 28 + i * step;
    const y = 8 + (h - 16) * (1 - Math.min(100, v) / 100);
    i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
  });
  ctx.strokeStyle = "#d978ff";
  ctx.lineWidth = 1.6;
  ctx.stroke();
  ctx.lineTo(28 + (cpuHistory.length - 1) * step, h - 8);
  ctx.lineTo(28, h - 8);
  ctx.closePath();
  ctx.fillStyle = grad;
  ctx.fill();
}

async function loadServerStats() {
  try {
    const data = await api("/api/server/stats");
    renderServerStats(data);
    $("#srv-refresh-note") && ($("#srv-refresh-note").textContent = `每秒更新 · ${new Date().toLocaleTimeString("zh-CN", { hour12: false })}`);
  } catch (e) { /* 静默 */ }
}

function startServerStats() {
  stopServerStats();
  loadServerStats();
  serverStatsTimer = setInterval(loadServerStats, 1000);
}

function stopServerStats() {
  if (serverStatsTimer) { clearInterval(serverStatsTimer); serverStatsTimer = null; }
}


// ---------- 版本信息徽标 ----------
async function loadVersionBadge() {
  try {
    const info = await api("/api/server/info");
    const badge = $("#version-badge");
    if (badge) badge.textContent = `RR-vps ${info.script_version || "?"} · sing-box ${info.core_version || "?"}`;
  } catch (e) { /* 静默 */ }
}

// ---------- 流媒体解锁 ----------
function renderMediaUnlock(data) {
  const list = $("#srv-unlock-list");
  if (!list) return;
  const rows = (data.results || []).map(r => {
    const cls = r.status === "unlock" ? "unlock-yes" : r.status === "blocked" ? "unlock-no" : "unlock-unknown";
    return `<div class="srv-device-row"><span class="unlock-dot ${cls}"></span><div class="srv-device-info"><b>${escapeHtml(r.name)}</b><small>${escapeHtml(r.text)}</small></div></div>`;
  }).join("");
  list.innerHTML = rows;
  $("#srv-unlock-note").textContent = `解锁 ${data.unlock_count}/${data.total} · 检测于 ${data.checked_at || "—"}`;
}

async function loadMediaUnlock(refresh = false) {
  try {
    const data = await api(`/api/media-unlock${refresh ? "?refresh=1" : ""}`);
    renderMediaUnlock(data);
  } catch (e) { /* 静默 */ }
}

$("#unlock-refresh")?.addEventListener("click", () => { $("#srv-unlock-list").innerHTML = '<p class="form-hint">重新检测中…</p>'; loadMediaUnlock(true); });

// ---------- 防火墙工作区 ----------
function renderFirewallPermission(perm) {
  const body = $("#fw-perm-body");
  if (!body) return;
  const ok = perm.uid === 0 && perm.iptables && perm.rr_tool;
  body.innerHTML = ok
    ? '<p class="fw-ok">✅ 已授权：面板以 root 运行，iptables 与 rr 工具可用。</p>'
    : '<p class="fw-bad">⚠ 权限异常：<code>uid=' + perm.uid + '</code> iptables=' + perm.iptables + ' rr=' + perm.rr_tool + '。请查看下方「权限教程」操作。</p>';
}

function renderFirewallPorts(ports) {
  const list = $("#fw-port-list");
  if (!list) return;
  list.innerHTML = (ports || []).map(p => `
    <div class="srv-device-row">
      <div class="srv-device-info"><b>${escapeHtml(p.name)}</b><small>${p.port} / ${p.proto.toUpperCase()}</small></div>
      <button class="fw-toggle ${p.open === 1 ? "fw-on" : "fw-off"}${p.name.includes("SSH") ? " fw-locked" : ""}" data-fw-port="${p.port}" data-fw-proto="${p.proto}" ${p.name.includes("SSH") ? "disabled" : ""}>${p.name.includes("SSH") ? "🔒 保护" : (p.open === 1 ? "放行中" : "已关闭")}</button>
    </div>`).join("") || '<p class="form-hint">暂无端口</p>';
  $$("#fw-port-list .fw-toggle").forEach(btn => {
    btn.addEventListener("click", async () => {
      const action = btn.classList.contains("fw-on") ? "关闭" : "放行";
      if (!confirm(`确定要${action}端口 ${btn.dataset.fwPort} / ${btn.dataset.fwProto.toUpperCase()} 吗？`)) return;
      btn.disabled = true;
      try {
        const result = await api("/api/firewall/toggle", { method: "POST", body: JSON.stringify({ port: Number(btn.dataset.fwPort), proto: btn.dataset.fwProto }) });
        toast(result.action === "opened" ? "端口已放行" : result.action === "closed" ? "端口已关闭" : (result.error || "操作失败"), !result.ok);
        loadFirewall();
      } catch (e) { toast(e.message, true); }
    });
  });
}

async function loadFirewall() {
  try {
    const [info, fw] = await Promise.all([api("/api/server/info"), api("/api/firewall")]);
    renderFirewallPermission(info.firewall_permission || {});
    renderFirewallPorts(fw.ports || []);
    $("#fw-entry-now").textContent = info.entry_ip_mode || "—";
    $("#fw-outbound-now").textContent = info.outbound_ip_mode || "—";
    $("#fw-entry-select").value = ["auto", "ipv4", "ipv6"].includes(info.entry_ip_mode) ? info.entry_ip_mode : "auto";
    $("#fw-outbound-select").value = ["auto", "prefer_ipv4", "prefer_ipv6", "ipv4_only", "ipv6_only"].includes(info.outbound_ip_mode) ? info.outbound_ip_mode : "auto";
  } catch (e) { /* 静默 */ }
}

$("#fw-apply-ipmode")?.addEventListener("click", async () => {
  const entry = $("#fw-entry-select").value;
  const outbound = $("#fw-outbound-select").value;
  const msg = $("#fw-ipmode-msg");
  msg.textContent = "应用中（会重建配置并重启节点，约 5 秒）…";
  try {
    const result = await api("/api/firewall/ip-mode", { method: "POST", body: JSON.stringify({ entry, outbound }) });
    if (result.ok) {
      msg.textContent = `✅ 已应用：入口 ${result.entry} · 出口 ${result.outbound}`;
      $("#fw-entry-now").textContent = result.entry || entry;
      $("#fw-outbound-now").textContent = result.outbound || outbound;
      loadFirewall();
    }
    else { msg.textContent = `❌ 应用失败：${result.error || "未知错误"}`; }
  } catch (e) { msg.textContent = `❌ ${e.message}`; }
});

// ---------- 初始化 ----------
loadVersionBadge();

// ========== 多服务器远程管理（6.6.0） ==========
state.remoteServers = [];
state.remoteActive = null;
state.remoteCred = "";
state.remoteDevices = [];

// CSP style-src 'self' 拦截内联 style 属性（HTML 属性保留但 CSSOM 拒绝），
// 所有进度条宽度改经 CSSOM 赋值；MutationObserver 覆盖全部渲染路径。
function applyBarWidths(root) {
  const scope = root || document;
  scope.querySelectorAll(".quota-track i[data-w], .mini-progress i[data-w], .rs-bar i[data-w]").forEach(el => {
    el.style.width = Math.min(100, Math.max(0, Number(el.dataset.w) || 0)) + "%";
  });
  scope.querySelectorAll(".ring-fg[data-dash]").forEach(el => {
    el.style.strokeDasharray = el.dataset.dash + " 100";
  });
}
applyBarWidths();
new MutationObserver(mutations => {
  for (const m of mutations) if (m.addedNodes.length) applyBarWidths(document);
}).observe(document.body, { childList: true, subtree: true });
state._rsPrevTraffic = {};
state.remoteTimer = null;

function rsRemoteApi(method, path, body) {
  return api("/api/remote/proxy", { method: "POST", body: { server_id: state.remoteActive, method, path, body } });
}

function rsServerById(id) {
  return state.remoteServers.find(s => String(s.id) === String(id)) || null;
}

async function loadRemoteServers() {
  try {
    const list = await api("/api/remote-servers");
    state.remoteServers = list.servers || [];
    const empty = state.remoteServers.length === 0;
    $("#rs-empty").classList.toggle("hidden", !empty);
    $("#rs-grid").classList.toggle("hidden", empty);
    if (empty) return;
    try {
      const st = await api("/api/remote-servers/status", { method: "POST", body: {} });
      renderRemoteServers(st.servers || []);
    } catch (e) { renderRemoteServers(state.remoteServers.map(s => ({ ...s, online: false, ping: 0 }))); }
  } catch (e) { toast(e.message, true); }
}

function renderRemoteServers(servers) {
  state.remoteServers = servers.map(s => ({ ...rsServerById(s.id), ...s }));
  $("#rs-grid").innerHTML = state.remoteServers.map(s => {
    const online = Boolean(s.online);
    const cpu = Number(s.cpu || 0), mem = Number(s.mem || 0);
    const used = s.used_gb != null ? `${s.used_gb} GB` : "—";
    const chips = [];
    if (s.services) {
      const svc = s.services["sing-box"] === "active";
      chips.push(`<span class="rs-chip ${svc ? "g" : "r"}">节点 ${svc ? "在线" : "离线"}</span>`);
    }
    chips.push(`<span class="rs-chip b">${escapeHtml(s.active_devices ?? "—")} 实时在线 · ${escapeHtml(s.enabled ?? s.devices ?? 0)} 启用</span>`);
    chips.push(`<span class="rs-chip">${s.ver ? "v" + escapeHtml(s.ver) : "版本未知"}</span>`);
    if (s.ping) chips.push(`<span class="rs-chip">${escapeHtml(s.ping)} ms</span>`);
    if (!online) {
      if (s.state === "revoked") chips.push(`<span class="rs-chip r">钥匙已吊销 · 需重新添加</span>`);
      else if (s.state === "locked") chips.push(`<span class="rs-chip r">临时锁定 · 稍后自动恢复</span>`);
      else chips.push(`<span class="rs-chip r">已离线</span>`);
    }
    return `
    <div class="rs-card ${online ? "" : "offline"}" data-rs-open="${s.id}">
      <div class="rs-card-head"><span class="rs-dot ${online ? "on" : "off"}"></span><span class="rs-name">${escapeHtml(s.name)}</span><span class="rs-addr">${escapeHtml(s.addr || "")}</span></div>
      <div class="rs-metrics">
        <div class="rs-metric"><div class="k">CPU</div><div class="v">${online ? cpu + "%" : "—"}</div><div class="rs-bar"><i data-w="${Math.min(100, cpu)}"></i></div></div>
        <div class="rs-metric"><div class="k">内存</div><div class="v">${online ? mem + "%" : "—"}</div><div class="rs-bar"><i data-w="${Math.min(100, mem)}"></i></div></div>
        <div class="rs-metric"><div class="k">总用量</div><div class="v">${online ? used : "—"}</div></div>
      </div>
      <div class="rs-chips">${chips.join("")}</div>
      <div class="rs-card-foot"><span>${s.last_seen ? "上次同步 " + relativeTime(s.last_seen) : "未同步"}</span><span class="ops"><button data-rs-ren="${s.id}" title="修改备注名">✎ 改名</button><button data-rs-del="${s.id}" title="移除这台服务器">✕ 移除</button></span></div>
    </div>`;
  }).join("");
  $$("#rs-grid [data-rs-open]").forEach(card => card.addEventListener("click", e => {
    if (e.target.closest("[data-rs-del]") || e.target.closest("[data-rs-ren]")) return;
    rsOpenDetail(card.dataset.rsOpen);
  }));
  $$("#rs-grid [data-rs-del]").forEach(btn => btn.addEventListener("click", e => {
    e.stopPropagation();
    rsDeleteServer(btn.dataset.rsDel);
  }));
  $$("#rs-grid [data-rs-ren]").forEach(btn => btn.addEventListener("click", e => {
    e.stopPropagation();
    rsRenameServer(btn.dataset.rsRen);
  }));
}

async function rsRenameServer(id) {
  const server = rsServerById(id);
  if (!server) return;
  const name = prompt("修改备注名：", server.name);
  if (name === null) return;
  const trimmed = name.trim();
  if (!trimmed) { toast("备注名不能为空", true); return; }
  try {
    await api(`/api/remote-servers/${id}`, { method: "PATCH", body: { name: trimmed } });
    toast("备注名已更新");
    loadRemoteServers();
  } catch (e) { toast(e.message, true); }
}

async function rsCheckUpdate() {
  if (!state.remoteActive) return;
  const box = $("#rs-update-box");
  box.classList.remove("hidden");
  box.innerHTML = `<div class="rs-update-row"><span>⏳ 正在检查远程版本…</span></div>`;
  try {
    const r = await rsRemoteApi("POST", "/api/update/check", {});
    if (r.error) { box.innerHTML = `<div class="rs-update-row warn"><span>⚠️ ${escapeHtml(r.message || r.error)}</span></div>`; return; }
    if (r.manifest_checked === false) { box.innerHTML = `<div class="rs-update-row warn"><span>⚠️ 检查失败：无法连接更新源，请稍后重试</span></div>`; return; }
    const cur = r.current || "未知";
    if (r.update_available) {
      box.innerHTML = `<div class="rs-update-row"><span><b>发现新版本</b>：副面板当前 v${escapeHtml(cur)}，仓库已有更新</span><button class="button tiny primary" id="rs-update-run">⬆ 远程升级（自动拉起新版本）</button></div>`;
      const btn = $("#rs-update-run");
      if (btn) btn.addEventListener("click", rsRunUpdate);
    } else {
      box.innerHTML = `<div class="rs-update-row ok"><span>✅ 已是最新版本（v${escapeHtml(cur)}）</span></div>`;
    }
  } catch (e) {
    box.innerHTML = `<div class="rs-update-row warn"><span>⚠️ 检查失败：${escapeHtml(e.message)}</span></div>`;
  }
}

async function rsRunUpdate() {
  if (!state.remoteActive) return;
  if (!confirm("确认远程升级这台服务器吗？\n\n升级过程约 1-3 分钟：下载校验新版本 → 原子替换 → 自动重启节点服务与面板。全程不需要你登录该服务器。")) return;
  const box = $("#rs-update-box");
  box.innerHTML = `<div class="rs-update-row"><span>🚀 已下发升级任务，正在执行…</span></div>`;
  try {
    const run = await rsRemoteApi("POST", "/api/update/run", {});
    if (!run.started) { box.innerHTML = `<div class="rs-update-row warn"><span>⚠️ ${escapeHtml(run.message || "升级任务未启动")}</span></div>`; return; }
    // 轮询状态（升级中副面板会重启，请求失败=仍在升级）
    for (let i = 0; i < 72; i++) {
      await sleep(5000);
      try {
        const st = await rsRemoteApi("POST", "/api/update/status", {});
        if (st.state === "done") {
          box.innerHTML = `<div class="rs-update-row ok"><span>✅ ${escapeHtml(st.detail || "升级完成")}。正在刷新状态…</span></div>`;
          toast("远程升级完成，副面板已自动切换到新版本");
          await sleep(3000);
          rsOpenDetail(state.remoteActive);
          return;
        }
        if (st.state === "failed") {
          box.innerHTML = `<div class="rs-update-row warn"><span>❌ ${escapeHtml(st.detail || "升级失败")}${st.log_tail ? `\n\n${escapeHtml(st.log_tail)}` : ""}</span></div>`;
          toast("远程升级失败，详见提示", true);
          return;
        }
        if (st.state === "running") {
          const tail = st.log_tail ? st.log_tail.split("\n").filter(Boolean).slice(-2).join(" · ") : "";
          let hint = `⏳ 升级进行中（${Math.round((i + 1) * 5 / 60)} 分钟）…副面板重启属正常现象`;
          if (st.stalled) hint = `⚠️ 疑似卡住：升级日志 ${st.heartbeat_seconds ?? "?"} 秒无更新，最多再等 8 分钟将自动中止`;
          if (tail) hint += `\n📄 ${tail}`;
          box.innerHTML = `<div class="rs-update-row ${st.stalled ? "warn" : ""}"><span class="preline">${escapeHtml(hint)}</span></div>`;
        }
      } catch (e) { /* 副面板重启中，连接失败属预期 */ }
    }
    box.innerHTML = `<div class="rs-update-row warn"><span>⚠️ 升级超过 6 分钟仍在进行，请稍后点「检查更新」查看版本确认结果</span></div>`;
  } catch (e) {
    box.innerHTML = `<div class="rs-update-row warn"><span>❌ 下发失败：${escapeHtml(e.message)}</span></div>`;
  }
}

// ========== 主面板自身一键升级（本地直调 /api/update/*） ==========

async function loadLocalVersion() {
  try {
    const info = await api("/api/server/info");
    const ver = $("#local-ver");
    if (ver && info.script_version) ver.textContent = "v" + escapeHtml(info.script_version);
  } catch (e) { /* 静默 */ }
}

async function localCheckUpdate() {
  const box = $("#local-update-box");
  if (!box) return;
  box.classList.remove("hidden");
  box.innerHTML = `<div class="rs-update-row"><span>⏳ 正在检查版本…</span></div>`;
  try {
    const channel = $("#update-channel")?.value || "stable";
    const r = await api("/api/update/check", { method: "POST", body: { channel } });
    if (r.error) { box.innerHTML = `<div class="rs-update-row warn"><span>⚠️ ${escapeHtml(r.message || r.error)}</span></div>`; return; }
    if (r.manifest_checked === false) { box.innerHTML = `<div class="rs-update-row warn"><span>⚠️ 检查失败：无法连接更新源，请稍后重试</span></div>`; return; }
    const cur = r.current || "未知";
    const ver = $("#local-ver");
    if (ver) ver.textContent = "v" + escapeHtml(cur);
    if (r.preflight && r.preflight.ok === false) {
      box.innerHTML = `<div class="rs-update-row warn"><span>⚠️ 更新预检未通过：${escapeHtml(r.preflight.summary || r.preflight.error || "请先运行 rr doctor")}</span></div>`;
      return;
    }
    if (r.update_available) {
      box.innerHTML = `<div class="rs-update-row"><span><b>发现新版本</b>：当前 v${escapeHtml(cur)} · ${escapeHtml(r.channel || channel)} 通道 · 预检通过</span><button class="button tiny primary" id="local-update-run">⬆ 一键升级（自动拉起新版本）</button></div>`;
      const btn = $("#local-update-run");
      if (btn) btn.addEventListener("click", localRunUpdate);
    } else {
      box.innerHTML = `<div class="rs-update-row ok"><span>✅ 已是最新版本（v${escapeHtml(cur)}）</span></div>`;
    }
  } catch (e) {
    box.innerHTML = `<div class="rs-update-row warn"><span>⚠️ 检查失败：${escapeHtml(e.message)}</span></div>`;
  }
}

async function localRunUpdate() {
  if (!confirm("确认升级本面板吗？\n\n升级过程约 1-3 分钟：下载校验新版本 → 原子替换 → 自动重启节点服务与面板。升级期间面板会重启数次，页面短暂断连属正常现象。")) return;
  const box = $("#local-update-box");
  if (!box) return;
  box.classList.remove("hidden");
  box.innerHTML = `<div class="rs-update-row"><span>🚀 已下发升级任务，正在执行…</span></div>`;
  try {
    const run = await api("/api/update/run", { method: "POST", body: { channel: $("#update-channel")?.value || "stable" } });
    if (!run.started) { box.innerHTML = `<div class="rs-update-row warn"><span>⚠️ ${escapeHtml(run.message || "升级任务未启动")}</span></div>`; return; }
    // 轮询状态（升级中面板会重启，请求失败=仍在升级）
    for (let i = 0; i < 72; i++) {
      await sleep(5000);
      try {
        const st = await api("/api/update/status", { method: "POST", body: {} });
        if (st.state === "done") {
          box.innerHTML = `<div class="rs-update-row ok"><span>✅ ${escapeHtml(st.detail || "升级完成")}。正在刷新状态…</span></div>`;
          toast("升级完成，面板已自动切换到新版本");
          await sleep(3000);
          location.reload();
          return;
        }
        if (st.state === "failed") {
          box.innerHTML = `<div class="rs-update-row warn"><span>❌ ${escapeHtml(st.detail || "升级失败")}${st.log_tail ? `\n\n${escapeHtml(st.log_tail)}` : ""}</span></div>`;
          toast("升级失败，详见提示", true);
          return;
        }
        if (st.state === "running") {
          const tail = st.log_tail ? st.log_tail.split("\n").filter(Boolean).slice(-2).join(" · ") : "";
          let hint = `⏳ 升级进行中（${Math.round((i + 1) * 5 / 60)} 分钟）…面板重启属正常现象`;
          if (st.stalled) hint = `⚠️ 疑似卡住：升级日志 ${st.heartbeat_seconds ?? "?"} 秒无更新，最多再等 8 分钟将自动中止`;
          if (tail) hint += `\n📄 ${tail}`;
          box.innerHTML = `<div class="rs-update-row ${st.stalled ? "warn" : ""}"><span class="preline">${escapeHtml(hint)}</span></div>`;
        }
      } catch (e) { /* 面板重启中，连接失败属预期 */ }
    }
    box.innerHTML = `<div class="rs-update-row warn"><span>⚠️ 升级超过 6 分钟仍在进行，请稍后点「检查更新」查看版本确认结果</span></div>`;
  } catch (e) {
    box.innerHTML = `<div class="rs-update-row warn"><span>❌ 下发失败：${escapeHtml(e.message)}</span></div>`;
  }
}

async function rsDeleteServer(id) {
  const server = rsServerById(id);
  if (!server) return;
  if (!confirm(`确定移除「${server.name}」吗？\n（副面板侧可随时吊销钥匙）`)) return;
  try {
    await api(`/api/remote-servers/${id}`, { method: "DELETE" });
    toast("已移除");
    loadRemoteServers();
  } catch (e) { toast(e.message, true); }
}

async function rsOpenDetail(id) {
  const server = rsServerById(id);
  if (!server) return;
  state.remoteActive = id;
  $("#view-remote .section-toolbar").classList.add("hidden");
  $("#rs-grid").classList.add("hidden");
  $("#rs-empty").classList.add("hidden");
  $("#rs-detail").classList.remove("hidden");
  $("#rs-detail-title").textContent = server.name;
  $("#rs-detail-sub").textContent = `${server.addr} · 远程管理（副面板全权限）`;
  $("#rs-update-box").classList.add("hidden");
  await Promise.all([rsLoadDevices(), rsLoadServerPlan()]);
  if (state.remoteTimer) clearInterval(state.remoteTimer);
  state.remoteTimer = setInterval(() => {
    rsLoadDevices();
    rsLoadServerPlan(false);
  }, 3000);
}

function rsBack() {
  if (state.remoteTimer) { clearInterval(state.remoteTimer); state.remoteTimer = null; }
  state._rsPrevTraffic = {};
  state.remoteActive = null;
  $("#rs-detail").classList.add("hidden");
  $("#view-remote .section-toolbar").classList.remove("hidden");
  loadRemoteServers();
}

async function rsLoadDevices() {
  try {
    const data = await rsRemoteApi("GET", "/api/devices");
    state.remoteDevices = data.devices || [];
    renderRemoteDevices(data.devices || []);
  } catch (e) { toast(e.message, true); }
}

async function rsLoadServerPlan(notify = true) {
  if (!state.remoteActive) return;
  try {
    const data = await rsRemoteApi("GET", "/api/server/traffic-policy", {});
    renderServerPlan(data.policy || {}, "rs-");
  } catch (error) { if (notify) toast(error.message, true); }
}

function renderRemoteDevices(devices) {
  const grid = $("#rs-device-grid");
  $("#rs-device-empty").classList.toggle("hidden", devices.length > 0);
  grid.classList.toggle("hidden", devices.length === 0);
  grid.innerHTML = devices.map(device => {
    const quota = Number(device.quota_bytes || 0);
    const used = Number(device.used_bytes || 0);
    const percent = quota ? Math.min(100, used / quota * 100) : 0;
    const enabled = device.enabled === 1 || device.enabled === true;
    const active = device.active === true || device.active === 1 || enabled;
    const quotaLabel = quota ? `${formatBytes(used)} / ${formatBytes(quota)}` : `${formatBytes(used)} · 不限`;
    const expiry = device.expires_at || "长期有效";
    const resetPlan = device.next_reset_at
      ? `${device.next_reset_at} · 剩余 ${device.reset_remaining} 次`
      : Number(device.reset_max || 0) ? "自动重置已完成" : "未设置";
    return `
    <article class="device-card glass ${enabled ? "" : "disabled"}" data-rs-dev="${escapeHtml(device.id)}">
      <div class="device-top"><span class="device-avatar">◇</span><span class="status-pill ${active ? "" : "off"}"><i></i>${statusLabel(device)}</span></div>
      <h3 class="device-name">${escapeHtml(device.name)}</h3><span class="device-id">${escapeHtml(device.id)}</span>
      <div class="device-traffic"><div><small>上传</small><b>↑ ${formatBytes(device.uploaded_bytes)}</b></div><div><small>下载</small><b>↓ ${formatBytes(device.downloaded_bytes)}</b></div><div class="traffic-total"><small>总流量</small><b>${formatBytes(used)}</b></div></div>
      <div class="device-rate"><small>实时速率</small><span class="r-up">↑ ${formatRate(rsRateOf(device.id, device.uploaded_bytes))}</span><span class="r-down">↓ ${formatRate(rsRateOf(device.id, device.downloaded_bytes, true))}</span></div>
      <div class="quota-block"><div><small>${quota ? "流量额度" : "流量额度不限"}</small><span>${quotaLabel}</span></div>${quota ? `<div class="quota-track"><i data-w="${percent.toFixed(1)}"></i></div>` : ""}</div>
      <div class="device-meta"><span><small>到期时间</small><b>${escapeHtml(expiry)}</b></span><span><small>自动重置</small><b>${escapeHtml(resetPlan)}</b></span></div>
      <div class="device-actions">
        <button data-rs-links="${escapeHtml(device.id)}">链接与二维码</button>
        <button data-rs-rename="${escapeHtml(device.id)}">改备注</button>
        <button data-rs-reset="${escapeHtml(device.id)}">重置流量</button>
        <button data-rs-toggle="${escapeHtml(device.id)}">${enabled ? "暂停" : "启用"}</button>
        <button class="danger" data-rs-del="${escapeHtml(device.id)}" title="删除">×</button>
      </div>
    </article>`;
  }).join("");
  $$("#rs-device-grid [data-rs-links]").forEach(btn => btn.addEventListener("click", () => rsOpenLinks(btn.dataset.rsLinks)));
  $$("#rs-device-grid [data-rs-rename]").forEach(btn => btn.addEventListener("click", () => {
    const device = (state.remoteDevices || []).find(item => String(item.id) === String(btn.dataset.rsRename));
    if (device) openRenameDialog(device, true);
  }));
  $$("#rs-device-grid [data-rs-toggle]").forEach(btn => btn.addEventListener("click", () => rsToggleDevice(btn.dataset.rsToggle)));
  $$("#rs-device-grid [data-rs-reset]").forEach(btn => btn.addEventListener("click", () => rsResetDevice(btn.dataset.rsReset)));
  $$("#rs-device-grid [data-rs-del]").forEach(btn => btn.addEventListener("click", () => rsDeleteDevice(btn.dataset.rsDel)));
}

async function rsOpenLinks(id) {
  const device = (state.remoteDevices || []).find(d => String(d.id) === String(id));
  if (!device) { toast("未找到该设备，请刷新重试", true); return; }
  const list = $("#links-list");
  $("#links-title").textContent = `${device.name} · 连接信息（远程服务器）`;
  list.innerHTML = '<p class="form-hint">正在生成…</p>';
  $("#links-dialog").showModal();
  try {
    const data = await rsRemoteApi("GET", `/api/devices/${id}/links`);
    const box = $("#subscription-box");
    const urls = data.subscription_urls || [];
    box.classList.toggle("hidden", urls.length === 0);
    const qrUrlOf = (params) => `/api/remote/qr?server_id=${state.remoteActive}&device_id=${encodeURIComponent(id)}&${params}`;
    $("#subscription-urls").innerHTML = urls.map((item) => {
      const qrUrl = qrUrlOf(`raw=${encodeURIComponent(item.url)}`);
      return `<div class="sub-url-row"><b>${escapeHtml(item.format)}</b><small>${escapeHtml(item.name)}</small><code>${escapeHtml(item.url)}</code><img class="sub-qr" src="${qrUrl}" alt="订阅二维码"><button class="copy-button" data-copy-sub-url="${escapeHtml(item.url)}">复制</button><button class="copy-button" data-remote-open-sub-qr="${encodeURIComponent(qrUrl)}">打开二维码</button></div>`;
    }).join("");
    list.innerHTML = data.links.length ? data.links.map((link, index) => {
      const qrUrl = qrUrlOf(`index=${index}`);
      return `<div class="link-row"><img src="${qrUrl}" alt="${escapeHtml(protocolName(link))} 二维码"><div class="link-content"><b>${escapeHtml(protocolName(link))}</b><code>${escapeHtml(link)}</code></div><div class="link-actions"><button data-copy-link="${index}">复制链接</button><button data-remote-open-qr="${encodeURIComponent(qrUrl)}">打开二维码</button></div></div>`;
    }).join("") : '<p class="form-hint">当前没有启用的节点协议。</p>';
    list.dataset.links = JSON.stringify(data.links);
    list.dataset.device = id;
    list.dataset.remote = "1";
  } catch (error) { list.innerHTML = `<p class="form-error">${escapeHtml(error.message)}</p>`; }
}

function rsRateOf(id, bytes, isDown) {
  // 远程设备实时速率：与 local 面板同款差分算法，独立命名空间
  const nowTs = Date.now();
  const prev = (state._rsPrevTraffic[id] || { up: 0, down: 0, ts: nowTs - 3000 });
  const elapsed = Math.max(1, (nowTs - prev.ts) / 1000);
  const rate = Math.max(0, ((bytes || 0) - (isDown ? prev.down : prev.up)) / elapsed);
  if (isDown) state._rsPrevTraffic[id] = { up: prev.up, down: bytes || 0, ts: nowTs };
  else state._rsPrevTraffic[id] = { up: bytes || 0, down: prev.down, ts: nowTs };
  return rate;
}

async function rsToggleDevice(id) {
  const device = (state.remoteDevices || []).find(d => String(d.id) === String(id));
  if (!device) { toast("未找到该设备，请刷新重试", true); return; }
  const enabled = device.enabled === 1 || device.enabled === true;
  try {
    await rsRemoteApi("PATCH", `/api/devices/${id}`, { enabled: !enabled });
    toast(enabled ? "设备已停用（断网）" : "设备已启用");
    delete state._rsPrevTraffic[id];
    rsLoadDevices();
  } catch (e) { toast(e.message, true); }
}

async function rsResetDevice(id) {
  const device = (state.remoteDevices || []).find(item => String(item.id) === String(id));
  if (!device) { toast("未找到该设备，请刷新重试", true); return; }
  openResetDialog(device, true);
}

async function rsDeleteDevice(id) {
  const name = $(`[data-rs-dev="${id}"] b`)?.textContent || id;
  if (!confirm(`确定删除设备「${name}」吗？其订阅将立即失效。`)) return;
  try {
    await rsRemoteApi("DELETE", `/api/devices/${id}`);
    toast("设备已删除");
    rsLoadDevices();
  } catch (e) { toast(e.message, true); }
}

async function rsCreateDevice() {
  openCreate(true);
}

// ---- 副面板：远程钥匙 ----
async function rsKeyLoad() {
  try {
    const st = await api("/api/remote/status", { method: "POST", body: {} });
    const stateEl = $("#rs-key-state");
    stateEl.textContent = st.enabled ? "可签发" : "不可签发";
    stateEl.classList.toggle("safe", Boolean(st.enabled));
    stateEl.classList.toggle("warn", !st.enabled);
    $("#rs-key-state-note").textContent = st.enabled ? "公网证书面板 · 可生成接入钥匙" : (st.reason || "仅公网证书面板可签发");
    $("#rs-key-issue").classList.toggle("hidden", !st.enabled);
  } catch (e) { /* 静默 */ }
}

async function rsKeyIssue() {
  const name = prompt("给这把钥匙起个名字（显示在钥匙里，如：香港 HKS4）：", $("#rs-key-state-note").dataset.name || "");
  if (name === null) return;
  try {
    const result = await api("/api/remote/issue", { method: "POST", body: { name: name || "远程服务器" } });
    $("#rs-key-text").textContent = result.cred;
    $("#rs-key-box-wrap").classList.remove("hidden");
    toast("钥匙已生成，复制后粘贴到主面板即可");
  } catch (e) { toast(e.message, true); }
}

async function rsKeyRevoke() {
  if (!confirm("确定吊销全部远程钥匙吗？\n所有主面板持有的旧钥匙将立即失效。")) return;
  try {
    await api("/api/remote/revoke", { method: "POST", body: {} });
    $("#rs-key-box-wrap").classList.add("hidden");
    $("#rs-key-text").textContent = "";
    toast("全部旧钥匙已吊销，可重新生成");
  } catch (e) { toast(e.message, true); }
}

// ---- 事件绑定 ----
$("#rs-add-open")?.addEventListener("click", () => $("#rs-add-dialog").showModal());
$("#rs-refresh")?.addEventListener("click", loadRemoteServers);
$("#rs-back")?.addEventListener("click", rsBack);
$("#rs-update-btn")?.addEventListener("click", rsCheckUpdate);
$("#local-update-btn")?.addEventListener("click", localCheckUpdate);
$("#local-update-run-btn")?.addEventListener("click", localRunUpdate);
const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));
$("#rs-device-add")?.addEventListener("click", rsCreateDevice);
$("#rs-server-traffic-form")?.addEventListener("submit", event => saveServerPlan(event, true));
$("#rs-server-plan-reset")?.addEventListener("click", () => resetServerPlan(true));
$("#rs-key-issue")?.addEventListener("click", rsKeyIssue);
$("#rs-key-revoke")?.addEventListener("click", rsKeyRevoke);
$("#rs-key-copy")?.addEventListener("click", async () => {
  const text = $("#rs-key-text").textContent;
  if (!text) return;
  try { await navigator.clipboard.writeText(text); toast("钥匙已复制"); }
  catch (e) { prompt("手动复制钥匙：", text); }
});
$$("[data-rs-add-close]").forEach(btn => btn.addEventListener("click", () => $("#rs-add-dialog").close()));
$("#rs-add-form")?.addEventListener("submit", async e => {
  e.preventDefault();
  const form = e.target;
  const name = form.rs_name.value.trim();
  const cred = form.rs_cred.value.trim();
  const err = $("#rs-add-error");
  err.textContent = "";
  $("#rs-add-submit").disabled = true;
  try {
    await api("/api/remote-servers", { method: "POST", body: { name, cred } });
    $("#rs-add-dialog").close();
    form.reset();
    toast("服务器已添加并验证通过");
    loadRemoteServers();
  } catch (error) {
    err.textContent = error.message || "添加失败";
  } finally {
    $("#rs-add-submit").disabled = false;
  }
});


/* 6.6.18 订阅地址「打开二维码」按钮（与单节点一致：新窗口大图） */
document.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-open-sub-qr]");
  if (btn) window.open(btn.dataset.openSubQr, "_blank", "noopener");
});
