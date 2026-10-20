import Darwin
import Foundation

struct TestCase {
    let name: String
    let run: () async throws -> Void
}

@main
struct MergeServiceTestRunner {
    static func main() async {
        let filter = CommandLine.arguments.dropFirst().first
        let all: [TestCase] = [
            TestCase(name: "unreadableSourceSubtreeDoesNotDeleteDestination", run: unreadableSourceSubtreeDoesNotDeleteDestination),
            TestCase(name: "unreadableSourceRootThrowsAndKeepsDestination", run: unreadableSourceRootThrowsAndKeepsDestination),
            TestCase(name: "nestedDestinationSymlinkRejected", run: nestedDestinationSymlinkRejected),
            TestCase(name: "rootAncestorCheck", run: rootAncestorCheck),
            TestCase(name: "failedDeletionIsReportedAsError", run: failedDeletionIsReportedAsError),
            TestCase(name: "retryIsDisabledAfterPathEdit", run: retryIsDisabledAfterPathEdit),
            TestCase(name: "destinationSymlinkIsReplacedBySourceFile", run: destinationSymlinkIsReplacedBySourceFile),
            TestCase(name: "overwriteDeletesDestinationOnlySymlink", run: overwriteDeletesDestinationOnlySymlink),
            TestCase(name: "longFileNameIsCopied", run: longFileNameIsCopied),
            TestCase(name: "streamsEqualRejectsOneSidedEOF", run: streamsEqualRejectsOneSidedEOF),
            TestCase(name: "unchangedFilesDoNotInflateCopyBytes", run: unchangedFilesDoNotInflateCopyBytes),
            TestCase(name: "directoryCacheSuccessClearsFailure", run: directoryCacheSuccessClearsFailure),
            TestCase(name: "statisticsIncludeIdenticalFiles", run: statisticsIncludeIdenticalFiles),
            TestCase(name: "mergeDoesNotDeleteDestinationDirectoryOnTypeMismatch", run: mergeDoesNotDeleteDestinationDirectoryOnTypeMismatch),
            TestCase(name: "specialFileDoesNotParticipateInSync", run: specialFileDoesNotParticipateInSync),
            TestCase(name: "settingsChangeInvalidatesReview", run: settingsChangeInvalidatesReview),
            TestCase(name: "mirroredItemSwapsDirection", run: mirroredItemSwapsDirection),
            TestCase(name: "disconnectErrorClassification", run: disconnectErrorClassification),
            TestCase(name: "remoteVolumeUsesTheItemPath", run: remoteVolumeUsesTheItemPath),
            TestCase(name: "concurrentCopyFailureIsRecordedInSummary", run: concurrentCopyFailureIsRecordedInSummary),
            TestCase(name: "missingDestinationUnderSymlinkIsRejected", run: missingDestinationUnderSymlinkIsRejected),
        ]
        let selected = filter.map { name in all.filter { $0.name == name } } ?? all
        if selected.isEmpty {
            print("没有匹配的测试：\(filter ?? "")")
            exit(2)
        }

        var failures = 0
        for test in selected {
            do {
                try await test.run()
                print("PASS  \(test.name)")
            } catch {
                failures += 1
                print("FAIL  \(test.name)")
                print("      \(error)")
            }
        }
        print("---")
        print("\(selected.count - failures)/\(selected.count) passed")
        exit(failures == 0 ? 0 : 1)
    }
}

// MARK: - Tests

func unreadableSourceSubtreeDoesNotDeleteDestination() async throws {
    let root = try makeTempRoot("unreadable-subtree")
    defer { cleanup(root) }
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try makeDirectory(root, "A/sub")
    try makeDirectory(root, "B/sub")
    try makeFile(a, "sub/x.txt", "hello")
    let destinationFile = try makeFile(b, "sub/x.txt", "hello")

    try chmod(a.appendingPathComponent("sub"), 0o000)
    defer { try? chmod(a.appendingPathComponent("sub"), 0o755) }

    _ = try await FileMergeService().overwriteLeftToRight(
        sourceRoot: a,
        destinationRoot: b,
        includeHiddenItems: true,
        strictMD5: true
    )

    try expect(FileManager.default.fileExists(atPath: destinationFile.path),
               "源子目录不可读时，目标中的对应文件不能被删除")
}

