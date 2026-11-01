import AppKit
import ApplicationServices
import Darwin
import CryptoKit

struct GestureSettings: Codable {
    var enabled = true
    var inverted = true
    var sensitivity = 0.7
    var zoomSpeed: Double? = nil
    var effectiveZoomSpeed: Double { min(8, max(0.5, zoomSpeed ?? 3)) }
}

// No global keyboard tap: receive only mouse/scroll/modifier events destined
// for the single validated game PID. Never record input events or text.
final class TrackpadController: NSObject, NSApplicationDelegate {
    let pid: Int32
    let root = (ProcessInfo.processInfo.environment["NNG_STATE_ROOT"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NNG Mac Community")).appendingPathComponent("compat")
    var settings = GestureSettings()
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var permissionTimer: Timer?
    var releaseTimer: Timer?
    var gameExit: DispatchSourceProcess?
    var activationObserver: NSObjectProtocol?
    var reportPending = false
    var holding = false
    var window: NSWindow!
    var instructions = NSTextField(wrappingLabelWithString: "")
    var status = NSTextField(wrappingLabelWithString: "")
    var enabled: NSButton!
    var inverted: NSButton!
    var zoomSlider: NSSlider!
    var zoomLabel = NSTextField(labelWithString: "")
    var lastStatus = ""
    var lastReport = 0.0
    var cameraEvents = 0
    var zoomEvents = 0
    var receivedScrolls = 0
    var commandScrolls = 0
    var eventCommandScrolls = 0
    var hidCommandScrolls = 0
    var termination: DispatchSourceSignal?
    var lockFD: Int32 = -1
    var bridge: Process?
    var bridgeInput: FileHandle?
    var bridgeOutput: FileHandle?
    var bridgeReady = false
    var bridgeFocused = false
    var bridgeRequests: [Int:Double] = [:]
    var bridgeSequence = 0
    var bridgePending: Int { bridgeRequests.count }
    var bridgeLastReply = 0.0
    var bridgeError = ""
    var bridgeInjected = 0
    var bridgeWindowsPID = 0
    var bridgeRightDown = false
    var bridgeBuffer = Data()
    var bridgeFocusPending = false
    var zoomRemainder = 0.0
    var cameraRemainderX = 0.0
    var cameraRemainderY = 0.0
    let bridgeQueue = DispatchQueue(label: "ru.nng.mouse-pipe", qos: .userInteractive)

    init(pid: Int32) { self.pid = pid; super.init() }

    static func shouldShowOnLaunch(_ arguments: [String]) -> Bool { arguments.contains("--show") }
    // Quartz carries both the generic Command flag and left/right device bits.
    // Wine reconstructs the generic modifier from those device bits, so the
    // reserved gesture modifier must be removed in all three representations.
    static let commandMask = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08 | 0x10)
    static func commandInFlags(_ flags: CGEventFlags) -> Bool { !flags.intersection(commandMask).isEmpty }
    static func commandForGesture(event: CGEventFlags, hid: CGEventFlags) -> Bool {
        commandInFlags(event) || commandInFlags(hid)
    }
    static func gameFlags(_ flags: CGEventFlags, type: CGEventType = .scrollWheel) -> CGEventFlags {
        // Only the scroll gesture and its modifier transition are reserved.
        // Keyboard events are not tapped; native Command shortcuts retain flags.
        guard type == .scrollWheel || type == .flagsChanged else { return flags }
        return flags.subtracting(commandMask)
    }
    static func cameraMode(modifier: Bool, inverted: Bool) -> Bool { modifier != inverted }
    static func canIntercept(ready: Bool, focused: Bool, pending: Int, age: Double) -> Bool {
        ready && focused && pending < 12 && age < 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        lockFD = Darwin.open(root.appendingPathComponent(".trackpad.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { NSApp.terminate(nil); return }
        if let d = try? Data(contentsOf: root.appendingPathComponent("trackpad-settings.json")),
           let value = try? JSONDecoder().decode(GestureSettings.self, from: d) { settings = value }
        settings.sensitivity = min(2, max(0.2, settings.sensitivity))
        makeWindow()
        // The kernel reports process exit; workspace notifications report focus.
        gameExit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        gameExit?.setEventHandler { NSApp.terminate(nil) }; gameExit?.resume()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tick()
        }
        signal(SIGPIPE, SIG_IGN)
        startBridge()
        signal(SIGTERM, SIG_IGN)
        termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination?.setEventHandler { NSApp.terminate(nil) }; termination?.resume()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showWindow), name: Notification.Name("ru.nng.community.trackpad.show"), object: nil, suspensionBehavior: .deliverImmediately)
        tick()
        if Self.shouldShowOnLaunch(CommandLine.arguments) { showWindow() }
    }

    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled,.closable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "Тачпад NNG Mac"; window.isReleasedWhenClosed = false; window.center()
        let content = NSView(); window.contentView = content
        let title = NSTextField(labelWithString: "Камера без удержания клика")
        title.font = .boldSystemFont(ofSize: 20)
        let help = instructions
        updateInstructions()
        enabled = NSButton(checkboxWithTitle: "Включить управление тачпадом", target: self, action: #selector(changeSettings))
        enabled.state = settings.enabled ? .on : .off
        inverted = NSButton(checkboxWithTitle: "Наоборот: два пальца — камера, ⌘ — зум", target: self, action: #selector(changeSettings))
        inverted.state = settings.inverted ? .on : .off
        zoomSlider = NSSlider(value:settings.effectiveZoomSpeed,minValue:0.5,maxValue:8,target:self,action:#selector(changeSettings))
        zoomSlider.numberOfTickMarks = 16; zoomSlider.allowsTickMarkValuesOnly = true
        zoomSlider.setAccessibilityLabel("Скорость зума")
        updateZoomLabel()
        let permission = NSButton(title: "Разрешить управление в macOS…", target: self, action: #selector(requestPermission))
        permission.bezelStyle = .rounded
        let views: [NSView] = [title, help, enabled, inverted, zoomLabel, zoomSlider, status, permission]
        for v in views { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), title.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            help.leadingAnchor.constraint(equalTo: title.leadingAnchor), help.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14), help.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            enabled.leadingAnchor.constraint(equalTo: title.leadingAnchor), enabled.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 18),
            inverted.leadingAnchor.constraint(equalTo: title.leadingAnchor), inverted.topAnchor.constraint(equalTo: enabled.bottomAnchor, constant: 10),
            zoomLabel.leadingAnchor.constraint(equalTo:title.leadingAnchor), zoomLabel.topAnchor.constraint(equalTo:inverted.bottomAnchor,constant:14),
            zoomSlider.leadingAnchor.constraint(equalTo:title.leadingAnchor), zoomSlider.trailingAnchor.constraint(equalTo:help.trailingAnchor), zoomSlider.topAnchor.constraint(equalTo:zoomLabel.bottomAnchor,constant:4),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor), status.topAnchor.constraint(equalTo: zoomSlider.bottomAnchor, constant: 12), status.trailingAnchor.constraint(equalTo: help.trailingAnchor),
            permission.leadingAnchor.constraint(equalTo: title.leadingAnchor), permission.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Only the launcher settings command may show this accessory window.
        return false
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate() }
    @objc func requestPermission() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    @objc func changeSettings() {
        releaseCamera()
        settings.enabled = enabled.state == .on
        settings.inverted = inverted.state == .on
        settings.zoomSpeed = zoomSlider.doubleValue
        zoomRemainder = 0
        updateZoomLabel()
        updateInstructions()
        if let bytes = try? JSONEncoder().encode(settings) { try? bytes.write(to: root.appendingPathComponent("trackpad-settings.json"), options: .atomic) }
        tick()
    }
    func updateZoomLabel() { zoomLabel.stringValue = String(format:"Скорость зума: %.1f×",settings.effectiveZoomSpeed) }
    func updateInstructions() {
        instructions.stringValue = settings.inverted
            ? "Два пальца БЕЗ клика — поворот камеры.\n⌘ Command + два пальца — зум.\nОбычное движение указателя остаётся обычным.\nРаботает только в активной Lineage II."
            : "Два пальца — зум.\n⌘ Command + два пальца — поворот камеры без клика.\nРаботает только в активной Lineage II."
    }

