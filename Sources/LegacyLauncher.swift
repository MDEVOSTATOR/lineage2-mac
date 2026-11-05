import AppKit
import CryptoKit
import Darwin

func launcherRoot() -> URL {
    if let path=ProcessInfo.processInfo.environment["NNG_STATE_ROOT"],path.hasPrefix("/") {return URL(fileURLWithPath:path)}
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NNG Mac")
}

struct RuntimePin: Decodable {
    let name: String
    let sha256: String
    let size: Int64
}
struct CachedFile: Decodable { let size: Int64; let sha: String }
struct ModulePin: Decodable { let size: Int64; let sha256: String }
struct ProfileFile: Decodable { let base_sha256: String; let sha256: String }
struct ClientProfile: Decodable { let version: Int; let files: [String:ProfileFile] }

func clientProfile() throws -> ClientProfile? {
    let url = Bundle.main.resourceURL!.appendingPathComponent("client-profile/profile.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let profile = try JSONDecoder().decode(ClientProfile.self, from: Data(contentsOf: url))
    guard profile.version == 1, Set(profile.files.keys) == Set(["L2.ini", "User.ini"]) else { throw NSError(domain: "NNGProfile", code: 1) }
    for (name, pin) in profile.files {
        guard try digest(url.deletingLastPathComponent().appendingPathComponent(name)) == pin.sha256 else { throw NSError(domain: "NNGProfile", code: 2) }
    }
    return profile
}

// Applied only before a new game starts. Never rewrite the live player's files.
func applyClientProfile(root: URL, wine: URL, environment: [String:String]) throws {
    guard let profile = try clientProfile() else { return }
    let fm = FileManager.default
    let game = root.appendingPathComponent("compat/mac-client/system")
    let stock = root.appendingPathComponent("client/system")
    let backup = root.appendingPathComponent("compat/settings-backups/profile-v1")
    var cameraProfile = false
    for (name, pin) in profile.files.sorted(by: { $0.key < $1.key }) {
        let destination = game.appendingPathComponent(name)
        let current = try digest(destination)
        if current == pin.sha256 {
            if name == "User.ini" { cameraProfile = true }
            continue
        }
        // An updated server INI or custom key bindings take precedence over
        // this profile. Unrelated user settings are never replaced blindly.
        guard current == pin.base_sha256, try digest(stock.appendingPathComponent(name)) == pin.base_sha256 else {
            print("Preserving custom or newer configuration: \(name)"); continue
        }
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        let original = backup.appendingPathComponent(name + "." + pin.base_sha256)
        if !fm.fileExists(atPath: original.path) { try fm.copyItem(at: destination, to: original) }
        let bytes = try Data(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("client-profile/" + name))
        try bytes.write(to: destination, options: .atomic)
        guard try digest(destination) == pin.sha256 else { throw NSError(domain: "NNGProfile", code: 3) }
        if name == "User.ini" { cameraProfile = true }
        print("Applied Mac settings: \(name)")
    }
    for executable in ["l2.exe", "l2.bin"] {
        var options = [("UsePreciseScrolling", "n")]
        if cameraProfile { options += [("LeftOptionIsAlt", "y"), ("RightOptionIsAlt", "y")] }
        for (key, value) in options {
            let p = Process(); p.executableURL = wine
            p.arguments = ["reg", "add", "HKCU\\Software\\Wine\\AppDefaults\\" + executable + "\\Mac Driver", "/v", key, "/t", "REG_SZ", "/d", value, "/f"]
            p.environment = environment; p.standardInput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw NSError(domain: "NNGProfile", code: 4) }
        }
    }
}

