import Foundation

/// 大量小文件拷贝基准测试。
///
/// 用法：
///   bash Tests/run_tests.sh --benchmark
///   bash Tests/run_tests.sh --benchmark 10000 4096
///   bash Tests/run_tests.sh --benchmark 10000 4096 /Volumes/SMBShare
///
/// 参数依次为：文件数（默认 5000）、单文件字节数（默认 4096）、目标根目录（默认系统临时目录）。
/// 指定网络共享挂载点时，会在该卷上创建并清理一个临时目录，用于测真实 RTT 下的吞吐。
func runBenchmarks(arguments: [String]) async throws {
    let count = Int(arguments.first ?? "") ?? 5000
    let fileSize = Int(arguments.dropFirst().first ?? "") ?? 4096
    let baseRoot: URL
    if let custom = arguments.dropFirst(2).first {
        baseRoot = URL(fileURLWithPath: custom, isDirectory: true)
    } else {
        baseRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    guard count > 0, fileSize > 0 else {
        throw TestFailure.failed("文件数与文件大小必须为正数")
    }

    let root = baseRoot.appendingPathComponent("afile-benchmark-\(UUID().uuidString)", isDirectory: true)
    let a = root.appendingPathComponent("A", isDirectory: true)
    let b = root.appendingPathComponent("B", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: a, withIntermediateDirectories: true)
    try fm.createDirectory(at: b, withIntermediateDirectories: true)
    defer { cleanup(root) }

    print("benchmark root: \(root.path)")
    print("files: \(count), file size: \(fileSize) B")

    let payload = Data(repeating: 0x41, count: fileSize)
    for index in 0..<count {
        try payload.write(to: a.appendingPathComponent(fileName(index)), options: .atomic)
    }

    // 1) 扫描 + 对比（目标为空）：衡量逐文件元数据读取成本。
    let service = FileMergeService()
    var start = Date()
    _ = try await service.compare(
        sourceRoot: a,
        destinationRoot: b,
        includeHiddenItems: true,
        strictMD5: false
    )
    printResult("compare (empty destination)", elapsed: Date().timeIntervalSince(start), count: count, bytes: Int64(count) * Int64(fileSize))

    // 2) 新建拷贝：目标为空，走并发复制。
    start = Date()
    _ = try await service.mergeLeftToRight(
        sourceRoot: a,
        destinationRoot: b,
        includeHiddenItems: true,
        strictMD5: false
    )
    printResult("copy new files", elapsed: Date().timeIntervalSince(start), count: count, bytes: Int64(count) * Int64(fileSize))

    // 3) 覆盖拷贝：目标文件大小不同（避免哈希），强制走覆盖路径。
    try? fm.removeItem(at: b)
    try fm.createDirectory(at: b, withIntermediateDirectories: true)
    let olderPayload = Data(repeating: 0x42, count: max(1, fileSize / 2))
    for index in 0..<count {
        try olderPayload.write(to: b.appendingPathComponent(fileName(index)), options: .atomic)
    }

    start = Date()
    _ = try await service.mergeLeftToRight(
        sourceRoot: a,
        destinationRoot: b,
        includeHiddenItems: true,
        strictMD5: false
    )
    printResult("copy overwrite", elapsed: Date().timeIntervalSince(start), count: count, bytes: Int64(count) * Int64(fileSize))

    // 4) 删除目标独有文件：空源 + 覆盖模式，目标 count 个文件全部删除。
    let c = root.appendingPathComponent("C", isDirectory: true)
    try fm.createDirectory(at: c, withIntermediateDirectories: true)
    try? fm.removeItem(at: b)
    try fm.createDirectory(at: b, withIntermediateDirectories: true)
    for index in 0..<count {
        try payload.write(to: b.appendingPathComponent("old-\(fileName(index))"), options: .atomic)
    }

    start = Date()
    _ = try await service.overwriteLeftToRight(
        sourceRoot: c,
        destinationRoot: b,
        includeHiddenItems: true,
        strictMD5: false
    )
    printResult("delete destination-only", elapsed: Date().timeIntervalSince(start), count: count, bytes: nil)
}

private func fileName(_ index: Int) -> String {
    String(format: "f-%06d.bin", index)
}

private func printResult(_ name: String, elapsed: TimeInterval, count: Int, bytes: Int64?) {
    let filesPerSecond = elapsed > 0 ? Double(count) / elapsed : 0
    let paddedName = name.padding(toLength: 28, withPad: " ", startingAt: 0)
    let throughput: String
    if let bytes, elapsed > 0 {
        let megabytesPerSecond = Double(bytes) / elapsed / (1024 * 1024)
        throughput = String(format: "%8.2f MB/s", megabytesPerSecond)
    } else {
        throughput = "          —"
    }
    print("\(paddedName) \(String(format: "%7.2f", elapsed)) s | \(String(format: "%8.0f", filesPerSecond)) files/s | \(throughput)")
}