func unreadableSourceRootThrowsAndKeepsDestination() async throws {
    let root = try makeTempRoot("unreadable-root")
    defer { cleanup(root) }
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try makeDirectory(root, "A")
    try makeDirectory(root, "B")
    let destinationFile = try makeFile(b, "keep.txt", "keep")

    try chmod(a, 0o000)
    defer { try? chmod(a, 0o755) }

    do {
        _ = try await FileMergeService().overwriteLeftToRight(
            sourceRoot: a,
            destinationRoot: b,
            includeHiddenItems: true,
            strictMD5: true
        )
        throw TestFailure.failed("源根目录不可读时应抛出错误，而不是按空目录继续")
    } catch is TestFailure {
        throw TestFailure.failed("源根目录不可读时应抛出错误，而不是按空目录继续")
    } catch {
        // 期望的错误
    }

    try expect(FileManager.default.fileExists(atPath: destinationFile.path),
               "源根目录不可读时，目标内容不能被删除")
}

func nestedDestinationSymlinkRejected() async throws {
    let root = try makeTempRoot("nested-symlink")
    defer { cleanup(root) }
    let a = root.appendingPathComponent("A")
    try makeDirectory(a, "sub")
    try makeFile(a, "sub/x.txt", "x")
    let link = root.appendingPathComponent("B")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a.appendingPathComponent("sub"))

    do {
        _ = try await FileMergeService().compare(sourceRoot: a, destinationRoot: link)
        throw TestFailure.failed("目标指向源子目录的符号链接应被父子关系校验拒绝")
    } catch is TestFailure {
        throw TestFailure.failed("目标指向源子目录的符号链接应被父子关系校验拒绝")
    } catch {
        try expect(error.localizedDescription.contains("父子"),
                   "应抛出父子包含关系错误，实际：\(error.localizedDescription)")
    }
}

func rootAncestorCheck() throws {
    let service = FileMergeService()
    try expect(service.isAncestor("/", of: "/Users/me/backup"), "根路径必须是任意绝对路径的祖先")
    try expect(service.isAncestor("/Users/me", of: "/Users/me/backup"), "普通祖先路径判断应成立")
    try expect(!service.isAncestor("/Users/me", of: "/Users/metrics"), "前缀相同的兄弟目录不能被误判为祖先")
}

func failedDeletionIsReportedAsError() async throws {
    let root = try makeTempRoot("failed-delete")
    defer { cleanup(root) }
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try makeDirectory(root, "A")
    try makeDirectory(root, "B")
    try makeFile(b, "locked.txt", "keep")

    // 目标根目录去掉写权限：removeItem 会失败，但扫描仍可读。
    try chmod(b, 0o555)
    defer { try? chmod(b, 0o755) }

    let summary = try await FileMergeService().overwriteLeftToRight(
        sourceRoot: a,
        destinationRoot: b,
        includeHiddenItems: true,
        strictMD5: true
    )

    let item = summary.items.first { $0.relativePath == "locked.txt" }
    try expect(item != nil, "删除失败的条目必须保留在结果中")
    try expect(item?.status == .error, "删除失败必须标记为 .error，而不是 .same")
    try expect(summary.hasErrors, "删除失败必须计入 summary.errors")
    try expect(FileManager.default.fileExists(atPath: b.appendingPathComponent("locked.txt").path),
               "删除失败时文件应仍然存在")
}

@MainActor
func retryIsDisabledAfterPathEdit() async throws {
    let root = try makeTempRoot("retry-stale-path")
    defer { cleanup(root) }
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try makeDirectory(root, "A")
    try makeDirectory(root, "B")
    try makeFile(a, "new.txt", "data")

    // 目标不可写，制造一个复制失败项。
    try chmod(b, 0o555)
    defer { try? chmod(b, 0o755) }

    let viewModel = FileCompareViewModel()
    viewModel.sourcePath = a.path
    viewModel.destinationPath = b.path
    viewModel.mergeLeftToRight()

    let deadline = Date().addingTimeInterval(15)
    while viewModel.isWorking && Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    try expect(!viewModel.isWorking, "同步应在超时前结束")
    try expect(viewModel.canRetry, "存在失败项时应允许重试")

    viewModel.sourcePath = root.appendingPathComponent("C").path
    try expect(!viewModel.canRetry,
               "修改路径后必须禁用重试，否则会在旧目录上执行覆盖")
}

