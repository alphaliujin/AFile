import Darwin
import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

func expect(_ condition: Bool, _ message: String, line: UInt = #line) throws {
    if !condition {
        throw TestFailure.failed("断言失败（line \(line)）：\(message)")
    }
}

func makeTempRoot(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("afile-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
func makeFile(_ root: URL, _ relativePath: String, _ contents: String = "x") throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: false, encoding: .utf8)
    return url
}

@discardableResult
func makeDirectory(_ root: URL, _ relativePath: String) throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func chmod(_ url: URL, _ permissions: Int) throws {
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}

func makeSymlink(_ root: URL, _ relativePath: String, to target: URL) throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    return url
}

func makeFIFO(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard mkfifo(url.path, 0o644) == 0 else {
        throw TestFailure.failed("mkfifo 失败：\(String(cString: strerror(errno)))")
    }
}

func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
}

func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var maxCompleted: Int64 = 0
    private var maxTotal: Int64 = 0

    var maxCompletedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return maxCompleted
    }

    var maxTotalBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return maxTotal
    }

    var handler: FileMergeService.ProgressHandler {
        { [weak self] progress in
            guard let self,
                  progress.phase == .copying,
                  let completed = progress.completedBytes,
                  let total = progress.totalBytes else { return }
            self.lock.lock()
            self.maxCompleted = max(self.maxCompleted, completed)
            self.maxTotal = max(self.maxTotal, total)
            self.lock.unlock()
        }
    }
}

func fileContents(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

func cleanup(_ root: URL) {
    let fm = FileManager.default
    func unlock(_ url: URL) {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        if let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for child in children { unlock(child) }
        }
    }
    unlock(root)
    try? fm.removeItem(at: root)
}
