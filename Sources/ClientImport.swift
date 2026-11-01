import Foundation
import Darwin


func publicError(_ message:String) -> NSError { NSError(domain:"NNGCommunity",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }

// Publisher URL and checksum are part of the signed app, not a game-server manifest.
func acquireWineArchive(root:URL,pin:RuntimePin) throws -> URL {
    let fm=FileManager.default,folder=root.appendingPathComponent("compat/downloads")
    try fm.createDirectory(at:folder,withIntermediateDirectories:true)
    let target=folder.appendingPathComponent(pin.name)
    if (try? digest(target)) == pin.sha256 { return target }
    guard let value=pin.url,let url=URL(string:value),url.scheme=="https",url.host=="github.com" else {throw publicError("Нет проверенного адреса Wine.")}
    print("Downloading pinned Wine runtime from GitHub (235 MB)…")
    let done=DispatchSemaphore(value:0)
    var downloaded:URL?,failure:Error?
    let task=URLSession.shared.downloadTask(with:url) {temporary,response,error in
        defer {done.signal()}
        if let error {failure=error;return}
        guard let temporary,let http=response as? HTTPURLResponse,http.statusCode==200 else {failure=publicError("Сервер загрузки Wine вернул ошибку.");return}
        let local=folder.appendingPathComponent(".wine-"+UUID().uuidString)
        do {try fm.moveItem(at:temporary,to:local);downloaded=local} catch {failure=error}
    }
    task.resume()
    guard done.wait(timeout:.now()+900) == .success else {task.cancel();throw publicError("Истекло время загрузки Wine.")}
    if let failure {throw failure}
    guard let downloaded else {throw publicError("Загрузка Wine не завершилась.")}
    defer {try? fm.removeItem(at:downloaded)}
    guard (try fm.attributesOfItem(atPath:downloaded.path)[.size] as? NSNumber)?.int64Value==pin.size,try digest(downloaded)==pin.sha256 else {throw publicError("Контрольная сумма Wine не совпала.")}
    if fm.fileExists(atPath:target.path) {try fm.removeItem(at:target)}
    try fm.moveItem(at:downloaded,to:target)
    return target
}

// Import a compatible, user-supplied client. Copy only system/, share asset
// folders read-only by convention; never modify the selected source directory.
func importClient(from source:URL,root:URL) throws {
    let fm=FileManager.default,source=source.resolvingSymlinksInPath().standardizedFileURL,root=root.resolvingSymlinksInPath().standardizedFileURL
    guard !source.path.hasPrefix(root.standardizedFileURL.path+"/"),source != root,
          fm.fileExists(atPath:source.appendingPathComponent("system/l2.exe").path),
          fm.fileExists(atPath:source.appendingPathComponent("system/Engine.dll").path) else {
        throw publicError("Нужна внешняя совместимая папка клиента с system/l2.exe и Engine.dll.")
    }
    try fm.createDirectory(at:root.appendingPathComponent("compat"),withIntermediateDirectories:true)
    let lockURL=root.appendingPathComponent(".launch.lock")
    let fd=Darwin.open(lockURL.path,O_CREAT|O_RDWR,0o600)
    guard fd>=0 else {throw publicError("Не удалось открыть блокировку клиента.")}
    defer {Darwin.close(fd)}
    guard flock(fd,LOCK_EX|LOCK_NB)==0 else {throw publicError("Сначала закройте игру.")}
    let staging=root.appendingPathComponent("compat/.import-"+UUID().uuidString)
    try fm.createDirectory(at:staging,withIntermediateDirectories:true)
    defer {try? fm.removeItem(at:staging)}
    let cp=Process();cp.executableURL=URL(fileURLWithPath:"/bin/cp")
    cp.arguments=["-cR",source.appendingPathComponent("system").path,staging.appendingPathComponent("system").path]
    try cp.run();cp.waitUntilExit()
    guard cp.terminationStatus==0 else {throw publicError("Не удалось скопировать system/. Исходная папка сохранена.")}
    var records=[String:[String:Any]]()
    let excluded=Set(["logs","log","accounts","account"])
    let system=staging.appendingPathComponent("system").resolvingSymlinksInPath()
    let iterator=fm.enumerator(at:system,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.isDirectoryKey])!
    for case let file as URL in iterator {
        let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.isDirectoryKey])
        let lower=file.lastPathComponent.lowercased()
        if values.isDirectory==true && excluded.contains(lower) {iterator.skipDescendants();try fm.removeItem(at:file);continue}
        guard values.isSymbolicLink != true else {throw publicError("Ссылки внутри system/ не поддерживаются.")}
        if values.isRegularFile != true {continue}
        if lower=="running.ini" || lower.hasSuffix(".log") || lower.hasSuffix(".lock") {try fm.removeItem(at:file);continue}
        // The game owns these mutable files. Do not make them integrity pins.
        if ["option.ini","user.ini","s_info.ini","mtld3d.conf"].contains(lower) {continue}
        let relative="system/"+String(file.resolvingSymlinksInPath().path.dropFirst(system.path.count+1))
        records[relative]=["size":(try fm.attributesOfItem(atPath:file.path)[.size] as! NSNumber).int64Value,"sha":try digest(file)]
    }
    for folder in try fm.contentsOfDirectory(at:source,includingPropertiesForKeys:[.isDirectoryKey]) {
        if folder.lastPathComponent.lowercased()=="system" || folder.lastPathComponent.hasPrefix(".") {continue}
        var isDirectory:ObjCBool=false
        if fm.fileExists(atPath:folder.path,isDirectory:&isDirectory),isDirectory.boolValue {
            try fm.createSymbolicLink(at:staging.appendingPathComponent(folder.lastPathComponent),withDestinationURL:folder)
        }
    }
    let client=root.appendingPathComponent("client"),game=root.appendingPathComponent("compat/mac-client")
    if fm.fileExists(atPath:client.path) || (try? fm.destinationOfSymbolicLink(atPath:client.path)) != nil {
        guard (try? fm.destinationOfSymbolicLink(atPath:client.path)) != nil else {throw publicError("Существующая папка client сохранена. Используйте чистую папку состояния.")}
    }
    if fm.fileExists(atPath:game.path) {
        let backups=root.appendingPathComponent("compat/import-backups")
        try fm.createDirectory(at:backups,withIntermediateDirectories:true)
        try fm.moveItem(at:game,to:backups.appendingPathComponent(UUID().uuidString))
    }
    if (try? fm.destinationOfSymbolicLink(atPath:client.path)) != nil {try fm.removeItem(at:client)}
    try fm.createSymbolicLink(at:client,withDestinationURL:source)
    try fm.moveItem(at:staging,to:game)
    try JSONSerialization.data(withJSONObject:records,options:.sortedKeys).write(to:root.appendingPathComponent("compat/imported-files.json"),options:.atomic)
}

