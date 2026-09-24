// App.swift. Sleepless: a standalone menu-bar toggle that keeps the Mac running
// with the lid closed (on battery, no external display) via `pmset disablesleep`.
//
// Mechanism (verified live on this machine; disablesleep is UNDOCUMENTED in
// pmset(1) but real. It sets IORegistry "SleepDisabled" = Yes and disables
// idle + Apple-menu + lid-close clamshell sleep):
//   ON : sudo pmset -a disablesleep 1
//   OFF: sudo pmset -a disablesleep 0
//   READ (no root): pmset -g | grep -i SleepDisabled  (value 1 = ON; 0/absent = OFF)
// The OFF/ON commands run passwordless via a tightly-scoped /etc/sudoers.d drop-in.
// disablesleep is runtime-only and resets to 0 on reboot, and that reset is a
// deliberate safety feature; the app does NOT auto re-arm.
//
// UI: clicking the menu-bar coffee cup opens a small native popover with an NSSwitch
// toggle (the System-Settings control), a state caption, an auto-off timer, the
// battery-floor slider, a Claude Remote Control switch + repo picker, a Launch-at-login
// switch, and Quit. The menu-bar glyph also shows state at a glance.
//
// The coffee-cup metaphor is literal: an EMPTY cup means the Mac sleeps normally, a
// FULL cup means it is being kept awake (caffeinated), and a full cup with a small
// dot means it is awake on battery with the auto-off safety net live.
//
// Four small, fail-safe features layer on top, none of which adds a daemon or
// persists OS state (so "reboot resets it" still holds):
//   1. Auto-off timer (1h / 2h) — a one-shot in-memory Timer that flips sleep back
//      on when it fires. Dies on quit; nothing survives a reboot.
//   2. Launch at login (SMAppService.mainApp) — OFF by default. The app always
//      launches reading the TRUE system state, so a login launch can never
//      re-enable disablesleep on its own.
//   3. Low-Power-Mode auto-off — on battery, if Low Power Mode is on, Sleepless
//      turns itself off. Same shape as the battery floor, evaluated on the same tick.
//   4. Claude Remote Control — ON by default. While the Mac is kept awake, a supervised
//      `claude remote-control` child process runs in a repo you pick under ~/Projects, so
//      new Claude Code sessions can be started from the phone with the lid closed. It is a
//      child process, not a daemon: it starts and dies with the keep-awake switch, and the
//      OS reaps it on sleep.
//
// Build (mirrors Nexus.app): Command Line Tools `swiftc`, NO Xcode project.
//   swiftc -O -parse-as-library -target arm64-apple-macos26.0 -framework AppKit \
//          -framework ServiceManagement
//   File MUST be named App.swift and compiled -parse-as-library so the
//   @main enum + @MainActor static main() entry is Swift-6 isolation-safe.
import AppKit
import ServiceManagement

// MARK: - Tunables
private let pollInterval: TimeInterval = 60
// Battery-floor config (user-adjustable via the popover slider; persisted in UserDefaults).
private let floorKey = "batteryFloorPercent"
private let floorDefault = 15
private let floorMin = 5
private let floorMax = 50

// Claude Remote Control (Feature 4): an optional companion process running
// `claude remote-control` inside a chosen repo, so a lid-closed Mac can still accept new
// Claude Code sessions started from the phone. Its lifecycle follows the keep-awake switch —
// the server exists only while the Mac is kept awake, and macOS reaping it on sleep is
// exactly the wanted behaviour, so no extra teardown is needed for the auto-off timer.
private let rcEnabledKey = "remoteControlEnabled"
private let rcRepoKey = "remoteControlRepo"
private let rcDefaultRepo = "inLineAPI"
private let rcProjectsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects")
// Supervisor backoff. `claude remote-control` exits on its own after roughly 10 minutes
// without network, so a short outage must not need a manual restart — but a permanently
// broken setup must not retry forever either, hence a hard cap rather than endless backoff.
private let rcBackoffDelays: [TimeInterval] = [5, 15, 45, 120, 300]
private let rcHealthyUptime: TimeInterval = 120   // ran at least this long -> next exit gets a fresh retry budget
private let rcLogByteCap = 256 * 1024             // pathological-output backstop; dedup alone keeps runs far below this
private let rcLogFrameCap = 64 * 1024             // output with no repaint in it at all must not buffer forever

// A pipe read ends wherever the buffer ran out, which can be mid-character — and the status
// line is full of multi-byte glyphs (·, ✔︎, …). Decoding a chunk that ends that way yields
// nothing at all, so the trailing partial sequence is held back until the rest of it arrives.
private func trailingPartialCharacterLength(_ data: Data) -> Int {
    var trailing = 0
    var index = data.endIndex - 1
    while index >= data.startIndex, trailing < 4 {
        let byte = data[index]
        if byte & 0xC0 == 0x80 { trailing += 1; index -= 1; continue }   // continuation byte
        let width = byte & 0x80 == 0 ? 1 : (byte & 0xE0 == 0xC0 ? 2 : (byte & 0xF0 == 0xE0 ? 3 : 4))
        return width > trailing + 1 ? trailing + 1 : 0                   // still short of a whole character
    }
    return 0   // all continuation bytes, or empty: nothing useful to hold back
}

// `claude remote-control` draws a live TUI: it repaints its whole status block about once a
// second by moving the cursor up and erasing. Invisible in a terminal, but against a file it
// appends ~1.8 MB an hour of byte-identical frames. The CLI offers no way off: this subcommand
// rejects `--ax-screen-reader` outright and ignores CLAUDE_AX_SCREEN_READER, so the supervisor
// filters the stream itself rather than depending on CLI behaviour that is not documented.
//
// The cursor-up sequence IS the child's frame delimiter, so we split on it and keep a frame
// only when it differs from the one before. Repaints collapse to nothing while every state
// change and error still lands in the file, which is the part worth keeping.
private let rcCursorUpPattern = "\u{1B}\\[[0-9]*A"
private let rcEscapePattern =
    "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)"   // OSC (hyperlinks); payload goes with it
    + "|\u{1B}\\[[0-9;?]*[ -/]*[@-~]"                  // CSI (colour, erase, cursor moves)
    + "|\u{1B}."                                       // anything else escaped

private final class RemoteControlLog {
    private let queue = DispatchQueue(label: "com.sleepless.remote-control-log")
    private let handle: FileHandle?
    private var bytes = Data()
    private var pending = ""
    private var lastFrame = ""
    private var written = 0

