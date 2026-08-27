"use strict";

// RR Nexus 7.1 feature module: MFA/passkeys, alert center, long-term metrics,
// device groups/templates and single-transaction batch operations.
(() => {
  const adminState = { groups: [], templates: [], selected: new Set(), security: null };

  const fromB64 = value => {
    const raw = atob(String(value).replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "="));
    return Uint8Array.from(raw, char => char.charCodeAt(0)).buffer;
  };
  const toB64 = value => {
    const raw = String.fromCharCode(...new Uint8Array(value));
    return btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  };

  function restoreSelections() {
    $$('[data-device-select]').forEach(input => { input.checked = adminState.selected.has(input.dataset.deviceSelect); });
    updateBatchCount();
  }

  const originalRenderDevices = renderDevices;
  renderDevices = function renderDevicesWithSelection() {
    originalRenderDevices();
    restoreSelections();
  };

  function updateBatchCount() {
    const count = adminState.selected.size;
    $("#batch-count").textContent = `已选 ${count} 台`;
    const current = visibleDevices();
    const all = current.length > 0 && current.every(device => adminState.selected.has(device.id));
    $("#device-select-all").checked = all;
    $("#device-select-all").indeterminate = !all && current.some(device => adminState.selected.has(device.id));
  }

  async function loadOrganization() {
    if (!state.csrf) return;
    try {
      const [groupData, templateData] = await Promise.all([
        api("/api/device-groups"), api("/api/device-templates"),
      ]);
      adminState.groups = groupData.groups || [];
      adminState.templates = templateData.templates || [];
      renderOrganization();
    } catch (error) {
      toast(error.message, true);
    }
  }

  function renderOrganization() {
    const groupOptions = adminState.groups.map(group => `<option value="${group.id}">${escapeHtml(group.name)} · ${group.device_count}</option>`).join("");
    $("#device-group-filter").innerHTML = `<option value="all">全部分组</option><option value="">未分组</option>${groupOptions}`;
    $("#device-group-filter").value = state.groupFilter;
    $("#device-form-group").innerHTML = `<option value="">未分组</option>${groupOptions}`;
    $("#device-form-template").innerHTML = `<option value="">不使用模板</option>${adminState.templates.map(item => `<option value="${item.id}">${escapeHtml(item.name)}</option>`).join("")}`;
    $("#group-list").innerHTML = adminState.groups.map(group => `<div class="compact-row"><i style="background:${escapeHtml(group.color)}"></i><span><b>${escapeHtml(group.name)}</b><small>${group.device_count} 台设备</small></span><button data-delete-group="${group.id}">删除</button></div>`).join("") || '<p class="form-hint">还没有分组。</p>';
    $("#template-list").innerHTML = adminState.templates.map(item => `<div class="compact-row"><span><b>${escapeHtml(item.name)}</b><small>${formatBytes(item.quota_bytes)} · ${item.expiry_days || "长期"} 天 · ${item.reset_max || 0} 月</small></span><button data-delete-template="${item.id}">删除</button></div>`).join("") || '<p class="form-hint">还没有模板。</p>';
    updateBatchTarget();
  }

  function dateInputValue(date) {
    return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()))
      .toISOString().slice(0, 10);
  }

  function addUtcMonth(date) {
    const year = date.getUTCFullYear();
    const month = date.getUTCMonth() + 1;
    const day = date.getUTCDate();
    const lastDay = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
    return new Date(Date.UTC(year, month, Math.min(day, lastDay)));
  }

  function applyDeviceTemplate() {
    const form = $("#device-form");
    const template = adminState.templates.find(item => String(item.id) === $("#device-form-template").value);
    if (!template) {
      form.elements.quota_gb.value = "0";
      form.elements.expires_at.value = "";
      form.elements.reset_at.value = "";
      form.elements.reset_max.value = "0";
      return;
    }
    const now = new Date();
    form.elements.quota_gb.value = String(Number(template.quota_bytes || 0) / 1024 ** 3);
    form.elements.expires_at.value = Number(template.expiry_days || 0) > 0
      ? dateInputValue(new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + Number(template.expiry_days))))
      : "";
    form.elements.reset_at.value = Number(template.reset_max || 0) > 0 ? dateInputValue(addUtcMonth(now)) : "";
    form.elements.reset_max.value = String(Number(template.reset_max || 0));
  }

  function updateBatchTarget() {
    const action = $("#batch-action").value;
    const target = $("#batch-target");
    if (action === "move_group") {
      target.innerHTML = `<option value="">未分组</option>${adminState.groups.map(item => `<option value="${item.id}">${escapeHtml(item.name)}</option>`).join("")}`;
      target.classList.remove("hidden");
    } else if (action === "apply_template") {
      target.innerHTML = adminState.templates.map(item => `<option value="${item.id}">${escapeHtml(item.name)}</option>`).join("");
      target.classList.toggle("hidden", !adminState.templates.length);
    } else {
      target.classList.add("hidden");
    }
  }

  async function runBatch() {
    const action = $("#batch-action").value;
    const ids = [...adminState.selected];
    if (!action || !ids.length) return toast("请先选择设备和批量操作。", true);
    if (action === "delete" && !confirm(`确定删除选中的 ${ids.length} 台设备？所有旧凭据会立即失效。`)) return;
    const body = { action, device_ids: ids };
    if (action === "move_group") body.group_id = $("#batch-target").value || null;
    if (action === "apply_template") body.template_id = Number($("#batch-target").value || 0);
    try {
      const result = await api("/api/devices/batch", { method: "POST", body });
      adminState.selected.clear();
      await refreshLive(false);
      toast(`批量操作完成：${result.changed} 台设备。`);
    } catch (error) { toast(error.message, true); }
  }

  async function loadSecurity() {
    if (!state.csrf) return;
    try {
      const [security, alerts] = await Promise.all([api("/api/security"), api("/api/notifications")]);
      adminState.security = security;
      $("#totp-state").textContent = security.totp_enabled ? "已开启" : "未开启";
      $("#totp-state").className = security.totp_enabled ? "safe" : "warn";
      $("#totp-enable").classList.toggle("hidden", security.totp_enabled);
      $("#totp-disable").classList.toggle("hidden", !security.totp_enabled);
      $("#passkey-add").disabled = !security.passkey_available;
      $("#security-mfa-note").textContent = security.passkey_available
        ? `剩余 ${security.recovery_codes_remaining} 个恢复码。Passkey 可用于免密码登录。`
        : "Passkey 需要 HTTPS 域名，或通过 127.0.0.1 本地隧道访问。";
      $("#passkey-list").innerHTML = (security.passkeys || []).map(item => `<div class="compact-row"><span><b>${escapeHtml(item.name)}</b><small>${escapeHtml(item.transports || "平台/安全密钥")} · ${new Date(item.created_at).toLocaleDateString("zh-CN")}</small></span><button data-delete-passkey="${escapeHtml(item.credential_id)}">删除</button></div>`).join("") || '<p class="form-hint">尚未添加 Passkey。</p>';
      const settings = alerts.settings || {};
      const form = $("#notification-form");
      form.enabled.checked = Boolean(settings.enabled);
      form.telegram_token.value = settings.telegram_token || "";
      form.telegram_chat_id.value = settings.telegram_chat_id || "";
      form.webhook_url.value = settings.webhook_url || "";
      form.webhook_secret.value = settings.webhook_secret || "";
      form.disk_threshold.value = settings.disk_threshold || 90;
      form.traffic_threshold.value = settings.traffic_threshold || 90;
    } catch (error) { toast(error.message, true); }
  }

  async function beginTotp() {
    try {
      const data = await api("/api/security/totp/begin", { method: "POST", body: {} });
      $("#totp-secret").textContent = data.secret;
      $("#totp-qr").src = "/api/security/totp/qr?t=" + Date.now();
      $("#totp-error").textContent = "";
      $("#totp-dialog").showModal();
    } catch (error) { toast(error.message, true); }
  }

  async function addPasskey() {
    if (!window.PublicKeyCredential) return toast("当前浏览器不支持 Passkey。", true);
    const name = prompt("给这个 Passkey 起一个名称：", "我的设备");
    if (name === null) return;
    try {
      const begin = await api("/api/security/passkeys/register/begin", { method: "POST", body: {} });
      const options = begin.publicKey;
      options.challenge = fromB64(options.challenge);
      options.user.id = fromB64(options.user.id);
      options.excludeCredentials = (options.excludeCredentials || []).map(item => ({ ...item, id: fromB64(item.id) }));
      const credential = await navigator.credentials.create({ publicKey: options });
      const transports = credential.response.getTransports ? credential.response.getTransports() : [];
      await api("/api/security/passkeys/register/finish", { method: "POST", body: {
        challenge_id: begin.challenge_id, name,
        credential_id: toB64(credential.rawId),
        client_data: toB64(credential.response.clientDataJSON),
        attestation: toB64(credential.response.attestationObject), transports,
      }});
      toast("Passkey 已添加。");
      await loadSecurity();
    } catch (error) { toast(error.name === "NotAllowedError" ? "已取消 Passkey 操作。" : error.message, true); }
  }

  async function passkeyLogin() {
    if (!window.PublicKeyCredential) return $("#login-error").textContent = "当前浏览器不支持 Passkey。";
    try {
      const begin = await api("/api/passkeys/login/begin", { method: "POST", body: {} });
      const options = begin.publicKey;
      options.challenge = fromB64(options.challenge);
      const credential = await navigator.credentials.get({ publicKey: options });
      await api("/api/passkeys/login/finish", { method: "POST", body: {
        challenge_id: begin.challenge_id, credential_id: toB64(credential.rawId),
        client_data: toB64(credential.response.clientDataJSON),
        authenticator_data: toB64(credential.response.authenticatorData),
        signature: toB64(credential.response.signature),
        user_handle: credential.response.userHandle ? toB64(credential.response.userHandle) : "",
      }});
      const session = await api("/api/session");
      showConsole(session);
      await refreshLive(false);
    } catch (error) { $("#login-error").textContent = error.name === "NotAllowedError" ? "已取消 Passkey 登录。" : error.message; }
  }

  function drawSystemChart(samples) {
    const canvas = $("#system-history-chart");
    const empty = $("#system-history-empty");
    empty.classList.toggle("hidden", Boolean(samples.length));
    canvas.classList.toggle("hidden", !samples.length);
    if (!samples.length || !canvas.clientWidth) return;
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    const width = canvas.clientWidth, height = canvas.clientHeight;
    canvas.width = width * ratio; canvas.height = height * ratio;
    const ctx = canvas.getContext("2d"); ctx.scale(ratio, ratio); ctx.clearRect(0, 0, width, height);
    const pad = { left: 44, right: 14, top: 12, bottom: 25 };
    const cw = width - pad.left - pad.right, ch = height - pad.top - pad.bottom;
    ctx.strokeStyle = "rgba(255,255,255,.08)"; ctx.fillStyle = "#7f8aa3"; ctx.font = "10px sans-serif";
    for (let i = 0; i <= 4; i++) {
      const y = pad.top + ch * i / 4; ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(width - pad.right, y); ctx.stroke();
      ctx.fillText(`${100 - i * 25}%`, 5, y + 3);
    }
    const min = samples[0].bucket, max = samples.at(-1).bucket || min + 1;
    const plot = (key, color) => {
      ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.beginPath();
      samples.forEach((sample, index) => {
        const x = pad.left + (sample.bucket - min) / Math.max(1, max - min) * cw;
        const y = pad.top + ch - Math.min(100, Number(sample[key] || 0)) / 100 * ch;
        index ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
      }); ctx.stroke();
    };
    plot("cpu_percent", "#6ce6ce"); plot("memory_percent", "#967cff"); plot("disk_percent", "#f5c86c");
  }

  async function loadMetrics(notify = true) {
    if (!state.csrf) return;
    try {
      const data = await api(`/api/metrics?range=${encodeURIComponent(state.metricRange)}`);
      drawSystemChart(data.samples || []);
    } catch (error) { if (notify) toast(error.message, true); }
  }

  $("#passkey-login").addEventListener("click", passkeyLogin);
  $("#totp-enable").addEventListener("click", beginTotp);
  $("#totp-disable").addEventListener("click", async () => {
    const password = prompt("请输入当前管理员密码："); if (password === null) return;
    const code = prompt("请输入当前 6 位动态码："); if (code === null) return;
    try { await api("/api/security/totp/disable", { method: "POST", body: { password, code } }); await loadSecurity(); toast("TOTP 已关闭。"); }
    catch (error) { toast(error.message, true); }
  });
  $("#totp-form").addEventListener("submit", async event => {
    event.preventDefault();
    try { await api("/api/security/totp/confirm", { method: "POST", body: { code: new FormData(event.currentTarget).get("code") } }); $("#totp-dialog").close(); await loadSecurity(); toast("TOTP 两步验证已启用。"); }
    catch (error) { $("#totp-error").textContent = error.message; }
  });
  $$('[data-close-totp]').forEach(button => button.addEventListener("click", () => $("#totp-dialog").close()));
  $("#passkey-add").addEventListener("click", addPasskey);
  $("#passkey-list").addEventListener("click", async event => {
    const button = event.target.closest("[data-delete-passkey]"); if (!button) return;
    if (!confirm("确定删除这个 Passkey？")) return;
    try { await api(`/api/security/passkeys/${encodeURIComponent(button.dataset.deletePasskey)}`, { method: "DELETE" }); await loadSecurity(); }
    catch (error) { toast(error.message, true); }
  });

  $("#notification-form").addEventListener("submit", async event => {
    event.preventDefault(); const form = event.currentTarget;
    const body = {
      enabled: form.enabled.checked, telegram_token: form.telegram_token.value.trim(),
      telegram_chat_id: form.telegram_chat_id.value.trim(), webhook_url: form.webhook_url.value.trim(),
      webhook_secret: form.webhook_secret.value, disk_threshold: Number(form.disk_threshold.value),
      traffic_threshold: Number(form.traffic_threshold.value),
      events: ["service_down", "disk_high", "traffic_threshold", "certificate_expiry", "device_quota", "update_failed", "backup_failed", "security_lockout", "argo_domain_changed"],
    };
    try { await api("/api/notifications", { method: "POST", body }); await loadSecurity(); toast("告警设置已保存。"); }
    catch (error) { toast(error.message, true); }
  });
  $("#notification-test").addEventListener("click", async () => {
    try { await api("/api/notifications/test", { method: "POST", body: {} }); toast("测试消息已发送。"); }
    catch (error) { toast(error.message, true); }
  });

  $("#device-grid").addEventListener("change", event => {
    const input = event.target.closest("[data-device-select]"); if (!input) return;
    input.checked ? adminState.selected.add(input.dataset.deviceSelect) : adminState.selected.delete(input.dataset.deviceSelect);
    updateBatchCount();
  });
  $("#device-select-all").addEventListener("change", event => {
    visibleDevices().forEach(device => event.target.checked ? adminState.selected.add(device.id) : adminState.selected.delete(device.id));
    restoreSelections();
  });
  $("#batch-action").addEventListener("change", updateBatchTarget);
  $("#batch-apply").addEventListener("click", runBatch);
  $("#device-form-template").addEventListener("change", applyDeviceTemplate);
  $("#device-admin-open").addEventListener("click", () => { renderOrganization(); $("#device-admin-dialog").showModal(); });
  $$('[data-close-device-admin]').forEach(button => button.addEventListener("click", () => $("#device-admin-dialog").close()));

  $("#group-form").addEventListener("submit", async event => {
    event.preventDefault(); const data = new FormData(event.currentTarget);
    try { await api("/api/device-groups", { method: "POST", body: { name: data.get("name"), color: data.get("color") } }); event.currentTarget.reset(); await loadOrganization(); }
    catch (error) { toast(error.message, true); }
  });
  $("#template-form").addEventListener("submit", async event => {
    event.preventDefault(); const form = event.currentTarget, data = new FormData(form);
    try { await api("/api/device-templates", { method: "POST", body: { name: data.get("name"), quota_gb: Number(data.get("quota_gb")), expiry_days: Number(data.get("expiry_days")), reset_max: Number(data.get("reset_max")), enabled: form.enabled.checked } }); form.reset(); form.enabled.checked = true; await loadOrganization(); }
    catch (error) { toast(error.message, true); }
  });
  $("#group-list").addEventListener("click", async event => {
    const button = event.target.closest("[data-delete-group]"); if (!button || !confirm("删除分组？组内设备会变为未分组。")) return;
    try { await api(`/api/device-groups/${button.dataset.deleteGroup}`, { method: "DELETE" }); await loadOrganization(); await loadDevices(false); }
    catch (error) { toast(error.message, true); }
  });
  $("#template-list").addEventListener("click", async event => {
    const button = event.target.closest("[data-delete-template]"); if (!button || !confirm("删除模板？现有设备不受影响。")) return;
    try { await api(`/api/device-templates/${button.dataset.deleteTemplate}`, { method: "DELETE" }); await loadOrganization(); }
    catch (error) { toast(error.message, true); }
  });

  $$('[data-metric-range]').forEach(button => button.addEventListener("click", async () => {
    state.metricRange = button.dataset.metricRange;
    $$('[data-metric-range]').forEach(item => item.classList.toggle("active", item === button));
    await Promise.all([loadTraffic(false), loadMetrics(false)]);
  }));
  window.addEventListener("resize", () => loadMetrics(false));

  window.RRAdmin = {
    onConsole: () => { loadOrganization(); },
    loadOrganization,
    loadSecurity,
    loadMetrics,
  };
})();