struct RendererManifest: Decodable { let version: Int; let backend: String; let files: [String:RuntimePin] }
struct RendererSettings: Codable { let backend: String }
func selectedRenderer(root: URL) -> String {
    let url = root.appendingPathComponent("compat/renderer-settings.json")
    let value = (try? JSONDecoder().decode(RendererSettings.self, from: Data(contentsOf:url)))?.backend
    return ["mtld3d","d9vk"].contains(value ?? "") ? value! : "wined3d"
}
func rendererEnvironment(root: URL, game: URL, environment: [String:String]) throws -> [String:String] {
    var env = environment
    guard selectedRenderer(root: root) == "d9vk" else {
        env["WINEDLLOVERRIDES"] = "d3d9=b;" + (env["WINEDLLOVERRIDES"] ?? "")
        print("Renderer: WineD3D / OpenGL"); return env
    }
    let source = Bundle.main.resourceURL!.appendingPathComponent("renderer")
    let manifest = try JSONDecoder().decode(RendererManifest.self, from: Data(contentsOf: source.appendingPathComponent("renderer.json")))
    guard manifest.version == 1, manifest.backend == "d9vk", Set(manifest.files.keys) == Set(["d3d9.dll", "libMoltenVK.dylib"]) else { throw NSError(domain:"NNGRenderer",code:1) }
    // Verify every bundled byte before modifying the game's renderer files.
    for (name,pin) in manifest.files {
        let file = source.appendingPathComponent(name)
        guard pin.name == name, (try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.int64Value == pin.size, try digest(file) == pin.sha256 else { throw NSError(domain:"NNGRenderer",code:2) }
    }
    let cache = root.appendingPathComponent("compat/renderers/d9vk-v1")
    try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
    for (name,pin) in manifest.files {
        let dst = name == "d3d9.dll" ? game.appendingPathComponent("system/d3d9.dll") : cache.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath:dst.path) {
            guard try digest(dst) == pin.sha256 else {
                throw NSError(domain:"NNGRenderer",code:3,userInfo:[NSLocalizedDescriptionKey:"Существующий \(name) отличается. Выберите OpenGL или восстановите компонент."])
            }
        } else { try Data(contentsOf:source.appendingPathComponent(name)).write(to:dst,options:.atomic) }
    }
    env["WINEDLLOVERRIDES"] = "d3d9=n;" + (env["WINEDLLOVERRIDES"] ?? "")
    env["DYLD_FALLBACK_LIBRARY_PATH"] = cache.path + ":" + (env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "/usr/lib")
    env["DXVK_ASYNC"] = "0"
    env["DXVK_LOG_PATH"] = root.appendingPathComponent("logs").path
    env["DXVK_LOG_LEVEL"] = "info"
    let diagnostics = root.appendingPathComponent("compat/fps-diagnostics.json")
    if let data = try? Data(contentsOf:diagnostics),
       let value = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any], value["enabled"] as? Bool == true {
        env["DXVK_HUD"] = value["hud"] as? String ?? "fps,frametimes,drawcalls,compiler,cs,gpuload"
        print("FPS diagnostics: in-game FPS / frametime / drawcall overlay enabled")
    }
    print("Renderer: D9VK / MoltenVK / Metal (pinned components)")
    return env
}

func verifyGameInstallation(root: URL, progress: ((Int,Int)->Void)? = nil) throws -> Bool {
    defer {flushFileDigestCache(root:root)}
    let fm = FileManager.default
    let client = root.appendingPathComponent("client")
    let game = root.appendingPathComponent("compat/mac-client")
    let cache = client.appendingPathComponent(".nng-state.json")
    guard fm.fileExists(atPath: game.appendingPathComponent("system/l2.exe").path), fm.fileExists(atPath: cache.path) else { return false }
    let records = try JSONDecoder().decode([String:CachedFile].self, from: Data(contentsOf: cache))
    guard records.count >= 2000, records["system/Engine.dll"] != nil, records["system/L2.ini"] != nil else {
        throw NSError(domain:"NNG",code:5,userInfo:[NSLocalizedDescriptionKey:"Нет полной записи проверки клиента. Нажмите «Проверить обновления»."])
    }
    let modules = try JSONDecoder().decode([String:ModulePin].self, from: Data(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("mac-binaries.json")))
    let overlayNames = Set(modules.keys.map { $0.lowercased() })
    let profile = try clientProfile()
    for (index, pair) in records.sorted(by: { $0.key < $1.key }).enumerated() {
        let (name, pin) = pair
        guard !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator:"/").contains("..") else { throw NSError(domain:"NNG",code:6) }
        let file = client.appendingPathComponent(name)
        let size = try fm.attributesOfItem(atPath:file.path)[.size] as? NSNumber
        guard size?.int64Value == pin.size, try digest(file) == pin.sha else {
            throw NSError(domain:"NNG",code:7,userInfo:[NSLocalizedDescriptionKey:"Файл клиента повреждён: \(name). Нажмите «Проверить обновления»."])
        }
        if name.lowercased().hasPrefix("system/") {
            let leaf = file.lastPathComponent.lowercased()
            // The game writes s_info.ini's dates/counters on exit.
            if !overlayNames.contains(leaf), !["option.ini","user.ini","s_info.ini"].contains(leaf) {
                let actual = try digest(game.appendingPathComponent(name))
                let tuned = leaf == "l2.ini" && profile?.files["L2.ini"]?.base_sha256 == pin.sha && profile?.files["L2.ini"]?.sha256 == actual
                if actual != pin.sha && !tuned {
                    throw NSError(domain:"NNG",code:8,userInfo:[NSLocalizedDescriptionKey:"Требуется обновить файлы запуска: \(name)"])
                }
            }
        } else if name.contains("/") {
            guard game.appendingPathComponent(name).resolvingSymlinksInPath() == file.resolvingSymlinksInPath() else { throw NSError(domain:"NNG",code:9) }
        }
        if index % 100 == 0 {
            progress?(index, records.count)
        }
    }
    for (name,pin) in modules {
        guard try digest(game.appendingPathComponent("system").appendingPathComponent(name)) == pin.sha256 else {
            throw NSError(domain:"NNG",code:10,userInfo:[NSLocalizedDescriptionKey:"Повреждён компонент запуска: \(name)"])
        }
    }
    return true
}