    // Truncated per run: only the current server's output matters.
    init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func ingest(_ data: Data) {
        queue.async { [self] in
            bytes.append(data)
            let cut = bytes.count - trailingPartialCharacterLength(bytes)
            guard cut > 0 else { return }
            pending += String(decoding: bytes.prefix(cut), as: UTF8.self)
            bytes.removeFirst(cut)
            var frames = pending
                .replacingOccurrences(of: rcCursorUpPattern, with: "\u{0}", options: .regularExpression)
                .components(separatedBy: "\u{0}")
            pending = frames.removeLast()   // no delimiter yet: still being drawn, wait for the rest
            frames.forEach(emit)
            if pending.utf8.count > rcLogFrameCap { emit(pending); pending = "" }   // never repaints; don't hoard it
        }
    }

    // Blocks until everything handed over so far is on disk, so the exit path can read the
    // file back and still see the message the child printed on its way out.
    func flush() {
        queue.sync { drain() }
    }

    // Flushes the frame in flight, which is the one carrying an exit message or a crash.
    func finish() {
        queue.async { [self] in
            drain()
            try? handle?.close()
        }
    }

    private func drain() {
        emit(pending + String(decoding: bytes, as: UTF8.self))   // no more bytes coming to complete it
        bytes.removeAll()
        pending = ""
    }

    private func emit(_ frame: String) {
        let text = frame
            .replacingOccurrences(of: rcEscapePattern, with: "", options: .regularExpression)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !text.isEmpty else { return }
        let body = text.joined(separator: "\n")
        guard body != lastFrame else { return }
        lastFrame = body
        let stamp = rcLogTimeFormatter.string(from: Date())
        write(text.map { "[\(stamp)] \($0)\n" }.joined())
    }

    private func write(_ line: String) {
        guard let handle, let data = line.data(using: .utf8) else { return }
        if written + data.count > rcLogByteCap {
            try? handle.truncate(atOffset: 0)
            try? handle.seek(toOffset: 0)
            written = 0
            lastFrame = ""
        }
        try? handle.write(contentsOf: data)
        written += data.count
    }
}

private let rcLogTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

// MARK: - Menu-bar coffee glyph (native SF Symbols, MONOCHROME template — state by SHAPE)
// macOS convention: a menu-bar extra is a template image (no colour) so it adapts to light/dark
// bars and inverts on highlight. State is read from the SILHOUETTE, not colour. The old
// empty-vs-filled cups looked near-identical at 16 px, so we switch the silhouette dramatically
// with steam (a hot cup = awake):
//   OFF   (sleeps normally)        = cup.and.saucer            cup resting on its saucer, NO steam (cold/asleep)
//   ON    (kept awake, on power)   = cup.and.heat.waves.fill   hot cup with rising steam (awake)
//   ARMED (kept awake, on battery) = cup.and.heat.waves.fill + a small dot (awake, safety net live)
// The no-steam → steam change reads instantly even at 16 px; the armed dot is the only extra
// mark. All template (monochrome) — SF Symbols only, no hand-drawn paths.
enum SleepGlyph {
    case off
    case on
    case armed
}

private func makeCupGlyph(_ glyph: SleepGlyph) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular).applying(.init(scale: .medium))
    let name = (glyph == .off) ? "cup.and.saucer" : "cup.and.heat.waves.fill"
    let base = NSImage(systemSymbolName: name, accessibilityDescription: "Sleepless")?
        .withSymbolConfiguration(cfg)
        ?? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Sleepless")
        ?? NSImage()

    guard glyph == .armed else {
        base.isTemplate = true
        return base
    }
    // ARMED: full steaming cup + a small filled dot top-right (the "auto-off safety net is live"
    // mark). Drawn in template black so it tints + inverts with the menu bar exactly like the cup.
    let size = base.size
    guard size.width > 0, size.height > 0 else { base.isTemplate = true; return base }
    let composed = NSImage(size: size)
    composed.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: size))
    let d = max(size.height * 0.26, 4)
    let dot = NSBezierPath(ovalIn: NSRect(x: size.width - d, y: size.height - d, width: d, height: d))
    NSColor.black.setFill()
    dot.fill()
    composed.unlockFocus()
    composed.isTemplate = true
    return composed
}

// Flipped container so popover content lays out top-down with simple frames.
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

// Brand accent (2026 "Liquid Glass" redesign): indigo -> violet -> fuchsia. The
// violet mid-tone is the single accent the popover uses to communicate the
// privileged "awake" state, matching the app icon's gradient mid-stop. These are
// the only hard-coded colours; everything else stays on system semantic colours so
// the panel still reads as a first-party control.
private let brandAccent = NSColor(srgbRed: 139/255.0, green: 92/255.0, blue: 246/255.0, alpha: 1)   // #8B5CF6 violet
private let brandAccentSoft = NSColor(srgbRed: 167/255.0, green: 139/255.0, blue: 250/255.0, alpha: 1) // #A78BFA

// Frosted-glass popover backing: a flipped NSVisualEffectView so content still
// lays out top-down while the panel gets a translucent, blurred material that
// samples the desktop/windows behind it (system light/dark aware). On macOS 26 the
// .popover material renders as the system Liquid Glass automatically; we deliberately
// keep this native (no hand-rolled tint on the surface) so a sudo-touching panel
// stays visually first-party. Colour lives on the controls, never the surface.
private final class GlassView: NSVisualEffectView { override var isFlipped: Bool { true } }