    func gameActive() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    // The Windows process has no window, sockets or keyboard hooks. Its stdin
    // is owned by this helper; closing it releases RMB and exits the process.
    func fastRuntimePins() -> [String:String]? {
        let sessionURL = root.appendingPathComponent("game-session.json")
        guard let data = try? Data(contentsOf:sessionURL),
              let session = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              (session["pid"] as? NSNumber)?.int32Value == pid, session["accelerated"] as? Bool == true else { return nil }
        let mainApp = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let manifest = try? Data(contentsOf:mainApp.appendingPathComponent("Contents/Resources/acceleration/runtime.json")),
              let json = try? JSONSerialization.jsonObject(with:manifest) as? [String:Any],
              json["version"] as? Int == 1, let pins = json["files"] as? [String:String] else { return nil }
        for name in ["wine/bin/wine","x87sidecar"] {
            guard let expected = pins[name], let bytes = try? Data(contentsOf:root.appendingPathComponent("cx26-x87/" + name)),
                  SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined() == expected else { return nil }
        }
        return pins
    }

    func startBridge() {
        let assets = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/input-bridge")
        let executable = assets.appendingPathComponent("nng-input.exe")
        guard let pin = try? String(contentsOf: assets.appendingPathComponent("sha256"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let bytes = try? Data(contentsOf: executable),
              SHA256.hash(data: bytes).map({ String(format:"%02x",$0) }).joined() == pin else {
            bridgeError = "input_asset_integrity"; return
        }
        let p = Process(), input = Pipe(), output = Pipe()
        p.executableURL = root.appendingPathComponent("cx23/wswine.bundle/bin/wine")
        p.arguments = [executable.path]
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = root.appendingPathComponent("prefix-cx23-macbin").path
        env["WINEDEBUG"] = "-all"
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="
        env["DYLD_FALLBACK_LIBRARY_PATH"] = root.appendingPathComponent("template/Template-1.0.24.app/Contents/Frameworks").path + ":/usr/lib"
        if fastRuntimePins() != nil {
            p.executableURL = root.appendingPathComponent("cx26-x87/wine/bin/wine")
            env["WINEPREFIX"] = root.appendingPathComponent("prefix-cx26-x87").path
            env["ROSETTA_X87_PATH"] = root.appendingPathComponent("cx26-x87/x87sidecar").path
            env["WINEMSYNC"] = "1"
            for key in ["DYLD_INSERT_LIBRARIES","DYLD_FALLBACK_LIBRARY_PATH","WINELOADERNOEXEC","X87_SAMPLE","X87_LOGS","X87_DISABLE_HOOK"] { env.removeValue(forKey:key) }
        } else if let data = try? Data(contentsOf:root.appendingPathComponent("game-session.json")),
                  let json = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  (json["pid"] as? NSNumber)?.int32Value == pid, json["accelerated"] as? Bool == true {
            bridgeError = "fast_runtime_integrity"; return
        }
        p.environment = env
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        bridgeInput = input.fileHandleForWriting; bridgeOutput = output.fileHandleForReading
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { self?.receiveBridge(data) }
        }
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.bridgeStopped("input_bridge_exited") } }
        do { try p.run(); bridge = p }
        catch { bridgeStopped("input_bridge_launch_failed") }
    }
    func bridgeStopped(_ reason: String) {
        bridgeReady = false; bridgeFocused = false; bridgeFocusPending = false
        bridgeRequests.removeAll(); holding = false; bridgeRightDown = false
        bridgeError = reason
        releaseTimer?.invalidate(); releaseTimer = nil
        try? bridgeInput?.close(); bridgeInput = nil
        scheduleReport()
    }
    @discardableResult func sendBridge(_ message: [String:Any]) -> Bool {
        guard let handle = bridgeInput, bridge?.isRunning == true, bridgePending < 16 else { return false }
        bridgeSequence += 1
        var framed = message; framed["seq"] = bridgeSequence
        guard let data = try? JSONSerialization.data(withJSONObject:framed) else { return false }
        bridgeRequests[bridgeSequence] = ProcessInfo.processInfo.systemUptime
        bridgeQueue.async { [weak self] in
            do { try handle.write(contentsOf: data + Data([10])) }
            catch { DispatchQueue.main.async { self?.bridgeStopped("input_pipe_failed") } }
        }
        return true
    }
    func requestBridgeFocus() {
        guard bridgeReady, gameActive(), !bridgeFocusPending else { return }
        bridgeFocusPending = sendBridge(["type":"focus"])
    }
    func receiveBridge(_ data: Data) {
        guard !data.isEmpty else { bridgeStopped("input_pipe_closed"); return }
        bridgeBuffer.append(data)
        guard bridgeBuffer.count < 65536 else { bridgeStopped("input_protocol_overflow"); return }
        while let newline = bridgeBuffer.firstIndex(of:10) {
            let line = bridgeBuffer.prefix(upTo:newline); bridgeBuffer.removeSubrange(...newline)
            guard let info = (try? JSONSerialization.jsonObject(with:Data(line))) as? [String:Any] else { continue }
            bridgeLastReply = ProcessInfo.processInfo.systemUptime
            if info["ready"] as? Bool == true {
                bridgeReady = true; bridgeError = ""; requestBridgeFocus()
            }
            if let seq = info["seq"] as? Int { bridgeRequests.removeValue(forKey:seq) }
            if let focused = info["focused"] as? Bool { bridgeFocused = focused && gameActive(); bridgeFocusPending = false }
            if let count = info["injected_inputs"] as? Int { bridgeInjected = count }
            if let windowsPID = info["windows_pid"] as? Int { bridgeWindowsPID = windowsPID }
            if let down = info["right_button_down"] as? Bool { bridgeRightDown = down }
            if info["released"] as? Bool == true { bridgeRightDown = false }
            if let error = info["error"] as? String {
                bridgeError = error
                if error != "physical_right_button_held" { bridgeFocused = false }
            }
            scheduleReport()
        }
    }
    func releaseCamera() {
        if holding { _ = sendBridge(["type":"release"]) }
        holding = false
        releaseTimer?.invalidate(); releaseTimer = nil
    }

    func installTap() {
        let types: [CGEventType] = [.scrollWheel,.flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<TrackpadController>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        tap = CGEvent.tapCreateForPid(pid: pid, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: callback,
                                     userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            releaseCamera(); if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard settings.enabled, gameActive() else { releaseCamera(); return Unmanaged.passUnretained(event) }
        // Command is reserved for the selected gesture even while the bridge
        // starts or recovers. A readiness-dependent filter can forward Alt-down
        // but strip Alt-up, leaving Wine's modifier state stuck.
        // The event snapshot remains authoritative when a global HID query
        // misses the modifier or runs after its release. Read it BEFORE the
        // Wine-facing copy is stripped; retain HID as a fallback for its taps.
        let originalFlags = event.flags
        let hidFlags = CGEventSource.flagsState(.hidSystemState)
        let modifier = Self.commandForGesture(event:originalFlags,hid:hidFlags)
        event.flags = Self.gameFlags(originalFlags,type:type)
        if type == .flagsChanged {
            releaseCamera(); zoomRemainder = 0
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        let now = ProcessInfo.processInfo.systemUptime
        // An absent, blocked or stale bridge must NEVER eat ordinary zoom.
        guard Self.canIntercept(ready:bridgeReady, focused:bridgeFocused, pending:bridgePending, age:bridgeRequests.values.min().map { now - $0 } ?? 0) else {
            requestBridgeFocus(); return Unmanaged.passUnretained(event)
        }
        receivedScrolls += 1
        if modifier { commandScrolls += 1 }
        if Self.commandInFlags(originalFlags) { eventCommandScrolls += 1 }
        if Self.commandInFlags(hidFlags) { hidCommandScrolls += 1 }
        scheduleReport()
        if event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return nil }
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        if !Self.cameraMode(modifier:modifier,inverted:settings.inverted) {
            releaseCamera()
            zoomRemainder += dy
            let pointsPerNotch = 18 / settings.effectiveZoomSpeed
            let notches = max(-2,min(2,Int(zoomRemainder / pointsPerNotch)))
            if notches != 0 {
                guard sendBridge(["type":"zoom","Wheel":notches]) else { return Unmanaged.passUnretained(event) }
                zoomRemainder -= Double(notches)*pointsPerNotch; zoomEvents += 1
            }
            return nil
        }
        zoomRemainder = 0
        cameraRemainderX += max(-60,min(60,dx*settings.sensitivity))
        cameraRemainderY += max(-60,min(60,dy*settings.sensitivity))
        let x = max(-60,min(60,Int(cameraRemainderX))), y = max(-60,min(60,Int(cameraRemainderY)))
        if x == 0 && y == 0 { return nil }
        guard sendBridge(["type":"camera","X":x,"Y":y]) else { return Unmanaged.passUnretained(event) }
        cameraRemainderX -= Double(x); cameraRemainderY -= Double(y)
        holding = true; cameraEvents += 1
        if let releaseTimer { releaseTimer.fireDate = Date(timeIntervalSinceNow:0.14) }
        else { releaseTimer = Timer.scheduledTimer(withTimeInterval:0.14,repeats:false) { [weak self] _ in self?.releaseCamera() } }
        return nil
    }

    func scheduleReport() {
        guard !reportPending else { return }
        reportPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }; self.reportPending = false; self.tick(forceReport: true)
        }
    }
    func tick(forceReport: Bool = false) {
        guard kill(pid, 0) == 0 else { NSApp.terminate(nil); return }
        if !gameActive() {
            releaseCamera(); bridgeFocused = false; bridgeFocusPending = false
        } else if !bridgeFocused { requestBridgeFocus() }
        let trusted = AXIsProcessTrusted()
        // Only while waiting for the owner to grant permission. No idle timer
        // remains after access is granted, nor after the game exits.
        if !trusted && permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
            permissionTimer?.tolerance = 1
        } else if trusted { permissionTimer?.invalidate(); permissionTimer = nil }
        if trusted && tap == nil { installTap() }
        let message = !trusted ? "Нужно разрешение «Универсальный доступ» для NNG Mac."
            : tap == nil ? "macOS не разрешила обработку событий окна игры."
            : !settings.enabled ? "Управление выключено."
            : !bridgeReady ? "Мост ввода недоступен; обычный зум сохранён. " + bridgeError
            : gameActive() && !bridgeFocused ? "Ожидание окна Lineage II; обычный зум сохранён."
            : gameActive() ? "Работает в окне Lineage II." : "Готово. Переключись в окно Lineage II."
        status.stringValue = message
        if message != lastStatus || forceReport {
            lastStatus = message
            lastReport = ProcessInfo.processInfo.systemUptime
            let info: [String:Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "game_pid": pid, "trusted": trusted, "tap_active": tap != nil, "status": message, "inverted": settings.inverted, "zoom_speed":settings.effectiveZoomSpeed, "camera_events": cameraEvents, "zoom_events": zoomEvents, "received_scrolls": receivedScrolls, "command_scrolls": commandScrolls, "event_command_scrolls": eventCommandScrolls, "hid_command_scrolls": hidCommandScrolls, "gesture_modifier":"command", "event_tap_scope": "game_pid_only", "bridge_ready":bridgeReady, "bridge_focused":bridgeFocused, "bridge_pending":bridgePending, "bridge_error":bridgeError, "windows_inputs":bridgeInjected, "windows_pid":bridgeWindowsPID, "windows_right_button_down":bridgeRightDown, "input_backend":"wine_SendInput_pipe"]
            if let data = try? JSONSerialization.data(withJSONObject: info, options: .prettyPrinted) { try? data.write(to: root.appendingPathComponent("trackpad-status.json"), options: .atomic) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        releaseCamera()
        bridgeQueue.sync { try? bridgeInput?.close() }; bridgeInput = nil
        bridgeOutput?.readabilityHandler = nil
        permissionTimer?.invalidate(); gameExit?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let tap { CFMachPortInvalidate(tap) }
        if lockFD >= 0 { Darwin.close(lockFD) }
    }
}