struct AcceleratedManifest: Decodable {
    let version: Int
    let archive: RuntimePin
    let files: [String:String]
}
struct GameSession: Codable {
    let pid: Int32
    let accelerated: Bool
    let startedAt: Date
}
func acceleratedManifest() throws -> AcceleratedManifest {
    let url = Bundle.main.resourceURL!.appendingPathComponent("acceleration/runtime.json")
    let pin = try JSONDecoder().decode(AcceleratedManifest.self, from: Data(contentsOf:url))
    guard pin.version == 1, pin.files["wine/bin/wine"] != nil, pin.files["wine/bin/wineserver"] != nil, pin.files["x87sidecar"] != nil,
          pin.files.keys.allSatisfy({ !$0.hasPrefix("/") && !$0.contains("..") && !$0.contains("\\") }) else { throw NSError(domain:"NNGRuntime",code:1) }
    return pin
}
func acceleratedPaths(root:URL) -> (base:URL,wine:URL,prefix:URL,sidecar:URL) {
    let base = root.appendingPathComponent("compat/cx26-x87")
    return (base,base.appendingPathComponent("wine/bin/wine"),root.appendingPathComponent("compat/prefix-cx26-x87"),base.appendingPathComponent("x87sidecar"))
}
func acceleratedEnvironment(root:URL, source:[String:String]) -> [String:String] {
    let paths = acceleratedPaths(root:root)
    var env = source
    for key in ["DYLD_INSERT_LIBRARIES","DYLD_FALLBACK_LIBRARY_PATH","WINELOADERNOEXEC","X87_LOGS","X87_DISABLE_HOOK","X87_SAMPLE","X87_SAMPLE_HZ","X87_SAMPLE_REPORT","X87_NO_UNWIND","DXVK_HUD","MTL_HUD_LOG_ENABLED"] { env.removeValue(forKey:key) }
    env["WINEPREFIX"] = paths.prefix.path
    env["WINEDEBUG"] = "-all,err+module,err+seh"
    env["WINEMSYNC"] = "1"
    env["WINEDLLOVERRIDES"] = "d3d9=b;vcomp=n,b;mscoree,mshtml="
    env["ROSETTA_X87_PATH"] = paths.sidecar.path
    env["PATH"] = paths.wine.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
    let diagnostics = root.appendingPathComponent("compat/fps-diagnostics.json")
    if let data = try? Data(contentsOf:diagnostics), let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any], value["enabled"] as? Bool == true { env["MTL_HUD_ENABLED"] = "1" }
    else { env.removeValue(forKey:"MTL_HUD_ENABLED") }
    return env
}
func prepareAcceleratedRuntime(root:URL) throws {
    defer {flushFileDigestCache(root:root)}
    let fm = FileManager.default, pin = try acceleratedManifest(), paths = acceleratedPaths(root:root)
    let resources = Bundle.main.resourceURL!.appendingPathComponent("acceleration")
    try fm.createDirectory(at:paths.base,withIntermediateDirectories:true)
    if !fm.fileExists(atPath:paths.wine.path) {
        let archive = resources.appendingPathComponent(pin.archive.name)
        guard try digest(archive) == pin.archive.sha256 else { throw NSError(domain:"NNGRuntime",code:2) }
        let extraction = paths.base.appendingPathComponent(".extract-" + UUID().uuidString)
        try fm.createDirectory(at:extraction,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:extraction) }
        let tar = Process();tar.executableURL=URL(fileURLWithPath:"/usr/bin/tar");tar.arguments=["-xJf",archive.path,"-C",extraction.path]
        try tar.run();tar.waitUntilExit();guard tar.terminationStatus == 0 else { throw NSError(domain:"NNGRuntime",code:3) }
        try fm.moveItem(at:extraction.appendingPathComponent("wine"),to:paths.base.appendingPathComponent("wine"))
    }
    // These bundled files are a pinned renderer update and our built sidecar.
    for (name,sha) in pin.files {
        let supplied = resources.appendingPathComponent("overlay/" + name)
        let target = paths.base.appendingPathComponent(name)
        if fm.fileExists(atPath:supplied.path), (try? digest(target)) != sha {
            guard try digest(supplied) == sha else { throw NSError(domain:"NNGRuntime",code:4) }
            try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(contentsOf:supplied).write(to:target,options:.atomic)
            if name == "x87sidecar" { try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:target.path) }
        }
        guard try digest(target) == sha else { throw NSError(domain:"NNGRuntime",code:5,userInfo:[NSLocalizedDescriptionKey:"Повреждён быстрый движок: \(name)"]) }
    }
    if !fm.fileExists(atPath:paths.prefix.path) {
        let legacy = root.appendingPathComponent("compat/prefix-cx23-macbin")
        let cp = Process();cp.executableURL=URL(fileURLWithPath:"/bin/cp");cp.arguments=["-cR",legacy.path,paths.prefix.path]
        try cp.run();cp.waitUntilExit();guard cp.terminationStatus == 0 else { throw NSError(domain:"NNGRuntime",code:6) }
        let link = paths.prefix.appendingPathComponent("drive_c/NNG")
        try fm.removeItem(at:link)
        try fm.createSymbolicLink(at:link,withDestinationURL:root.appendingPathComponent("compat/mac-client"))
    }
}
func activeGameSession(root:URL) -> GameSession? {
    guard let data = try? Data(contentsOf:root.appendingPathComponent("compat/game-session.json")),
          let session = try? JSONDecoder().decode(GameSession.self,from:data), session.pid > 1,
          Darwin.kill(session.pid,0) == 0 else { return nil }
    var buffer = [CChar](repeating:0,count:4096)
    guard proc_pidpath(session.pid,&buffer,UInt32(buffer.count)) > 0 else { return nil }
    let executable = URL(fileURLWithPath:String(cString:buffer)).resolvingSymlinksInPath().path
    let expected = acceleratedPaths(root:root).base.appendingPathComponent("wine/lib/wine/x86_64-unix/wine").resolvingSymlinksInPath().path
    guard executable == expected else { return nil }
    return session
}