func destinationSymlinkIsReplacedBySourceFile() async throws {
    let root = try makeTempRoot("dest-symlink")
    defer { cleanup(root) }
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try makeDirectory(root, "A")
    try makeDirectory(root, "B")
    try makeFile(a, "f.txt", "new")
    let outsideTarget = try makeFile(root, "target.txt", "old")
    let link = try makeSymlink(b, "f.txt", to: outsideTarget)

    _ = try await FileMergeService().mergeLeftToRight(
        sourceRoot: a,
        destinationRoot: b,
        includeHiddenItems: true,
        strictMD5: true
    )

    try expect(!isSymbolicLink(link), "同名源文件必须替换目标符号链接")
    try expect(fileContents(link) == "new", "替换后内容应为源文件内容")
    try expect(fileContents(outsideTarget) == "old", "不能写入符号链接原本指向的文件")
}

func overwriteDeletesDestinationOnlySymlink() async throws {
    let root = try makeTempRoot("dest-only-symlink")
    defer { cleanup(root) }
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try makeDirectory(root, "A")
    try makeDirectory(root, "B")
    let outsideTarget = try makeFile(root, "target.txt", "old")
    let link = try makeSymlink(b, "only-b.txt", to: outsideTarget)

    _ = try await FileMergeService().overwriteLeftToRight(
        sourceRoot: a,
        destinationRoot: b,
        includeHiddenItems: true,
        strictMD5: true
    )

    try expect(!FileManager.default.fileExists(atPath: link.path),
               "覆盖模式必须删除目标独有的符号链接")
    try expect(FileManager.default.fileExists(atPath: outsideTarget.path),
               "删除符号链接不能删除其指向的文件")
}

func longFileNameIsCopied() async throws {
    let root = try makeTempRoot("long-name")
    defer { cleanup(root) }
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try makeDirectory(root, "A")
    try makeDirectory(root, "B")
    let name = String(repeating: "a", count: 240)
    try makeFile(a, name, "long-name-content")

    _ = try await FileMergeService().mergeLeftToRight(
        sourceRoot: a,
        destinationRoot: b,
        includeHiddenItems: true,
        strictMD5: true
    )

    try expect(FileManager.default.fileExists(atPath: b.appendingPathComponent(name).path),
               "240 字节的合法文件名必须能够复制")
}

func streamsEqualRejectsOneSidedEOF() throws {
    let root = try makeTempRoot("streams-eof")
    defer { cleanup(root) }
    let empty = try makeFile(root, "empty.txt", "")
    let five = try makeFile(root, "five.txt", "12345")

    // 模拟扫描后文件被改动：调用方仍认为两端大小都是 5。
    let equal = try FileMergeService().streamsEqual(
        sourceURL: empty,
        destinationURL: five,
        sourceSize: 5,
        destinationSize: 5
    )
    try expect(!equal, "一端提前 EOF 时必须判为不同，不能误判为相同")
}

func unchangedFilesDoNotInflateCopyBytes() async throws {
    let root = try makeTempRoot("same-bytes")
    defer { cleanup(root) }
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try makeDirectory(root, "A")
    try makeDirectory(root, "B")
    for index in 0..<3 {
        let source = try makeFile(a, "same-\(index).txt", "identical-content-\(index)")
        try FileManager.default.copyItem(at: source, to: b.appendingPathComponent("same-\(index).txt"))
    }
    try makeFile(a, "new.txt", "new")

    let recorder = ProgressRecorder()
    _ = try await FileMergeService().mergeLeftToRight(
        sourceRoot: a,
        destinationRoot: b,
        includeHiddenItems: true,
        strictMD5: false,
        progress: recorder.handler
    )

    try expect(recorder.maxTotalBytes > 0, "应上报拷贝字节总量")
    try expect(recorder.maxCompletedBytes <= recorder.maxTotalBytes,
               "已完成字节 \(recorder.maxCompletedBytes) 不应超过总量 \(recorder.maxTotalBytes)")
}

func directoryCacheSuccessClearsFailure() throws {
    let cache = FileMergeService.DirectoryCreationCache()
    cache.markFailed("/a/b")
    try expect(cache.hasFailed("/a/b"), "失败标记应生效")
    cache.markSucceeded("/a/b")
    try expect(!cache.hasFailed("/a/b"), "成功创建必须清除同一路径的失败标记")

    cache.markFailed("/a/b")
    cache.markSucceeded("/a/b/c")
    try expect(!cache.hasFailed("/a/b"), "子路径创建成功必须清除祖先目录的失败标记")
}

