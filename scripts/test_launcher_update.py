#!/usr/bin/env python3
"""Exercise signed launcher updates against disposable copies of both app variants."""
import hashlib
import plistlib
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
HARNESS = r'''
import CryptoKit
import Darwin
import Foundation

func mustFail(_ block: () throws -> Void) {
    do { try block(); fatalError("Unexpected success") }
    catch { print("Rejected: " + error.localizedDescription) }
}

let app = URL(fileURLWithPath: CommandLine.arguments[1])
let root = URL(fileURLWithPath: CommandLine.arguments[2])
let identifier = CommandLine.arguments[3]
let asset = CommandLine.arguments[4]
let version = CommandLine.arguments[5]
let current = CommandLine.arguments[6]
let binary = app.appendingPathComponent("Contents/MacOS/nng")
let bytes = try Data(contentsOf: binary)
let key = Curve25519.Signing.PrivateKey()
let publicKey = key.publicKey.rawRepresentation

func signed(asset: String, version: String, bytes: Data) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: [
        "schema": 1, "releases": [
            identifier: ["version": version, "asset": asset, "tag": "v1.4.4-preview.1",
                         "size": bytes.count, "sha256": sha256Data(bytes)]
        ]
    ])
    return try JSONSerialization.data(withJSONObject: [
        "payload": payload.base64EncodedString(),
        "signature": key.signature(for: payload).base64EncodedString()
    ])
}

func infoVersion() throws -> String {
    let plist = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    return (try PropertyListSerialization.propertyList(from: plist, format: nil) as! [String: Any])["CFBundleShortVersionString"] as! String
}

let manifest = try signed(asset: asset, version: version, bytes: bytes)
let release = try launcherRelease(from: manifest, publicKey: publicKey, identifier: identifier, current: current)!
let replay = try launcherRelease(from: manifest, publicKey: publicKey, identifier: identifier, current: version)
precondition(replay == nil)
mustFail { _ = try launcherRelease(from: manifest, publicKey: Data(repeating: 42, count: 32), identifier: identifier, current: current) }
mustFail {
    let mismatch = try signed(asset: "wrong-asset", version: version, bytes: bytes)
    _ = try launcherRelease(from: mismatch, publicKey: publicKey, identifier: identifier, current: current)
}
mustFail { try installLauncherRelease(release, bytes: Data(repeating: 0, count: bytes.count), app: app, root: root, reopen: false) }

try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for name in [".native-launch.lock", ".launch.lock"] {
    let fd = Darwin.open(root.appendingPathComponent(name).path, O_CREAT | O_RDWR, 0o600)
    precondition(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
    mustFail { try installLauncherRelease(release, bytes: bytes, app: app, root: root, reopen: false) }
    Darwin.close(fd)
}
let badBytes = try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/false"))
let badManifest = try signed(asset: asset, version: version, bytes: badBytes)
let badRelease = try launcherRelease(from: badManifest, publicKey: publicKey, identifier: identifier, current: current)!
mustFail { try installLauncherRelease(badRelease, bytes: badBytes, app: app, root: root, reopen: false) }
let afterFailure = try infoVersion()
precondition(afterFailure == current)
try installLauncherRelease(release, bytes: bytes, app: app, root: root, reopen: false)
let afterSuccess = try infoVersion()
precondition(afterSuccess == version)
mustFail { try installLauncherRelease(release, bytes: bytes, app: app, root: root, reopen: false) }
print("PASS signed update, tampering, replay, lock coordination, and preflight failure")
'''


def run(*arguments):
    subprocess.run([str(arg) for arg in arguments], check=True, timeout=150)


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


with tempfile.TemporaryDirectory(prefix="nng-launcher-tests-", dir=BUILD) as directory:
    folder = Path(directory)
    main = folder / "main.swift"
    main.write_text(HARNESS)
    tester = folder / "test-launcher"
    run("xcrun", "swiftc", "-O", main, ROOT / "Sources/LauncherUpdate.swift",
        ROOT / "Sources/UpdateCheck.swift", "-o", tester)

    for name, current, version, asset in [
        ("NNG Mac Easy.app", "1.4.3", "1.4.4", "NNG-Mac-Easy-launcher-arm64"),
        ("NNG Mac Updated.app", "1.3.7", "1.3.8", "NNG-Mac-Installed-launcher-arm64"),
    ]:
        app = folder / name
        run("/bin/cp", "-cR", BUILD / name, app)
        plist = app / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info.update(CFBundleShortVersionString=current, CFBundleVersion=current)
        plist.write_bytes(plistlib.dumps(info))
        identifier = info["CFBundleIdentifier"]
        run("codesign", "--force", "--sign", "-", "--identifier", identifier, app)
        inode = app.stat().st_ino
        watched = [app / "Contents/Resources/acceleration/runtime.json"]
        watched.extend(path for path in (app / "Contents/Helpers").rglob("*") if path.is_file())
        before = [digest(path) for path in watched]
        root = folder / (name + "-state")
        root.mkdir()
        sentinel = root / "player-data"
        sentinel.write_bytes(b"unchanged")
        run(tester, app, root, identifier, asset, version, current)
        assert sentinel.read_bytes() == b"unchanged"
        assert app.stat().st_ino == inode
        assert [digest(path) for path in watched] == before
        assert not list(app.glob(".nng-update-*"))
        run("codesign", "--verify", "--deep", "--strict", app)
        run(app / "Contents/MacOS/nng", "--launcher-update-preflight", version)