func applyGamePolicy(root:URL) throws {
    let fm=FileManager.default,paths=acceleratedPaths(root:root)
    let reg=paths.prefix.appendingPathComponent("nng-community-policy.reg")
    let text="""
    Windows Registry Editor Version 5.00

    [HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\l2.exe]
    "Version"="win7"

    [HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\l2.exe\\Mac Driver]
    "AllowSetGamma"="N"
    "UsePreciseScrolling"="n"
    "LeftOptionIsAlt"="y"
    "RightOptionIsAlt"="y"
    """+"\n"
    var bytes=Data([0xff,0xfe]);bytes.append(text.data(using:.utf16LittleEndian)!)
    try bytes.write(to:reg,options:.atomic)
    let process=Process();process.executableURL=paths.wine;process.arguments=["regedit","/S",reg.path]
    process.environment=acceleratedEnvironment(root:root,source:ProcessInfo.processInfo.environment)
    process.standardInput=FileHandle.nullDevice
    try runSetupProcess(process,timeout:30,label:"настройка Wine")
    guard process.terminationStatus==0 else {throw publicError("Не удалось применить настройки Wine.")}
    let system=root.appendingPathComponent("compat/mac-client/system")
    try fm.createDirectory(at:system,withIntermediateDirectories:true)
    let config=system.appendingPathComponent("mtld3d.conf")
    let old=(try? String(contentsOf:config,encoding:.utf8)) ?? ""
    var lines=old.components(separatedBy:.newlines).filter {line in
        let t=line.trimmingCharacters(in:.whitespaces);return !t.hasPrefix("color.hdr.enable=") && !t.hasPrefix("color.space=")
    }
    lines += ["color.hdr.enable=false","color.space=accurate",""]
    try lines.joined(separator:"\n").write(to:config,atomically:true,encoding:.utf8)
}
