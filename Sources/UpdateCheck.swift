import Foundation
import CryptoKit
import Darwin

struct UpdateProbeFailure: Error, LocalizedError {
    let message:String
    var errorDescription:String? { message }
}
private struct ServerFilePin: Decodable {let size:Int64;let sha256:String}
private struct LocalFilePin: Decodable {let size:Int64;let sha:String}
private struct ManifestReceipt: Codable {let url:String;let etag:String;let localStateSHA256:String}
func sha256Data(_ data:Data) -> String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}

// A validator is reusable only for the exact updater state previously matched
// against a complete server manifest. Merely seeing an ETag never trusts it.
func clientNeedsUpdate(root:URL,base:URL,timeout:TimeInterval=4) throws -> Bool {
    let fm=FileManager.default,state=root.appendingPathComponent("client/.nng-state.json")
    guard let bytes=try? Data(contentsOf:state),
          let local=try? JSONDecoder().decode([String:LocalFilePin].self,from:bytes),local.count>=2000,
          fm.fileExists(atPath:root.appendingPathComponent("compat/mac-client/system/l2.exe").path) else {return true}
    let stateSHA=sha256Data(bytes),url=base.appendingPathComponent("manifest.json")
    let cache=root.appendingPathComponent("compat/update-manifest-check.json")
    let receipt=(try? Data(contentsOf:cache)).flatMap{try? JSONDecoder().decode(ManifestReceipt.self,from:$0)}
    var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:timeout)
    request.setValue("no-cache",forHTTPHeaderField:"Cache-Control")
    var validator:String?
    if let receipt,receipt.url==url.absoluteString,receipt.localStateSHA256==stateSHA,!receipt.etag.isEmpty {
        validator=receipt.etag;request.setValue(receipt.etag,forHTTPHeaderField:"If-None-Match")
    }
    let started=Date()
    func fetch(_ request:URLRequest) throws -> (HTTPURLResponse,Data) {
        // The original NNG endpoint is HTTP on a numeric address. Use the same
        // transport as its existing updater, without weakening app-wide ATS.
        let remaining=max(0.05,timeout-Date().timeIntervalSince(started))
        let folder=fm.temporaryDirectory.appendingPathComponent("nng-update-"+UUID().uuidString)
        try fm.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer {try? fm.removeItem(at:folder)}
        let body=folder.appendingPathComponent("body"),headers=folder.appendingPathComponent("headers")
        let p=Process(),output=Pipe(),errors=Pipe(),done=DispatchSemaphore(value:0)
        p.executableURL=URL(fileURLWithPath:"/usr/bin/curl")
        var arguments=["--silent","--show-error","--location","--max-redirs","3","--max-time",String(remaining),"--connect-timeout",String(min(remaining,2)),"--max-filesize","2097152","--output",body.path,"--dump-header",headers.path,"--write-out","%{http_code}"]
        if request.httpMethod=="HEAD" {arguments.append("--head")}
        for (name,value) in request.allHTTPHeaderFields ?? [:] {arguments += ["--header",name+": "+value]}
        arguments.append(url.absoluteString);p.arguments=arguments;p.standardOutput=output;p.standardError=errors;p.standardInput=FileHandle.nullDevice
        p.terminationHandler={_ in done.signal()};try p.run()
        guard done.wait(timeout:.now()+remaining+0.25) == .success else {
            if p.isRunning {p.terminate()}
            throw UpdateProbeFailure(message:"Сервер обновлений не ответил вовремя.")
        }
        guard p.terminationStatus==0 else {throw UpdateProbeFailure(message:"Не удалось связаться с сервером обновлений (код \(p.terminationStatus)).")}
        let codeText=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
        guard let status=Int(codeText.trimmingCharacters(in:.whitespacesAndNewlines)) else {throw UpdateProbeFailure(message:"Неверный ответ сервера обновлений.")}
        var fields=[String:String]()
        for line in ((try? String(contentsOf:headers,encoding:.utf8)) ?? "").components(separatedBy:.newlines) {
            if line.hasPrefix("HTTP/") {fields=[:]}
            else if let colon=line.firstIndex(of:":") {fields[String(line[..<colon])]=String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespacesAndNewlines)}
        }
        guard let http=HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:fields) else {throw UpdateProbeFailure(message:"Неверные заголовки обновления.")}
        return (http,request.httpMethod=="HEAD" ? Data() : ((try? Data(contentsOf:body)) ?? Data()))
    }
    // NNG serves strong ETags but currently ignores conditional GET. HEAD keeps
    // the unchanged path to one request with no manifest body on either server.
    if let validator {
        var head=request;head.httpMethod="HEAD"
        let (response,_)=try fetch(head)
        if response.statusCode==304 || (response.statusCode==200 && response.value(forHTTPHeaderField:"ETag")==validator) {
            print("Update check: HTTP\(response.statusCode) HEAD; unchanged manifest; 0 downloaded body bytes; \(Int(Date().timeIntervalSince(started)*1000)) ms")
            return false
        }
    }
    let (http,data)=try fetch(request)
    if http.statusCode==304,validator != nil {
        print("Update check: HTTP304; unchanged manifest; 0 downloaded bytes; \(Int(Date().timeIntervalSince(started)*1000)) ms")
        return false
    }
    guard http.statusCode==200,data.count<=2*1024*1024,
          let remote=try? JSONDecoder().decode([String:ServerFilePin].self,from:data),remote.count>=2000 else {
        throw UpdateProbeFailure(message:"Сервер обновлений вернул неверный манифест (HTTP \(http.statusCode)).")
    }
    for (path,pin) in remote {
        guard !path.hasPrefix("/"),!path.contains("\\"),!path.split(separator:"/").contains(".."),pin.size>=0,
              pin.sha256.count==64,pin.sha256.allSatisfy({$0.isHexDigit}) else {throw UpdateProbeFailure(message:"Некорректный путь или хеш в манифесте.")}
        if local[path]?.size != pin.size || local[path]?.sha != pin.sha256 {
            print("Update check: changed file \(path); updater required")
            return true
        }
    }
    // An HTTP304 is safe only after ALL remote entries match local state.
    if let etag=http.value(forHTTPHeaderField:"ETag"),!etag.isEmpty {
        try fm.createDirectory(at:cache.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(ManifestReceipt(url:url.absoluteString,etag:etag,localStateSHA256:stateSHA)).write(to:cache,options:.atomic)
    }
    print("Update check: HTTP200; \(remote.count) matching files; \(data.count) manifest bytes; \(Int(Date().timeIntervalSince(started)*1000)) ms")
    return false
}

