// DashboardPage.swift. The single page the phone loads: a bento of battery and Sleepless tiles
// over a list of power-hungry apps and a Wi-Fi list. Plain HTML + JS, no build step. It polls /api/status, and while a Wi-Fi
// switch runs it keeps polling through the moment the link drops, because the Mac keeps its
// Tailscale address and comes back on its own. The server sends codes; all wording lives here.

let dashboardManifest = #"""
{"name":"Sleepless","short_name":"Sleepless","lang":"zh-Hant-TW","start_url":"/","display":"standalone",
 "background_color":"#0a0a0c","theme_color":"#0a0a0c","icons":[{"src":"/icon.png","sizes":"180x180","type":"image/png"}]}
"""#

let dashboardPage = #"""
<!doctype html>
<html lang="zh-Hant-TW">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Sleepless">
<meta name="theme-color" content="#f2f2f7" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0a0a0c" media="(prefers-color-scheme: dark)">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/icon.png">
<title>Sleepless</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #f2f2f7;
    --tile: #ffffff;
    --tile-2: #f7f7fa;
    --text: #1c1c1e;
    --text-2: rgba(60, 60, 67, .62);
    --text-3: rgba(60, 60, 67, .32);
    --sep: rgba(60, 60, 67, .12);
    --track: rgba(120, 120, 128, .16);
    --shadow: 0 1px 2px rgba(0, 0, 0, .04), 0 8px 24px rgba(0, 0, 0, .06);
    --accent: #007aff;
    --accent-soft: rgba(0, 122, 255, .11);
    --brand: linear-gradient(135deg, #22d3ee 0%, #0ea5e9 42%, #2563eb 100%);
    --brand-glow: rgba(14, 165, 233, .32);
    --green: #34c759;
    --amber: #ff9500;
    --red: #ff3b30;
    --sheet: #ffffff;
    --scrim: rgba(0, 0, 0, .28);
    --radius: 22px;
    --ease: cubic-bezier(.32, .72, 0, 1);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0a0a0c;
      --tile: #1c1c1f;
      --tile-2: #242428;
      --text: #f5f5f7;
      --text-2: rgba(235, 235, 245, .6);
      --text-3: rgba(235, 235, 245, .28);
      --sep: rgba(84, 84, 88, .4);
      --track: rgba(120, 120, 128, .28);
      --shadow: 0 0 0 1px rgba(255, 255, 255, .05);
      --accent: #3b9eff;
      --accent-soft: rgba(59, 158, 255, .16);
      --green: #30d158;
      --amber: #ff9f0a;
      --red: #ff453a;
      --sheet: #1c1c1f;
      --scrim: rgba(0, 0, 0, .55);
    }
  }

  * { box-sizing: border-box; margin: 0; }
  [hidden] { display: none !important; }
  html { background: var(--bg); }
  body {
    min-height: 100dvh;
    background: var(--bg);
    color: var(--text);
    font: 17px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang TC", system-ui, sans-serif;
    -webkit-font-smoothing: antialiased;
    -webkit-tap-highlight-color: transparent;
    touch-action: manipulation;
    overscroll-behavior-y: contain;
  }
  button { font: inherit; color: inherit; background: none; border: 0; padding: 0; cursor: pointer; text-align: inherit; }
  svg { display: block; }
  .rounded { font-family: ui-rounded, "SF Pro Rounded", -apple-system, system-ui, sans-serif; font-variant-numeric: tabular-nums; }

  .app {
    max-width: 520px;
    margin: 0 auto;
    padding: calc(env(safe-area-inset-top) + 18px) 16px calc(env(safe-area-inset-bottom) + 32px);
    transition: transform .35s var(--ease);
  }

  /* Header */
  .top { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; margin: 6px 4px 18px; }
  .eyebrow { font-size: 13px; font-weight: 500; color: var(--text-2); letter-spacing: .01em; }
  h1 { font-size: 28px; font-weight: 700; letter-spacing: -.02em; line-height: 1.15; margin-top: 2px;
       overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
  .live { flex: none; display: inline-flex; align-items: center; gap: 10px; height: 30px; padding: 0 13px;
          border-radius: 15px; background: var(--tile); box-shadow: var(--shadow); font-size: 13px; font-weight: 600; margin-top: 2px; }
  .live .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--green); position: relative; }
  .live .dot::after { content: ""; position: absolute; inset: -3px; border-radius: 50%; background: inherit; opacity: .35; animation: pulse 2s ease-out infinite; }
  .live.stale .dot { background: var(--amber); }
  .live.gone .dot { background: var(--text-3); }
  .live.gone .dot::after { display: none; }
  @keyframes pulse { 0% { transform: scale(.6); opacity: .5; } 100% { transform: scale(1.6); opacity: 0; } }

  /* Bento */
  .bento { display: grid; grid-template-columns: 1.08fr 1fr; grid-template-rows: auto auto; gap: 12px; }
  .tile { position: relative; background: var(--tile); border-radius: var(--radius); box-shadow: var(--shadow);
          padding: 16px; overflow: hidden; display: flex; flex-direction: column; min-height: 132px; }
  .tile-label { display: flex; align-items: center; gap: 6px; font-size: 13px; font-weight: 600; color: var(--text-2); }
  .tile-label svg { width: 16px; height: 16px; }
  .tile-value { font-size: 22px; font-weight: 700; letter-spacing: -.01em; margin-top: auto; }
  .tile-sub { font-size: 13px; color: var(--text-2); margin-top: 2px; }
  .tile .chev { position: absolute; top: 16px; right: 14px; width: 14px; height: 14px; color: var(--text-3); }
  .pressable { transition: transform .18s var(--ease), opacity .18s; }
  .pressable:active { transform: scale(.97); opacity: .85; }

  .battery { grid-row: span 2; align-items: stretch; }
  .ring-wrap { position: relative; width: 100%; max-width: 168px; aspect-ratio: 1; margin: 12px auto 10px; }
  .ring { width: 100%; height: 100%; transform: rotate(-90deg); }
  .ring circle { fill: none; stroke-width: 11; }
  .ring .track { stroke: var(--track); }
  .ring .fill { stroke: var(--green); stroke-linecap: round; transition: stroke-dashoffset 1s var(--ease), stroke .4s; }
  .ring .floor { stroke: var(--text); stroke-width: 3; stroke-linecap: round; opacity: .55; transition: opacity .3s; }
  .ring-center { position: absolute; inset: 0; display: grid; place-content: center; text-align: center; }
  .pct { font-size: 44px; font-weight: 700; letter-spacing: -.03em; line-height: 1; }
  .pct small { font-size: 20px; font-weight: 600; margin-left: 1px; color: var(--text-2); }
  .bolt { width: 18px; height: 18px; margin: 6px auto 0; color: var(--green); opacity: 0; transform: scale(.6); transition: .3s var(--ease); }
  .bolt.on { opacity: 1; transform: none; }
  .battery .foot { margin-top: auto; }
  .battery .foot .primary { font-size: 17px; font-weight: 650; }

  .awake { background: var(--brand); color: #fff; box-shadow: 0 10px 30px var(--brand-glow); }
  .awake .tile-label, .awake .tile-sub { color: rgba(255, 255, 255, .82); }
  .awake .chev { color: rgba(255, 255, 255, .7); }
  .awake.off { background: var(--tile); color: var(--text); box-shadow: var(--shadow); }
  .awake.off .tile-label, .awake.off .tile-sub { color: var(--text-2); }
  .awake.off .chev { color: var(--text-3); }
  .chip { display: inline-flex; align-items: center; gap: 4px; font-size: 11px; font-weight: 700; padding: 3px 7px;
          border-radius: 8px; background: rgba(255, 255, 255, .2); margin-top: 6px; width: fit-content; }
  .timer .tile-value { font-size: 26px; }
  .timer.idle .tile-value { font-size: 20px; color: var(--text-2); }

  /* Wi-Fi */
  .section { margin-top: 28px; }
  .section-head { display: flex; align-items: center; justify-content: space-between; margin: 0 4px 10px; }
  h2 { font-size: 22px; font-weight: 700; letter-spacing: -.01em; }
  .icon-btn { width: 36px; height: 36px; border-radius: 18px; display: grid; place-items: center; background: var(--tile);
              box-shadow: var(--shadow); color: var(--accent); }
  .icon-btn svg { width: 18px; height: 18px; }
  .icon-btn.spin svg { animation: spin .9s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }

  .current { position: relative; border-radius: var(--radius); padding: 18px; overflow: hidden; background: var(--tile); box-shadow: var(--shadow);
             display: flex; align-items: center; gap: 14px; }
  .current::before { content: ""; position: absolute; inset: 0; background: var(--brand); opacity: .1; }
  .current > * { position: relative; }
  .current .badge { width: 46px; height: 46px; flex: none; border-radius: 14px; background: var(--brand); color: #fff;
                    display: grid; place-items: center; box-shadow: 0 6px 18px var(--brand-glow); }
  .current .badge svg { width: 24px; height: 24px; }
  .current.none .badge { background: var(--track); color: var(--text-2); box-shadow: none; }
  .current .meta { min-width: 0; }
  .current .kicker { font-size: 12px; font-weight: 600; color: var(--accent); letter-spacing: .02em; }
  .current .name { font-size: 20px; font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .current .sub { font-size: 13px; color: var(--text-2); }

  .list { margin-top: 12px; background: var(--tile); border-radius: var(--radius); box-shadow: var(--shadow); overflow: hidden; }
  .list:empty { display: none; }
  .net { width: 100%; display: flex; align-items: center; gap: 14px; padding: 13px 16px; position: relative; }
  .net + .net::before { content: ""; position: absolute; top: 0; left: 62px; right: 0; height: 1px; background: var(--sep); }
  .net .sig { width: 32px; height: 32px; flex: none; border-radius: 10px; display: grid; place-items: center; background: var(--tile-2); }
  .net .sig svg { width: 20px; height: 20px; }
  .net .meta { flex: 1; min-width: 0; }
  .net .name { font-size: 17px; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .net .sub { font-size: 13px; color: var(--text-2); }
  .net.muted .name, .net.muted .sig { opacity: .45; }
  .pill { flex: none; font-size: 15px; font-weight: 650; color: var(--accent); background: var(--accent-soft);
          height: 32px; padding: 0 14px; border-radius: 16px; display: inline-flex; align-items: center; }
  .net:active:not(.muted) { background: var(--tile-2); }
  .hint { display: flex; gap: 8px; font-size: 13px; color: var(--text-2); margin: 12px 6px 0; }
  .hint svg { width: 16px; height: 16px; flex: none; margin-top: 1px; }
  .hint:empty { display: none; }
  .empty { padding: 18px 16px; font-size: 15px; color: var(--text-2); text-align: center; }

  .bars path { fill: var(--text-3); transition: fill .3s; }
  .bars path.lit { fill: var(--text); }
  .badge .bars path, .hero .bars path { fill: rgba(255, 255, 255, .35); }
  .badge .bars path.lit, .hero .bars path.lit { fill: #fff; }

  /* Power-hungry apps */
  .thermal { display: inline-flex; align-items: center; gap: 6px; height: 28px; padding: 0 11px; border-radius: 14px;
             background: var(--tile); box-shadow: var(--shadow); font-size: 13px; font-weight: 600; color: var(--text-2); }
  .thermal .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--green); }
  .thermal.warm .dot { background: var(--amber); }
  .thermal.hot { color: var(--red); }
  .thermal.hot .dot { background: var(--red); }
  .draw { background: var(--tile); border-radius: var(--radius); box-shadow: var(--shadow); padding: 16px 18px; }
  .draw-top { display: flex; align-items: flex-end; justify-content: space-between; gap: 12px; }
  .draw .kicker { font-size: 13px; font-weight: 600; color: var(--text-2); }
  .draw-value { font-size: 34px; font-weight: 700; letter-spacing: -.02em; line-height: 1.1; margin-top: 2px; }
  .draw-value small { font-size: 17px; font-weight: 600; color: var(--text-2); margin-left: 3px; }
  .draw .aside { text-align: right; font-size: 13px; color: var(--text-2); padding-bottom: 4px; }
  .meter { margin-top: 14px; height: 8px; border-radius: 4px; background: var(--track); overflow: hidden; }
  .meter span { display: block; height: 100%; border-radius: 4px; background: var(--accent); transition: width .6s var(--ease); }
  .legend { display: flex; gap: 16px; margin-top: 8px; font-size: 12px; color: var(--text-2); }
  .legend i { display: inline-block; width: 8px; height: 8px; border-radius: 2px; margin-right: 6px; background: var(--track); }
  .legend i.apps { background: var(--accent); }

  .app-row { display: flex; align-items: center; gap: 12px; padding: 11px 16px; position: relative; }
  .app-row + .app-row::before, .more::before { content: ""; position: absolute; top: 0; left: 64px; right: 0; height: 1px; background: var(--sep); }
  .more::before { left: 0; }
  .app-icon { width: 36px; height: 36px; flex: none; display: grid; place-items: center; }
  .app-icon img { width: 36px; height: 36px; }
  .app-icon.generic { border-radius: 9px; background: var(--tile-2); color: var(--text-3); }
  .app-icon.generic svg { width: 20px; height: 20px; }
  .app-row .meta { flex: 1; min-width: 0; }
  .app-row .name { font-size: 16px; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .usage { display: flex; align-items: center; gap: 8px; margin-top: 5px; }
  .usage .bar { flex: 1; max-width: 132px; height: 5px; border-radius: 3px; background: var(--track); overflow: hidden; }
  .usage .bar span { display: block; height: 100%; border-radius: 3px; background: var(--text-3); transition: width .6s var(--ease); }
  .usage .bar span.mid { background: var(--amber); }
  .usage .bar span.high { background: var(--red); }
  .usage .watts { font-size: 13px; color: var(--text-2); white-space: nowrap; font-variant-numeric: tabular-nums; }
  .app-row .why { font-size: 12px; color: var(--text-2); margin-top: 3px; }
  .app-row .why.warn { color: var(--amber); font-weight: 600; }
  .quit { flex: none; height: 32px; min-width: 66px; padding: 0 14px; border-radius: 16px; font-size: 15px; font-weight: 650;
          color: var(--red); background: color-mix(in srgb, var(--red) 13%, transparent); display: inline-flex; align-items: center;
          justify-content: center; gap: 6px; position: relative; overflow: hidden; transition: background .2s, color .2s; }
  .quit.armed { background: var(--red); color: #fff; }
  .quit.armed::after { content: ""; position: absolute; left: 0; bottom: 0; height: 3px; width: 100%; background: rgba(255, 255, 255, .6);
                       transform-origin: left; animation: drain 3s linear forwards; animation-delay: var(--elapsed, 0ms); }
  @keyframes drain { from { transform: scaleX(1); } to { transform: scaleX(0); } }
  .quit:disabled { color: var(--text-2); background: var(--tile-2); }
  .quit:disabled svg { width: 14px; height: 14px; animation: spin .9s linear infinite; }
  .lock { flex: none; width: 32px; height: 32px; display: grid; place-items: center; color: var(--text-3); }
  .lock svg { width: 17px; height: 17px; }
  .more { width: 100%; padding: 13px 16px; font-size: 15px; font-weight: 600; color: var(--accent); text-align: center; position: relative; }
  .hint.warn svg { color: var(--amber); }

  /* Skeleton */
  .skeleton { color: transparent !important; background: linear-gradient(90deg, var(--track) 0%, var(--tile-2) 50%, var(--track) 100%);
              background-size: 200% 100%; animation: shimmer 1.3s ease-in-out infinite; border-radius: 8px; }
  @keyframes shimmer { 0% { background-position: 100% 0; } 100% { background-position: -100% 0; } }

  /* Entrance */
  .rise { animation: rise .6s var(--ease) both; }
  @keyframes rise { from { opacity: 0; transform: translateY(12px); } to { opacity: 1; transform: none; } }

  /* Pull to refresh */
  .ptr { position: fixed; left: 50%; top: calc(env(safe-area-inset-top) + 6px); width: 34px; height: 34px; margin-left: -17px;
         border-radius: 50%; background: var(--tile); box-shadow: var(--shadow); display: grid; place-items: center;
         color: var(--accent); opacity: 0; transform: translateY(-40px); z-index: 5; pointer-events: none; }
  .ptr svg { width: 18px; height: 18px; }
  .ptr.loading svg { animation: spin .9s linear infinite; }

  /* Toast */
  .toast { position: fixed; left: 16px; right: 16px; bottom: calc(env(safe-area-inset-bottom) + 16px); max-width: 488px; margin: 0 auto;
           display: flex; gap: 10px; align-items: flex-start; padding: 14px 16px; border-radius: 18px; z-index: 30;
           background: color-mix(in srgb, var(--sheet) 88%, transparent); backdrop-filter: blur(20px) saturate(1.6);
           -webkit-backdrop-filter: blur(20px) saturate(1.6); box-shadow: 0 12px 40px rgba(0, 0, 0, .18), 0 0 0 1px var(--sep);
           font-size: 15px; transform: translateY(140%); transition: transform .45s var(--ease); }
  .toast.show { transform: none; }
  .toast svg { width: 20px; height: 20px; flex: none; color: var(--amber); margin-top: 1px; }
  .toast.good svg { color: var(--green); }

  /* Sheet */
  .scrim { position: fixed; inset: 0; background: var(--scrim); opacity: 0; pointer-events: none; transition: opacity .35s var(--ease); z-index: 20; }
  .scrim.show { opacity: 1; pointer-events: auto; }
  .scrim, .sheet { touch-action: none; }
  body.locked { overflow: hidden; }
  .sheet { position: fixed; left: 0; right: 0; bottom: 0; max-width: 520px; margin: 0 auto; z-index: 21;
           background: var(--sheet); border-radius: 28px 28px 0 0; padding: 10px 20px calc(env(safe-area-inset-bottom) + 20px);
           transform: translateY(105%); transition: transform .5s var(--ease); box-shadow: 0 -10px 40px rgba(0, 0, 0, .2); }
  .sheet.show { transform: none; }
  .grabber { width: 36px; height: 5px; border-radius: 3px; background: var(--text-3); margin: 0 auto 18px; }
  .sheet .hero { width: 64px; height: 64px; border-radius: 20px; display: grid; place-items: center; margin: 4px auto 14px; color: #fff; background: var(--brand); }
  .sheet .hero svg { width: 32px; height: 32px; }
  .sheet .hero.good { background: var(--green); }
  .sheet .hero.warn { background: var(--amber); }
  .sheet .hero.bad { background: var(--red); }
  .sheet .hero.busy { background: var(--accent-soft); color: var(--accent); }
  .sheet .hero.busy svg { animation: spin 1s linear infinite; }
  .sheet h3 { font-size: 22px; font-weight: 700; text-align: center; letter-spacing: -.01em; }
  .sheet .body { font-size: 15px; color: var(--text-2); text-align: center; margin: 8px 6px 0; }
  .sheet .actions { display: grid; gap: 10px; margin-top: 22px; }
  .btn { height: 52px; border-radius: 16px; font-size: 17px; font-weight: 650; display: grid; place-items: center; width: 100%; text-align: center; }
  .btn.primary { background: var(--brand); color: #fff; box-shadow: 0 8px 24px var(--brand-glow); }
  .btn.plain { background: var(--tile-2); }
  .btn.destructive { background: color-mix(in srgb, var(--red) 14%, transparent); color: var(--red); }
  .facts { margin-top: 18px; background: var(--tile-2); border-radius: 16px; padding: 4px 16px; }
  .fact { display: flex; justify-content: space-between; gap: 12px; padding: 12px 0; font-size: 15px; }
  .fact + .fact { border-top: 1px solid var(--sep); }
  .fact span:last-child { color: var(--text-2); text-align: right; }
  .steps { margin-top: 20px; display: grid; gap: 14px; }
  .step { display: flex; align-items: center; gap: 12px; font-size: 15px; color: var(--text-3); transition: color .3s; }
  .step .mark { width: 24px; height: 24px; flex: none; border-radius: 12px; border: 2px solid var(--track); display: grid; place-items: center; transition: .3s; }
  .step .mark svg { width: 14px; height: 14px; }
  .step.active { color: var(--text); font-weight: 600; }
  .step.active .mark { border-color: var(--accent); border-top-color: transparent; animation: spin .9s linear infinite; }
  .step.done { color: var(--text); }
  .step.done .mark { background: var(--green); border-color: var(--green); color: #fff; }
  .step.error { color: var(--text); }
  .step.error .mark { background: var(--red); border-color: var(--red); color: #fff; }
  .choices { margin-top: 20px; background: var(--tile-2); border-radius: 16px; overflow: hidden; }
  .choice { width: 100%; display: flex; align-items: center; gap: 12px; padding: 13px 16px; position: relative; }
  .choice + .choice::before { content: ""; position: absolute; top: 0; left: 16px; right: 0; height: 1px; background: var(--sep); }
  .choice:active { background: var(--track); }
  .choice .meta { flex: 1; min-width: 0; }
  .choice .title { font-size: 17px; font-weight: 600; }
  .choice .sub { font-size: 13px; color: var(--text-2); margin-top: 1px; font-variant-numeric: tabular-nums; }
  .choice .mark { width: 22px; height: 22px; flex: none; color: var(--accent); opacity: 0; }
  .choice .mark svg { width: 22px; height: 22px; }
  .choice.selected .title { color: var(--accent); }
  .choice.selected .mark, .choice.busy .mark { opacity: 1; }
  .choice.busy .mark svg { animation: spin .9s linear infinite; }
  .sheet .note { font-size: 13px; color: var(--text-2); text-align: center; margin-top: 16px; min-height: 18px; }

  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after { animation-duration: .01ms !important; animation-iteration-count: 1 !important; transition-duration: .01ms !important; }
  }
</style>
</head>
<body>
<div class="ptr" id="ptr"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/></svg></div>

<div class="app" id="app">
  <header class="top rise">
    <div style="min-width:0">
      <div class="eyebrow" id="updated">透過 Tailscale 連線</div>
      <h1 id="machine">Mac</h1>
    </div>
    <div class="live stale" id="live"><span class="dot"></span><span id="live-text">連線中</span></div>
  </header>

  <section class="bento">
    <article class="tile battery rise" style="animation-delay:.04s">
      <div class="tile-label"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="7" width="17" height="10" rx="3"/><path d="M22 11v2"/></svg>電池</div>
      <div class="ring-wrap">
        <svg class="ring" viewBox="0 0 120 120">
          <circle class="track" cx="60" cy="60" r="52"/>
          <circle class="fill" id="ring" cx="60" cy="60" r="52" stroke-dasharray="326.73" stroke-dashoffset="326.73"/>
          <line class="floor" id="floor" x1="105" y1="60" x2="119" y2="60" style="opacity:0"/>
        </svg>
        <div class="ring-center">
          <div class="pct rounded"><span id="pct" class="skeleton">00</span><small>%</small></div>
          <svg class="bolt" id="bolt" viewBox="0 0 24 24" fill="currentColor"><path d="M13.5 2 4 13.5h6.5L9.5 22 20 9.5h-6.5L13.5 2Z"/></svg>
        </div>
      </div>
      <div class="foot">
        <div class="primary" id="power">&nbsp;</div>
        <div class="tile-sub" id="power-sub">&nbsp;</div>
      </div>
    </article>

    <button class="tile awake pressable rise" id="awake" style="animation-delay:.08s">
      <svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="m9 6 6 6-6 6"/></svg>
      <div class="tile-label"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9h13v5a6 6 0 0 1-6 6H10a6 6 0 0 1-6-6V9Z"/><path d="M17 11h1.5a2.5 2.5 0 0 1 0 5H17"/><path d="M8 2.5c-.6 1 .6 1.8 0 3M12 2.5c-.6 1 .6 1.8 0 3"/></svg>Sleepless</div>
      <div class="tile-value" id="awake-value">&nbsp;</div>
      <div class="tile-sub" id="awake-sub">&nbsp;</div>
      <div class="chip" id="lpm" hidden><svg viewBox="0 0 24 24" width="12" height="12" fill="currentColor"><path d="M12 3a9 9 0 1 0 9 9 7 7 0 0 1-9-9Z"/></svg>低耗電模式</div>
    </button>

    <button class="tile timer idle pressable rise" id="timer" style="animation-delay:.12s">
      <svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="m9 6 6 6-6 6"/></svg>
      <div class="tile-label"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="13" r="8"/><path d="M12 9v4l2.5 2.5M10 2h4"/></svg>計時關閉</div>
      <div class="tile-value rounded" id="timer-value">未設定</div>
      <div class="tile-sub" id="timer-sub">點一下設定</div>
    </button>
  </section>

  <section class="section rise" style="animation-delay:.16s">
    <div class="section-head">
      <h2>耗電 App</h2>
      <span class="thermal" id="thermal" hidden><span class="dot"></span><span id="thermal-text"></span></span>
    </div>
    <div class="draw" id="draw">
      <div class="draw-top">
        <div>
          <div class="kicker" id="draw-kicker">App 合計耗電</div>
          <div class="draw-value rounded"><span id="draw-watts" class="skeleton">0.0</span><small>W</small></div>
        </div>
        <div class="aside" id="draw-aside">&nbsp;</div>
      </div>
      <div id="draw-meter" hidden>
        <div class="meter"><span id="draw-share"></span></div>
        <div class="legend"><span><i class="apps"></i><span id="legend-apps"></span></span><span><i></i><span id="legend-rest"></span></span></div>
      </div>
    </div>
    <div class="list" id="apps"></div>
    <p class="hint" id="apps-hint"></p>
  </section>

  <section class="section rise" style="animation-delay:.2s">
    <div class="section-head">
      <h2>Wi-Fi</h2>
      <button class="icon-btn pressable" id="scan" aria-label="重新掃描"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/></svg></button>
    </div>
    <div class="current" id="current">
      <div class="badge" id="current-badge"></div>
      <div class="meta">
        <div class="kicker">目前連線</div>
        <div class="name" id="current-name"><span class="skeleton">bigcat-name</span></div>
        <div class="sub" id="current-sub">&nbsp;</div>
      </div>
    </div>
    <div class="list" id="networks"></div>
    <p class="hint" id="hint"></p>
  </section>
</div>

<div class="toast" id="toast" role="status"><span id="toast-icon"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm0 5a1.2 1.2 0 0 1 1.2 1.2v4.6a1.2 1.2 0 1 1-2.4 0V8.2A1.2 1.2 0 0 1 12 7Zm0 11a1.4 1.4 0 1 1 0-2.8 1.4 1.4 0 0 1 0 2.8Z"/></svg></span><span id="toast-text"></span></div>
<div class="scrim" id="scrim"></div>
<div class="sheet" id="sheet" role="dialog" aria-modal="true"><div class="grabber"></div><div id="sheet-body"></div></div>

<script>
const $ = (id) => document.getElementById(id);
const RING = 2 * Math.PI * 52;
const FINAL = new Set(["done", "reverted", "failed"]);
const ICON = {
  check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>',
  cross: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><path d="M7 7l10 10M17 7 7 17"/></svg>',
  back: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/></svg>',
  spinner: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"><path d="M21 12a9 9 0 1 1-6.2-8.56"/></svg>',
  power: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"><path d="M12 3v8"/><path d="M6.3 6.8a8 8 0 1 0 11.4 0"/></svg>',
  lock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="11" width="14" height="10" rx="2.5"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>',
  timer: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="13" r="8"/><path d="M12 9v4l2.5 2.5M10 2h4"/></svg>',
  // Two interlocked rings, like iOS's Personal Hotspot glyph: each ring breaks where the other passes over it.
  hotspot: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round"><path d="M14.87 17.06A6 6 0 1 1 15.31 13.58"/><path d="M9.13 6.94A6 6 0 1 1 8.69 10.42"/></svg>',
  window: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="3"/><path d="M3 9h18"/></svg>',
  info: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm0 4.6a1.4 1.4 0 1 1 0 2.8 1.4 1.4 0 0 1 0-2.8ZM13.2 17h-2.4v-6h2.4v6Z"/></svg>',
};

const state = { status: null, networks: null, lastOk: 0, switching: null, turnedOff: false, sheet: null,
                apps: null, appsExpanded: false, armed: null, quitting: {} };

// ---------- helpers ----------
function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else if (k === "html") node.innerHTML = v;
    else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v);
  }
  children.flat().forEach((c) => c != null && node.append(c instanceof Node ? c : document.createTextNode(c)));
  return node;
}

async function api(path, { method = "GET", body, timeout = 6000 } = {}) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeout);
  try {
    const res = await fetch(path, { method, signal: ctl.signal, cache: "no-store",
      headers: body ? { "Content-Type": "application/json" } : {}, body: body && JSON.stringify(body) });
    const isJSON = res.headers.get("content-type")?.includes("json");
    return { ok: res.ok, status: res.status, body: isJSON ? await res.json() : await res.text() };
  } finally { clearTimeout(timer); }
}

const quote = (s) => `「${s}」`;
function duration(min) {
  if (min == null) return null;
  const h = Math.floor(min / 60), m = min % 60;
  return h ? `${h} 小時${m ? ` ${m} 分` : ""}` : `${m} 分鐘`;
}
function strength(rssi) {
  if (rssi == null) return { level: 0, word: "" };
  if (rssi >= -60) return { level: 3, word: "訊號強" };
  if (rssi >= -72) return { level: 2, word: "訊號良好" };
  return { level: 1, word: "訊號弱" };
}
// iPhone hotspots are named after the phone by default, so the name is the tell.
const isHotspot = (ssid) => /iphone|熱點|hotspot/i.test(ssid ?? "");
const networkIcon = (ssid, level) => (isHotspot(ssid) ? ICON.hotspot : wifiIcon(level));

function wifiIcon(level) {
  const lit = (n) => (level >= n ? "lit" : "");
  return `<svg class="bars" viewBox="0 0 24 24"><path class="${lit(1)}" d="M12 20.5a2 2 0 1 0 0-4 2 2 0 0 0 0 4Z"/>` +
    `<path class="${lit(2)}" d="M7.05 14.6a7 7 0 0 1 9.9 0l-1.77 1.77a4.5 4.5 0 0 0-6.36 0L7.05 14.6Z"/>` +
    `<path class="${lit(3)}" d="M3.5 11.07a12 12 0 0 1 17 0l-1.77 1.77a9.5 9.5 0 0 0-13.46 0L3.5 11.07Z"/></svg>`;
}
function clock(date) {
  return date.toLocaleTimeString("zh-TW", { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
}
function countdown(ms) {
  const s = Math.max(0, Math.round(ms / 1000)), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
  const pad = (n) => String(n).padStart(2, "0");
  return h ? `${h}:${pad(m)}:${pad(r)}` : `${m}:${pad(r)}`;
}

let toastTimer;
const ALERT_ICON = $("toast-icon").innerHTML;
function toast(text, { good = false } = {}) {
  $("toast-icon").innerHTML = good ? ICON.check : ALERT_ICON;
  $("toast").classList.toggle("good", good);
  $("toast-text").textContent = text;
  $("toast").classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => $("toast").classList.remove("show"), 4200);
}

// ---------- rendering ----------
function renderLive() {
  const live = $("live"), age = Date.now() - state.lastOk;
  let kind = "", text = "即時";
  if (state.turnedOff) { kind = "gone"; text = "已離線"; }
  else if (!state.lastOk || age > 25000) { kind = "stale"; text = state.lastOk ? "重新連線中" : "連線中"; }
  live.className = `live ${kind}`;
  $("live-text").textContent = text;
  if (!state.lastOk) return;
  const s = Math.round(age / 1000);
  const when = s < 5 ? "剛剛更新" : s < 60 ? `${s} 秒前更新` : `${Math.round(s / 60)} 分鐘前更新`;
  $("updated").textContent = state.turnedOff ? "Sleepless 已關閉，Mac 將會睡眠" : `透過 Tailscale · ${when}`;
}

function renderBattery(b, floor) {
  if (!b) return;
  const pct = $("pct");
  pct.classList.remove("skeleton");
  pct.textContent = b.percent;
  const color = b.charging ? "var(--green)" : b.percent <= floor + 5 ? "var(--red)" : b.percent <= 30 ? "var(--amber)" : "var(--green)";
  const ring = $("ring");
  ring.style.stroke = color;
  ring.style.strokeDashoffset = RING * (1 - b.percent / 100);
  const floorLine = $("floor");
  if (floor > 0 && !b.charging) {
    floorLine.setAttribute("transform", `rotate(${floor * 3.6} 60 60)`);
    floorLine.style.opacity = "";
  } else floorLine.style.opacity = "0";
  $("bolt").classList.toggle("on", b.charging);
  const left = duration(b.minutesRemaining);
  const [primary, sub] = b.charging ? ["充電中", left ? `約 ${left}後充滿` : "正在估算充滿時間"]
    : b.onBattery ? ["使用電池", left ? `約可再用 ${left}` : "正在估算剩餘時間"]
    : ["已接上電源", "目前未充電"];
  $("power").textContent = primary;
  $("power-sub").textContent = sub;
}

function renderSleepless(s) {
  if (!s) return;
  const tile = $("awake");
  tile.classList.toggle("off", !s.on);
  $("awake-value").textContent = s.on ? "保持喚醒" : "已關閉";
  $("awake-sub").textContent = s.on ? `電量 ${s.floorPercent}% 時自動關閉` : "闔上螢幕時 Mac 會睡眠";
  $("lpm").hidden = !s.lowPowerMode;
  renderTimer();
}

function renderTimer() {
  const at = state.status?.sleepless?.autoOffAt ? new Date(state.status.sleepless.autoOffAt) : null;
  const tile = $("timer");
  const active = at && at > Date.now();
  tile.classList.toggle("idle", !active);
  $("timer-value").textContent = active ? countdown(at - Date.now()) : "未設定";
  $("timer-sub").textContent = active ? `${clock(at)} 關閉` : "點一下設定";
  if (state.sheet?.kind === "timer") renderTimerChoices();
}

function renderCurrent(w) {
  const card = $("current"), name = $("current-name"), sub = $("current-sub");
  const s = strength(w.rssi);
  card.classList.toggle("none", !w.current);
  $("current-badge").innerHTML = networkIcon(w.current, w.current ? s.level : 0);
  if (!w.locationAuthorized) {
    name.textContent = "無法讀取網路名稱";
    sub.textContent = "請在 Mac 上允許 Sleepless 使用定位服務";
  } else if (!w.current) {
    name.textContent = "未連上 Wi-Fi";
    sub.textContent = "";
  } else {
    name.textContent = w.current;
    sub.textContent = s.word;
  }
}

function renderNetworks() {
  const list = $("networks");
  const nets = (state.networks || []).filter((n) => !n.current);
  if (!state.networks) return;
  if (!nets.length) {
    list.replaceChildren(el("div", { class: "empty" }, "附近沒有其他已儲存的網路"));
  } else {
    list.replaceChildren(...nets.map((n) => {
      const s = strength(n.rssi);
      const usable = n.saved && n.inRange;
      const sub = !n.saved ? "尚未在 Mac 上儲存密碼" : !n.inRange ? "不在範圍內" : `已儲存 · ${s.word}`;
      const row = el(usable ? "button" : "div", { class: `net${usable ? " pressable" : " muted"}` },
        el("div", { class: "sig", html: networkIcon(n.ssid, n.inRange ? s.level : 0) }),
        el("div", { class: "meta" }, el("div", { class: "name" }, n.ssid), el("div", { class: "sub" }, sub)),
        usable ? el("span", { class: "pill" }, "切換") : null);
      if (usable) row.addEventListener("click", () => confirmSwitch(n.ssid));
      return row;
    }));
  }
  const hotspotAway = nets.some((n) => n.saved && !n.inRange && isHotspot(n.ssid));
  const hint = $("hint");
  hint.replaceChildren();
  if (hotspotAway) hint.append(el("span", { html: ICON.info }), "iPhone 熱點要在「設定 › 個人熱點」畫面開著時才會出現，打開後再按右上角重新掃描。");
  else if (nets.some((n) => !n.saved)) hint.append(el("span", { html: ICON.info }), "在 Mac 的 Sleepless › Phone dashboard › Wi-Fi passwords 儲存密碼後，就能從這裡切換。");
}

function render() {
  const st = state.status;
  if (!st) return;
  $("machine").textContent = st.machine;
  renderBattery(st.battery, st.sleepless?.floorPercent ?? 0);
  renderSleepless(st.sleepless);
  renderCurrent(st.wifi);
  renderNetworks();
  trackSwitch(st.wifi.lastSwitch);
}

// ---------- power-hungry apps ----------
// Apps below this are idle; they stay behind "show all" so the list leads with what matters.
const BUSY_WATTS = 0.05, TOP_APPS = 6, ARM_MS = 3000;
const PROTECTION = { agents: "agent 在這裡執行，不能從手機結束", tailscale: "手機靠它連到 Mac", sleepless: "讓 Mac 保持喚醒的就是它" };
const THERMAL = { nominal: ["", "溫度正常"], fair: ["warm", "有點熱"], serious: ["hot", "偏熱"], critical: ["hot", "過熱"] };

function watts(w) {
  if (w < 0.1) return "< 0.1 W";
  return `${w < 10 ? w.toFixed(1) : Math.round(w)} W`;
}

function renderDraw(report) {
  const appsTotal = report.apps.reduce((sum, a) => sum + a.watts, 0);
  const mac = report.macWatts;
  const value = $("draw-watts");
  value.classList.remove("skeleton");
  value.textContent = (mac ?? appsTotal).toFixed(1);
  $("draw-kicker").textContent = mac != null ? "Mac 目前耗電" : "App 合計耗電";
  $("draw-aside").textContent = mac != null ? `過去 ${Math.round(report.windowSeconds)} 秒平均` : "已接上電源";
  $("draw-meter").hidden = mac == null;
  if (mac != null) {
    const apps = Math.min(appsTotal, mac);
    $("draw-share").style.width = `${mac > 0 ? (apps / mac) * 100 : 0}%`;
    $("legend-apps").textContent = `App ${watts(apps)}`;
    $("legend-rest").textContent = `系統與其他 ${watts(mac - apps)}`;
  }
  const [kind, word] = THERMAL[report.thermal] ?? THERMAL.nominal;
  $("thermal").hidden = false;
  $("thermal").className = `thermal ${kind}`;
  $("thermal-text").textContent = word;
}

function appRow(app, maxWatts) {
  const phase = app.quit;
  const level = app.watts >= 2 ? "high" : app.watts >= 0.5 ? "mid" : "";
  const icon = el("div", { class: "app-icon" },
    el("img", { src: `/api/apps/icon/${encodeURIComponent(app.id)}`, alt: "", loading: "lazy",
                onerror: (e) => { const box = e.target.parentNode; box.className = "app-icon generic"; box.innerHTML = ICON.window; } }));
  const why = app.protection ? el("div", { class: "why" }, PROTECTION[app.protection])
    : phase === "notResponding" ? el("div", { class: "why warn" }, "沒有回應，可能正在等待存檔")
    : null;
  const meta = el("div", { class: "meta" },
    el("div", { class: "name" }, app.name),
    el("div", { class: "usage" },
      el("div", { class: "bar" }, el("span", { class: level, style: `width:${Math.max(3, (app.watts / maxWatts) * 100)}%` })),
      el("span", { class: "watts" }, watts(app.watts))),
    why);
  return el("div", { class: "app-row" }, icon, meta, app.protection ? el("span", { class: "lock", html: ICON.lock }) : quitButton(app));
}

// Two taps, no sheet: the first arms the button for a few seconds, the second quits. Quick when
// clearing several apps in a row, and a bump on the train can't quit anything by itself.
function quitButton(app) {
  if (app.quit === "quitting") return el("button", { class: "quit", disabled: "" }, el("span", { html: ICON.spinner }), "結束中");
  const force = app.quit === "notResponding";
  const key = `${app.id}|${force}`;
  const armed = state.armed?.key === key;
  const label = force ? (armed ? "確定強制結束" : "強制結束") : (armed ? "確定結束" : "結束");
  const btn = el("button", { class: `quit pressable${armed ? " armed" : ""}`, onclick: () => tapQuit(app, force, key) }, label);
  if (armed) btn.style.setProperty("--elapsed", `${-(Date.now() - state.armed.at)}ms`);
  return btn;
}

function tapQuit(app, force, key) {
  if (state.armed?.key !== key) {
    clearTimeout(state.armed?.timer);
    state.armed = { key, at: Date.now(), timer: setTimeout(() => { state.armed = null; renderApps(); }, ARM_MS) };
    return renderApps();
  }
  if (Date.now() - state.armed.at < 350) return;   // a double tap is not a confirmation
  clearTimeout(state.armed.timer);
  state.armed = null;
  quitApp(app, force);
}

const QUIT_REFUSAL = {
  protected: (n) => `${quote(n)}受到保護，不能從手機結束。`,
  notRunning: (n) => `${quote(n)}已經結束了。`,
};

async function quitApp(app, force) {
  state.quitting[app.id] = { name: app.name, watts: app.watts };
  app.quit = "quitting";
  renderApps();
  try {
    const res = await api("/api/apps/quit", { method: "POST", body: { id: app.id, force } });
    if (!res.ok) {
      delete state.quitting[app.id];
      const f = QUIT_REFUSAL[res.body?.code];
      toast(f ? f(app.name) : `無法結束${quote(app.name)}（${res.status}）`);
    }
  } catch {
    delete state.quitting[app.id];
    toast("無法連線到 Mac。");
  }
  scheduleApps(1500);
}

function renderApps() {
  const list = $("apps");
  const report = state.apps;
  if (!report) {
    list.replaceChildren(...[0, 1, 2].map(() => el("div", { class: "app-row" },
      el("div", { class: "app-icon generic" }), el("div", { class: "meta" }, el("span", { class: "name skeleton" }, "Application name")))));
    return;
  }
  renderDraw(report);
  const busy = report.apps.filter((a) => a.watts >= BUSY_WATTS || a.quit);
  const shown = state.appsExpanded ? report.apps : busy.slice(0, TOP_APPS);
  const maxWatts = Math.max(0.5, ...report.apps.map((a) => a.watts));
  const rows = shown.map((a) => appRow(a, maxWatts));
  if (!rows.length) rows.push(el("div", { class: "empty" }, "目前沒有明顯耗電的 App"));
  const hidden = report.apps.length - shown.length;
  if (state.appsExpanded || hidden > 0) {
    rows.push(el("button", { class: "more", onclick: () => { state.appsExpanded = !state.appsExpanded; renderApps(); } },
      state.appsExpanded ? "只顯示耗電的 App" : `顯示全部 ${report.apps.length} 個 App`));
  }
  list.replaceChildren(...rows);

  const hint = $("apps-hint");
  hint.replaceChildren();
  hint.className = "hint";
  if (report.thermal === "serious" || report.thermal === "critical") {
    hint.classList.add("warn");
    hint.append(el("span", { html: ICON.info }), "Mac 正在變熱。結束耗電的 App，或讓包包裡的 Mac 有點空間散熱。");
  }
}

// An app that disappears while it was being quit has really quit; say what that saved.
function settleQuits(report) {
  const running = new Set(report.apps.map((a) => a.id));
  for (const [id, q] of Object.entries(state.quitting)) {
    if (running.has(id)) continue;
    delete state.quitting[id];
    toast(`已結束${quote(q.name)}${q.watts >= 0.1 ? `，省下約 ${watts(q.watts)}` : ""}。`, { good: true });
  }
}

let appsTimer = null;
async function loadApps() {
  clearTimeout(appsTimer);
  try {
    const res = await api("/api/apps", { timeout: 8000 });
    if (res.ok) {
      settleQuits(res.body);
      state.apps = res.body;
      renderApps();
    }
  } catch { /* the status poll already shows the link state */ }
  scheduleApps();
}

function scheduleApps(delay) {
  clearTimeout(appsTimer);
  if (document.visibilityState !== "visible") return;
  const quitting = state.apps?.apps.some((a) => a.quit === "quitting");
  appsTimer = setTimeout(loadApps, delay ?? (quitting ? 2000 : 10000));
}

// ---------- sheet ----------
function openSheet(kind, build, { dismissable = true } = {}) {
  state.sheet = { kind, dismissable };
  $("sheet-body").replaceChildren(...build().filter(Boolean));
  $("scrim").classList.add("show");
  $("sheet").classList.add("show");
  document.body.classList.add("locked");
}
function closeSheet() {
  state.sheet = null;
  $("scrim").classList.remove("show");
  $("sheet").classList.remove("show");
  document.body.classList.remove("locked");
}
$("scrim").addEventListener("click", () => state.sheet?.dismissable && closeSheet());

// Drag to dismiss, like an iOS sheet: it follows the finger, and a long enough drag or a quick
// flick closes it. A sheet that can't be dismissed (a switch in progress) resists and springs back.
(() => {
  const sheet = $("sheet"), scrim = $("scrim");
  const resist = (dy) => Math.sign(dy) * Math.pow(Math.abs(dy), 0.7);
  let startY = null, lastY = 0, lastT = 0, velocity = 0, dragging = false;
  sheet.addEventListener("touchstart", (e) => {
    if (!state.sheet) return;
    startY = lastY = e.touches[0].clientY;
    lastT = e.timeStamp;
    velocity = 0;
    dragging = false;
  }, { passive: true });
  sheet.addEventListener("touchmove", (e) => {
    if (startY == null) return;
    const y = e.touches[0].clientY;
    if (!dragging && Math.abs(y - startY) < 6) return;   // still a tap
    dragging = true;
    velocity = (y - lastY) / Math.max(1, e.timeStamp - lastT);
    lastY = y;
    lastT = e.timeStamp;
    const raw = y - startY;
    const dy = raw > 0 && state.sheet.dismissable ? raw : resist(raw);
    sheet.style.transition = scrim.style.transition = "none";
    sheet.style.transform = `translateY(${dy}px)`;
    if (dy > 0 && state.sheet.dismissable) scrim.style.opacity = String(1 - Math.min(1, dy / sheet.offsetHeight));
  }, { passive: true });
  const release = () => {
    if (startY == null) return;
    const dy = lastY - startY;
    startY = null;
    sheet.style.transition = scrim.style.transition = sheet.style.transform = scrim.style.opacity = "";
    const flung = velocity > 0.5 && dy > 30;
    if (dragging && state.sheet?.dismissable && (dy > sheet.offsetHeight * 0.25 || flung)) closeSheet();
  };
  sheet.addEventListener("touchend", release);
  sheet.addEventListener("touchcancel", release);
})();

function confirmSwitch(ssid) {
  const from = state.status?.wifi?.current;
  openSheet("confirm", () => [
    el("div", { class: "hero", html: networkIcon(ssid, 3) }),
    el("h3", {}, `切換到${quote(ssid)}？`),
    el("p", { class: "body" }, `Mac 會暫時斷線幾秒鐘。${from ? `如果 45 秒內連不上網路，會自動切回${quote(from)}。` : ""}`),
    el("div", { class: "actions" },
      el("button", { class: "btn primary pressable", onclick: () => startSwitch(ssid) }, "切換"),
      el("button", { class: "btn plain pressable", onclick: closeSheet }, "取消")),
  ]);
}

const REFUSAL = {
  busy: () => "正在進行另一次切換，請稍候。",
  alreadyConnected: (s) => `Mac 已經連在${quote(s)}。`,
  noSavedPassword: (s) => `還沒儲存${quote(s)}的密碼，請先在 Mac 上的 Sleepless 儲存。`,
  noWayBack: (s) => `目前的網路${quote(s)}沒有儲存密碼，切換失敗時會回不來。請先在 Mac 上儲存它的密碼。`,
  notInRange: (s) => `掃描不到${quote(s)}。如果是 iPhone 熱點，請先打開「個人熱點」畫面。`,
};

async function startSwitch(ssid) {
  state.switching = { target: ssid, from: state.status?.wifi?.current, startedAt: Date.now(), phase: "switching", reason: null, lost: false };
  renderSwitchSheet();
  try {
    const res = await api("/api/wifi/switch", { method: "POST", body: { ssid }, timeout: 20000 });
    if (!res.ok) {
      state.switching = null;
      closeSheet();
      const f = REFUSAL[res.body?.code];
      toast(f ? f(res.body.ssid ?? ssid) : `無法切換（${res.status}）`);
      return;
    }
  } catch { /* the link may already be dropping; polling picks it up */ }
  schedule(0);
}

function trackSwitch(last) {
  const sw = state.switching;
  if (!sw || !last || last.target !== sw.target) return;
  if (new Date(last.updatedAt).getTime() < sw.startedAt - 3000) return;   // an older switch's result
  sw.phase = last.phase;
  sw.reason = last.reason;
  sw.from = last.from ?? sw.from;
  sw.lost = false;
  renderSwitchSheet();
  if (FINAL.has(last.phase)) {
    state.switching = null;
    loadNetworks();
  }
}

function renderSwitchSheet() {
  const sw = state.switching ?? state.lastSwitch;
  if (!sw) return;
  state.lastSwitch = sw;
  const { target, from, phase, reason } = sw;
  const final = FINAL.has(phase);
  const failedBranch = ["reverting", "reverted", "failed"].includes(phase);
  const hero = phase === "done" ? ["good", ICON.check] : phase === "reverted" ? ["warn", ICON.back]
    : phase === "failed" ? ["bad", ICON.cross] : ["busy", ICON.spinner];
  const title = phase === "done" ? `已切換到${quote(target)}`
    : phase === "reverted" ? `已切回${quote(from)}`
    : phase === "failed" ? "切換沒有成功"
    : phase === "reverting" ? `正在切回${quote(from)}…` : `正在切換到${quote(target)}…`;
  const why = reason === "noInternet" ? `${quote(target)}在 45 秒內無法上網，可能是密碼錯誤，或需要網頁登入。`
    : reason === "joinFailed" ? `無法加入${quote(target)}，可能是密碼錯誤或訊號太弱。` : "";
  const body = phase === "done" ? "Mac 已經可以正常上網。"
    : phase === "reverted" ? `${why}Mac 已經回到原本的網路。`
    : phase === "failed" ? `${why}${from ? `也無法切回${quote(from)}，` : ""}macOS 會自動連上其他認得的網路。`
    : "連線會中斷幾秒鐘，Mac 回來之後這裡會自動更新。";

  const step = (label, status) => el("div", { class: `step ${status}` },
    el("span", { class: "mark", html: status === "done" ? ICON.check : status === "error" ? ICON.cross : "" }), label);
  const joinStatus = phase === "switching" ? "active" : reason === "joinFailed" ? "error" : "done";
  const netStatus = phase === "switching" ? "" : phase === "verifying" ? "active" : reason === "noInternet" ? "error" : reason === "joinFailed" ? "" : "done";
  const steps = [step(`加入${quote(target)}`, joinStatus), step("確認可以上網", netStatus)];
  if (failedBranch && from) steps.push(step(`切回${quote(from)}`, phase === "reverting" ? "active" : phase === "reverted" ? "done" : "error"));
  else steps.push(step("完成", phase === "done" ? "done" : ""));

  const elapsed = Math.round((Date.now() - (sw.startedAt || Date.now())) / 1000);
  const note = final ? "" : sw.lost ? `Mac 暫時斷線中，正在等它回來…（${elapsed} 秒）` : `已經過 ${elapsed} 秒`;

  const render = () => [
    el("div", { class: `hero ${hero[0]}`, html: hero[1] }),
    el("h3", {}, title),
    el("p", { class: "body" }, body),
    el("div", { class: "steps" }, steps),
    el("p", { class: "note", id: "switch-note" }, note),
    final ? el("div", { class: "actions" }, el("button", { class: "btn plain pressable", onclick: () => { state.lastSwitch = null; closeSheet(); } }, "完成")) : null,
  ];
  if (state.sheet?.kind === "switch") $("sheet-body").replaceChildren(...render().filter(Boolean));
  else openSheet("switch", render, { dismissable: final });
  state.sheet.dismissable = final;
}

function openSleeplessSheet() {
  const s = state.status?.sleepless;
  if (!s) return;
  const at = s.autoOffAt ? new Date(s.autoOffAt) : null;
  openSheet("sleepless", () => [
    el("div", { class: "hero", html: ICON.power }),
    el("h3", {}, s.on ? "Sleepless 正在保持喚醒" : "Sleepless 已關閉"),
    el("p", { class: "body" }, s.on ? "闔上螢幕時，Mac 會繼續執行工作。" : "闔上螢幕時 Mac 會正常睡眠。"),
    el("div", { class: "facts" },
      el("div", { class: "fact" }, el("span", {}, "低電量自動關閉"), el("span", {}, `${s.floorPercent}%`)),
      el("div", { class: "fact" }, el("span", {}, "計時關閉"), el("span", {}, at && at > Date.now() ? `${clock(at)}` : "未設定")),
      el("div", { class: "fact" }, el("span", {}, "低耗電模式"), el("span", {}, s.lowPowerMode ? "開啟" : "關閉"))),
    s.on ? el("p", { class: "body", style: "margin-top:16px;font-size:13px" }, "關閉後，Mac 會在螢幕闔上時進入睡眠，這個頁面也會中斷，直到你再次打開 Mac。") : null,
    el("div", { class: "actions" },
      s.on ? el("button", { class: "btn destructive pressable", onclick: turnOff }, "關閉 Sleepless") : null,
      el("button", { class: "btn plain pressable", onclick: closeSheet }, s.on ? "取消" : "完成")),
  ]);
}

// ---------- auto-off timer ----------
const AUTO_OFF = [[0, "不自動關閉"], [60, "1 小時後"], [120, "2 小時後"]];

function timerChoiceSub(minutes) {
  const s = state.status?.sleepless;
  const at = s?.autoOffAt ? new Date(s.autoOffAt) : null;
  if (!minutes) return "保持喚醒，直到你關閉 Sleepless";
  if (s?.autoOffMinutes === minutes && at > Date.now()) return `還剩 ${countdown(at - Date.now())} · 再點一下重新計時`;
  return `${clock(new Date(Date.now() + minutes * 60000))} 關閉`;
}

// Updates the rows in place: rebuilding them every second would swallow a tap in progress.
function renderTimerChoices() {
  const chosen = state.status?.sleepless?.autoOffMinutes ?? 0;
  for (const [minutes] of AUTO_OFF) {
    const row = document.getElementById(`choice-${minutes}`);
    if (!row) continue;
    const busy = state.settingAutoOff === minutes;
    row.className = `choice${busy ? " busy" : minutes === chosen && state.settingAutoOff == null ? " selected" : ""}`;
    row.querySelector(".mark").innerHTML = busy ? ICON.spinner : ICON.check;
    row.querySelector(".sub").textContent = timerChoiceSub(minutes);
  }
}

function openTimerSheet() {
  if (!state.status?.sleepless?.on) return;
  openSheet("timer", () => [
    el("div", { class: "hero", html: ICON.timer }),
    el("h3", {}, "計時關閉"),
    el("p", { class: "body" }, "時間到時 Sleepless 會關閉，闔著螢幕的 Mac 會進入睡眠，這個頁面也會中斷。"),
    el("div", { class: "choices" }, AUTO_OFF.map(([minutes, label]) =>
      el("button", { class: "choice", id: `choice-${minutes}`, onclick: () => setAutoOff(minutes) },
        el("div", { class: "meta" }, el("div", { class: "title" }, label), el("div", { class: "sub" })),
        el("span", { class: "mark" })))),
    el("div", { class: "actions" }, el("button", { class: "btn plain pressable", onclick: closeSheet }, "完成")),
  ]);
  renderTimerChoices();
}

async function setAutoOff(minutes) {
  if (state.settingAutoOff != null) return;
  state.settingAutoOff = minutes;
  renderTimerChoices();
  try {
    const res = await api("/api/sleepless/auto-off", { method: "POST", body: { minutes } });
    if (!res.ok) return toast("無法設定計時關閉。");
    state.status.sleepless = res.body;
    state.settingAutoOff = null;
    render();
    closeSheet();
    const at = res.body.autoOffAt ? new Date(res.body.autoOffAt) : null;
    toast(at ? `Sleepless 會在 ${clock(at)} 自動關閉。` : "已取消計時關閉。", { good: true });
  } catch { toast("無法連線到 Mac。"); }
  finally {
    state.settingAutoOff = null;
    renderTimerChoices();
  }
}

async function turnOff() {
  closeSheet();
  try {
    const res = await api("/api/sleepless/off", { method: "POST", body: {} });
    if (!res.ok) return toast("無法關閉 Sleepless。");
    state.turnedOff = true;
    if (state.status?.sleepless) state.status.sleepless.on = false;
    render();
    renderLive();
    toast("Sleepless 已關閉。");
  } catch { toast("無法連線到 Mac。"); }
}

// ---------- data ----------
let pollTimer = null;
async function poll() {
  try {
    const res = await api("/api/status", { timeout: state.switching ? 3500 : 6000 });
    if (res.ok) {
      state.status = res.body;
      state.lastOk = Date.now();
      state.turnedOff = false;
      render();
    } else if (res.status === 403 || res.status === 503) {
      toast(typeof res.body === "string" ? res.body : `錯誤 ${res.status}`);
    }
  } catch {
    if (state.switching) {
      state.switching.lost = true;
      renderSwitchSheet();
      if (Date.now() - state.switching.startedAt > 240000) {
        state.switching.phase = "failed";
        state.switching.reason = null;
        state.switching = null;
        closeSheet();
        toast("超過 4 分鐘聯絡不到 Mac。如果切換失敗，Mac 會自行切回原本的網路。");
      }
    }
  }
  renderLive();
  schedule();
}

function schedule(delay) {
  clearTimeout(pollTimer);
  if (document.visibilityState !== "visible") return;
  pollTimer = setTimeout(poll, delay ?? (state.switching ? 2000 : 10000));
}

async function loadNetworks() {
  const btn = $("scan");
  btn.classList.add("spin");
  btn.disabled = true;
  try {
    const res = await api("/api/wifi/networks", { timeout: 15000 });
    if (res.ok) {
      state.networks = res.body.networks;
      renderNetworks();
    }
  } catch { if (!state.switching) toast("掃描失敗，無法連線到 Mac。"); }
  btn.classList.remove("spin");
  btn.disabled = false;
}

// ---------- pull to refresh ----------
(() => {
  const ptr = $("ptr"), app = $("app");
  let startY = null, pulled = 0;
  addEventListener("touchstart", (e) => { startY = scrollY <= 0 && !state.sheet ? e.touches[0].clientY : null; pulled = 0; }, { passive: true });
  addEventListener("touchmove", (e) => {
    if (startY == null) return;
    pulled = Math.max(0, Math.min(110, (e.touches[0].clientY - startY) * 0.5));
    ptr.style.transition = app.style.transition = "none";
    ptr.style.opacity = Math.min(1, pulled / 60);
    ptr.style.transform = `translateY(${pulled - 40}px) rotate(${pulled * 4}deg)`;
    app.style.transform = `translateY(${pulled * 0.5}px)`;
  }, { passive: true });
  addEventListener("touchend", async () => {
    if (startY == null) return;
    startY = null;
    ptr.style.transition = app.style.transition = "";
    app.style.transform = "";
    if (pulled < 60) { ptr.style.opacity = 0; ptr.style.transform = ""; return; }
    ptr.classList.add("loading");
    ptr.style.transform = "translateY(14px)";
    await Promise.all([poll(), loadNetworks(), loadApps()]);
    ptr.classList.remove("loading");
    ptr.style.opacity = 0;
    ptr.style.transform = "";
  });
})();

// ---------- wiring ----------
$("scan").addEventListener("click", loadNetworks);
$("awake").addEventListener("click", openSleeplessSheet);
$("timer").addEventListener("click", openTimerSheet);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") { poll(); loadNetworks(); loadApps(); }
  else { clearTimeout(pollTimer); clearTimeout(appsTimer); }
});
setInterval(() => {
  renderLive();
  renderTimer();
  if (state.switching && state.sheet?.kind === "switch") {
    const note = document.getElementById("switch-note");
    const elapsed = Math.round((Date.now() - state.switching.startedAt) / 1000);
    if (note) note.textContent = state.switching.lost ? `Mac 暫時斷線中，正在等它回來…（${elapsed} 秒）` : `已經過 ${elapsed} 秒`;
  }
}, 1000);

poll();
loadNetworks();
renderApps();
loadApps();
</script>
</body>
</html>
"""#
