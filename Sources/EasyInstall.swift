import Foundation
import Darwin

struct VendorMember: Decodable { let name:String; let size:Int64; let sha256:String; let source_entry:String }
struct EasyConfiguration: Decodable {
    let version:Int; let client_base:String; let updater_archive:RuntimePin
    let updater:VendorMember; let modules_archive:RuntimePin; let modules:[VendorMember]
}
struct SettingsDelta: Decodable { let offset:Int; let old:Data; let new:Data }
struct SettingsPatch: Decodable { let base_sha256:String; let sha256:String; let patches:[SettingsDelta] }
func easyConfiguration() throws -> EasyConfiguration? {
    let url=Bundle.main.resourceURL!.appendingPathComponent("easy-install.json")
    guard FileManager.default.fileExists(atPath:url.path) else {return nil}
    let value=try JSONDecoder().decode(EasyConfiguration.self,from:Data(contentsOf:url))
    guard value.version==1, value.modules.count==16 else {throw publicError("Неверный профиль установки.")}
    return value
}
func isEasyInstaller() -> Bool { Bundle.main.object(forInfoDictionaryKey:"NNGEasyInstaller") as? Bool == true }
func runSetupProcess(_ p:Process,timeout:TimeInterval,label:String) throws {
    let done=DispatchSemaphore(value:0)
    p.terminationHandler={_ in done.signal()}
    try p.run()
    guard done.wait(timeout:.now()+timeout) == .success else {
        if p.isRunning {p.terminate()}
        if done.wait(timeout:.now()+3) != .success,p.isRunning {_ = Darwin.kill(p.processIdentifier,SIGKILL)}
        throw publicError("Истекло время: "+label+". Повторите подготовку.")
    }
}
func setupStage(_ text:String) { print("NNG_STAGE: "+text);fflush(stdout) }
func rosettaAvailable() -> Bool {
    let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/arch");p.arguments=["-x86_64","/usr/bin/true"]
    p.standardInput=FileHandle.nullDevice;p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
    do {try p.run();p.waitUntilExit();return p.terminationStatus==0} catch {return false}
}
func ensureRosetta(acceptLicense:Bool) throws {
    guard !rosettaAvailable() else {return}
    guard acceptLicense else {throw publicError("Нужна Rosetta. Нажмите «Установить и играть» и подтвердите условия Apple.")}
    setupStage("Устанавливаем Rosetta от Apple…")
    let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/sbin/softwareupdate");p.arguments=["--install-rosetta","--agree-to-license"]
    p.standardInput=FileHandle.nullDevice;try p.run();p.waitUntilExit()
    guard p.terminationStatus==0,rosettaAvailable() else {throw publicError("Apple не смогла установить Rosetta. Проверьте подключение и повторите.")}
}

// The HTTP updater archive has a SHA pinned in the signed app; game updates
// retain the original publisher/updater trust model. No credentials are used.
func acquireSetupArchive(root:URL,pin:RuntimePin) throws -> URL {
    let fm=FileManager.default,cache=root.appendingPathComponent("compat/downloads")
    try fm.createDirectory(at:cache,withIntermediateDirectories:true)
    guard pin.name==URL(fileURLWithPath:pin.name).lastPathComponent,
          let value=pin.url,let url=URL(string:value),["http","https"].contains(url.scheme ?? "") else {throw publicError("Неверный адрес компонента.")}
    let target=cache.appendingPathComponent(pin.name)
    if (try? digest(target))==pin.sha256 {return target}
    let temporary=cache.appendingPathComponent(".download-"+UUID().uuidString)
    defer {try? fm.removeItem(at:temporary)}
    let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/curl")
    // Bounded retry, no shell, no downloaded scripts, output goes to a file.
    p.arguments=["--fail","--location","--silent","--show-error","--retry","2","--connect-timeout","20","--max-time","1800","--output",temporary.path,value]
    p.standardInput=FileHandle.nullDevice;try p.run();p.waitUntilExit()
    guard p.terminationStatus==0 else {throw publicError("Не удалось загрузить "+pin.name+". Повторите — готовые компоненты сохраняются.")}
    guard (try fm.attributesOfItem(atPath:temporary.path)[.size] as? NSNumber)?.int64Value==pin.size,try digest(temporary)==pin.sha256 else {throw publicError("Контрольная сумма не совпала: "+pin.name)}
    if fm.fileExists(atPath:target.path) {try fm.removeItem(at:target)}
    try fm.moveItem(at:temporary,to:target);return target
}
func extractVerifiedMember(archive:URL,member:VendorMember,to target:URL) throws {
    let fm=FileManager.default
    guard member.name==URL(fileURLWithPath:member.name).lastPathComponent,!member.source_entry.contains(".."),!member.source_entry.hasPrefix("/") else {throw publicError("Неверный путь компонента.")}
    if (try? digest(target))==member.sha256 {return}
    try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
    let temp=target.deletingLastPathComponent().appendingPathComponent(".member-"+UUID().uuidString)
    fm.createFile(atPath:temp.path,contents:nil);defer {try? fm.removeItem(at:temp)}
    let file=try FileHandle(forWritingTo:temp);defer {try? file.close()}
    let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/unzip");p.arguments=["-p",archive.path,member.source_entry]
    p.standardInput=FileHandle.nullDevice;p.standardOutput=file;try p.run();p.waitUntilExit();try file.synchronize()
    guard p.terminationStatus==0,(try fm.attributesOfItem(atPath:temp.path)[.size] as? NSNumber)?.int64Value==member.size,try digest(temp)==member.sha256 else {throw publicError("Повреждён компонент: "+member.name)}
    if fm.fileExists(atPath:target.path) {try fm.removeItem(at:target)}
    try fm.moveItem(at:temp,to:target)
}
func installConfigurationPatches(system:URL) throws {
    let patches=try settingsPatches()
    for (name,pin) in patches {
        guard ["L2.ini","User.ini"].contains(name) else {throw publicError("Неверный файл настроек.")}
        let target=system.appendingPathComponent(name)
        guard (try? digest(target))==pin.base_sha256 else {continue}
        var data=try Data(contentsOf:target)
        for delta in pin.patches {
            guard delta.offset>=0,delta.old.count==delta.new.count,delta.offset+delta.old.count<=data.count,
                  data.subdata(in:delta.offset..<delta.offset+delta.old.count)==delta.old else {throw publicError("Профиль настроек не соответствует клиенту.")}
            data.replaceSubrange(delta.offset..<delta.offset+delta.old.count,with:delta.new)
        }
        let temporary=system.appendingPathComponent(".settings-"+UUID().uuidString)
        try data.write(to:temporary);defer {try? FileManager.default.removeItem(at:temporary)}
        guard try digest(temporary)==pin.sha256 else {throw publicError("Неверная сумма настроек.")}
        try data.write(to:target,options:.atomic)
    }
}
func settingsPatches() throws -> [String:SettingsPatch] {
    guard isEasyInstaller() else {return [:]}
    return try JSONDecoder().decode([String:SettingsPatch].self,from:Data(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("settings-patches.json")))
}
func tunedSettingMatches(name:String,base:String,actual:String) throws -> Bool {
    guard name.lowercased()=="l2.ini",let pin=try settingsPatches()["L2.ini"] else {return false}
    return pin.base_sha256==base && pin.sha256==actual
}

