// DashboardPage.swift. The single page the phone loads. Plain HTML + JS, no build step: it polls
// /api/status, and while a Wi-Fi switch runs it keeps polling through the moment the link drops,
// because the Mac keeps its Tailscale address and comes back on its own.

let dashboardManifest = #"""
{"name":"Sleepless","short_name":"Sleepless","start_url":"/","display":"standalone",
 "background_color":"#111014","theme_color":"#111014","icons":[{"src":"/icon.png","sizes":"180x180","type":"image/png"}]}
"""#

let dashboardPage = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Sleepless">
<meta name="theme-color" content="#111014">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/icon.png">
<title>Sleepless</title>
<style>
  :root {
    --bg: #f4f3f7; --card: #ffffff; --text: #17151c; --muted: #6d6878; --line: #e6e3ec;
    --accent: #8b5cf6; --good: #16a34a; --warn: #d97706; --bad: #dc2626;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #111014; --card: #1c1a21; --text: #f2f0f6; --muted: #9a94a6; --line: #2c2933; }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--text);
    font: 16px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    padding: max(16px, env(safe-area-inset-top)) 16px max(24px, env(safe-area-inset-bottom));
    -webkit-tap-highlight-color: transparent;
  }
  main { max-width: 480px; margin: 0 auto; display: grid; gap: 14px; }
  header { display: flex; align-items: baseline; justify-content: space-between; padding: 4px 4px 0; }
  h1 { font-size: 22px; margin: 0; }
  .muted { color: var(--muted); font-size: 13px; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 16px; padding: 16px; }
  .card h2 { font-size: 13px; font-weight: 600; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); margin: 0 0 10px; }
  .big { font-size: 44px; font-weight: 700; letter-spacing: -.02em; line-height: 1; }
  .bar { height: 8px; border-radius: 4px; background: var(--line); overflow: hidden; margin: 12px 0 8px; }
  .bar > div { height: 100%; background: var(--good); transition: width .4s; }
  .row { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 10px 0; border-top: 1px solid var(--line); }
  .row:first-of-type { border-top: 0; }
  .name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  button {
    font: inherit; font-size: 15px; font-weight: 600; border: 0; border-radius: 10px; padding: 8px 14px;
    background: var(--accent); color: #fff; cursor: pointer; white-space: nowrap;
  }
  button.secondary { background: var(--line); color: var(--text); }
  button.danger { background: transparent; color: var(--bad); border: 1px solid var(--bad); width: 100%; margin-top: 12px; }
  button:disabled { opacity: .45; }
  .banner { border-radius: 12px; padding: 12px 14px; font-size: 14px; display: none; }
  .banner.show { display: block; }
  .banner.info { background: color-mix(in srgb, var(--accent) 15%, transparent); }
  .banner.good { background: color-mix(in srgb, var(--good) 15%, transparent); }
  .banner.bad { background: color-mix(in srgb, var(--bad) 15%, transparent); }
  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 8px; background: var(--muted); }
  .dot.connected { background: var(--good); } .dot.pending, .dot.stopping { background: var(--warn); } .dot.failed { background: var(--bad); }
  .signal { font-size: 13px; color: var(--muted); }
</style>
</head>
<body>
<main>
  <header><h1 id="machine">Sleepless</h1><span class="muted" id="updated">Connecting…</span></header>
  <div class="banner bad" id="offline">Can’t reach the Mac. Retrying…</div>
  <div class="banner" id="switch"></div>

  <section class="card">
    <h2>Battery</h2>
    <div class="big" id="percent">–</div>
    <div class="bar"><div id="level" style="width:0"></div></div>
    <div class="muted" id="power"></div>
  </section>

  <section class="card">
    <h2>Wi-Fi</h2>
    <div class="row"><div><div class="name" id="ssid">–</div><div class="signal" id="ssid-note"></div></div>
      <button class="secondary" id="scan">Scan</button></div>
    <div id="networks"></div>
  </section>

  <section class="card">
    <h2>Sleepless</h2>
    <div id="sleepless" class="muted"></div>
    <div id="rc"></div>
    <button class="danger" id="off">Turn Sleepless off</button>
  </section>
</main>
<script>
const $ = (id) => document.getElementById(id);
const FINAL = new Set(["done", "reverted", "failed"]);
let switching = null;   // { target, startedAt }
let pollTimer = null;

async function api(path, options = {}) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), options.timeout || 6000);
  try {
    const res = await fetch(path, { ...options, signal: ctl.signal,
      headers: options.body ? { "Content-Type": "application/json" } : {} });
    const body = res.headers.get("content-type")?.includes("json") ? await res.json() : await res.text();
    return { ok: res.ok, status: res.status, body };
  } finally { clearTimeout(timer); }
}

function signalWord(rssi) {
  if (rssi == null) return "";
  return rssi >= -55 ? "Strong" : rssi >= -70 ? "Good" : "Weak";
}

function minutes(m) {
  if (m == null) return null;
  const h = Math.floor(m / 60), r = m % 60;
  return h ? `${h}h ${r}m` : `${r}m`;
}

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  Object.entries(attrs).forEach(([k, v]) => k === "class" ? node.className = v : node.setAttribute(k, v));
  children.flat().forEach((c) => node.append(c instanceof Node ? c : document.createTextNode(c ?? "")));
  return node;
}

function banner(id, kind, text) {
  const b = $(id);
  b.className = `banner ${kind}${text ? " show" : ""}`;
  b.textContent = text || "";
}

function renderStatus(s) {
  $("machine").textContent = s.machine;
  $("updated").textContent = "Updated " + new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  banner("offline", "bad", "");

  const b = s.battery;
  if (b) {
    $("percent").textContent = `${b.percent}%`;
    $("level").style.width = `${b.percent}%`;
    const floor = s.sleepless?.floorPercent ?? 0;
    $("level").style.background = b.percent <= floor + 5 ? "var(--bad)" : b.percent <= 30 ? "var(--warn)" : "var(--good)";
    const left = minutes(b.minutesRemaining);
    $("power").textContent = b.charging ? `Charging${left ? ` · ${left} to full` : ""}`
      : b.onBattery ? `On battery${left ? ` · about ${left} left` : " · estimating…"}` : "Plugged in, not charging";
  }

  const w = s.wifi;
  $("ssid").textContent = w.current || (w.locationAuthorized ? "Not on Wi-Fi" : "Unknown");
  $("ssid-note").textContent = !w.locationAuthorized
    ? "Allow Location Services for Sleepless on the Mac to see network names."
    : w.current ? `Connected · ${signalWord(w.rssi)}` : "";

  const sl = s.sleepless;
  if (sl) {
    const parts = [sl.on ? "Keeping the Mac awake." : "Off. The Mac sleeps when the lid is closed."];
    if (sl.on) parts.push(`Turns off at ${sl.floorPercent}% battery.`);
    if (sl.autoOffAt) parts.push(`Auto-off at ${new Date(sl.autoOffAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}.`);
    if (sl.lowPowerMode) parts.push("Low Power Mode is on.");
    $("sleepless").textContent = parts.join(" ");
    $("rc").replaceChildren(...sl.remoteControl.map((r) =>
      el("div", { class: "row" }, el("div", { class: "name" }, el("span", { class: `dot ${r.state}` }), r.repo),
        el("span", { class: "signal" }, r.state))));
    $("off").disabled = !sl.on;
  }

  trackSwitch(w.lastSwitch);
}

function trackSwitch(last) {
  if (!switching) return;
  const elapsed = Math.round((Date.now() - switching.startedAt) / 1000);
  const fresh = last && last.target === switching.target && new Date(last.updatedAt).getTime() >= switching.startedAt - 2000;
  if (fresh && FINAL.has(last.phase)) {
    banner("switch", last.phase === "done" ? "good" : "bad", last.message);
    switching = null;
    loadNetworks();
    schedule();
    return;
  }
  banner("switch", "info", `${fresh ? last.message : `Switching to ${switching.target}…`} (${elapsed}s)`);
}

async function poll() {
  try {
    const res = await api("/api/status", { timeout: switching ? 3500 : 6000 });
    if (res.ok) renderStatus(res.body);
    else banner("offline", "bad", typeof res.body === "string" ? res.body : `Error ${res.status}`);
  } catch {
    if (switching) {
      const elapsed = Math.round((Date.now() - switching.startedAt) / 1000);
      banner("switch", "info", `The Mac is changing networks. Waiting for it to come back… (${elapsed}s)`);
      if (elapsed > 240) {
        banner("switch", "bad", `Lost contact for 4 minutes. If ${switching.target} didn’t work, the Mac goes back to the previous network on its own.`);
        switching = null;
      }
    } else banner("offline", "bad", "Can’t reach the Mac. Retrying…");
  }
  schedule();
}

function schedule() {
  clearTimeout(pollTimer);
  if (document.visibilityState !== "visible") return;
  pollTimer = setTimeout(poll, switching ? 2000 : 10000);
}

async function loadNetworks() {
  $("scan").disabled = true;
  $("scan").textContent = "Scanning…";
  try {
    const res = await api("/api/wifi/networks", { timeout: 15000 });
    if (res.ok) renderNetworks(res.body.networks);
  } catch {}
  $("scan").disabled = false;
  $("scan").textContent = "Scan";
}

function renderNetworks(list) {
  const rows = list.filter((n) => !n.current).map((n) => {
    let action;
    if (!n.saved) action = el("span", { class: "signal" }, "Save its password in Sleepless");
    else if (!n.inRange) action = el("span", { class: "signal" }, "Not in range");
    else {
      action = el("button", {}, "Switch");
      action.onclick = () => switchTo(n.ssid);
    }
    return el("div", { class: "row" },
      el("div", {}, el("div", { class: "name" }, n.ssid), el("div", { class: "signal" }, n.inRange ? signalWord(n.rssi) : "")),
      action);
  });
  $("networks").replaceChildren(...rows);
}

async function switchTo(ssid) {
  if (switching) return;
  if (!confirm(`Switch the Mac to “${ssid}”?\n\nThe connection drops for a few seconds. If ${ssid} has no internet within 45 seconds, the Mac goes back to the current network.`)) return;
  switching = { target: ssid, startedAt: Date.now() };
  banner("switch", "info", `Switching to ${ssid}…`);
  try {
    const res = await api("/api/wifi/switch", { method: "POST", body: JSON.stringify({ ssid }), timeout: 20000 });
    if (!res.ok) {
      switching = null;
      banner("switch", "bad", res.body?.error || res.body || `Error ${res.status}`);
    }
  } catch {}   // the link may already be dropping; polling picks it up
  schedule();
}

$("scan").onclick = loadNetworks;
$("off").onclick = async () => {
  if (!confirm("Turn Sleepless off? With the lid closed the Mac goes to sleep and this page stops working until you open it.")) return;
  try { await api("/api/sleepless/off", { method: "POST", body: "{}" }); } catch {}
  banner("switch", "info", "Turning Sleepless off…");
};
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") poll(); else clearTimeout(pollTimer); });

poll();
loadNetworks();
</script>
</body>
</html>
"""#
