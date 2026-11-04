import Foundation

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

enum Shell {
    struct Result {
        var status: Int32
        var output: String
        var timedOut: Bool
    }

    static func find(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.orbstack/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/\(name)" }
        return (fromPath + candidates).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `mergeErrors` puts standard error into `output` too, for messages shown to people.
    static func run(_ executable: String, _ arguments: [String], cwd: String? = nil, timeout: TimeInterval = 20, mergeErrors: Bool = false) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        var environment = ProcessInfo.processInfo.environment
        // Read-only git calls must not take the index lock of a worktree someone is using.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = mergeErrors ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "", timedOut: false)
        }
        let timedOut = Locked(false)
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self),
            timedOut: timedOut.withLock { $0 }
        )
    }
}

func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

func modificationDate(of path: String) -> Date? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

public func displayPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    guard path.hasPrefix(home) else { return path }
    return "~" + path.dropFirst(home.count)
}