func stageManagedClient(root:URL,configuration:EasyConfiguration) throws {
    let fm=FileManager.default,client=root.appendingPathComponent("client"),game=root.appendingPathComponent("compat/mac-client")
    let data=try Data(contentsOf:client.appendingPathComponent(".nng-state.json"))
    let records=try JSONDecoder().decode([String:CachedFile].self,from:data)
    guard records.count>=2000,records["system/l2.exe"] != nil,records["system/Engine.dll"] != nil else {throw publicError("Апдейтер не подготовил полный клиент.")}
    // Validate all manifest paths before using any of them, including symlinks.
    for (name,_) in records {
        guard !name.hasPrefix("/"),!name.contains("\\"),!name.split(separator:"/").contains(where:{$0==".." || $0=="."}),
              client.appendingPathComponent(name).resolvingSymlinksInPath().path.hasPrefix(client.resolvingSymlinksInPath().path+"/") else {throw publicError("Небезопасный путь в клиенте.")}
    }
    let staging=root.appendingPathComponent("compat/.setup-"+UUID().uuidString)
    try fm.createDirectory(at:staging,withIntermediateDirectories:true);defer {try? fm.removeItem(at:staging)}
    let cp=Process();cp.executableURL=URL(fileURLWithPath:"/bin/cp");cp.arguments=["-cR",client.appendingPathComponent("system").path,staging.appendingPathComponent("system").path]
    try cp.run();cp.waitUntilExit();guard cp.terminationStatus==0 else {throw publicError("Не удалось подготовить system/.")}
    let system=staging.appendingPathComponent("system")
    if let iterator=fm.enumerator(at:system,includingPropertiesForKeys:[.isSymbolicLinkKey,.isDirectoryKey]) {
        for case let file as URL in iterator {
            let values=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey]);let low=file.lastPathComponent.lowercased()
            guard values.isSymbolicLink != true else {throw publicError("Ссылки внутри system/ не поддерживаются.")}
            if (values.isDirectory==true && ["log","logs","account","accounts"].contains(low)) || low=="running.ini" || low.hasSuffix(".log") || low.hasSuffix(".lock") {
                if values.isDirectory==true {iterator.skipDescendants()};try fm.removeItem(at:file)
            }
        }
    }
    for name in ["User.ini","Option.ini"] {
        let original=game.appendingPathComponent("system/"+name),target=system.appendingPathComponent(name)
        if fm.fileExists(atPath:original.path) {try Data(contentsOf:original).write(to:target,options:.atomic)}
    }
    let needsModules=configuration.modules.contains {(try? digest(root.appendingPathComponent("compat/vendor-modules/"+$0.name))) != $0.sha256}
    if needsModules {
        setupStage("Загружаем совместимые Mac-модули (498 МБ)…")
        let archive=try acquireSetupArchive(root:root,pin:configuration.modules_archive)
        for member in configuration.modules {try extractVerifiedMember(archive:archive,member:member,to:root.appendingPathComponent("compat/vendor-modules/"+member.name))}
    }
    for member in configuration.modules {try Data(contentsOf:root.appendingPathComponent("compat/vendor-modules/"+member.name)).write(to:system.appendingPathComponent(member.name),options:.atomic)}
    try installConfigurationPatches(system:system)
    for entry in try fm.contentsOfDirectory(at:client,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey]) {
        if entry.lastPathComponent.lowercased()=="system" || entry.lastPathComponent.hasPrefix(".") {continue}
        let values=try entry.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {throw publicError("Неожиданная ссылка клиента.")}
        if values.isDirectory==true {try fm.createSymbolicLink(at:staging.appendingPathComponent(entry.lastPathComponent),withDestinationURL:entry)}
    }
    let backup=root.appendingPathComponent("compat/setup-backups/"+UUID().uuidString)
    if fm.fileExists(atPath:game.path) {try fm.createDirectory(at:backup.deletingLastPathComponent(),withIntermediateDirectories:true);try fm.moveItem(at:game,to:backup)}
    do {try fm.moveItem(at:staging,to:game)} catch {if fm.fileExists(atPath:backup.path) {try? fm.moveItem(at:backup,to:game)};throw error}
    try data.write(to:root.appendingPathComponent("compat/imported-files.json"),options:.atomic)
}
func installLocalFonts(root:URL) throws {
    let fonts=["Tahoma.ttf":"tahoma.ttf","Tahoma Bold.ttf":"tahomabd.ttf","Arial.ttf":"arial.ttf","Arial Bold.ttf":"arialbd.ttf","Arial Italic.ttf":"ariali.ttf","Arial Unicode.ttf":"arialuni.ttf","Verdana.ttf":"verdana.ttf","Verdana Bold.ttf":"verdanab.ttf","Courier New.ttf":"cour.ttf","Times New Roman.ttf":"times.ttf"]
    let target=acceleratedPaths(root:root).prefix.appendingPathComponent("drive_c/windows/Fonts")
    try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
    for (name,destination) in fonts {
        let source=URL(fileURLWithPath:"/System/Library/Fonts/Supplemental/"+name)
        if FileManager.default.fileExists(atPath:source.path) {try Data(contentsOf:source).write(to:target.appendingPathComponent(destination),options:.atomic)}
        else if name=="Tahoma.ttf" {throw publicError("Системный шрифт Tahoma недоступен.")}
    }
}
// Caller holds .launch.lock through setup and the complete game session.
func prepareManagedInstallation(root:URL,acceptRosetta:Bool) throws {
    guard let config=try easyConfiguration() else {throw publicError("Нет профиля сервера.")}
    let fm=FileManager.default
    try fm.createDirectory(at:root.appendingPathComponent("compat"),withIntermediateDirectories:true)
    let volume=try root.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])
    let probeName="nngcase"+UUID().uuidString.lowercased()+".probe",probe=root.appendingPathComponent(probeName)
    try Data([1]).write(to:probe);defer {try? fm.removeItem(at:probe)}
    guard fm.fileExists(atPath:root.appendingPathComponent(probeName.uppercased()).path) else {throw publicError("Нужен том без различия регистра имён файлов.")}
    guard (volume.volumeAvailableCapacityForImportantUsage ?? 0)>20*1024*1024*1024 else {throw publicError("Для установки освободите не менее 20 ГБ.")}
    try ensureRosetta(acceptLicense:acceptRosetta)
    setupStage("Загружаем и проверяем апдейтер…")
    let archive=try acquireSetupArchive(root:root,pin:config.updater_archive),client=root.appendingPathComponent("client")
    try fm.createDirectory(at:client,withIntermediateDirectories:true)
    let updater=client.appendingPathComponent("nng-updater")
    try extractVerifiedMember(archive:archive,member:config.updater,to:updater)
    try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:updater.path)
    setupStage("Апдейтер скачивает клиент (~11 ГБ). Можно оставить окно открытым…")
    let p=Process();p.executableURL=updater;p.arguments=["-nolaunch","-base",config.client_base];p.currentDirectoryURL=client;p.standardInput=FileHandle.nullDevice
    try p.run();p.waitUntilExit();guard p.terminationStatus==0 else {throw publicError("Апдейтер не завершил загрузку. Нажмите «Повторить» — скачанное сохранено.")}
    setupStage("Готовим совместимый клиент…")
    try stageManagedClient(root:root,configuration:config)
    setupStage("Готовим Wine, Metal и ускорение x87…")
    try prepareAcceleratedRuntime(root:root);try installLocalFonts(root:root)
    setupStage("Проверяем готовую установку…")
    guard try verifyGameInstallation(root:root) else {throw publicError("Итоговая проверка клиента не пройдена.")}
    try Data("{\"version\":1}\n".utf8).write(to:root.appendingPathComponent("compat/easy-ready.json"),options:.atomic)
    setupStage("Установка завершена")
}