@MainActor
func statisticsIncludeIdenticalFiles() async throws {
    let root = try makeTempRoot("statistics")
    defer { cleanup(root) }
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try makeDirectory(root, "A")
    try makeDirectory(root, "B")
    try makeFile(a, "same1.txt", "hello")
    try makeFile(a, "same2.txt", "world")
    try makeFile(a, "diff.txt", "AAAA")
    try makeFile(b, "same1.txt", "hello")
    try makeFile(b, "same2.txt", "world")
    try makeFile(b, "diff.txt", "BBBB")

    let viewModel = FileCompareViewModel()
    viewModel.sourcePath = a.path
    viewModel.destinationPath = b.path
    viewModel.strictMD5 = true
    defer { viewModel.strictMD5 = false }
    viewModel.compare()

    let deadline = Date().addingTimeInterval(15)
    while viewModel.isWorking && Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    try expect(!viewModel.isWorking, "对比应在超时前结束")
    try expect(viewModel.items.count == 1, "表格应只显示差异项")
    try expect(viewModel.statistics.total == 3, "总计应包含相同文件，实际 \(viewModel.statistics.total)")
    try expect(viewModel.statistics.same == 2, "相同文件数应为 2，实际 \(viewModel.statistics.same)")
}

func mergeDoesNotDeleteDestinationDirectoryOnTypeMismatch() async throws {
    let root = try makeTempRoot("type-mismatch-merge")
    defer { cleanup(root) }
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try makeDirectory(root, "A")
    try makeDirectory(root, "B")
    try makeFile(a, "d", "file")
    try makeDirectory(b, "d")
    let keep = try makeFile(b, "d/keep.txt", "keep")

    _ = try await FileMergeService().mergeLeftToRight(
        sourceRoot: a,
        destinationRoot: b,
        includeHiddenItems: true,
        strictMD5: true
    )

    try expect(isDirectory(b.appendingPathComponent("d")), "合并模式不能把目标目录替换为文件")
    try expect(FileManager.default.fileExists(atPath: keep.path),
               "合并模式必须保留目标目录内的文件")
}

func specialFileDoesNotParticipateInSync() async throws {
    let root = try makeTempRoot("special-file")
    defer { cleanup(root) }
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try makeDirectory(root, "A")
    try makeDirectory(root, "B")
    try makeFIFO(a.appendingPathComponent("pipe"))

    let items = try await FileMergeService().compare(
        sourceRoot: a,
        destinationRoot: b,
        includeHiddenItems: true,
        strictMD5: true
    )
    let pipe = items.first { $0.relativePath == "pipe" }
    try expect(pipe?.status == .error,
               "FIFO/设备/套接字不能被当作普通文件参与比较与复制")

    // 同步阶段同样不能打开 FIFO（否则 FileHandle 会永久阻塞）。
    _ = try await FileMergeService().mergeLeftToRight(
        sourceRoot: a,
        destinationRoot: b,
        includeHiddenItems: true,
        strictMD5: true
    )
    try expect(!FileManager.default.fileExists(atPath: b.appendingPathComponent("pipe").path),
               "FIFO 不能被复制到目标")
}

