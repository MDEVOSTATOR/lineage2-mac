import AppKit
import CryptoKit
import Darwin

private let updateRepository = "https://github.com/MDEVOSTATOR/lineage2-mac/releases/download/"
private let updateFeed = URL(string: "https://raw.githubusercontent.com/MDEVOSTATOR/lineage2-mac/main/resources/mac-launcher-channel.json")!
private let launcherAssetLimit = 8 * 1024 * 1024
private let launcherMetadataLimit = 16 * 1024
private let updateVersionKey = "CFBundleShortVersionString"
private let updateTargets = [
    "ru.nng.macclient.easy": "NNG-Mac-Easy-launcher-arm64",
    "ru.nng.macclient": "NNG-Mac-Installed-launcher-arm64"
]

private struct SignedLauncherFeed: Decodable {
    let payload: Data
    let signature: Data
}

struct LauncherRelease: Decodable {
    let version: String
    let tag: String
    let size: Int
    let sha256: String
    let asset: String

    var url: URL { URL(string: updateRepository + tag + "/" + asset)! }
}

private struct LauncherFeed: Decodable {
    let schema: Int
    let releases: [String: LauncherRelease]
}

private func launcherUpdateError(_ message: String) -> NSError {
    NSError(domain: "NNGLauncherUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func versionParts(_ version: String) -> [Int]? {
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    let values = parts.compactMap { Int($0) }
    guard parts.count == 3, values.count == 3, values.allSatisfy({ 0...999 ~= $0 }),
          values.map(String.init).joined(separator: ".") == version else { return nil }
    return values
}

func launcherRelease(from data: Data, publicKey: Data, identifier: String, current: String) throws -> LauncherRelease? {
    guard data.count <= launcherMetadataLimit else { throw launcherUpdateError("Слишком большой каталог обновлений.") }
    let signed = try JSONDecoder().decode(SignedLauncherFeed.self, from: data)
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    guard key.isValidSignature(signed.signature, for: signed.payload) else {
        throw launcherUpdateError("Подпись каталога обновлений не совпала.")
    }
    let feed = try JSONDecoder().decode(LauncherFeed.self, from: signed.payload)
    guard feed.schema == 1, let expectedAsset = updateTargets[identifier], let release = feed.releases[identifier],
          release.asset == expectedAsset,
          release.tag.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+(-preview\.[0-9]+)?\z"#, options: .regularExpression) != nil,
          release.size > 0, release.size <= launcherAssetLimit,
          release.sha256.utf8.count == 64, release.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
          let old = versionParts(current), let new = versionParts(release.version) else {
        throw launcherUpdateError("Каталог не подходит для этой сборки NNG Mac.")
    }
    return old.lexicographicallyPrecedes(new) ? release : nil
}

private func launcherDownload(_ url: URL, limit: Int, timeout: Int) throws -> Data {
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("nng-launcher-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: folder) }
    let output = folder.appendingPathComponent("download")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["--disable", "--fail", "--silent", "--location", "--max-redirs", "3",
                         "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "3",
                         "--max-time", String(timeout), "--max-filesize", String(limit), "--output", output.path, url.absoluteString]
    try runLauncherProcess(process, timeout: Double(timeout) + 1, error: "Не удалось загрузить обновление лаунчера из GitHub.")
    let data = try Data(contentsOf: output)
    guard data.count <= limit else { throw launcherUpdateError("Размер обновления превышает допустимый.") }
    return data
}

private func runLauncherProcess(_ process: Process, timeout: TimeInterval, error: String) throws {
    let done = DispatchSemaphore(value: 0)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in done.signal() }
    try process.run()
    guard done.wait(timeout: .now() + timeout) == .success else {
        if process.isRunning { process.terminate() }
        if done.wait(timeout: .now() + 1) != .success, process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        throw launcherUpdateError(error)
    }
    guard process.terminationStatus == 0 else { throw launcherUpdateError(error) }
}

private func runLauncherTool(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try runLauncherProcess(process, timeout: timeout, error: "Проверка новой сборки лаунчера не прошла.")
}

private func launcherBundleInfo(_ app: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          info["CFBundleExecutable"] as? String == "nng",
          let identifier = info["CFBundleIdentifier"] as? String, updateTargets[identifier] != nil else {
        throw launcherUpdateError("Установленная сборка не поддерживает обновление лаунчера.")
    }
    return info
}

func installLauncherRelease(_ release: LauncherRelease, bytes: Data, app: URL, root: URL, reopen: Bool) throws {
    guard bytes.count == release.size, sha256Data(bytes) == release.sha256 else {
        throw launcherUpdateError("Контрольная сумма нового лаунчера не совпала.")
    }
    let fm = FileManager.default
    let app = app.resolvingSymlinksInPath()
    guard app.pathExtension == "app", fm.isWritableFile(atPath: app.path) else {
        throw launcherUpdateError("Перенесите NNG Mac в доступную для записи папку «Программы».")
    }
    let appLock = Darwin.open(app.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard appLock >= 0 else { throw launcherUpdateError("Не удалось открыть папку лаунчера.") }
    var locks = [appLock]
    defer { for fd in locks.reversed() { Darwin.close(fd) } }
    guard flock(appLock, LOCK_EX | LOCK_NB) == 0 else {
        throw launcherUpdateError("Обновление лаунчера уже устанавливается.")
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for name in [".native-launch.lock", ".launch.lock"] {
        let fd = Darwin.open(root.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw launcherUpdateError("Не удалось заблокировать запуск игры на время установки.") }
        locks.append(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw launcherUpdateError("Закройте игру и повторите обновление лаунчера.")
        }
    }
    var info = try launcherBundleInfo(app)
    guard let current = info[updateVersionKey] as? String, let old = versionParts(current),
          let new = versionParts(release.version), old.lexicographicallyPrecedes(new),
          let identifier = info["CFBundleIdentifier"] as? String, updateTargets[identifier] == release.asset else {
        throw launcherUpdateError("Обновление уже установлено или предназначено для другой сборки.")
    }
    try runLauncherTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 30)
    // Stage on the same volume. Clone the bundle on APFS, including the local
    // owner's existing resources. The only payload is a signed launcher binary.
    let folder = app.appendingPathComponent(".nng-update-" + UUID().uuidString, isDirectory: true)
    let staged = folder.appendingPathComponent(app.lastPathComponent)
    let currentContents = app.appendingPathComponent("Contents")
    let stagedContents = staged.appendingPathComponent("Contents")
    try fm.createDirectory(at: staged, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var keepBackup = false
    defer { if !keepBackup { try? fm.removeItem(at: folder) } }
    try runLauncherTool("/bin/cp", ["-cR", currentContents.path, stagedContents.path], timeout: 60)
    let executable = stagedContents.appendingPathComponent("MacOS/nng")
    try bytes.write(to: executable, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    info[updateVersionKey] = release.version
    info["CFBundleVersion"] = release.version
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: stagedContents.appendingPathComponent("Info.plist"), options: .atomic)
    try runLauncherTool("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, staged.path], timeout: 30)
    try runLauncherTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path], timeout: 30)
    try runLauncherTool(executable.path, ["--launcher-update-preflight", release.version], timeout: 8)
    let swap = {
        renameatx_np(AT_FDCWD, currentContents.path, AT_FDCWD, stagedContents.path, UInt32(RENAME_SWAP)) == 0
    }
    guard swap() else { throw launcherUpdateError("macOS не смогла заменить файлы лаунчера.") }
    if reopen {
        let process = Process()
        process.executableURL = currentContents.appendingPathComponent("MacOS/nng")
        process.arguments = ["--launcher-update-reopen", String(getpid())]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            if !swap() { keepBackup = true }
            throw launcherUpdateError("Не удалось перезапустить лаунчер. Откройте его из Dock.")
        }
    }
}

func handleLauncherUpdateArguments() {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else { return }
    if arguments[1] == "--launcher-update-preflight" {
        let info = try? launcherBundleInfo(Bundle.main.bundleURL)
        exit(info?[updateVersionKey] as? String == arguments[2] ? 0 : 1)
    }
    if arguments[1] == "--launcher-update-reopen" {
        guard let parent = Int32(arguments[2]), getppid() == parent else { exit(1) }
        let deadline = DispatchTime.now() + 20
        while getppid() == parent && DispatchTime.now() < deadline { usleep(50000) }
        guard getppid() != parent else { exit(1) }
        try? runLauncherTool("/usr/bin/open", [Bundle.main.bundleURL.path], timeout: 8)
        exit(0)
    }
}

final class LauncherUpdates: NSObject {
    private let root: URL
    private var checking = false
    private(set) var installing = false
    private var pending: LauncherRelease?
    private var prompted = false
    private var canPrompt: () -> Bool = { true }

    init(root: URL) { self.root = root }

    func addMenuItem(to menu: NSMenu, canPrompt: @escaping () -> Bool) {
        guard let identifier = Bundle.main.bundleIdentifier, updateTargets[identifier] != nil else { return }
        self.canPrompt = canPrompt
        let item = menu.addItem(withTitle: "Проверить обновление лаунчера…", action: #selector(checkFromMenu), keyEquivalent: "")
        item.target = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.check(manual: false) }
    }

    @objc private func checkFromMenu() { check(manual: true) }

    func offerPendingUpdate() {
        guard let release = pending, !prompted, !checking, !installing, NSApp.isActive, canPrompt() else { return }
        prompted = true
        showUpdate(release)
    }

    private func check(manual: Bool) {
        guard !checking, !installing else { return }
        checking = true
        DispatchQueue.global(qos: manual ? .userInitiated : .utility).async {
            let result = Result {
                guard let identifier = Bundle.main.bundleIdentifier,
                      let current = Bundle.main.object(forInfoDictionaryKey: updateVersionKey) as? String,
                      let keyURL = Bundle.main.url(forResource: "launcher-update-public-key", withExtension: "txt") else {
                    throw launcherUpdateError("В этой сборке нет ключа обновлений.")
                }
                let text = try String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let key = Data(base64Encoded: text) else { throw launcherUpdateError("Неверный ключ обновлений.") }
                let data = try launcherDownload(updateFeed, limit: launcherMetadataLimit, timeout: 5)
                return try launcherRelease(from: data, publicKey: key, identifier: identifier, current: current)
            }
            DispatchQueue.main.async {
                self.checking = false
                switch result {
                case .success(let release):
                    self.pending = release
                    if manual {
                        if let release { self.showUpdate(release) }
                        else { self.showMessage("Установлена актуальная версия лаунчера") }
                    } else { self.offerPendingUpdate() }
                case .failure(let error):
                    if manual { self.showMessage("Не удалось проверить обновление лаунчера", error.localizedDescription) }
                }
            }
        }
    }

    private func showUpdate(_ release: LauncherRelease) {
        let alert = NSAlert()
        alert.messageText = "Доступен NNG Mac " + release.version
        alert.informativeText = "Обновятся файлы лаунчера. Игра и настройки сохранятся."
        alert.addButton(withTitle: "Обновить и перезапустить")
        alert.addButton(withTitle: "Позже")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard canPrompt() else { showMessage("Закройте игру и повторите обновление лаунчера"); return }
        installing = true
        let app = Bundle.main.bundleURL
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                let bytes = try launcherDownload(release.url, limit: release.size, timeout: 30)
                try installLauncherRelease(release, bytes: bytes, app: app, root: self.root, reopen: true)
            }
            DispatchQueue.main.async {
                switch result {
                case .success: NSApp.terminate(nil)
                case .failure(let error):
                    self.installing = false
                    self.showMessage("Не удалось обновить лаунчер", error.localizedDescription)
                }
            }
        }
    }

    private func showMessage(_ title: String, _ detail: String = "") {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
