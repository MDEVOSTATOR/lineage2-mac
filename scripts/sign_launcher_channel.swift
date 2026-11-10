#!/usr/bin/swift
import CryptoKit
import Darwin
import Foundation

struct Release: Encodable {
    let version: String
    let tag: String
    let size: Int
    let sha256: String
    let asset: String
}

struct Feed: Encodable {
    let schema = 1
    let releases: [String: Release]
}

struct SignedFeed: Encodable {
    let payload: Data
    let signature: Data
}

func require(_ condition: Bool, _ message: String) {
    if !condition { fputs(message + "\n", stderr); exit(1) }
}

let arguments = Array(CommandLine.arguments.dropFirst())
require(arguments.count == 2 || arguments.count == 8,
        "Usage: swift sign_launcher_channel.swift init KEY | sign KEY PUBLIC_KEY TAG EASY_VERSION EASY_BINARY INSTALLED_VERSION INSTALLED_BINARY")
let keyPath = URL(fileURLWithPath: arguments[1])
if arguments[0] == "init", arguments.count == 2 {
    let key = Curve25519.Signing.PrivateKey()
    let fd = Darwin.open(keyPath.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
    require(fd >= 0, "Cannot create a new private key. Existing keys are preserved.")
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try file.write(contentsOf: key.rawRepresentation)
    try file.close()
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}
require(arguments.count == 8 && arguments[0] == "sign", "Expected sign and both launcher targets.")
let fd = Darwin.open(keyPath.path, O_RDONLY | O_NOFOLLOW)
require(fd >= 0, "Cannot open the private key.")
let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
var keyStat = stat()
require(fstat(fd, &keyStat) == 0 && keyStat.st_mode & S_IFMT == S_IFREG &&
        keyStat.st_mode & 0o777 == 0o600 && keyStat.st_uid == getuid() && keyStat.st_size == 32,
        "The private key must be a 32-byte regular file owned by this user with mode 600.")
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: file.readToEnd() ?? Data())
let pinnedPublicKey = try String(contentsOfFile: arguments[2], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
require(key.publicKey.rawRepresentation.base64EncodedString() == pinnedPublicKey,
        "Private key does not match the public key pinned by the app.")
func release(version: String, binary: String, asset: String) throws -> Release {
    let data = try Data(contentsOf: URL(fileURLWithPath: binary))
    require(data.count > 0 && data.count <= 8 * 1024 * 1024, "Invalid launcher binary size.")
    return Release(version: version, tag: arguments[3], size: data.count,
                   sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), asset: asset)
}

let feed = try Feed(releases: [
    "ru.nng.macclient.easy": release(version: arguments[4], binary: arguments[5], asset: "NNG-Mac-Easy-launcher-arm64"),
    "ru.nng.macclient": release(version: arguments[6], binary: arguments[7], asset: "NNG-Mac-Installed-launcher-arm64")
])
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
let payload = try encoder.encode(feed)
encoder.outputFormatting.insert(.prettyPrinted)
let signed = try encoder.encode(SignedFeed(payload: payload, signature: key.signature(for: payload)))
print(String(decoding: signed, as: UTF8.self))