if CommandLine.arguments.contains("--self-test") {
    precondition(!TrackpadController.shouldShowOnLaunch(["nng-trackpad","--game-pid","123"]))
    precondition(TrackpadController.shouldShowOnLaunch(["nng-trackpad","--show"]))
    precondition(TrackpadController.gameFlags([.maskCommand,.maskShift]) == [.maskShift])
    precondition(TrackpadController.gameFlags([]).isEmpty)
    // Exact flags from the owner's failing gesture: left Command, not Option.
    precondition(TrackpadController.commandForGesture(event:CGEventFlags(rawValue:0x100008),hid:[]))
    for flags in [CGEventFlags.maskCommand, CGEventFlags(rawValue:0x08), CGEventFlags(rawValue:0x10), TrackpadController.commandMask] {
        precondition(TrackpadController.commandForGesture(event:flags,hid:[]))
        precondition(TrackpadController.commandForGesture(event:[],hid:flags))
        precondition(TrackpadController.gameFlags(flags).isEmpty)
    }
    precondition(!TrackpadController.commandForGesture(event:[.maskShift],hid:[.maskAlternate]))
    precondition(TrackpadController.gameFlags([TrackpadController.commandMask,.maskShift,.maskAlternate]) == [.maskShift,.maskAlternate])
    // The PID tap never subscribes to keyDown/up. Retain Command for shortcuts.
    precondition(TrackpadController.gameFlags([.maskCommand],type:.keyDown) == [.maskCommand])
    precondition(TrackpadController.gameFlags([.maskCommand],type:.keyUp) == [.maskCommand])
    precondition(!TrackpadController.cameraMode(modifier: false, inverted: false))
    precondition(TrackpadController.cameraMode(modifier: true, inverted: false))
    precondition(TrackpadController.cameraMode(modifier: false, inverted: true))
    precondition(!TrackpadController.cameraMode(modifier: true, inverted: true))
    let legacy = try JSONDecoder().decode(GestureSettings.self,from:Data("{\"sensitivity\":0.7,\"enabled\":true,\"inverted\":true}".utf8))
    precondition(legacy.inverted && legacy.sensitivity == 0.7 && legacy.effectiveZoomSpeed == 3)
    // Regression: missing/stale Windows bridge must leave scroll available.
    precondition(TrackpadController.canIntercept(ready:true,focused:true,pending:0,age:0.1))
    precondition(!TrackpadController.canIntercept(ready:false,focused:true,pending:0,age:0.1))
    precondition(!TrackpadController.canIntercept(ready:true,focused:false,pending:0,age:0.1))
    precondition(!TrackpadController.canIntercept(ready:true,focused:true,pending:12,age:0.1))
    precondition(!TrackpadController.canIntercept(ready:true,focused:true,pending:0,age:2))
    let controller = TrackpadController(pid:getpid())
    controller.receiveBridge(Data("{\"ready\":tr".utf8))
    precondition(!controller.bridgeReady)
    controller.receiveBridge(Data("ue,\"windows_pid\":568}\n{\"injected_inputs\":42}\n".utf8))
    precondition(controller.bridgeReady && controller.bridgeWindowsPID == 568 && controller.bridgeInjected == 42)
    controller.receiveBridge(Data())
    precondition(!controller.bridgeReady && !controller.bridgeFocused)
    print("PASS: explicit-only settings window; Command filtering independent of bridge readiness; camera/zoom inversion; fragmented and batched protocol lines; EOF/stale/backlog fail open; no input posted")
    exit(0)
}
guard let index = CommandLine.arguments.firstIndex(of: "--game-pid"), index + 1 < CommandLine.arguments.count,
      let pid = Int32(CommandLine.arguments[index+1]), pid > 1 else { exit(2) }