@MainActor
func settingsChangeInvalidatesReview() async throws {
    let root = try makeTempRoot("settings-invalidation")
    defer { cleanup(root) }
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try makeDirectory(root, "A")
    try makeDirectory(root, "B")
    try makeFile(a, "only.txt", "x")

    let viewModel = FileCompareViewModel()
    viewModel.sourcePath = a.path
    viewModel.destinationPath = b.path
    viewModel.compare()
    let deadline = Date().addingTimeInterval(15)
    while viewModel.isWorking && Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    try expect(viewModel.items.count == 1, "首次对比应产生一个差异项")

    viewModel.includeHiddenItems = true
    try expect(viewModel.items.isEmpty, "更改“包含隐藏文件”后必须作废旧对比结果")

    viewModel.compare()
    let deadline2 = Date().addingTimeInterval(15)
    while viewModel.isWorking && Date() < deadline2 {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    try expect(!viewModel.items.isEmpty, "重新对比应产生结果")

    viewModel.strictMD5 = true
    try expect(viewModel.items.isEmpty, "更改严格 MD5 后必须作废旧对比结果")
    viewModel.strictMD5 = false
}

func mirroredItemSwapsDirection() throws {
    let sourceOnly = FileComparisonItem(
        id: "x",
        relativePath: "x",
        sourceURL: URL(fileURLWithPath: "/B/x"),
        destinationURL: nil,
        isDirectory: false,
        sourceSize: 10,
        destinationSize: nil,
        sourceMD5: "b",
        destinationMD5: nil,
        status: .onlyInSource,
        message: nil
    )
    let mirrored = sourceOnly.mirrored()
    try expect(mirrored.status == .onlyInDestination, "仅源状态镜像后应变为仅目标")
    try expect(mirrored.sourceURL == nil && mirrored.destinationURL != nil, "URL 必须交换")
    try expect(mirrored.sourceSize == nil && mirrored.destinationSize == 10, "大小必须交换")
    try expect(mirrored.sourceMD5 == nil && mirrored.destinationMD5 == "b", "MD5 必须交换")

    let destinationOnly = FileComparisonItem(
        id: "y",
        relativePath: "y",
        sourceURL: nil,
        destinationURL: URL(fileURLWithPath: "/A/y"),
        isDirectory: false,
        sourceSize: nil,
        destinationSize: 20,
        sourceMD5: nil,
        destinationMD5: "a",
        status: .onlyInDestination,
        message: nil
    )
    try expect(destinationOnly.mirrored().status == .onlyInSource,
               "仅目标状态镜像后应变为仅源")
}

func disconnectErrorClassification() throws {
    try expect(FileMergeService.isDisconnectError(
        NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN))
    ), "ENOTCONN 应识别为断线")
    try expect(FileMergeService.isDisconnectError(
        NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE))
    ), "ESTALE 应识别为断线")
    try expect(!FileMergeService.isDisconnectError(
        NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
    ), "EACCES 是权限错误，不能当作断线")
    try expect(!FileMergeService.isDisconnectError(
        NSError(domain: NSCocoaErrorDomain, code: 513)
    ), "NSFileWriteNoPermissionError 不能当作断线")
}

func remoteVolumeUsesTheItemPath() throws {
    let root = try makeTempRoot("statfs-path")
    defer { cleanup(root) }
    let service = FileMergeService()
    try expect(service.statfsPath(for: root) == root.path,
               "存在的路径应直接用于 statfs（网络卷挂载点不能被误判为父目录所在卷）")
    let missing = root.appendingPathComponent("does-not-exist")
    try expect(service.statfsPath(for: missing) == root.path,
               "不存在的路径应退回父目录")
}

func concurrentCopyFailureIsRecordedInSummary() async throws {
    let root = try makeTempRoot("concurrent-failure")
    defer { cleanup(root) }
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try makeDirectory(root, "A")
    try makeDirectory(root, "B")
    try makeFile(a, "a.txt", "aaa")
    try makeFile(a, "b.txt", "bbb")

    try chmod(b, 0o555)
    defer { try? chmod(b, 0o755) }

    let summary = try await FileMergeService().mergeLeftToRight(
        sourceRoot: a,
        destinationRoot: b,
        includeHiddenItems: true,
        strictMD5: true
    )

    try expect(summary.errors.count == 2, "并发复制失败必须全部计入 summary.errors")
    try expect(summary.copiedFiles == 0, "失败文件不能被统计为已复制")
    try expect(summary.items.filter { $0.status == .error }.count == 2,
               "失败条目必须保持 .error 状态")
}

func missingDestinationUnderSymlinkIsRejected() async throws {
    let root = try makeTempRoot("missing-dest-symlink")
    defer { cleanup(root) }
    let data = root.appendingPathComponent("data")
    try makeDirectory(data, "mirror")
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: data.appendingPathComponent("mirror"))

    // 目标 = 符号链接下的一个尚不存在的子目录；解析链接前缀后它位于源目录内部。
    let missingDestination = link.appendingPathComponent("data")
    try expect(!FileManager.default.fileExists(atPath: missingDestination.path),
               "测试前提：目标目录应尚不存在")

    do {
        _ = try await FileMergeService().compare(
            sourceRoot: data,
            destinationRoot: missingDestination,
            destinationMayNotExist: true
        )
        throw TestFailure.failed("尚不存在的目标目录也必须解析符号链接前缀并拒绝父子包含")
    } catch is TestFailure {
        throw TestFailure.failed("尚不存在的目标目录也必须解析符号链接前缀并拒绝父子包含")
    } catch {
        try expect(error.localizedDescription.contains("父子"),
                   "应抛出父子包含关系错误，实际：\(error.localizedDescription)")
    }
}