// Inset grouping "card" (System Settings rhythm): a flipped, layer-backed container
// with a subtle, appearance-adaptive fill, a hairline border, and continuous-corner
// rounding. When `active`, the card carries a faint brand-violet wash + a violet
// hairline so the privileged "kept awake" state is unmistakable at a glance in the
// accent colour (Apple's "tint elements, not surfaces" model). Re-resolved on
// light/dark changes and on state changes via updateLayer.
private final class CardView: NSView {
    var active = false { didSet { if active != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if active {
            layer?.backgroundColor = brandAccent.withAlphaComponent(dark ? 0.18 : 0.10).cgColor
            layer?.borderColor = brandAccent.withAlphaComponent(dark ? 0.60 : 0.45).cgColor
            layer?.borderWidth = 1
        } else {
            layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.06)
                                           : NSColor.black.withAlphaComponent(0.045)).cgColor
            layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.08)
                                       : NSColor.black.withAlphaComponent(0.06)).cgColor
            layer?.borderWidth = 1
        }
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate,
                         NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let onGlyph = makeCupGlyph(.on)
    private let offGlyph = makeCupGlyph(.off)
    private let armedGlyph = makeCupGlyph(.armed)

    // Popover UI
    private let popover = NSPopover()
    private var toggleSwitch: NSSwitch!
    private var mainCard: CardView!         // group-1 card; gets the brand-violet wash when awake
    private var headerMark: NSImageView!    // header coffee mark; tints violet when awake
    private var captionLabel: NSTextField!
    private var floorValueLabel: NSTextField!
    private var floorSlider: NSSlider!
    private var autoOffControl: NSSegmentedControl!
    private var countdownLabel: NSTextField!
    private var loginSwitch: NSSwitch!
    private var clickMonitor: Any?
    private var batteryFloorPercent = floorDefault
    private var isOn = false
    private var userForcedOn = false   // user deliberately turned it on; honor over the Low Power Mode auto-off (the hard battery floor still wins)

    // Auto-off timer (in-memory; dies on quit, never survives a reboot)
    private var autoOffMinutes = 0           // 0 = none (stay on until off), 60, or 120
    private var keepAwakeTimer: Timer?       // one-shot: flips sleep back on when it fires
    private var countdownTicker: Timer?      // 1 Hz label refresh, only while the popover is open
    private var timerEndDate: Date?

    // Claude Remote Control (Feature 4)
    private var rcSwitch: NSSwitch!
    private var rcRepoButton: NSButton!
    private var rcStatusLabel: NSTextField!
    private var rcEnabled = true
    private var rcRepo = rcDefaultRepo
    private var rcProcess: Process?
    private var rcStoppingProcess: Process?
    private var rcStartedAt: Date?
    private var rcAttempt = 0
    private var rcRetryTimer: Timer?
    private var rcRetryDeadline: Date?
    private var rcMessage = ""
    private var rcLog: RemoteControlLog?

    // Searchable repo picker (second page of the popover)
    private var settingsPage: FlippedView!
    private var pickerPage: FlippedView!
    private var repoSearchField: NSSearchField!
    private var repoTable: NSTableView!
    private var allRepos: [String] = []
    private var filteredRepos: [String] = []

    private let popoverWidth: CGFloat = 320
    private let popoverHeight: CGFloat = 544

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        batteryFloorPercent = min(max((UserDefaults.standard.object(forKey: floorKey) as? Int) ?? floorDefault, floorMin), floorMax)
        rcEnabled = (UserDefaults.standard.object(forKey: rcEnabledKey) as? Bool) ?? true   // ON by default
        rcRepo = UserDefaults.standard.string(forKey: rcRepoKey) ?? rcDefaultRepo
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = offGlyph
            button.action = #selector(statusClicked)
            button.target = self
        }
        popover.behavior = .applicationDefined   // app-managed dismissal (no transient close/reopen flicker)
        popover.animates = true
        popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight)
        popover.contentViewController = makeContentController()

        refresh()   // reflect TRUE system state on launch (never a stale assumption)
        timer = Timer.scheduledTimer(timeInterval: pollInterval, target: self,
                                     selector: #selector(poll), userInfo: nil, repeats: true)
    }

    // MARK: - Popover content (native NSSwitch toggle, macOS-aligned)
    private func makeContentController() -> NSViewController {
        let W = popoverWidth, pad: CGFloat = 16
        let contentW = W - pad * 2
        let ci: CGFloat = 12                 // card inner padding
        let cw = contentW - ci * 2           // card inner content width

        // Standard system popover material: untinted, no forced emphasis, so it reads
        // as a first-party control (like the Wi-Fi / Sound / Battery popovers), not a
        // themed panel. NSPopover supplies its own corner, shadow, and arrow.
        let root = GlassView(frame: NSRect(x: 0, y: 0, width: W, height: popoverHeight))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState
        // Two pages share the popover: the settings list, and the repo picker. A nested
        // NSPopover would fight the parent for key-window status and break the search
        // field's typing, so the picker swaps in place instead.
        let page = FlippedView(frame: root.bounds)
        root.addSubview(page)
        settingsPage = page

        // Header: small coffee mark + "Sleepless" (quiet system glyph, not a branded logo).
        // The mark tints to the brand violet while the Mac is kept awake.
        let mark = NSImageView(frame: NSRect(x: pad, y: 14, width: 18, height: 18))
        let headerCup = makeCupGlyph(.on); headerCup.isTemplate = true
        mark.image = headerCup
        mark.contentTintColor = .labelColor
        page.addSubview(mark)
        headerMark = mark
        let title = makeLabel("Sleepless", font: .systemFont(ofSize: 14, weight: .semibold), color: .labelColor)
        title.frame = NSRect(x: pad + 24, y: 14, width: contentW - 24, height: 20)
        page.addSubview(title)

        // Grouped inset cards (System Settings rhythm) replace per-row hairline separators.
        func makeCard(_ rect: NSRect) -> CardView {
            let c = CardView(frame: rect)
            c.wantsLayer = true
            page.addSubview(c)
            return c
        }
        let swProto = NSSwitch().intrinsicContentSize
        let swW = swProto.width > 0 ? swProto.width : 38
        let swH = swProto.height > 0 ? swProto.height : 21

        // GROUP 1 — main switch + state caption
        let g1y: CGFloat = 46, g1h: CGFloat = 84
        let g1 = makeCard(NSRect(x: pad, y: g1y, width: contentW, height: g1h))
        mainCard = g1
        let rowLabel = makeLabel("Keep awake with lid closed", font: .systemFont(ofSize: 13), color: .labelColor)
        rowLabel.frame = NSRect(x: ci, y: ci, width: cw - swW - 8, height: 22)
        g1.addSubview(rowLabel)
        toggleSwitch = NSSwitch()
        toggleSwitch.target = self
        toggleSwitch.action = #selector(switchToggled(_:))
        toggleSwitch.frame = NSRect(x: contentW - ci - swW, y: ci + (22 - swH) / 2, width: swW, height: swH)
        g1.addSubview(toggleSwitch)
        captionLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        captionLabel.frame = NSRect(x: ci, y: ci + 30, width: cw, height: 32)
        captionLabel.usesSingleLineMode = false
        captionLabel.lineBreakMode = .byWordWrapping
        captionLabel.maximumNumberOfLines = 2
        captionLabel.cell?.wraps = true
        g1.addSubview(captionLabel)

        // GROUP 2 — auto-off timer (label + segmented [Off | 1h | 2h] + countdown)
        let g2y = g1y + g1h + 12, g2h: CGFloat = 78
        let g2 = makeCard(NSRect(x: pad, y: g2y, width: contentW, height: g2h))
        let timerLabel = makeLabel("Auto-off timer", font: .systemFont(ofSize: 13), color: .labelColor)
        timerLabel.frame = NSRect(x: ci, y: ci + 3, width: 110, height: 22)
        g2.addSubview(timerLabel)
        autoOffControl = NSSegmentedControl(labels: ["Off", "1h", "2h"],
                                            trackingMode: .selectOne,
                                            target: self, action: #selector(autoOffChanged(_:)))
        autoOffControl.selectedSegment = 0
        autoOffControl.controlSize = .regular
        autoOffControl.segmentStyle = .automatic
        autoOffControl.sizeToFit()
        let segSize = autoOffControl.frame.size
        let segW = segSize.width > 0 ? segSize.width : 150
        autoOffControl.frame = NSRect(x: contentW - ci - segW, y: ci, width: segW, height: max(segSize.height, 24))
        g2.addSubview(autoOffControl)
        countdownLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        countdownLabel.frame = NSRect(x: ci, y: ci + 36, width: cw, height: 16)
        g2.addSubview(countdownLabel)

        // GROUP 3 — battery-floor (label + value + slider + min/max hints)
        let g3y = g2y + g2h + 12, g3h: CGFloat = 92
        let g3 = makeCard(NSRect(x: pad, y: g3y, width: contentW, height: g3h))
        let floorLabel = makeLabel("Auto-off at low battery", font: .systemFont(ofSize: 13), color: .labelColor)
        floorLabel.frame = NSRect(x: ci, y: ci, width: cw - 54, height: 18)
        g3.addSubview(floorLabel)
        floorValueLabel = makeLabel("\(batteryFloorPercent)%", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
        floorValueLabel.alignment = .right
        floorValueLabel.frame = NSRect(x: contentW - ci - 54, y: ci, width: 54, height: 18)
        g3.addSubview(floorValueLabel)
        floorSlider = NSSlider(value: Double(batteryFloorPercent), minValue: Double(floorMin), maxValue: Double(floorMax),
                               target: self, action: #selector(floorSliderChanged(_:)))
        floorSlider.isContinuous = true          // live update while dragging
        floorSlider.controlSize = .regular
        floorSlider.frame = NSRect(x: ci, y: ci + 26, width: cw, height: 20)
        g3.addSubview(floorSlider)
        let minHint = makeLabel("\(floorMin)%", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
        minHint.frame = NSRect(x: ci, y: ci + 50, width: 34, height: 13)
        g3.addSubview(minHint)
        let maxHint = makeLabel("\(floorMax)%", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
        maxHint.alignment = .right
        maxHint.frame = NSRect(x: contentW - ci - 34, y: ci + 50, width: 34, height: 13)
        g3.addSubview(maxHint)

        // GROUP 4 — Claude Remote Control companion (ON by default), plus the repo its
        // sessions open in. Turning it off here terminates the server immediately.
        let g4y = g3y + g3h + 12, g4h: CGFloat = 100
        let g4 = makeCard(NSRect(x: pad, y: g4y, width: contentW, height: g4h))
        let rcLabel = makeLabel("Claude Remote Control", font: .systemFont(ofSize: 13), color: .labelColor)
        rcLabel.frame = NSRect(x: ci, y: ci, width: cw - swW - 8, height: 22)
        g4.addSubview(rcLabel)
        rcSwitch = NSSwitch()
        rcSwitch.target = self
        rcSwitch.action = #selector(rcToggled(_:))
        rcSwitch.state = rcEnabled ? .on : .off
        rcSwitch.frame = NSRect(x: contentW - ci - swW, y: ci + (22 - swH) / 2, width: swW, height: swH)
        g4.addSubview(rcSwitch)
        let repoLabel = makeLabel("Repository", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        repoLabel.frame = NSRect(x: ci, y: ci + 34, width: 74, height: 22)
        g4.addSubview(repoLabel)
        rcRepoButton = NSButton(title: rcRepo, target: self, action: #selector(chooseRepo))
        rcRepoButton.bezelStyle = .rounded
        rcRepoButton.controlSize = .small
        rcRepoButton.font = .systemFont(ofSize: 12)
        rcRepoButton.cell?.lineBreakMode = .byTruncatingMiddle
        rcRepoButton.frame = NSRect(x: ci + 78, y: ci + 32, width: cw - 78, height: 22)
        g4.addSubview(rcRepoButton)
        rcStatusLabel = makeLabel("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        rcStatusLabel.frame = NSRect(x: ci, y: ci + 62, width: cw, height: 26)
        rcStatusLabel.usesSingleLineMode = false
        rcStatusLabel.lineBreakMode = .byWordWrapping
        rcStatusLabel.maximumNumberOfLines = 2
        rcStatusLabel.cell?.wraps = true
        g4.addSubview(rcStatusLabel)

        // GROUP 5 — launch at login (off by default; never auto-enables sleep prevention)
        let g5y = g4y + g4h + 12, g5h: CGFloat = 46
        let g5 = makeCard(NSRect(x: pad, y: g5y, width: contentW, height: g5h))
        let loginLabel = makeLabel("Launch at login", font: .systemFont(ofSize: 13), color: .labelColor)
        loginLabel.frame = NSRect(x: ci, y: ci, width: cw - swW - 8, height: 22)
        g5.addSubview(loginLabel)
        loginSwitch = NSSwitch()
        loginSwitch.target = self
        loginSwitch.action = #selector(loginToggled(_:))
        loginSwitch.state = loginItemEnabled() ? .on : .off
        loginSwitch.frame = NSRect(x: contentW - ci - swW, y: ci + (22 - swH) / 2, width: swW, height: swH)
        g5.addSubview(loginSwitch)

        // Footer — Quit (separated by space, not a hairline)
        let quit = NSButton(title: "Quit Sleepless", target: self, action: #selector(quit))
        quit.controlSize = .regular
        quit.bezelStyle = .rounded
        quit.sizeToFit()
        let qs = quit.frame.size
        quit.frame = NSRect(x: W - pad - qs.width, y: g5y + g5h + 12, width: qs.width, height: qs.height)
        page.addSubview(quit)

        // PAGE 2 — repo picker. ~40 repos under ~/Projects is far too many for a menu, so
        // this is a search field over a plain list: type any substrings, all must match.
        let picker = FlippedView(frame: root.bounds)
        picker.isHidden = true
        let back = NSButton(title: "Back", target: self, action: #selector(cancelRepoPick))
        back.bezelStyle = .rounded
        back.controlSize = .small
        back.sizeToFit()
        back.frame = NSRect(x: pad, y: 14, width: max(back.frame.width, 62), height: 20)
        picker.addSubview(back)
        let pickTitle = makeLabel("Choose repository", font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        pickTitle.alignment = .right
        pickTitle.frame = NSRect(x: pad + 70, y: 14, width: contentW - 70, height: 20)
        picker.addSubview(pickTitle)
        repoSearchField = NSSearchField(frame: NSRect(x: pad, y: 44, width: contentW, height: 24))
        repoSearchField.placeholderString = "Filter repositories"
        repoSearchField.delegate = self
        repoSearchField.sendsSearchStringImmediately = true
        repoSearchField.sendsWholeSearchString = false
        picker.addSubview(repoSearchField)
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 22
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repo"))
        col.width = contentW - 12
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(repoRowClicked)
        repoTable = table
        let scroll = NSScrollView(frame: NSRect(x: pad, y: 78, width: contentW, height: popoverHeight - 78 - pad))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        picker.addSubview(scroll)
        root.addSubview(picker)
        pickerPage = picker

        let vc = NSViewController()
        vc.view = root
        return vc
    }

    private func makeLabel(_ s: String, font: NSFont, color: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font
        t.textColor = color
        t.isEditable = false
        t.isBordered = false
        t.drawsBackground = false
        return t
    }

    // MARK: - Click the menu-bar cup to open/close the popover
    @objc private func statusClicked() {
        if popover.isShown { closePopover() } else { openPopover() }
    }

    private func openPopover() {
        refresh()                              // sync switch/caption to TRUE state before showing
        loginSwitch?.state = loginItemEnabled() ? .on : .off
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        showPicker(false)                      // always reopen on the settings page
        startCountdownTicker()                 // drives both the auto-off countdown and the reconnect countdown
        updateCountdownLabel()
        renderRemoteControlUI()
        // Close when the user clicks anywhere outside the app (status bar, another app, desktop).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        countdownTicker?.invalidate(); countdownTicker = nil   // stop the 1 Hz label refresh (keep-awake timer keeps running)
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
    }

    @objc private func switchToggled(_ sender: NSSwitch) {
        if performToggle(wantOn: sender.state == .on) {
            sender.state = .off   // setup needed / failed: reflect reality (performToggle notified)
        }
    }

    // Core keep-awake toggle, decoupled from the UI sender. Returns true ONLY when the user
    // must act (the passwordless grant is missing and setup did not complete) so the caller can
    // reflect OFF. The decision to prompt is made on the REAL sudo result (see setDisableSleep),
    // never by re-reading SleepDisabled: a successful sudo means the command ran, even if a
    // safety net (Low Power Mode / battery floor) legitimately turns sleep back on afterwards —
    // which must NOT be mistaken for "permission missing" and trigger a password prompt. This
    // unobservable, state-proxy decision is what made earlier releases re-prompt spuriously.
    @discardableResult
    private func performToggle(wantOn: Bool) -> Bool {
        var result = setDisableSleep(wantOn)
        // Only a genuinely MISSING grant warrants the one-time native-auth setup. A successful
        // sudo (.ok) — or any other failure — never re-prompts here.
        if wantOn, result == .grantMissing {
            if installGrantViaAuth() { result = setDisableSleep(true) }
            if result != .ok {
                notify("Couldn't keep awake. The permission isn't set up yet.")
                return true
            }
        }
        // A deliberate, successful turn-on wins over the Low Power Mode auto-off (hard floor still wins).
        userForcedOn = wantOn && result == .ok
        refresh()                              // applies UI + safety nets; switch reflects reality
        if isOn, autoOffMinutes > 0 { startKeepAwakeTimer(minutes: autoOffMinutes) }
        return false
    }

    // Install the one-time scoped grant via a SINGLE native macOS authorization (the
    // standard Touch ID / password sheet) — no Terminal. Runs the bundled, audited
    // grant.sh as root through osascript's "with administrator privileges"; grant.sh is
    // root-aware so it writes the sudoers drop-in directly with no inner sudo prompt.
    // Returns true once the passwordless grant is in place; after that the app never asks again.
    @discardableResult
    private func installGrantViaAuth() -> Bool {
        let intro = NSAlert()
        intro.alertStyle = .informational
        intro.messageText = "Enable keeping your Mac awake"
        intro.informativeText = "Sleepless flips a protected macOS setting (pmset disablesleep), so it needs your permission once. macOS will ask you to authenticate (Touch ID or your password). After that the switch works instantly, with no more prompts."
        intro.addButton(withTitle: "Enable")
        intro.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        guard intro.runModal() == .alertFirstButtonReturn else { return false }

        guard let res = Bundle.main.resourcePath else { return false }
        let grant = res + "/grant.sh"
        // Pass the REAL user: under the native auth sheet grant.sh runs as root with
        // SUDO_USER unset, so without this the grant would be written for "root" (useless).
        let shellCmd = "SLEEPLESS_USER='\(NSUserName())' /bin/bash '\(grant)' --yes"
        // escape for an AppleScript string literal, then run with one native auth sheet
        let escaped = shellCmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let osa = "do shell script \"\(escaped)\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", osa]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() }
        catch { notify("Couldn't start the one-time setup."); return false }
        if proc.terminationStatus == 0 { return true }   // grant.sh installed the rule successfully
        if proc.terminationStatus != 128 {               // 128 = user cancelled the auth sheet
            notify("Setup didn't complete. Try again, or run grant.sh from the app bundle.")
        }
        return false
    }

    // A brief, subtle pulse on the menu-bar glyph whenever the state (and thus the cup
    // shape) changes, so the change is noticeable. Opacity-only: no layer geometry is
    // mutated, so it can't shift the status item on any macOS version.
    private func pulseStatusItem() {
        guard let b = statusItem.button else { return }
        b.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.3
        pulse.toValue = 1.0
        pulse.duration = 0.34
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        b.layer?.add(pulse, forKey: "statePulse")
    }

    @objc private func poll() { refresh() }

    // MARK: - Auto-off timer (Feature 1)
    @objc private func autoOffChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 1: autoOffMinutes = 60
        case 2: autoOffMinutes = 120
        default: autoOffMinutes = 0
        }
        if isOn, autoOffMinutes > 0 {
            startKeepAwakeTimer(minutes: autoOffMinutes)
        } else {
            cancelKeepAwakeTimer()
            updateCountdownLabel()
        }
    }

    private func startKeepAwakeTimer(minutes: Int) {
        cancelKeepAwakeTimer()
        guard minutes > 0, isOn else { updateCountdownLabel(); return }
        let seconds = TimeInterval(minutes * 60)
        timerEndDate = Date().addingTimeInterval(seconds)
        keepAwakeTimer = Timer.scheduledTimer(timeInterval: seconds, target: self,
                                              selector: #selector(keepAwakeTimerFired), userInfo: nil, repeats: false)
        if popover.isShown { startCountdownTicker() }
        updateCountdownLabel()
    }

    private func cancelKeepAwakeTimer() {
        keepAwakeTimer?.invalidate(); keepAwakeTimer = nil
        countdownTicker?.invalidate(); countdownTicker = nil
        timerEndDate = nil
    }

    @objc private func keepAwakeTimerFired() {
        setDisableSleep(false)
        cancelKeepAwakeTimer()
        autoOffMinutes = 0
        autoOffControl?.selectedSegment = 0
        applyUI(on: readSleepDisabled())
        notify("Auto-off timer ended. Sleepless turned off.")
    }

    private func startCountdownTicker() {
        countdownTicker?.invalidate()
        countdownTicker = Timer.scheduledTimer(timeInterval: 1, target: self,
                                               selector: #selector(countdownTick), userInfo: nil, repeats: true)
    }

    @objc private func countdownTick() {
        updateCountdownLabel()
        rcStatusLabel?.stringValue = remoteControlStatusText()
    }

    private func updateCountdownLabel() {
        guard let end = timerEndDate, isOn else { countdownLabel?.stringValue = ""; return }
        let remaining = Int(end.timeIntervalSinceNow.rounded())
        guard remaining > 0 else { countdownLabel?.stringValue = ""; return }
        let h = remaining / 3600, m = (remaining % 3600) / 60, s = remaining % 60
        let t = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        countdownLabel?.stringValue = "Auto-off in \(t)"
    }

    // MARK: - Launch at login (Feature 2) — OFF by default; never re-enables sleep prevention
    @objc private func loginToggled(_ sender: NSSwitch) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Sleepless: login item update failed: %@", error.localizedDescription)
            notify("Couldn't update Launch at login.")
        }
        sender.state = loginItemEnabled() ? .on : .off
    }

    private func loginItemEnabled() -> Bool { SMAppService.mainApp.status == .enabled }

    // MARK: - Claude Remote Control (Feature 4)
    // A supervised child process running `claude remote-control` in the chosen repo. It is a
    // preference, not an independent switch: the server runs only while the Mac is kept awake,
    // so closing the lid keeps remote sessions reachable and every existing auto-off path
    // (timer, battery floor, Low Power Mode, manual toggle) tears it down for free.
    @objc private func rcToggled(_ sender: NSSwitch) {
        rcEnabled = sender.state == .on
        UserDefaults.standard.set(rcEnabled, forKey: rcEnabledKey)
        rcMessage = ""
        rcAttempt = 0
        syncRemoteControl()
        renderRemoteControlUI()
    }

    private func syncRemoteControl() {
        if isOn && rcEnabled { startRemoteControl() } else { stopRemoteControl() }
    }

    private func startRemoteControl() {
        guard rcProcess == nil, rcRetryTimer == nil else { return }   // already up, or a retry is pending
        // A stopped server takes a few seconds to shut its sessions down. Starting the next one
        // before it is gone would run two at once, and truncate the log under the old one's writes.
        if let previous = rcStoppingProcess, previous.isRunning {
            scheduleRemoteControlRetry(after: 1)
            return
        }
        rcStoppingProcess = nil
        guard let claude = resolveClaudeBinary() else {
            failRemoteControl("Couldn\u{2019}t find the claude CLI.")
            return
        }
        let cwd = rcProjectsRoot.appendingPathComponent(rcRepo)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
            failRemoteControl("\(rcRepo) is no longer in ~/Projects.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["remote-control"]
        process.currentDirectoryURL = cwd     // sessions are created here, so the repo IS the setting
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = home
        env["ANTHROPIC_API_KEY"] = nil        // Remote Control requires the claude.ai login; an API key blocks it
        process.environment = env
        process.standardInput = FileHandle.nullDevice   // no TTY: server mode runs fine, it just can\u{2019}t show its QR code
        // A Pipe rather than the log file directly, so the TUI repaints are filtered out on the
        // way through instead of piling up on disk. The handler drains it, so the child never
        // blocks on a full 64 KB buffer.
        let log = RemoteControlLog(url: remoteControlLogURL())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else {          // EOF: the child is gone
                fh.readabilityHandler = nil
                log.finish()
                return
            }
            log.ingest(data)
        }
        rcLog = log
        // Fires off the main thread; the pid is all we carry back, which also identifies
        // WHICH process died (a deliberate stop clears rcProcess first, so its exit is ignored).
        process.terminationHandler = { [weak self] proc in
            let pid = proc.processIdentifier, status = proc.terminationStatus
            Task { @MainActor in self?.remoteControlDidExit(pid: pid, status: status) }
        }
        do { try process.run() }
        catch {
            NSLog("Sleepless: failed to launch claude remote-control: %@", error.localizedDescription)
            failRemoteControl("Couldn\u{2019}t start claude remote-control.")
            return
        }
        rcProcess = process
        rcStartedAt = Date()
        rcMessage = ""
        renderRemoteControlUI()
    }

    private func stopRemoteControl() {
        rcRetryTimer?.invalidate(); rcRetryTimer = nil
        rcRetryDeadline = nil
        rcAttempt = 0
        guard let process = rcProcess else { return }
        rcProcess = nil                      // cleared first: the termination handler now ignores this exit
        rcStartedAt = nil
        rcLog = nil                          // the pipe handler owns it now, and closes it at EOF
        rcStoppingProcess = process
        process.terminate()                  // SIGTERM; claude shuts down and takes its session children with it
        Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(rcForceKill(_:)),
                             userInfo: process, repeats: false)
        renderRemoteControlUI()
    }

    // Asks the Process rather than probing a raw pid, which may already belong to someone else.
    @objc private func rcForceKill(_ timer: Timer) {
        guard let process = timer.userInfo as? Process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    // Changing the repo mid-flight: drop the old server, then start in the new directory
    // once it has exited (startRemoteControl waits for it).
    private func restartRemoteControl() {
        guard rcProcess != nil || rcRetryTimer != nil else { return }
        stopRemoteControl()
        scheduleRemoteControlRetry(after: 2)
    }

    @MainActor
    private func remoteControlDidExit(pid: Int32, status: Int32) {
        guard let current = rcProcess, current.processIdentifier == pid else { return }
        let uptime = rcStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        rcProcess = nil
        rcStartedAt = nil
        rcLog?.flush()                       // fatalRemoteControlReason() reads the file, so finish writing it first
        rcLog = nil
        NSLog("Sleepless: claude remote-control exited (status %d) after %.0fs", status, uptime)
        guard isOn, rcEnabled else { renderRemoteControlUI(); return }
        // Only a run that died young can be a setup failure. A long run's log also holds the
        // session titles, and one that happens to say "not trusted" must not turn the switch off.
        if uptime < rcHealthyUptime, let reason = fatalRemoteControlReason() {
            failRemoteControl(reason)
            return
        }
        if uptime >= rcHealthyUptime { rcAttempt = 0 }   // a long healthy run earns a fresh retry budget
        guard rcAttempt < rcBackoffDelays.count else {
            failRemoteControl("Claude Remote Control kept stopping. Turned it off.")
            return
        }
        let delay = rcBackoffDelays[rcAttempt] * Double.random(in: 0.8...1.2)   // jitter
        rcAttempt += 1
        scheduleRemoteControlRetry(after: delay)
    }

    private func scheduleRemoteControlRetry(after delay: TimeInterval) {
        rcRetryTimer?.invalidate()
        rcRetryDeadline = Date().addingTimeInterval(delay)
        rcRetryTimer = Timer.scheduledTimer(timeInterval: delay, target: self,
                                            selector: #selector(rcRetryFired), userInfo: nil, repeats: false)
        renderRemoteControlUI()
    }

    @objc private func rcRetryFired() {
        rcRetryTimer = nil
        rcRetryDeadline = nil
        syncRemoteControl()
        renderRemoteControlUI()
    }

    // Retrying can\u{2019}t fix an untrusted workspace or a missing claude.ai login, and the CLI says
    // so on stderr. Reading the tail turns five silent retries into one actionable message.
    private func fatalRemoteControlReason() -> String? {
        guard let data = try? Data(contentsOf: remoteControlLogURL()) else { return nil }
        let tail = String(decoding: data.suffix(4096), as: UTF8.self)
        func mentions(_ s: String) -> Bool { tail.range(of: s, options: .caseInsensitive) != nil }
        if mentions("not trusted") { return "Run claude once in ~/Projects/\(rcRepo) to trust it." }
        if mentions("full-scope login") || mentions("authenticated") || mentions("auth login") {
            return "Claude Remote Control needs a claude.ai login (claude auth login)."
        }
        if mentions("Remote Control is not available") { return "Remote Control isn\u{2019}t enabled for this account." }
        return nil
    }

    // Give up: stop retrying and flip the switch off, so what the popover shows is what is
    // actually running. Flipping it back on is the retry.
    private func failRemoteControl(_ message: String) {
        rcRetryTimer?.invalidate(); rcRetryTimer = nil
        rcRetryDeadline = nil
        rcAttempt = 0
        rcEnabled = false
        UserDefaults.standard.set(false, forKey: rcEnabledKey)
        rcMessage = message
        renderRemoteControlUI()
        notify(message)
    }

    private func remoteControlStatusText() -> String {
        if !rcMessage.isEmpty { return rcMessage }
        if !rcEnabled { return "Off. Sleepless won\u{2019}t start a remote session." }
        if let end = rcRetryDeadline {
            let s = max(Int(end.timeIntervalSinceNow.rounded()), 1)
            guard rcAttempt > 0 else { return "Restarting in \(s)s\u{2026}" }   // repo change, not a failure
            return "Reconnecting in \(s)s (attempt \(rcAttempt) of \(rcBackoffDelays.count))."
        }
        if rcProcess != nil { return "Running. Start a session from the Claude app." }
        return isOn ? "Starting\u{2026}" : "Starts when you turn Sleepless on."
    }

    private func renderRemoteControlUI() {
        rcSwitch?.state = rcEnabled ? .on : .off
        rcRepoButton?.title = rcRepo
        rcStatusLabel?.stringValue = remoteControlStatusText()
    }

    // A GUI app inherits no shell PATH, so the CLI is found by probing where it installs.
    private func resolveClaudeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/usr/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func remoteControlLogURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Sleepless/remote-control.log")
    }

    // MARK: - Repo picker (page 2)
    @objc private func chooseRepo() {
        allRepos = scanRepos()
        repoSearchField.stringValue = ""
        filteredRepos = allRepos
        repoTable.reloadData()
        selectRepoRow(filteredRepos.firstIndex(of: rcRepo) ?? 0)
        showPicker(true)
        repoSearchField.window?.makeFirstResponder(repoSearchField)
    }

    @objc private func cancelRepoPick() { showPicker(false) }

    @objc private func repoRowClicked() { commitRepoSelection() }

    private func showPicker(_ show: Bool) {
        pickerPage?.isHidden = !show
        settingsPage?.isHidden = show
    }

    private func scanRepos() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: rcProjectsRoot.path) else { return [] }
        return entries
            .filter { !$0.hasPrefix(".") && fm.fileExists(atPath: rcProjectsRoot.appendingPathComponent($0)
                                                                                 .appendingPathComponent(".git").path) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func applyRepoFilter() {
        let tokens = repoSearchField.stringValue.split(separator: " ").map(String.init)
        filteredRepos = tokens.isEmpty ? allRepos : allRepos.filter { name in
            tokens.allSatisfy { name.range(of: $0, options: .caseInsensitive) != nil }
        }
        repoTable.reloadData()
        selectRepoRow(0)
    }

    private func selectRepoRow(_ index: Int) {
        guard !filteredRepos.isEmpty else { return }
        let i = min(max(index, 0), filteredRepos.count - 1)
        repoTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        repoTable.scrollRowToVisible(i)
    }

    private func commitRepoSelection() {
        let row = repoTable.selectedRow
        showPicker(false)
        guard row >= 0, row < filteredRepos.count else { return }
        let picked = filteredRepos[row]
        guard picked != rcRepo else { return }
        rcRepo = picked
        UserDefaults.standard.set(picked, forKey: rcRepoKey)
        rcMessage = ""
        renderRemoteControlUI()
        restartRemoteControl()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredRepos.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("repoCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let t = NSTextField(labelWithString: "")
            t.font = .systemFont(ofSize: 12)
            t.lineBreakMode = .byTruncatingMiddle
            t.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(t)
            c.textField = t
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = filteredRepos[row]
        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as AnyObject?) === repoSearchField else { return }
        applyRepoFilter()
    }

    // Arrow keys drive the list while the caret stays in the search field, so filtering and
    // choosing are one uninterrupted keystroke sequence.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === repoSearchField else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):        selectRepoRow(repoTable.selectedRow + 1); return true
        case #selector(NSResponder.moveUp(_:)):          selectRepoRow(repoTable.selectedRow - 1); return true
        case #selector(NSResponder.insertNewline(_:)):   commitRepoSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)): showPicker(false); return true
        default: return false
        }
    }

    // MARK: - Core state sync
    @objc private func refresh() {
        let on = readSleepDisabled()
        applyUI(on: on)
        if on { enforceSafetyNets() }
    }

    private func applyUI(on: Bool) {
        isOn = on
        if !on { cancelKeepAwakeTimer() }   // going OFF clears any countdown/timer
        // ARMED = kept awake while actively discharging on battery, so the
        // auto-off safety net is live. Distinct menu-bar glyph (cup + dot).
        var armed = false
        if on {
            let (onBattery, discharging, _) = batteryStatus()
            armed = onBattery && discharging
        }
        if let button = statusItem.button {
            let newImage = on ? (armed ? armedGlyph : onGlyph) : offGlyph
            if button.image !== newImage {   // state (cup shape) changed -> swap + pulse
                button.image = newImage
                pulseStatusItem()
            }
            button.toolTip = on
                ? (armed
                    ? "Sleepless: on (battery). Auto-off at \(batteryFloorPercent)% or in Low Power Mode."
                    : "Sleepless: on. Stays awake with the lid closed.")
                : "Sleepless: off. Sleeps normally."
        }
        toggleSwitch?.state = on ? .on : .off
        // Brand-violet accent communicates the privileged "awake" state at a glance.
        mainCard?.active = on
        headerMark?.contentTintColor = on ? brandAccentSoft : .labelColor
        renderText()
        updateCountdownLabel()
        syncRemoteControl()
        renderRemoteControlUI()
    }

    // Update text labels only (no pmset subprocess; safe to call on every slider tick).
    private func renderText() {
        floorValueLabel?.stringValue = "\(batteryFloorPercent)%"
        captionLabel?.stringValue = isOn
            ? "Stays awake when the lid is closed. Turns off at \(batteryFloorPercent)% battery or in Low Power Mode."
            : "Sleeps normally when you close the lid."
    }

    @objc private func floorSliderChanged(_ sender: NSSlider) {
        let v = min(max(Int(sender.doubleValue.rounded()), floorMin), floorMax)
        if v != batteryFloorPercent {
            batteryFloorPercent = v
            UserDefaults.standard.set(v, forKey: floorKey)
        }
        renderText()
    }

    // Result of the privileged keep-awake toggle, based on sudo's REAL exit status — not on a
    // second, independent state read. `.ok` = the command ran; `.grantMissing` = the passwordless
    // sudoers grant isn't installed (sudo -n refused), the one case that warrants setup; `.failed`
    // = any other error. Using sudo's own result (instead of re-reading SleepDisabled) is the fix:
    // a safety net flipping sleep back on must never look like "permission missing" and re-prompt.
    private enum ToggleResult: Equatable { case ok, grantMissing, failed(String) }

    @discardableResult
    private func setDisableSleep(_ on: Bool) -> ToggleResult {
        // sudo -n: never prompt (GUI app has no TTY). The exact argument vector matches the
        // NOPASSWD sudoers grant, so this runs without a password.
        let (exit, _, err) = runPrivileged(["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
        let result: ToggleResult
        if exit == 0 {
            result = .ok
        } else if err.range(of: "a password is required", options: .caseInsensitive) != nil
               || err.range(of: "not allowed", options: .caseInsensitive) != nil
               || err.range(of: "may not run", options: .caseInsensitive) != nil {
            result = .grantMissing   // grant absent/removed -> sudo -n refused to run passwordless
        } else {
            result = .failed(err.isEmpty ? "exit \(exit)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    // Run a privileged command via sudo, capturing exit status + stderr (which the generic
    // runCapture discards). stdin is /dev/null so a GUI process with no controlling TTY can
    // never block on a prompt. This is what lets the app KNOW whether its own toggle worked.
    private func runPrivileged(_ args: [String]) -> (exit: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() }
        catch {
            NSLog("Sleepless: failed to launch sudo: %@", error.localizedDescription)
            return (-1, "", "launch failed: \(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }

    // MARK: - Battery + Low-Power-Mode safety nets (silent; no extra UI) — Feature 3
    private func enforceSafetyNets() {
        let (onBattery, discharging, percent) = batteryStatus()
        guard onBattery, discharging else { return }
        // Hard battery floor ALWAYS wins, even over a deliberate turn-on: never drain to empty.
        if percent <= batteryFloorPercent {
            setDisableSleep(false); userForcedOn = false
            applyUI(on: readSleepDisabled())
            notify("Battery low (\(percent)%). Sleepless turned off.")
            return
        }
        // Low Power Mode auto-off, UNLESS the user deliberately chose to keep awake this session.
        if ProcessInfo.processInfo.isLowPowerModeEnabled && !userForcedOn {
            setDisableSleep(false)
            applyUI(on: readSleepDisabled())
            notify("Low Power Mode on. Sleepless turned off.")
        }
    }

    // MARK: - Readers (no root needed)
    private func readSleepDisabled() -> Bool {
        let out = runCapture("/usr/bin/pmset", ["-g"])
        for line in out.split(whereSeparator: { $0 == "\n" }) {
            if line.range(of: "SleepDisabled", options: .caseInsensitive) != nil {
                let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if let last = toks.last { return last == "1" }
            }
        }
        return false   // line absent -> OFF
    }

    private func batteryStatus() -> (onBattery: Bool, discharging: Bool, percent: Int) {
        let out = runCapture("/usr/bin/pmset", ["-g", "batt"])
        let onBattery = out.contains("Battery Power")
        let discharging = out.range(of: "discharging", options: .caseInsensitive) != nil
        var percent = 100
        for tok in out.split(whereSeparator: { " \t\n;".contains($0) }) {
            if tok.hasSuffix("%"), let v = Int(tok.dropLast()) { percent = v; break }
        }
        return (onBattery, discharging, percent)
    }

    // MARK: - Notification (mirrors Nexus' osascript approach)
    private func notify(_ message: String) {
        // Passed as an argument, never spliced into the script: messages carry repo folder names.
        _ = runCapture("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "display notification (item 1 of argv) with title \"Sleepless\" sound name \"Tink\"",
            "-e", "end run",
            message,
        ])
    }

    // MARK: - Process runner (explicit PATH/HOME; captures stdout)
    @discardableResult
    private func runCapture(_ launchPath: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() }
        catch { NSLog("Sleepless: failed to launch %@: %@", launchPath, error.localizedDescription); return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        stopRemoteControl()   // never leave an orphaned remote-control server behind
    }
}

@main
enum SleeplessApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        objc_setAssociatedObject(app, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}

nonisolated(unsafe) private var delegateKey = 0