func runGameWorker(root: URL = launcherRoot(), prepareWithUpdater: Bool = false) -> Int32 {
    // Both launch routes stay in this native worker even if the GUI exits.
    // The bootstrap owns .launch.lock during preparation; it never launches.
    let coordination = Darwin.open(root.appendingPathComponent(".native-launch.lock").path, O_CREAT | O_RDWR, 0o600)
    guard coordination >= 0 else { return 1 }
    defer { Darwin.close(coordination) }
    guard flock(coordination, LOCK_EX | LOCK_NB) == 0 else { return 0 }
    if prepareWithUpdater {
        do {
            #if arch(arm64)
            let bootstrap = "nng-arm64"
            #else
            let bootstrap = "nng-x64"
            #endif
            let prepare = Process()
            prepare.executableURL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(bootstrap)
            prepare.arguments = ["-terminal", "-prepare-only"]
            prepare.standardInput = FileHandle.nullDevice
            try prepare.run(); prepare.waitUntilExit()
            guard prepare.terminationStatus == 0 else { return prepare.terminationStatus }
            guard try verifyGameInstallation(root:root) else { print("Updated game installation is incomplete"); return 1 }
        } catch { print("Game preparation failed: \(error)"); return 1 }
    }
    let fd = Darwin.open(root.appendingPathComponent(".launch.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return 1 }
    defer { Darwin.close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { print("NNG Mac is already running"); return 0 }
    let accelerated = selectedRenderer(root:root) == "mtld3d"
    let fast = acceleratedPaths(root:root)
    let runtime = accelerated ? fast.wine.deletingLastPathComponent() : root.appendingPathComponent("compat/cx23/wswine.bundle/bin")
    let prefix = accelerated ? fast.prefix : root.appendingPathComponent("compat/prefix-cx23-macbin")
    let game = root.appendingPathComponent("compat/mac-client")
    do {
        if accelerated {
            try prepareAcceleratedRuntime(root:root)
            try ensureNativeXMLRuntime(root:root,wine:fast.wine,prefix:fast.prefix,environment:acceleratedEnvironment(root:root,source:ProcessInfo.processInfo.environment),resources:Bundle.main.resourceURL!)
        }
        let pins = accelerated ? Dictionary(uniqueKeysWithValues:try acceleratedManifest().files.filter { $0.key.hasPrefix("wine/bin/") }.map { (URL(fileURLWithPath:$0.key).lastPathComponent,$0.value) }) : try JSONDecoder().decode([String:String].self, from: Data(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("runtime-executables.json")))
        for name in ["wine", "wineserver"] {
            guard try digest(runtime.appendingPathComponent(name)) == pins[name] else { print("Wine executable checksum mismatch"); return 1 }
        }
        guard prefix.appendingPathComponent("drive_c/NNG").resolvingSymlinksInPath().path == game.resolvingSymlinksInPath().path else { print("Unexpected game prefix"); return 1 }
        let marker = game.appendingPathComponent("system/Running.ini")
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = "-all,err+module,err+seh"
        env["WINEDLLOVERRIDES"] = "vcomp=n,b;mscoree,mshtml="
        env["DYLD_FALLBACK_LIBRARY_PATH"] = root.appendingPathComponent("compat/template/Template-1.0.24.app/Contents/Frameworks").path + ":/usr/lib"
        env["MVK_CONFIG_LOG_LEVEL"] = "0"
        env["PATH"] = runtime.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        if accelerated { env = acceleratedEnvironment(root:root,source:env) }
        try applyClientProfile(root: root, wine: runtime.appendingPathComponent("wine"), environment: env)
        if accelerated { env = acceleratedEnvironment(root:root,source:env); print("Renderer: mtld3d / Metal; cooperative x87 acceleration; MSync") }
        else { env = try rendererEnvironment(root: root, game: game, environment: env) }
        print("==> launch: verified local client; free Wine; no update-server connection")
        let p = Process(); p.executableURL = runtime.appendingPathComponent("wine")
        p.arguments = accelerated ? ["C:\\NNG\\system\\l2.exe"] : ["cmd", "/c", "cd /d C:\\NNG\\system && l2.exe"]
        p.environment = env; p.currentDirectoryURL = game.appendingPathComponent("system")
        try p.run()
        let sessionURL = root.appendingPathComponent("compat/game-session.json")
        if accelerated { try JSONEncoder().encode(GameSession(pid:p.processIdentifier,accelerated:true,startedAt:Date())).write(to:sessionURL,options:.atomic) }
        let helper = Process()
        if accelerated {
            // The cooperative x87 loader execs into Wine after Process.run().
            // Attach the PID-scoped tap only after that transition completes.
            let deadline = Date(timeIntervalSinceNow:15)
            let expectedHost = fast.base.appendingPathComponent("wine/lib/wine/x86_64-unix/wine").resolvingSymlinksInPath().path
            while p.isRunning && Date() < deadline {
                var buffer = [CChar](repeating:0,count:4096)
                if proc_pidpath(p.processIdentifier,&buffer,UInt32(buffer.count)) > 0,
                   URL(fileURLWithPath:String(cString:buffer)).resolvingSymlinksInPath().path == expectedHost { break }
                usleep(50000)
            }
            helper.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NNG Trackpad.app/Contents/MacOS/nng-trackpad")
            helper.arguments = ["--game-pid",String(p.processIdentifier)]
            helper.standardInput = FileHandle.nullDevice; helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
            try? helper.run()
        }
        p.waitUntilExit()
        if accelerated {
            if helper.isRunning { helper.terminate() }
            try? FileManager.default.removeItem(at:sessionURL)
            return p.terminationStatus
        }
        if p.terminationStatus != 0 { return p.terminationStatus }
        let wait = Process(); wait.executableURL = runtime.appendingPathComponent("wineserver")
        wait.arguments = ["-w"]; wait.environment = env
        try wait.run(); wait.waitUntilExit(); return wait.terminationStatus
    } catch { print("Local launch error: \(error)"); return 1 }
}

func digest(_ url: URL) throws -> String {try cachedFileDigest(url,root:launcherRoot())}

final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let root = launcherRoot()
    private var window: NSWindow!
    private let status = NSTextField(labelWithString: "Готов к запуску")
    private let detail = NSTextField(wrappingLabelWithString: "Клиент и обновления — в одном приложении.")
    private let button = NSButton(title: "Играть", target: nil, action: nil)
    private let updateButton = NSButton(title: "Проверить обновления", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var worker: Process?
    private var output: FileHandle?
    private var outputURL: URL?
    private var reader: FileHandle?
    private var logTail = ""
    private var preparing = false
    private var timer: Timer?
    private var failed = false
    private var trackpadStartedForPID: Int32?
    private var trackpadProcess: Process?
    private var metalItem: NSMenuItem!
    private var openGLItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "О программе NNG Mac", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(withTitle: "Управление тачпадом…", action: #selector(trackpadSettings), keyEquivalent: "t")
        metalItem = appMenu.addItem(withTitle: "Графика: Metal + ускорение x87", action: #selector(useMetal), keyEquivalent: "")
        openGLItem = appMenu.addItem(withTitle: "Графика: OpenGL (WineD3D)", action: #selector(useOpenGL), keyEquivalent: "")
        updateRendererMenu()
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть NNG Mac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Завершить NNG Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "NNG Mac"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let content = NSView(); content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.075, green: 0.08, blue: 0.095, alpha: 1).cgColor
        window.contentView = content

        let title = NSTextField(labelWithString: "NNG")
        title.font = .systemFont(ofSize: 52, weight: .bold)
        title.textColor = NSColor(calibratedRed: 0.88, green: 0.72, blue: 0.43, alpha: 1)
        let subtitle = NSTextField(labelWithString: "Lineage II для Mac")
        subtitle.font = .systemFont(ofSize: 17, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 19, weight: .semibold)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3
        progress.style = .spinning; progress.controlSize = .small
        progress.isIndeterminate = true; progress.isDisplayedWhenStopped = false
        button.bezelStyle = .rounded; button.controlSize = .large
        button.font = .systemFont(ofSize: 17, weight: .semibold)
        button.contentTintColor = NSColor(calibratedRed: 0.94, green: 0.8, blue: 0.54, alpha: 1)
        button.target = self; button.action = #selector(play)
        button.keyEquivalent = "\r"
        updateButton.bezelStyle = .rounded; updateButton.target = self; updateButton.action = #selector(update)
        let logs = NSButton(title: "Журнал", target: self, action: #selector(openLogs))
        let info = NSButton(title: "О программе", target: self, action: #selector(about))
        logs.bezelStyle = .inline; info.bezelStyle = .inline
        let footer = NSTextField(labelWithString: "Без подписки и пробного периода")
        footer.font = .systemFont(ofSize: 11); footer.textColor = .tertiaryLabelColor
        for view in [title, subtitle, status, detail, progress, button, updateButton, logs, info, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 44), title.topAnchor.constraint(equalTo: content.topAnchor, constant: 32),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor), subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor), status.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 38),
            progress.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 12), progress.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor), detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -44), detail.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 9),
            button.leadingAnchor.constraint(equalTo: title.leadingAnchor), button.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 28), button.widthAnchor.constraint(equalToConstant: 210), button.heightAnchor.constraint(equalToConstant: 46),
            updateButton.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 24), updateButton.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            footer.leadingAnchor.constraint(equalTo: title.leadingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            logs.trailingAnchor.constraint(equalTo: info.leadingAnchor, constant: -22), logs.centerYAnchor.constraint(equalTo: footer.centerYAnchor), info.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -38), info.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if activeGameSession(root:root) != nil { showGame(); return false }
        window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        return true
    }

    private func otherLaunchActive() -> Bool {
        let path = root.appendingPathComponent(".launch.lock").path
        let fd = Darwin.open(path, O_RDWR)
        if fd < 0 { return false }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { _ = flock(fd, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }

    private func gamePID() -> Int32? {
        if let session = activeGameSession(root:root) { return session.pid }
        let windows = CGWindowListCopyWindowInfo(.optionAll, 0) as? [[String: Any]] ?? []
        for win in windows {
            let owner = (win[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            if ["l2.exe", "l2.bin"].contains(owner), let pid = win[kCGWindowOwnerPID as String] as? Int32 { return pid }
        }
        return nil
    }

    private func refresh() {
        if let bytes = try? reader?.read(upToCount: 128 * 1024), !bytes.isEmpty {
            logTail += String(decoding: bytes, as: UTF8.self)
            if logTail.count > 32000 { logTail = String(logTail.suffix(24000)) }
        }
        if preparing { return }
        let busy = worker?.isRunning == true || otherLaunchActive()
        updateButton.isEnabled = !busy
        if busy, let pid = gamePID() {
            if activeGameSession(root:root) == nil, trackpadStartedForPID != pid { startTrackpad(pid: pid, show: false) }
            status.stringValue = "Игра открыта"
            detail.stringValue = "Эта кнопка также возвращает свёрнутое окно игры."
            button.title = "Показать игру"; button.isEnabled = true
            progress.stopAnimation(nil)
        } else if busy {
            status.stringValue = logTail.contains("==> launch") ? "Запускаем игру…" : "Проверяем файлы…"
            detail.stringValue = "Первая подготовка может занять несколько минут."
            button.title = "Подождите…"; button.isEnabled = false
            progress.startAnimation(nil)
        } else if !failed {
            trackpadStartedForPID = nil
            status.stringValue = "Готов к запуску"
            detail.stringValue = "Перед запуском автоматически проверим обновления."
            button.title = "Играть"; button.isEnabled = true
            progress.stopAnimation(nil)
        }
    }

    private func showGame() {
        guard let pid = gamePID(), let game = NSRunningApplication(processIdentifier:pid) else { return }
        NSApp.yieldActivation(to:game)
        window.orderOut(nil)
        game.unhide(); game.activate(options:[.activateAllWindows])
        guard let session = activeGameSession(root:root), session.accelerated else { return }
        DispatchQueue.global(qos:.userInitiated).async {
            let p = Process(); p.executableURL = acceleratedPaths(root:self.root).wine
            p.arguments = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NNG Trackpad.app/Contents/Resources/input-bridge/nng-input.exe").path,"--restore"]
            p.environment = acceleratedEnvironment(root:self.root,source:ProcessInfo.processInfo.environment)
            p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit() } catch { return }
            DispatchQueue.main.async { NSApp.yieldActivation(to:game); game.unhide(); game.activate(options:[.activateAllWindows]) }
        }
    }

    @objc private func play() {
        guard !preparing else { return }
        if worker?.isRunning == true || otherLaunchActive() {
            showGame(); return
        }
        preparing = true; failed = false
        status.stringValue = "Проверяем обновления…"
        detail.stringValue = "Проверяем встроенные компоненты приложения."
        button.isEnabled = false; updateButton.isEnabled = false; progress.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let needsUpdate=try clientNeedsUpdate(root:self.root,base:URL(string:"http://31.177.111.169:8086/files")!)
                let local = needsUpdate ? false : try self.verifyInstalledGame()
                if !local {try self.prepareRuntimeCache()}
                DispatchQueue.main.async { self.startWorker(local: local) }
            } catch let error as UpdateProbeFailure {
                DispatchQueue.main.async {self.updateCheckFailed(error)}
            } catch {
                DispatchQueue.main.async { self.showError(error.localizedDescription) }
            }
        }
    }

    @objc private func update() {
        guard !preparing, worker?.isRunning != true, !otherLaunchActive() else { return }
        preparing = true; failed = false; button.isEnabled = false; updateButton.isEnabled = false
        status.stringValue = "Проверяем обновления…"; progress.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            do { try self.prepareRuntimeCache(); DispatchQueue.main.async { self.startWorker(local: false) } }
            catch { DispatchQueue.main.async { self.showError(error.localizedDescription) } }
        }
    }

    private func verifyInstalledGame() throws -> Bool {
        try verifyGameInstallation(root:root) { index,total in
            DispatchQueue.main.async { self.status.stringValue = "Проверяем файлы: \(index)/\(total)" }
        }
    }

    private func prepareRuntimeCache() throws {
        defer {flushFileDigestCache(root:root)}
        let fm = FileManager.default
        let resources = Bundle.main.resourceURL!
        let pins = try JSONDecoder().decode([RuntimePin].self, from: Data(contentsOf: resources.appendingPathComponent("runtime-components.json")))
        guard pins.count == 2 else { throw NSError(domain: "NNG", code: 1, userInfo: [NSLocalizedDescriptionKey: "Неполный комплект Wine."]) }
        let cache = root.appendingPathComponent("compat")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        // Fail before copying anything if any bundled component is damaged.
        for pin in pins {
            guard !pin.name.contains("/"), !pin.name.contains("\\"), !pin.name.hasPrefix(".") else { throw NSError(domain: "NNG", code: 2) }
            let src = resources.appendingPathComponent("runtime").appendingPathComponent(pin.name)
            let size = try fm.attributesOfItem(atPath: src.path)[.size] as? NSNumber
            guard size?.int64Value == pin.size, try digest(src) == pin.sha256 else {
                throw NSError(domain: "NNG", code: 3, userInfo: [NSLocalizedDescriptionKey: "Компонент Wine повреждён: \(pin.name)"])
            }
        }
        for pin in pins {
            let dst = cache.appendingPathComponent(pin.name)
            if (try? digest(dst)) == pin.sha256 { continue }
            let tmp = cache.appendingPathComponent(pin.name + ".launcher-new")
            if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
            try fm.copyItem(at: resources.appendingPathComponent("runtime").appendingPathComponent(pin.name), to: tmp)
            guard try digest(tmp) == pin.sha256 else { throw NSError(domain: "NNG", code: 4) }
            if fm.fileExists(atPath: dst.path) { _ = try fm.replaceItemAt(dst, withItemAt: tmp) }
            else { try fm.moveItem(at: tmp, to: dst) }
        }
    }

    private func startWorker(local: Bool) {
        do {
            let logs = root.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let url = logs.appendingPathComponent("launcher-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            output = try FileHandle(forWritingTo: url); outputURL = url
            reader = try FileHandle(forReadingFrom: url); logTail = ""
            let p = Process()
            p.executableURL = Bundle.main.executableURL!
            p.arguments = local ? ["--game-worker"] : ["--update-and-game-worker"]
            p.standardOutput = output; p.standardError = output
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.preparing = false
                    try? self.output?.close(); self.output = nil
                    if process.terminationStatus != 0 { self.showError("Проверка или запуск завершились с ошибкой. Подробности — в журнале.") }
                    else { self.worker = nil; self.refresh() }
                }
            }
            worker = p
            try p.run(); preparing = false; refresh()
        } catch { showError(error.localizedDescription) }
    }

    private func updateCheckFailed(_ error:Error) {
        preparing=false;progress.stopAnimation(nil)
        let alert=NSAlert();alert.messageText="Не удалось проверить обновления"
        alert.informativeText=error.localizedDescription+"\nМожно повторить проверку или запустить проверенную локальную версию."
        alert.addButton(withTitle:"Повторить");alert.addButton(withTitle:"Запустить локально");alert.addButton(withTitle:"Отмена")
        let result=alert.runModal()
        if result == .alertFirstButtonReturn {play();return}
        if result != .alertSecondButtonReturn {refresh();return}
        preparing=true
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                guard try self.verifyInstalledGame() else {throw NSError(domain:"NNG",code:20,userInfo:[NSLocalizedDescriptionKey:"Полного локального клиента нет. Нужна загрузка обновлений."])}
                DispatchQueue.main.async {self.startWorker(local:true)}
            } catch {DispatchQueue.main.async {self.showError(error.localizedDescription)}}
        }
    }

    private func showError(_ message: String) {
        preparing = false; failed = true
        status.stringValue = "Не удалось запустить игру"
        detail.stringValue = message
        button.title = "Повторить"; button.isEnabled = true; updateButton.isEnabled = true; progress.stopAnimation(nil)
    }
    private func startTrackpad(pid: Int32, show: Bool) {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NNG Trackpad.app/Contents/MacOS/nng-trackpad")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return }
        if show {
            if let process = trackpadProcess, let app = NSRunningApplication(processIdentifier:process.processIdentifier) {
                NSApp.yieldActivation(to:app)
            } else { NSApp.yieldActivation(toApplicationWithBundleIdentifier:"ru.nng.macclient.trackpad") }
        }
        if trackpadStartedForPID == pid {
            if show { DistributedNotificationCenter.default().postNotificationName(Notification.Name("ru.nng.trackpad.show"), object: nil, userInfo: nil, deliverImmediately: true) }
            // No automatic crash-restart loop. A deliberate menu click can
            // restart an exited helper without restarting the player's game.
            if !show || trackpadProcess?.isRunning == true { return }
        }
        let p = Process(); p.executableURL = helper
        p.arguments = ["--game-pid", String(pid)] + (show ? ["--show"] : [])
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); trackpadProcess = p; trackpadStartedForPID = pid }
        catch { print("Trackpad helper could not start: \(error)") }
    }
    private func updateRendererMenu() {
        let metal = selectedRenderer(root:root) != "wined3d"
        metalItem.state = metal ? .on : .off; openGLItem.state = metal ? .off : .on
    }
    private func setRenderer(_ backend: String) {
        do {
            let file = root.appendingPathComponent("compat/renderer-settings.json")
            try JSONEncoder().encode(RendererSettings(backend:backend)).write(to:file,options:.atomic)
            updateRendererMenu()
            let alert = NSAlert(); alert.messageText = backend != "wined3d" ? "Выбрана графика Metal" : "Выбрана графика OpenGL"
            alert.informativeText = "Изменение применяется при следующем запуске игры. Закройте клиент обычным выходом, затем нажмите «Играть»."
            alert.runModal()
        } catch { showError(error.localizedDescription) }
    }
    @objc private func useMetal() { setRenderer("mtld3d") }
    @objc private func useOpenGL() { setRenderer("wined3d") }
    @objc private func trackpadSettings() {
        guard let pid = gamePID() else {
            let alert = NSAlert(); alert.messageText = "Сначала запустите игру"
            alert.informativeText = "Настройки тачпада доступны, когда открыто окно Lineage II."
            alert.runModal(); return
        }
        startTrackpad(pid: pid, show: true)
    }
    @objc private func openLogs() {
        let logs = root.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logs)
    }
    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "NNG Mac " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        alert.informativeText = "Собственный лаунчер для Lineage II на macOS.\n\nВстроен открытый Wine 11, Metal-рендерер mtld3d и ускорение x87. CrossOver устанавливать не требуется. Подписки и пробного периода нет.\n\nИгровые файлы принадлежат их правообладателям. Источники компонентов и лицензии приложены к программе."
        alert.addButton(withTitle: "Понятно"); alert.addButton(withTitle: "Компоненты и лицензии")
        if alert.runModal() == .alertSecondButtonReturn, let url = Bundle.main.url(forResource: "THIRD-PARTY", withExtension: "md") { NSWorkspace.shared.open(url) }
    }
}

