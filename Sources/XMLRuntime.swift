import Foundation
import CryptoKit
import Darwin

struct XMLRuntimePins:Codable {let version:Int;let files:[String:String];var probeSHA256:String?}
private struct XMLReady:Codable {let version:Int;let provider:String;let probeSHA256:String}
private struct XMLCheckpoint:Codable {var state:String;let registryBefore:[String:String];var provider:String?}
private func xmlError(_ text:String) -> NSError {NSError(domain:"NNGXML",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
private func xmlHash(_ file:URL) throws -> String {
    SHA256.hash(data:try Data(contentsOf:file)).map{String(format:"%02x",$0)}.joined()
}
private func xmlRun(_ executable:URL,_ arguments:[String],_ env:[String:String],timeout:TimeInterval=30) throws -> String {
    let done=DispatchSemaphore(value:0),p=Process(),out=Pipe()
    p.executableURL=executable;p.arguments=arguments;p.environment=env;p.standardInput=FileHandle.nullDevice
    p.standardOutput=out;p.standardError=FileHandle.nullDevice;p.terminationHandler={_ in done.signal()}
    try p.run()
    // Probe/registry commands have bounded, small stdout (the only emitter is
    // our bundled probe). stderr goes to /dev/null to prevent pipe backpressure.
    guard done.wait(timeout:.now()+timeout) == .success else {
        if p.isRunning {p.terminate()}
        if done.wait(timeout:.now()+2) != .success,p.isRunning {_ = Darwin.kill(p.processIdentifier,SIGKILL)}
        throw xmlError("XML: процесс не завершился вовремя. Закройте программы NNG и повторите запуск.")
    }
    guard p.terminationStatus==0 else {throw xmlError("XML: ошибка команды (код \(p.terminationStatus)).")}
    return String(decoding:out.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
}
private func xmlRegistryValue(_ file:URL,section:String,key:String) -> String? {
    guard let text=try? String(contentsOf:file,encoding:.utf8) else {return nil}
    var selected=false
    for line in text.components(separatedBy:.newlines) {
        if line.hasPrefix("["),let end=line.firstIndex(of:"]") {
            let name=String(line[line.index(after:line.startIndex)..<end]).replacingOccurrences(of:"\\\\",with:"\\").lowercased()
            selected=name==section.lowercased();continue
        }
        guard selected,let equals=line.firstIndex(of:"=") else {continue}
        let name=String(line[..<equals]).lowercased()
        guard name==key.lowercased() else {continue}
        let value=String(line[line.index(after:equals)...])
        guard let quote=value.firstIndex(of:"\"") else {return nil}
        return try? JSONDecoder().decode(String.self,from:Data(value[quote...].utf8))
    }
    return nil
}
private func xmlProviderFile(_ provider:String,prefix:URL) -> URL? {
    let head="C:\\nng-runtime\\msxml4\\"
    guard provider.lowercased().hasPrefix(head.lowercased()),provider.lowercased().hasSuffix("\\msxml4.dll") else {return nil}
    let relative=String(provider.dropFirst(3)).replacingOccurrences(of:"\\",with:"/")
    guard !relative.split(separator:"/").contains("..") else {return nil}
    return prefix.appendingPathComponent("drive_c/"+relative)
}
private func xmlNativeFilesMatch(_ provider:String,prefix:URL,pins:XMLRuntimePins) -> Bool {
    guard let dll=xmlProviderFile(provider,prefix:prefix) else {return false}
    return pins.files.allSatisfy {name,sha in (try? xmlHash(dll.deletingLastPathComponent().appendingPathComponent(name)))==sha}
}
private func xmlRegistrationMatches(_ provider:String,prefix:URL) -> Bool {
    let key="Software\\Classes\\Wow6432Node\\CLSID\\{88D969C0-F192-11D4-A65F-0040963251E5}\\InprocServer32"
    let system=xmlRegistryValue(prefix.appendingPathComponent("system.reg"),section:key,key:"@")
    guard system?.lowercased()==provider.lowercased() else {return false}
    // Refuse a conflicting HKCU provider instead of trusting an HKLM-only marker.
    for section in [key,key.replacingOccurrences(of:"Wow6432Node\\",with:"")] {
        if let user=xmlRegistryValue(prefix.appendingPathComponent("user.reg"),section:section,key:"@"),user.lowercased() != provider.lowercased() {return false}
    }
    for name in ["L2.exe","L2.bin"] {
        let value=xmlRegistryValue(prefix.appendingPathComponent("user.reg"),section:"Software\\Wine\\AppDefaults\\"+name+"\\DllOverrides",key:"\"msxml4\"")?.lowercased()
        guard value=="native" || value=="n" else {return false}
    }
    return true
}
private func xmlProbe(wine:URL,probe:URL,environment:[String:String],prefix:URL,pins:XMLRuntimePins) throws -> String? {
    let fm=FileManager.default,folder=fm.temporaryDirectory.appendingPathComponent("nng-xml-"+UUID().uuidString)
    try fm.createDirectory(at:folder,withIntermediateDirectories:true);defer {try? fm.removeItem(at:folder)}
    var provider:String?
    for name in ["L2.exe","L2.bin"] {
        let target=folder.appendingPathComponent(name);try fm.copyItem(at:probe,to:target)
        let output=try xmlRun(wine,[target.path],environment)
        let rows=output.components(separatedBy:.newlines).compactMap{try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]}
        guard rows.count==3,let dom=rows.first(where:{$0["class"] as? String=="DOMDocument40"}),
              let error=rows.first(where:{$0["get_url_hr"] != nil}) else {throw xmlError("XML: неполный ответ 32-битной проверки.")}
        guard dom["hresult"] as? String=="00000000",dom["nonnull"] as? Bool==true,
              error["loaded"] as? Int==0,error["get_url_hr"] as? String=="00000000",error["url_nonnull"] as? Bool==true,
              let path=dom["provider"] as? String,let dll=xmlProviderFile(path,prefix:prefix),
              try xmlHash(dll)==pins.files["msxml4.dll"] else {return nil}
        if let provider,provider.lowercased() != path.lowercased() {return nil}
        provider=path
    }
    return provider
}

// Caller holds the NNG launch lock. No running Wine process is stopped, and no
// registry file is replaced until the matching wineserver confirms idle state.
func ensureNativeXMLRuntime(root:URL,wine:URL,prefix:URL,environment:[String:String],resources:URL) throws {
    let fm=FileManager.default,manifest=resources.appendingPathComponent("xml-runtime.json")
    // Generic imported clients opt in only when this server's pins are supplied.
    guard fm.fileExists(atPath:manifest.path) else {return}
    let pins=try JSONDecoder().decode(XMLRuntimePins.self,from:Data(contentsOf:manifest))
    guard pins.version==1,Set(pins.files.keys)==Set(["msxml4.dll","msxml4a.dll","msxml4r.dll"]),let probeSHA=pins.probeSHA256 else {throw xmlError("Неверный профиль XML runtime.")}
    let probe=resources.appendingPathComponent("xml-runtime/msxml_probe.exe")
    guard try xmlHash(probe)==probeSHA else {throw xmlError("Повреждена проверка XML runtime.")}
    let lock=Darwin.open(prefix.appendingPathComponent(".nng-msxml-repair.lock").path,O_CREAT|O_RDWR,0o600)
    guard lock>=0 else {throw xmlError("Не удалось открыть блокировку XML runtime.")}
    defer {Darwin.close(lock)}
    guard flock(lock,LOCK_EX|LOCK_NB)==0 else {throw xmlError("Другая проверка XML уже работает.")}
    for checkpoint in try fm.contentsOfDirectory(at:prefix,includingPropertiesForKeys:nil) where checkpoint.lastPathComponent.hasPrefix("nng-msxml-backup-") {
        if let data=try? Data(contentsOf:checkpoint.appendingPathComponent("receipt.json")),let receipt=try? JSONDecoder().decode(XMLCheckpoint.self,from:data),receipt.state=="recovery-required" {
            throw xmlError("XML: предыдущий ремонт требует восстановления из checkpoint. Автоматический повтор остановлен.")
        }
    }
    let marker=prefix.appendingPathComponent(".nng-msxml4-v1.json")
    if let data=try? Data(contentsOf:marker),let ready=try? JSONDecoder().decode(XMLReady.self,from:data),ready.version==1,ready.probeSHA256==probeSHA,
       xmlRegistrationMatches(ready.provider,prefix:prefix),let dll=xmlProviderFile(ready.provider,prefix:prefix),
       pins.files.allSatisfy({name,sha in (try? xmlHash(dll.deletingLastPathComponent().appendingPathComponent(name)))==sha}) {
        print("XML runtime: verified native MSXML4; migration not needed");return
    }
    var env=environment;env["WINEPREFIX"]=prefix.path;env["WINEDEBUG"]="-all";env.removeValue(forKey:"WINEARCH")
    let server=wine.deletingLastPathComponent().appendingPathComponent("wineserver");env["WINESERVER"]=server.path
    func quiet() throws {_ = try xmlRun(server,["-w"],env,timeout:12)}
    func saveMarker(_ provider:String) throws {
        try JSONEncoder().encode(XMLReady(version:1,provider:provider,probeSHA256:probeSHA)).write(to:marker,options:.atomic)
    }
    try quiet()
    print("XML runtime: checking missing-schema error path…");fflush(stdout)
    if let provider=try xmlProbe(wine:wine,probe:probe,environment:env,prefix:prefix,pins:pins),xmlRegistrationMatches(provider,prefix:prefix),xmlNativeFilesMatch(provider,prefix:prefix,pins:pins) {
        try quiet();try saveMarker(provider);print("XML runtime: existing repair accepted");return
    }
    let registry=["system.reg","user.reg","userdef.reg"],system=root.appendingPathComponent("compat/mac-client/system")
    for (name,sha) in pins.files {guard try xmlHash(system.appendingPathComponent(name))==sha else {throw xmlError("Непроверенная версия XML-компонента: "+name)}}
    let regsvr=prefix.appendingPathComponent("drive_c/windows/syswow64/regsvr32.exe")
    guard fm.fileExists(atPath:regsvr.path) else {throw xmlError("Нужен 32-битный regsvr32.")}
    try quiet()
    let stamp=UUID().uuidString,checkpoint=prefix.appendingPathComponent("nng-msxml-backup-"+stamp)
    try fm.createDirectory(at:checkpoint,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    var before=[String:String]()
    for name in registry {
        let file=prefix.appendingPathComponent(name),backup=checkpoint.appendingPathComponent(name)
        try fm.copyItem(at:file,to:backup);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path);before[name]=try xmlHash(backup)
    }
    let report=checkpoint.appendingPathComponent("receipt.json")
    var receipt=XMLCheckpoint(state:"prepared",registryBefore:before)
    func saveReport() throws {
        try JSONEncoder().encode(receipt).write(to:report,options:.atomic)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:report.path)
    }
    try saveReport()
    let destination=prefix.appendingPathComponent("drive_c/nng-runtime/msxml4/"+stamp)
    try fm.createDirectory(at:destination,withIntermediateDirectories:true)
    for (name,sha) in pins.files {
        let target=destination.appendingPathComponent(name);try fm.copyItem(at:system.appendingPathComponent(name),to:target)
        guard try xmlHash(target)==sha else {throw xmlError("XML runtime изменился при копировании.")}
    }
    do {
        var native=env
        let groups=(env["WINEDLLOVERRIDES"] ?? "").split(separator:";").compactMap {group -> String? in
            let parts=group.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
            guard parts.count==2 else {return nil}
            let names=parts[0].split(separator:",").filter {!$0.lowercased().replacingOccurrences(of:"*",with:"").replacingOccurrences(of:".dll",with:"").trimmingCharacters(in:.whitespaces).elementsEqual("msxml4")}
            return names.isEmpty ? nil : names.joined(separator:",")+"="+parts[1]
        }
        native["WINEDLLOVERRIDES"]=(groups+["msxml4=n"]).joined(separator:";")
        _ = try xmlRun(wine,["C:\\windows\\syswow64\\regsvr32.exe","/s","C:\\nng-runtime\\msxml4\\"+stamp+"\\msxml4.dll"],native)
        for name in ["L2.exe","L2.bin"] {_ = try xmlRun(wine,["reg","add","HKCU\\Software\\Wine\\AppDefaults\\"+name+"\\DllOverrides","/v","msxml4","/t","REG_SZ","/d","native","/f"],env)}
        guard let provider=try xmlProbe(wine:wine,probe:probe,environment:env,prefix:prefix,pins:pins) else {throw xmlError("XML self-test не пройден.")}
        try quiet()
        guard xmlRegistrationMatches(provider,prefix:prefix) else {throw xmlError("Регистрация MSXML4 не сохранилась.")}
        try saveMarker(provider);receipt.state="applied";receipt.provider=provider;try saveReport()
        print("XML runtime: native MSXML4 repaired; both game-name probes passed")
    } catch {
        let failure=error
        do {
            try quiet()
            for name in registry {
                let backup=checkpoint.appendingPathComponent(name)
                guard try xmlHash(backup)==before[name] else {throw xmlError("Повреждена резервная копия XML.")}
                try Data(contentsOf:backup).write(to:prefix.appendingPathComponent(name),options:.atomic)
            }
            try? fm.removeItem(at:marker);receipt.state="rolled-back";try saveReport()
        } catch {receipt.state="recovery-required";try? saveReport();throw xmlError("XML: требуется восстановление из приватного checkpoint. Остановитесь и откройте журнал.")}
        throw failure
    }
}