private struct FileStamp: Codable,Equatable {
    let device:UInt64;let inode:UInt64;let size:Int64
    let modifiedSeconds:Int64;let modifiedNanos:Int64;let changedSeconds:Int64;let changedNanos:Int64
    init(_ value:stat) {
        device=UInt64(UInt32(bitPattern:value.st_dev));inode=UInt64(value.st_ino);size=Int64(value.st_size)
        modifiedSeconds=Int64(value.st_mtimespec.tv_sec);modifiedNanos=Int64(value.st_mtimespec.tv_nsec)
        changedSeconds=Int64(value.st_ctimespec.tv_sec);changedNanos=Int64(value.st_ctimespec.tv_nsec)
    }
}
private struct DigestEntry:Codable {let stamp:FileStamp;let sha256:String}
private struct DigestReceipt:Codable {var version=1;var entries:[String:DigestEntry]}
private final class FileDigestCache {
    let root:URL;let cacheURL:URL;var entries:[String:DigestEntry]=[:];var dirty=false
    var hits=0,hashed=0,hashedBytes:Int64=0
    init(root:URL) {
        self.root=root;cacheURL=root.appendingPathComponent("compat/verified-file-hashes-v1.json")
        if let data=try? Data(contentsOf:cacheURL),let receipt=try? JSONDecoder().decode(DigestReceipt.self,from:data),receipt.version==1 {entries=receipt.entries}
    }
    func digest(_ url:URL,force:Bool) throws -> String {
        // Open then fstat: cache identifies the actual opened inode and catches
        // same-size edits, timestamp restoration and atomic replacements.
        let file=try FileHandle(forReadingFrom:url);defer {try? file.close()}
        var before=stat();guard fstat(file.fileDescriptor,&before)==0 else {throw POSIXError(.EIO)}
        let stamp=FileStamp(before),key=url.standardizedFileURL.path
        if !force,let entry=entries[key],entry.stamp==stamp {hits+=1;return entry.sha256}
        var hash=SHA256()
        while let chunk=try file.read(upToCount:4*1024*1024),!chunk.isEmpty {hash.update(data:chunk)}
        var after=stat();guard fstat(file.fileDescriptor,&after)==0,FileStamp(after)==stamp else {throw POSIXError(.EBUSY)}
        let value=hash.finalize().map{String(format:"%02x",$0)}.joined()
        entries[key]=DigestEntry(stamp:stamp,sha256:value);dirty=true;hashed+=1;hashedBytes+=stamp.size
        return value
    }
    func flush() {
        if dirty {
            do {
                try FileManager.default.createDirectory(at:cacheURL.deletingLastPathComponent(),withIntermediateDirectories:true)
                try JSONEncoder().encode(DigestReceipt(entries:entries)).write(to:cacheURL,options:.atomic)
                try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:cacheURL.path)
                dirty=false
            } catch {print("Verification cache not saved; next launch will hash files again")}
        }
        print("File verification: \(hits) cache hits; \(hashed) hashed; \(hashedBytes) bytes read")
        hits=0;hashed=0;hashedBytes=0
    }
}
private let digestCacheLock=NSRecursiveLock()
private var digestCaches=[String:FileDigestCache]()
func cachedFileDigest(_ url:URL,root:URL) throws -> String {
    digestCacheLock.lock();defer {digestCacheLock.unlock()}
    let key=root.standardizedFileURL.path
    let cache=digestCaches[key] ?? FileDigestCache(root:root);digestCaches[key]=cache
    return try cache.digest(url,force:CommandLine.arguments.contains("--full-verification"))
}
func flushFileDigestCache(root:URL) {
    digestCacheLock.lock();defer {digestCacheLock.unlock()}
    digestCaches[root.standardizedFileURL.path]?.flush()
}
