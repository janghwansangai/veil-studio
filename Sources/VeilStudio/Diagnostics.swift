import Foundation

// Small rotating log in ~/Library/Logs/VeilStudio so failures on a user's Mac can be traced.
enum Log {
    private static let queue = DispatchQueue(label:"studio.veil.log",qos:.utility)
    static var folder: URL { FileManager.default.urls(for:.libraryDirectory,in:.userDomainMask)[0].appendingPathComponent("Logs/VeilStudio",isDirectory:true) }
    static var file: URL { folder.appendingPathComponent("veil.log") }
    static var enabled = true
    static func info(_ message: String) { write("INFO",message) }
    static func error(_ message: String) { write("ERROR",message) }
    private static func write(_ level: String, _ message: String) {
        guard enabled else { return }
        let line = "\(ISO8601DateFormatter().string(from:Date())) [\(level)] \(message.replacingOccurrences(of:"\n",with:" | "))\n"
        queue.async {
            do {
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                if let size = (try? FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.intValue, size > 2_000_000 {
                    let old = folder.appendingPathComponent("veil.1.log")
                    try? FileManager.default.removeItem(at:old); try? FileManager.default.moveItem(at:file,to:old)
                }
                if !FileManager.default.fileExists(atPath:file.path) { FileManager.default.createFile(atPath:file.path,contents:nil) }
                let handle = try FileHandle(forWritingTo:file); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf:Data(line.utf8))
            } catch {}
        }
    }
}

// A marker file exists while the app runs. If it is still there at the next launch the
// previous session ended unexpectedly and the autosaved work can be offered back.
enum SessionGuard {
    static var marker: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VeilStudio/session.running") }
    // Returns true when the previous run did not shut down cleanly.
    @discardableResult static func begin() -> Bool {
        let crashed = FileManager.default.fileExists(atPath:marker.path)
        try? FileManager.default.createDirectory(at:marker.deletingLastPathComponent(),withIntermediateDirectories:true)
        try? Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to:marker,options:.atomic)
        if crashed { Log.error("Previous session did not exit cleanly") }
        return crashed
    }
    static func end() { try? FileManager.default.removeItem(at:marker) }
}

// Keeps the Mac awake and out of App Nap while long analysis or export runs.
final class ActivityToken {
    private var token: NSObjectProtocol?
    func begin(_ reason: String) { if token == nil { token = ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:reason) } }
    func end() { if let token { ProcessInfo.processInfo.endActivity(token) }; token = nil }
    deinit { end() }
}

// Serialises autosave writes off the main thread.
actor RecoveryWriter {
    static let shared = RecoveryWriter()
    private var lastWritten: Project?
    func write(_ project: Project, to url: URL) throws {
        guard project != lastWritten else { return }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(project).write(to:url,options:.atomic)
        lastWritten = project
    }
    func reset() { lastWritten = nil }
}