if CommandLine.arguments.contains("--repair-xml") {
    let root=launcherRoot()
    let native=Darwin.open(root.appendingPathComponent(".native-launch.lock").path,O_CREAT|O_RDWR,0o600)
    let launch=Darwin.open(root.appendingPathComponent(".launch.lock").path,O_CREAT|O_RDWR,0o600)
    guard native>=0,launch>=0,flock(native,LOCK_EX|LOCK_NB)==0,flock(launch,LOCK_EX|LOCK_NB)==0 else {fputs("Закройте игру перед ремонтом XML.\n",stderr);exit(1)}
    do {
        let paths=acceleratedPaths(root:root)
        try ensureNativeXMLRuntime(root:root,wine:paths.wine,prefix:paths.prefix,environment:acceleratedEnvironment(root:root,source:ProcessInfo.processInfo.environment),resources:Bundle.main.resourceURL!)
        flushFileDigestCache(root:root);exit(0)
    } catch {fputs("XML repair failed: \(error)\n",stderr);exit(1)}
}
if CommandLine.arguments.contains("--check-updates") {
    do {
        let changed=try clientNeedsUpdate(root:launcherRoot(),base:URL(string:"http://31.177.111.169:8086/files")!)
        print(changed ? "UPDATES_AVAILABLE" : "UP_TO_DATE");exit(0)
    } catch {fputs("Update check failed: \(error)\n",stderr);exit(1)}
}
if CommandLine.arguments.contains("--verify-client") {
    do {guard try verifyGameInstallation(root:launcherRoot()) else {exit(2)};print("Client verified");exit(0)}
    catch {fputs("Verification failed: \(error)\n",stderr);exit(1)}
}
if CommandLine.arguments.contains("--game-worker") { exit(runGameWorker()) }
if CommandLine.arguments.contains("--update-and-game-worker") { exit(runGameWorker(prepareWithUpdater:true)) }
let app = NSApplication.shared
let delegate = Launcher()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
