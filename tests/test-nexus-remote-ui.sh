#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
APP_JS=${APP_JS:-"$REPO_ROOT/nexus/static/app.js"}
node --check "$APP_JS"
node - "$APP_JS" <<'JS'
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(process.argv[2], 'utf8');
const pending = () => {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return { promise, resolve, reject };
};
const drain = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function fixture() {
  const nodes = new Map(), intervals = new Map(), timeouts = [], requests = [], notices = [], confirmations = [];
  let clock = 10000, timerId = 0;
  const node = selector => {
    if (!nodes.has(selector)) {
      const classes = new Set();
      nodes.set(selector, {
        dataset: {}, style: {}, value: '', innerHTML: '', textContent: '', disabled: false, open: false,
        classList: {
          add: name => classes.add(name), remove: name => classes.delete(name), contains: name => classes.has(name),
          toggle(name, on) { const add = on === undefined ? !classes.has(name) : on; add ? classes.add(name) : classes.delete(name); },
        },
        addEventListener() {}, querySelector: node, querySelectorAll: () => [], contains: () => false,
        showModal() { this.open = true; }, close() { this.open = false; }, reset() {}, focus() {},
      });
    }
    return nodes.get(selector);
  };
  const controls = [node('#rs-server-plan-quota'), node('#rs-server-plan-mode'), node('#rs-server-plan-interface'), node('#rs-server-plan-current'), node('#rs-server-plan-reset'), node('#rs-server-plan-submit')];
  const document = {
    hidden: false, body: node('body'), activeElement: null,
    querySelector: node,
    querySelectorAll: selector => selector.startsWith('#rs-server-traffic-form input') ? controls : [],
    addEventListener() {},
  };
  const sandbox = {
    document, URL, console, sessionStorage: { getItem: () => null, removeItem() {}, setItem() {} },
    window: { location: { href: 'https://panel.example/', origin: 'https://panel.example' }, addEventListener() {} },
    MutationObserver: class { observe() {} },
    fetch: () => new Promise(() => {}),
    requestAnimationFrame: () => {},
    setInterval(callback) { const id = ++timerId; intervals.set(id, callback); return id; },
    clearInterval: id => intervals.delete(id),
    setTimeout(callback, delay) { timeouts.push({ callback, delay }); return timeouts.length; }, clearTimeout() {},
    Date: class extends Date { static now() { return clock; } },
    confirm: message => { confirmations.push(message); return true; }, prompt: () => '0',
    FormData: class { get(key) { return ({ name: 'new device', quota_gb: '0' })[key] || ''; } },
    testApi(path, options = {}) {
      const request = { ...pending(), path, options };
      requests.push(request);
      return request.promise;
    },
    testToast: (...args) => notices.push(args),
  };
  const context = vm.createContext(sandbox);
  vm.runInContext(source, context, { filename: process.argv[2] });
  const run = expression => vm.runInContext(expression, context);
  run('api = testApi; toast = testToast; formatRate = value => String(value); state.csrf = "csrf";');
  run('state.remoteServers = [{ id: "A", name: "Debian", addr: "a.example" }, { id: "B", name: "Ubuntu 22", addr: "b.example" }, { id: "C", name: "Ubuntu 24", addr: "c.example" }];');
  const activate = id => run(`state.remoteActive = ${JSON.stringify(id)};`);
  return { run, node, controls, requests, notices, confirmations, intervals, timeouts, activate, clock: value => { clock = value; } };
}
const sample = (f, up, down, extra = {}) => {
  f.run(`renderRemoteDevices(${JSON.stringify([{ id: 'shared', name: 'test device', uploaded_bytes: up, downloaded_bytes: down, enabled: true, active: true, ...extra }])})`);
  const html = f.node('#rs-device-grid').innerHTML;
  return [...html.matchAll(/class="r-(?:up|down)">[↑↓] ([\d.]+)/g)].map(match => Number(match[1]));
};
const tests = [];
const test = (name, fn) => tests.push([name, fn]);
test('first remote sample is a baseline, not lifetime traffic divided by 3 seconds', () => {
  const f = fixture(); f.activate('A');
  assert.deepEqual(sample(f, 9000000, 12000000), [0, 0]);
});
test('both directions use the same elapsed 3 seconds', () => {
  const f = fixture(); f.activate('A'); sample(f, 1000, 2000); f.clock(13000);
  assert.deepEqual(sample(f, 4000, 8000), [1000, 2000]);
  f.clock(17500); assert.deepEqual(sample(f, 8500, 17000), [1000, 2000]);
});
test('counter reset and idle samples do not produce negative or stale rates', () => {
  const f = fixture(); f.activate('A'); sample(f, 1000, 2000); f.clock(13000);
  assert.deepEqual(sample(f, 0, 0), [0, 0]);
  f.clock(16000); assert.deepEqual(sample(f, 3000, 6000), [1000, 2000]);
  f.clock(19000); assert.deepEqual(sample(f, 3000, 6000), [0, 0]);
});
test('removed device and server switches reset samples even when device IDs collide', () => {
  const f = fixture(); f.activate('A'); sample(f, 1000, 2000); f.run('renderRemoteDevices([])'); f.clock(13000);
  assert.deepEqual(sample(f, 9000, 12000), [0, 0]);
  f.run('rsOpenDetail("B")'); f.clock(16000);
  assert.deepEqual(sample(f, 900000, 1200000), [0, 0]);
});
test('expired enabled devices keep their inactive status marker', () => {
  const f = fixture(); f.activate('A'); sample(f, 1, 2, { active: false, status_reason: 'expired' });
  assert.match(f.node('#rs-device-grid').innerHTML, /status-pill off/);
});
test('late A device and plan responses cannot replace B; only B gets a poll timer', async () => {
  const f = fixture(); const a = f.run('rsOpenDetail("A")');
  assert(f.controls.every(control => control.disabled));
  const b = f.run('rsOpenDetail("B")');
  assert.equal(f.node('#rs-device-grid').innerHTML, '');
  f.requests[2].resolve({ devices: [{ id: 'shared', name: 'B device' }] });
  f.requests[3].resolve({ policy: { quota_bytes: 2 * 1024 ** 3 } }); await b;
  assert(f.controls.every(control => !control.disabled));
  f.requests[0].resolve({ devices: [{ id: 'shared', name: 'A device' }] });
  f.requests[1].resolve({ policy: { quota_bytes: 9 * 1024 ** 3 } }); await a;
  assert.match(f.node('#rs-device-grid').innerHTML, /B device/);
  assert.doesNotMatch(f.node('#rs-device-grid').innerHTML, /A device/);
  assert.equal(f.node('#rs-server-plan-quota').value, '2.00');
  assert.equal(f.intervals.size, 1);
  [...f.intervals.values()][0]();
  assert(f.requests.slice(4).every(request => request.options.body.server_id === 'B'));
});
test('A to B to A rejects the earlier A visit despite matching server ID', async () => {
  const f = fixture(); const a1 = f.run('rsOpenDetail("A")'); f.run('rsOpenDetail("B")'); const a2 = f.run('rsOpenDetail("A")');
  f.requests[4].resolve({ devices: [{ id: 'shared', name: 'new visit' }] }); f.requests[5].resolve({ policy: {} }); await a2;
  f.requests[0].resolve({ devices: [{ id: 'shared', name: 'old visit' }] }); f.requests[1].resolve({ policy: {} }); await a1;
  assert.match(f.node('#rs-device-grid').innerHTML, /new visit/);
  assert.equal(f.intervals.size, 1);
});
test('returning to overview before requests finish does not restart polling', async () => {
  const f = fixture(); const opening = f.run('rsOpenDetail("A")'); f.run('rsBack()');
  f.requests[0].resolve({ devices: [{ id: 'old', name: 'old' }] }); f.requests[1].resolve({ policy: {} }); await opening;
  assert.equal(f.intervals.size, 0); assert.equal(f.run('state.remoteDevices.length'), 0);
});
test('newer same-server device and plan replies win when requests complete out of order', async () => {
  const f = fixture(); f.activate('A');
  const oldDevices = f.run('rsLoadDevices()'), newDevices = f.run('rsLoadDevices()');
  f.requests[1].resolve({ devices: [{ id: 'new', name: 'new' }] }); await newDevices;
  f.requests[0].resolve({ devices: [{ id: 'old', name: 'old' }] }); await oldDevices;
  assert.match(f.node('#rs-device-grid').innerHTML, /data-rs-dev="new"/);
  const oldPlan = f.run('rsLoadServerPlan()'), newPlan = f.run('rsLoadServerPlan()');
  f.requests[3].resolve({ policy: { quota_bytes: 3 * 1024 ** 3 } }); await newPlan;
  f.requests[2].resolve({ policy: { quota_bytes: 1 * 1024 ** 3 } }); await oldPlan;
  assert.equal(f.node('#rs-server-plan-quota').value, '3.00');
});
test('slow requests still render while a newer request is in flight', async () => {
  const f = fixture(); f.activate('A'); const first = f.run('rsLoadDevices()'); f.run('rsLoadDevices()');
  f.requests[0].resolve({ devices: [{ id: 'live', name: 'live' }] }); await first;
  assert.match(f.node('#rs-device-grid').innerHTML, /data-rs-dev="live"/);
});
test('old overview status cannot unhide server cards or replace a detail visit', async () => {
  const f = fixture(); const list = f.run('loadRemoteServers()');
  f.requests[0].resolve({ servers: [{ id: 'A', name: 'A' }] }); await drain();
  f.run('rsOpenDetail("A")');
  f.requests[1].resolve({ servers: [{ id: 'A', name: 'stale list' }] }); await list;
  assert(f.node('#rs-grid').classList.contains('hidden'));
  assert.equal(f.run('state.remoteServers[0].name'), 'A');
});
test('slow overview status still renders when a newer poll has already started', async () => {
  const f = fixture(); const first = f.run('loadRemoteServers()');
  f.requests[0].resolve({ servers: [{ id: 'A', name: 'A' }] }); await drain();
  f.run('loadRemoteServers()');
  f.requests[2].resolve({ servers: [{ id: 'A', name: 'A' }] }); await drain();
  f.requests[1].resolve({ servers: [{ id: 'A', name: 'A', online: true, cpu: 12 }] }); await first;
  assert.match(f.node('#rs-grid').innerHTML, /12%/);
});
test('old overview status cannot restore removed servers or overwrite newer names', async () => {
  const f = fixture(); const first = f.run('loadRemoteServers()');
  f.requests[0].resolve({ servers: [{ id: 'A', name: 'old A' }, { id: 'B', name: 'deleted B' }] }); await drain();
  f.run('loadRemoteServers()');
  f.requests[2].resolve({ servers: [{ id: 'A', name: 'renamed A' }] }); await drain();
  f.requests[1].resolve({ servers: [{ id: 'A', name: 'old A', online: true }, { id: 'B', name: 'deleted B', online: true }] }); await first;
  assert.match(f.node('#rs-grid').innerHTML, /renamed A/);
  assert.doesNotMatch(f.node('#rs-grid').innerHTML, /old A|deleted B/);
});
test('old update-check reply is discarded after switching the detail', async () => {
  const f = fixture(); f.activate('A'); const check = f.run('rsCheckUpdate()'); f.run('rsOpenDetail("B")');
  const before = f.node('#rs-update-box').innerHTML;
  f.requests[0].resolve({ current: '7.0.0', update_available: true }); await check;
  assert.equal(f.node('#rs-update-box').innerHTML, before);
});
test('remote update polling never follows a newly selected server', async () => {
  const f = fixture(); f.activate('A'); const update = f.run('rsRunUpdate()');
  f.requests[0].resolve({ started: true }); await drain();
  assert.equal(f.timeouts[0].delay, 5000);
  f.run('rsOpenDetail("B")'); f.timeouts.shift().callback(); await update;
  assert.equal(f.requests.filter(request => request.options.body?.path === '/api/update/status').length, 0);
  assert.equal(f.requests[0].options.body.server_id, 'A');
});
test('in-flight update status cannot paint another server or reopen its details', async () => {
  const f = fixture(); f.activate('A'); const update = f.run('rsRunUpdate()');
  f.requests[0].resolve({ started: true }); await drain(); f.timeouts.shift().callback(); await drain();
  assert.equal(f.requests[1].options.body.server_id, 'A');
  f.run('rsOpenDetail("B")'); const before = f.node('#rs-update-box').innerHTML;
  f.requests[1].resolve({ state: 'done', detail: 'A done' }); await update;
  assert.equal(f.node('#rs-update-box').innerHTML, before);
  assert(!f.notices.some(notice => notice[0].includes('升级完成')));
});
test('last failed upgrade poll cannot write a timeout into another server', async () => {
  const f = fixture(); f.activate('A'); const update = f.run('rsRunUpdate()');
  f.requests[0].resolve({ started: true }); await drain();
  for (let i = 0; i < 72; i++) {
    f.timeouts.shift().callback(); await drain();
    const status = f.requests[i + 1];
    assert.equal(status.options.body.path, '/api/update/status');
    if (i < 71) { status.resolve({ state: 'running' }); await drain(); }
    else {
      f.run('rsOpenDetail("B")'); const before = f.node('#rs-update-box').innerHTML;
      status.reject(new Error('connection interrupted')); await update;
      assert.equal(f.node('#rs-update-box').innerHTML, before);
    }
  }
});
test('toggle finishing on A does not refresh or clear B traffic samples', async () => {
  const f = fixture(); f.activate('A'); f.run('state.remoteDevices = [{ id: "shared", name: "A device", enabled: true }]');
  const toggle = f.run('rsToggleDevice("shared")'); f.run('rsOpenDetail("B")'); sample(f, 100, 200);
  f.requests[0].resolve({ ok: true }); await toggle;
  assert.equal(f.requests.length, 3); assert.equal(f.run('state._rsPrevTraffic.shared.up'), 100);
});
test('a rename dialog cannot retarget its device to a different server', async () => {
  const f = fixture(); f.activate('A'); f.run('openRenameDialog({ id: "shared", name: "A device" }, true)');
  f.run('rsOpenDetail("B")'); f.node('#rename-input').value = 'renamed';
  const count = f.requests.length;
  const submission = f.run('submitRename({ preventDefault() {} })'); await drain();
  assert.equal(f.requests.length, count); await submission;
  assert.match(f.node('#rename-form-error').textContent, /已切换/);
});
test('create and reset dialogs also keep their original server context', async () => {
  for (const operation of ['create', 'reset']) {
    const f = fixture(); f.activate('A');
    if (operation === 'create') f.run('openCreate(true)');
    else f.run('openResetDialog({ id: "shared", name: "A device" }, true)');
    f.run('rsOpenDetail("B")'); const count = f.requests.length;
    const submission = f.run(operation === 'create' ? 'createDevice({ preventDefault() {}, currentTarget: document.querySelector("#device-form") })' : 'submitReset({ preventDefault() {} })');
    await drain(); assert.equal(f.requests.length, count, operation); await submission;
    assert.match(f.node(operation === 'create' ? '#device-form-error' : '#reset-form-error').textContent, /已切换/, operation);
  }
});
test('old CRUD success cannot close or enable a reopened same-server dialog', async () => {
  for (const operation of ['create', 'rename', 'reset']) {
    const f = fixture(); f.activate('A');
    const dialogId = { create: '#device-dialog', rename: '#rename-dialog', reset: '#reset-dialog' }[operation];
    const submitId = { create: 'button[type=submit]', rename: '#rename-submit', reset: '#reset-submit' }[operation];
    const open = () => f.run(operation === 'create' ? 'openCreate(true)' : operation === 'rename' ? 'openRenameDialog({ id: "shared", name: "device" }, true)' : 'openResetDialog({ id: "shared", name: "device" }, true)');
    open();
    const action = f.run(operation === 'create' ? 'createDevice({ preventDefault() {}, currentTarget: document.querySelector("#device-form") })' : operation === 'rename' ? 'submitRename({ preventDefault() {} })' : 'submitReset({ preventDefault() {} })');
    f.node(dialogId).close(); open();
    assert(!f.node(submitId).disabled, `reopened ${operation} is usable`);
    f.node(submitId).disabled = true;
    f.requests[0].resolve({ ok: true }); await drain();
    // Rename refreshes its original server before checking whether the dialog was reopened.
    if (f.requests[1]) f.requests[1].resolve({ devices: [] });
    await action;
    assert(f.node(dialogId).open, operation); assert(f.node(submitId).disabled, operation);
  }
});
test('late link replies do not mix A links with B QR addresses', async () => {
  const f = fixture(); f.activate('A'); f.run('state.remoteDevices = [{ id: "shared", name: "A device" }]');
  const links = f.run('rsOpenLinks("shared")'); f.run('rsOpenDetail("B")');
  f.requests[0].resolve({ links: ['vmess://example'], subscription_urls: [] }); await links;
  assert.doesNotMatch(f.node('#links-list').innerHTML, /server_id=B|vmess:\/\/example/);
});
test('ordinary remote create, rename, reset, toggle and delete still mutate and refresh A', async () => {
  for (const operation of ['create', 'rename', 'reset', 'toggle', 'delete']) {
    const f = fixture(); f.activate('A');
    f.run('state.remoteDevices = [{ id: "shared", name: "A device", enabled: true }]');
    let action;
    if (operation === 'create') {
      f.run('openCreate(true)');
      action = f.run('createDevice({ preventDefault() {}, currentTarget: document.querySelector("#device-form") })');
    } else if (operation === 'rename') {
      f.run('openRenameDialog(state.remoteDevices[0], true)'); f.node('#rename-input').value = 'renamed';
      action = f.run('submitRename({ preventDefault() {} })');
    } else if (operation === 'reset') {
      f.run('openResetDialog(state.remoteDevices[0], true)');
      action = f.run('submitReset({ preventDefault() {} })');
    } else action = f.run(operation === 'toggle' ? 'rsToggleDevice("shared")' : 'rsDeleteDevice("shared")');
    assert.equal(f.requests[0].options.body.server_id, 'A', operation);
    assert.equal(f.requests[0].options.body.method, { create: 'POST', rename: 'PATCH', reset: 'POST', toggle: 'PATCH', delete: 'DELETE' }[operation]);
    if (operation === 'delete') assert.match(f.confirmations[0], /A device/);
    f.requests[0].resolve({ ok: true }); await drain();
    assert.equal(f.requests[1].options.body.server_id, 'A');
    assert.equal(f.requests[1].options.body.path, '/api/devices');
    f.requests[1].resolve({ devices: [] }); await action;
    assert.equal(f.notices.length, 1, operation);
  }
});
test('normal remote plan writes work and an old poll cannot undo a saved plan', async () => {
  for (const operation of ['save', 'reset']) {
    const f = fixture(); f.activate('A');
    f.node('#rs-server-plan-current').value = '0'; f.node('#rs-server-plan-current').dataset.original = '0';
    const before = f.run('rsLoadServerPlan()');
    const action = f.run(operation === 'save' ? 'saveServerPlan({ preventDefault() {} }, true)' : 'resetServerPlan(true)');
    assert.equal(f.requests[1].options.body.server_id, 'A');
    f.requests[1].resolve({ policy: { quota_bytes: 6 * 1024 ** 3 } }); await action;
    assert.equal(f.node('#rs-server-plan-quota').value, '6.00');
    f.requests[0].resolve({ policy: { quota_bytes: 1 * 1024 ** 3 } }); await before;
    assert.equal(f.node('#rs-server-plan-quota').value, '6.00');
  }
});
test('normal remote upgrade polls A and refreshes A after completion', async () => {
  const f = fixture(); f.activate('A'); const update = f.run('rsRunUpdate()');
  f.requests[0].resolve({ started: true }); await drain();
  f.timeouts.shift().callback(); await drain();
  assert.equal(f.requests[1].options.body.path, '/api/update/status');
  f.requests[1].resolve({ state: 'done', detail: 'done' }); await drain();
  assert.equal(f.timeouts[0].delay, 3000); f.timeouts.shift().callback(); await update;
  assert(f.requests.every(request => request.options.body.server_id === 'A'));
  assert(f.notices.some(notice => notice[0].includes('升级完成')));
  assert.equal(f.requests.length, 4);
});
test('normal links and QR addresses consistently target the selected server', async () => {
  const f = fixture(); f.activate('A'); f.run('state.remoteDevices = [{ id: "shared", name: "A device" }]');
  const links = f.run('rsOpenLinks("shared")');
  f.requests[0].resolve({ links: ['vmess://example'], subscription_urls: [{ format: 'sing-box', name: 'sub', url: 'https://a.example/sub' }] }); await links;
  assert.match(f.node('#links-list').innerHTML, /server_id=A&amp;device_id=shared&amp;index=0/);
  assert.match(f.node('#subscription-urls').innerHTML, /server_id=A&amp;device_id=shared&amp;sub_index=0/);
});
test('logout clears remote polling and discards previous-session responses', async () => {
  const f = fixture(); const open = f.run('rsOpenDetail("A")');
  f.requests[0].resolve({ devices: [] }); f.requests[1].resolve({ policy: {} }); await open;
  const load = f.run('rsLoadDevices()'); f.run('showLogin()'); f.requests[2].resolve({ devices: [{ id: 'old', name: 'old' }] }); await load;
  assert.equal(f.intervals.size, 0); assert.equal(f.run('state.remoteActive'), null);
  assert.equal(f.run('state.remoteDevices.length'), 0);
  assert(f.node('#rs-detail').classList.contains('hidden'));
  assert(!f.node('#view-remote .section-toolbar').classList.contains('hidden'));
});
const watchdog = setTimeout(() => { console.error('Remote UI regression timed out (unresolved operation).'); process.exit(1); }, 10000);
(async () => {
  const selected = tests.filter(([name]) => !process.env.TEST_NAME || new RegExp(process.env.TEST_NAME).test(name));
  assert(selected.length > 0, 'test filter selected no cases');
  for (const [name, fn] of selected) { await fn(); console.log(`PASS ${name}`); }
  console.log(`Remote UI regression: ${selected.length} tests passed (real app.js; no network or server mutations).`);
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => clearTimeout(watchdog));
JS