var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
let result = proc_pidpath(pid, &path, UInt32(path.count))
let inspect = Process(); let output = Pipe()
inspect.executableURL = URL(fileURLWithPath: "/bin/ps"); inspect.arguments = ["-p",String(pid),"-o","comm="]
inspect.standardOutput = output
try inspect.run()
let command = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
inspect.waitUntilExit()
if CommandLine.arguments.contains("--diagnose-pid") {
    print("proc_pidpath=\(result) \(String(cString: path)); comm=\(command)"); exit(0)
}
// Rosetta can report its generic wine64-preloader as the kernel executable.
// Wine's per-process comm retains the actual Windows program wrapper path.
let executable = command
guard inspect.terminationStatus == 0 else { exit(2) }
let stateRoot = (ProcessInfo.processInfo.environment["NNG_STATE_ROOT"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NNG Mac Community")).appendingPathComponent("compat")
let receipt = (try? Data(contentsOf:stateRoot.appendingPathComponent("game-session.json"))).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
let expectedHost = stateRoot.appendingPathComponent("cx26-x87/wine/lib/wine/x86_64-unix/wine").resolvingSymlinksInPath().path
let fastGame = (receipt?["pid"] as? NSNumber)?.int32Value == pid && receipt?["accelerated"] as? Bool == true && result > 0 && URL(fileURLWithPath:String(cString:path)).resolvingSymlinksInPath().path == expectedHost
let legacyGame = (executable.hasPrefix("/var/folders/") || executable.hasPrefix("/private/var/folders/")) && (executable.lowercased().hasSuffix("/l2.exe") || executable.lowercased().hasSuffix("/l2.bin"))
guard fastGame || legacyGame else { exit(2) }
let app = NSApplication.shared
let delegate = TrackpadController(pid: pid)
app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
