import CryptoKit
import Darwin
import Foundation

/// 负责扫描、MD5 对比和 A → B 合并的文件服务。
final class FileMergeService: @unchecked Sendable {
    /// 进度回调，在后台线程调用；调用方需自行切回主线程。
    typealias ProgressHandler = @Sendable (FileOperationProgress) -> Void

    private struct FileNode: Sendable {
        let relativePath: String
        let url: URL
        let isDirectory: Bool
        let size: Int64?
        /// 修改时间：非严格模式下与 size 联用做「快速判定相同」，跳过全量 MD5 读盘。
        let modificationDate: Date?
    }

    /// 预计算的对比结果（或读取失败时的错误），供并发哈希阶段产出、构造阶段消费。
    /// 严格模式产出 sourceMD5/destinationMD5（供界面展示指纹）；非严格模式产出 areEqual
    ///（逐块对比，首块不同即停，比两端全量 MD5 对差异文件快得多）。
    private struct HashResult: Sendable {
        let sourceMD5: String?
        let destinationMD5: String?
        let areEqual: Bool?
        let error: Error?
    }

    /// 并发复制单个文件的结果，供 TaskGroup 收集后统一合并进 summary 与状态表。
    private struct FileCopyResult: Sendable {
        let itemID: String
        let overwritten: Bool   // 覆盖了已存在的目标
        let status: ComparisonStatus
        let message: String?
    }

    /// 线程安全的 Int64 计数器：并发复制/哈希时汇总已处理字节数与条目数，供进度回调使用。
    private final class AtomicInt64Counter: @unchecked Sendable {
        private var value: Int64 = 0
        private let lock = NSLock()

        /// 当前值。
        var current: Int64 {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        @discardableResult
        func add(_ delta: Int64) -> Int64 {
            lock.lock(); defer { lock.unlock() }
            value += delta
            return value
        }

        /// 直接设置为指定值，返回该值。用于按文件累计字节的绝对量推进。
        @discardableResult
        func setValue(_ newValue: Int64) -> Int64 {
            lock.lock(); defer { lock.unlock() }
            value = newValue
            return value
        }
    }

    /// 线程安全的布尔标志：并发复制时把 Task 取消信号桥接到脱离协作线程池的阻塞 I/O 循环里。
    /// 阻塞 I/O 跑在全局并发队列上，`Task.checkCancellation()` 在那里读不到任务上下文，
    /// 故由 `withTaskCancellationHandler` 置位此标志，I/O 循环逐块轮询以尽早退出。
    private final class AtomicFlag: @unchecked Sendable {
        private var value = false
        private let lock = NSLock()

        func set() {
            lock.lock(); defer { lock.unlock() }
            value = true
        }

        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    /// 线程安全的 continuation 容器：原子「取出并置空」，保证 `runBlockingOffCooperativePool` 中
    /// dispatch 线程与 onCancel 任一方首次 resume 后另一方拿不到 continuation，避免双重 resume。
    /// 同时记录「取消已到达」：若 onCancel 先于 store 触发，store 时立即以 CancellationError resume，
    /// 不让 dispatch 线程的 I/O 结果把已取消的任务「救活」。
    private final class ResumeBox<T: Sendable>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, Error>?
        private var cancelledBeforeStore = false
        private let lock = NSLock()

        /// 存入 continuation；若取消已先到达，立即 resume CancellationError 并丢弃该 continuation。
        func store(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if cancelledBeforeStore {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        /// 取出并 resume。若 continuation 已被另一方取走（含 store 前 onCancel），本次为空操作。
        /// 仅 CancellationError 才标记「取消已到达」——真实 I/O 错误不应让稍后的 store 误判为取消。
        func resume(_ result: Result<T, Error>) {
            lock.lock()
            if case .failure(let error) = result, error is CancellationError {
                cancelledBeforeStore = true
            }
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    /// 线程安全的目录创建缓存：记录「已成功创建」与「创建失败」的目录路径，贯穿顺序与并发阶段共享。
    /// 避免对同一目录重复 createDirectory——网络卷上每次 createDirectory 都是一次 RTT，
    /// 31 万文件同处一目录时，无缓存会逐文件发起 31 万次冗余往返（实测可达小时级）。
    /// 失败缓存让某目录首次创建失败后，其下所有文件直接跳过 createDirectory，
    /// 防止「单目录权限不足 → 整子树逐文件重复失败」的雪崩与错误刷屏。
    private final class DirectoryCreationCache: @unchecked Sendable {
        private var succeeded = Set<String>()
        private var failed = Set<String>()
        private let lock = NSLock()

        func hasSucceeded(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return succeeded.contains(path)
        }

        func hasFailed(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return failed.contains(path)
        }

        func markSucceeded(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            succeeded.insert(path)
        }

        func markFailed(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            failed.insert(path)
        }

        /// 清除全部失败标记。网络卷连接断开恢复后调用：断开期间目录创建的失败多为连接所致而非真权限问题，
        /// 清除后恢复重试能正常建目录，否则 hasFailed 会让其下文件持续跳过。
        func clearFailures() {
            lock.lock(); defer { lock.unlock() }
            failed.removeAll()
        }
    }

    private enum ServiceError: LocalizedError {
        case notDirectory(String)
        case nestedDirectory(source: String, destination: String)
        /// 父目录此前已创建失败（多为权限不足），其下文件直接跳过，避免逐文件重复 createDirectory 的雪崩。
        case parentDirectoryUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .notDirectory(let path):
                return "不是有效目录：\(path)"
            case .nestedDirectory(let source, let destination):
                return "路径 A 与路径 B 存在父子包含关系（\(source) ⊃/⊂ \(destination)），同步会导致内容无限嵌套复制或覆盖父目录文件，已拒绝。请选择两个互不包含的目录。"
            case .parentDirectoryUnavailable(let path):
                return "父目录「\(path)」无法创建（可能无写权限），已跳过该目录下的文件。"
            }
        }
    }

    private let fileManager = FileManager.default

    /// 进程级递增的临时文件序号：用于生成 temp 文件名后缀，比每文件生成 UUID 更轻、可预测。
    private static let tempCounter = AtomicInt64Counter()

    /// 并发上限。本地卷瓶颈是 CPU/磁盘，按 CPU 核数并发即可；网络卷（SMB/NFS 等）瓶颈是每文件的
    /// 网络往返（RTT）而非 CPU，必须让更多请求同时在途来重叠 RTT——用 CPU 核数限制会让网络链路严重欠载
    ///（8 核机器只并发 8 个请求，远不够饱和网络）。故网络卷用固定较高并发，本地卷用 CPU 核数。
    /// 哈希与复制两阶段共用同一上限。
    private static let maxConcurrentLocal = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
    private static let maxConcurrentRemote = 16

    func compare(
        sourceRoot: URL,
        destinationRoot: URL,
        includeHiddenItems: Bool = false,
        /// 目标目录允许尚不存在（“包含本目录”模式下，目标下的源文件夹子目录首次同步时还不存在）。
        destinationMayNotExist: Bool = false,
        strictMD5: Bool = false,
        progress: ProgressHandler? = nil
    ) async throws -> [FileComparisonItem] {
        // 对外入口返回本地化排序的结果（供界面稳定展示）；内部同步路径无需排序，
        // 走 `compareInternal(sortForDisplay: false)` 省一次大数组的本地化排序。
        try await compareInternal(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            includeHiddenItems: includeHiddenItems,
            destinationMayNotExist: destinationMayNotExist,
            sortForDisplay: true,
            strictMD5: strictMD5,
            progress: progress
        )
    }

    /// 对比实现。`sortForDisplay`：是否对结果做本地化排序（同步路径按执行顺序另行重排，置 false 省一次排序）。
    /// `strictMD5`：为 true 时对「大小相同」的文件一律两端全量 MD5；为 false 时启用「大小+mtime 快速判定」
    ///——两者一致即判相同、跳过读盘，仅不一致时回退 MD5（兼顾正确性与重扫速度）。
    private func compareInternal(
        sourceRoot: URL,
        destinationRoot: URL,
        includeHiddenItems: Bool,
        destinationMayNotExist: Bool,
        sortForDisplay: Bool,
        strictMD5: Bool,
        progress: ProgressHandler?
    ) async throws -> [FileComparisonItem] {
        progress?(FileOperationProgress(phase: .validating, message: FileProgressPhase.validating.defaultMessage))
        try validateDirectory(sourceRoot)
        try validateDirectory(destinationRoot, allowMissing: destinationMayNotExist)
        // 拒绝源/目标互为父子目录：否则同步会把一侧内容复制进另一侧子树，
        // 反复同步导致目录无限嵌套膨胀，直至磁盘写满。
        try validateNotNested(sourceRoot: sourceRoot, destinationRoot: destinationRoot)

        progress?(FileOperationProgress(phase: .scanningSource, message: FileProgressPhase.scanningSource.defaultMessage))
        let sourceNodes = try scan(root: sourceRoot, includeHiddenItems: includeHiddenItems, phase: .scanningSource, progress: progress)

        progress?(FileOperationProgress(phase: .scanningDestination, message: FileProgressPhase.scanningDestination.defaultMessage))
        let destinationNodes = try scan(root: destinationRoot, includeHiddenItems: includeHiddenItems, phase: .scanningDestination, progress: progress)

        let allRelativePaths: [String]
        if sortForDisplay {
            allRelativePaths = Set(sourceNodes.keys).union(destinationNodes.keys).sorted { lhs, rhs in
                lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        } else {
            // 同步路径稍后按执行顺序重排，这里任意稳定顺序即可，省一次本地化排序开销。
            allRelativePaths = (Set(sourceNodes.keys).union(destinationNodes.keys)).sorted()
        }

        // 仅对 A/B 中同名、且为文件、且大小相同的项计算 MD5；大小不同必然内容不同，
        // 无需读取文件即可判为 different，省去两次完整文件读取。Set 便于主循环 O(1) 查找。
        // 非 strict 模式下，「大小+mtime 一致」即可判相同、无需哈希，从候选集中剔除以省两次全量读盘，
        // 仅大小相同但 mtime 不同（可能内容已变）的文件才回退 MD5。
        var fastSamePaths = Set<String>()
        let hashCandidates = Set(allRelativePaths.filter { relativePath in
            guard let source = sourceNodes[relativePath],
                  let destination = destinationNodes[relativePath],
                  !source.isDirectory, !destination.isDirectory else {
                return false
            }
            guard source.size == destination.size else { return false }
            if !strictMD5, sameTimestamp(source: source, destination: destination) {
                fastSamePaths.insert(relativePath)
                return false
            }
            return true
        })
        let totalHashBytes = hashCandidates.reduce(Int64(0)) { partial, relativePath in
            let source = sourceNodes[relativePath]?.size ?? 0
            let destination = destinationNodes[relativePath]?.size ?? 0
            return partial + source + destination
        }

        // 并发比对候选文件：分批限流（每批并发数 = min(8, CPU 核数)），
        // 避免一次性打开过多文件描述符；批内多文件并行，充分利用多核。
        let hashResults = try await hashAll(
            candidates: hashCandidates,
            sourceNodes: sourceNodes,
            destinationNodes: destinationNodes,
            totalHashBytes: totalHashBytes,
            strictMD5: strictMD5,
            progress: progress
        )

        var results: [FileComparisonItem] = []
        results.reserveCapacity(allRelativePaths.count)

        for (index, relativePath) in allRelativePaths.enumerated() {
            try Task.checkCancellation()

            // 哈希已完成，此阶段仅按预计算结果构造 item，无字节进度信息增量；
            // 每 64 条发一次进度，避免大目录下逐条回调压垮主线程节流。
            if index.isMultiple(of: 64) || index == allRelativePaths.count - 1 {
                progress?(FileOperationProgress(
                    phase: .comparing,
                    completedItems: index,
                    totalItems: allRelativePaths.count,
                    message: FileProgressPhase.comparing.defaultMessage
                ))
            }

            let item = buildComparisonItem(
                relativePath: relativePath,
                source: sourceNodes[relativePath],
                destination: destinationNodes[relativePath],
                hashResult: hashResults[relativePath],
                fastSame: fastSamePaths.contains(relativePath)
            )
            results.append(item)
        }

        progress?(FileOperationProgress(
            phase: .comparing,
            completedItems: allRelativePaths.count,
            totalItems: allRelativePaths.count,
            message: "对比完成。"
        ))
        return results
    }

    /// 并发比对候选文件集合，返回各路径的对比结果（或读取错误）。分批限流以控制并发文件描述符数。
    /// `strictMD5` 为真时两端全量 MD5（供界面展示指纹）；为假时逐块对比，首块不同即停，
    /// 对「等长但内容不同」的文件省下几乎全部读盘，对相同文件也只读一次（两端 MD5 需读两次）。
    private func hashAll(
        candidates: Set<String>,
        sourceNodes: [String: FileNode],
        destinationNodes: [String: FileNode],
        totalHashBytes: Int64,
        strictMD5: Bool,
        progress: ProgressHandler?
    ) async throws -> [String: HashResult] {
        guard !candidates.isEmpty else { return [:] }

        let counter = AtomicInt64Counter()
        let orderedCandidates = candidates.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }

        var results: [String: HashResult] = [:]
        results.reserveCapacity(orderedCandidates.count)

        var index = 0
        while index < orderedCandidates.count {
            try Task.checkCancellation()
            let batchEnd = min(index + Self.maxConcurrentLocal, orderedCandidates.count)
            let batch = Array(orderedCandidates[index..<batchEnd])

            try await withThrowingTaskGroup(of: (String, HashResult).self) { group in
                for path in batch {
                    group.addTask { [sourceNodes, destinationNodes, counter, totalHashBytes, progress, strictMD5] in
                        guard let source = sourceNodes[path], let destination = destinationNodes[path] else {
                            return (path, HashResult(sourceMD5: nil, destinationMD5: nil, areEqual: nil, error: nil))
                        }
                        let emit: (Int64) -> Void = { bytes in
                            let completed = counter.add(bytes)
                            progress?(FileOperationProgress(
                                phase: .hashing,
                                completedBytes: completed,
                                totalBytes: totalHashBytes > 0 ? totalHashBytes : nil,
                                currentPath: path,
                                message: FileProgressPhase.hashing.defaultMessage
                            ))
                        }
                        // 阻塞读走全局并发队列，子任务在 continuation 处挂起、不占协作线程——
                        // 与复制阶段对称，避免网络卷大文件哈希时慢 I/O 占满协作线程池。
                        let cancellationFlag = AtomicFlag()
                        do {
                            let result: HashResult = try await self.runBlockingOffCooperativePool(cancellationFlag: cancellationFlag) {
                                do {
                                    if strictMD5 {
                                        let sourceMD5 = try self.md5Hex(of: source.url, isCancelled: { cancellationFlag.isSet }, onBytesRead: emit)
                                        let destinationMD5 = try self.md5Hex(of: destination.url, isCancelled: { cancellationFlag.isSet }, onBytesRead: emit)
                                        return HashResult(sourceMD5: sourceMD5, destinationMD5: destinationMD5, areEqual: nil, error: nil)
                                    } else {
                                        // 逐块对比：两端同位置读块比较，首块不同即判 different 返回，
                                        // 省去差异文件剩余部分与第二次全量读盘。进度上报双端字节数以匹配 totalHashBytes；
                                        // 差异文件提前退出后由本路径补齐两端未读字节，保证 hashing 字节进度能收尾到 100%。
                                        let areEqual = try self.streamsEqual(
                                            sourceURL: source.url,
                                            destinationURL: destination.url,
                                            sourceSize: source.size ?? 0,
                                            destinationSize: destination.size ?? 0,
                                            isCancelled: { cancellationFlag.isSet },
                                            onBytesRead: emit
                                        )
                                        return HashResult(sourceMD5: nil, destinationMD5: nil, areEqual: areEqual, error: nil)
                                    }
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    return HashResult(sourceMD5: nil, destinationMD5: nil, areEqual: nil, error: error)
                                }
                            }
                            return (path, result)
                        } catch is CancellationError {
                            // 取消向上传播：withThrowingTaskGroup 会自动取消其余子任务，
                            // 并把 CancellationError 抛给 hashAll → compare 调用方。
                            throw CancellationError()
                        } catch {
                            return (path, HashResult(sourceMD5: nil, destinationMD5: nil, areEqual: nil, error: error))
                        }
                    }
                }
                for try await (path, result) in group {
                    results[path] = result
                }
            }
            index = batchEnd
        }
        return results
    }

    func mergeLeftToRight(
        sourceRoot: URL,
        destinationRoot: URL,
        includeHiddenItems: Bool = false,
        destinationMayNotExist: Bool = false,
        strictMD5: Bool = false,
        progress: ProgressHandler? = nil
    ) async throws -> MergeSummary {
        try await sync(sourceRoot: sourceRoot, destinationRoot: destinationRoot, deletesDestinationOnlyItems: false, includeHiddenItems: includeHiddenItems, destinationMayNotExist: destinationMayNotExist, strictMD5: strictMD5, progress: progress)
    }

    func overwriteLeftToRight(
        sourceRoot: URL,
        destinationRoot: URL,
        includeHiddenItems: Bool = false,
        destinationMayNotExist: Bool = false,
        strictMD5: Bool = false,
        progress: ProgressHandler? = nil
    ) async throws -> MergeSummary {
        try await sync(sourceRoot: sourceRoot, destinationRoot: destinationRoot, deletesDestinationOnlyItems: true, includeHiddenItems: includeHiddenItems, destinationMayNotExist: destinationMayNotExist, strictMD5: strictMD5, progress: progress)
    }

    private func sync(sourceRoot: URL, destinationRoot: URL, deletesDestinationOnlyItems: Bool, includeHiddenItems: Bool, destinationMayNotExist: Bool, strictMD5: Bool, progress: ProgressHandler?) async throws -> MergeSummary {
        progress?(FileOperationProgress(phase: .validating, message: FileProgressPhase.validating.defaultMessage))
        try validateDirectory(sourceRoot)
        try validateDirectory(destinationRoot, allowMissing: destinationMayNotExist)
        // 拒绝源/目标互为父子目录：否则同步会把一侧内容复制进另一侧子树，
        // 反复同步导致目录无限嵌套膨胀，直至磁盘写满。
        try validateNotNested(sourceRoot: sourceRoot, destinationRoot: destinationRoot)

        let items = try await compareInternal(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            includeHiddenItems: includeHiddenItems,
            destinationMayNotExist: destinationMayNotExist,
            sortForDisplay: false,
            strictMD5: strictMD5,
            progress: progress
        )
        // 同步过程会按执行结果更新各 item 状态，最终回传给调用方刷新界面，省去同步后再扫一遍。
        var finalStatus: [String: ComparisonStatus] = [:]
        var finalMessage: [String: String] = [:]
        let orderedItems = items.sorted { lhs, rhs in
            if lhs.status == .onlyInDestination || rhs.status == .onlyInDestination {
                if lhs.isDirectory != rhs.isDirectory {
                    return !lhs.isDirectory && rhs.isDirectory
                }
                return lhs.relativePath.count > rhs.relativePath.count
            }
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }

        // 需要复制的文件总字节数，用于字节级进度。
        let totalCopyBytes = orderedItems.reduce(Int64(0)) { total, item in
            guard !item.isDirectory,
                  item.sourceURL != nil,
                  item.status == .onlyInSource || item.status == .different || item.status == .typeMismatch else {
                return total
            }
            return total + (item.sourceSize ?? 0)
        }

        var summary = MergeSummary()
        // 字节级进度跨顺序阶段与并发阶段共享，用原子计数器保证并发安全。
        let completedCopyBytes = AtomicInt64Counter()
        let completedItemsCounter = AtomicInt64Counter()
        let totalItemsCount = orderedItems.count
        // 目录创建缓存贯穿顺序与并发阶段：同目录只 createDirectory 一次，失败则其下文件跳过，
        // 避免网络卷上逐文件冗余 createDirectory 的 RTT 雪崩（同目录 31 万文件会放大到小时级）。
        let dirCache = DirectoryCreationCache()

        // 目标卷是否远程/网络卷：整个同步算一次复用，避免复制每个文件都 statfs 一次（网络卷上 statfs 也有 RTT）。
        let destinationIsRemote = isRemoteVolume(destinationRoot)

        /// 顺序阶段：处理目录创建、typeMismatch、删除等结构性操作（顺序敏感）。
        /// 普通文件复制（onlyInSource/different 且非目录）收集到 pendingFileCopies，后续并发执行。
        var pendingFileCopies: [FileComparisonItem] = []

        // 预计算「有文件待复制进去的目录」前缀集合：这些目录无需显式创建——并发复制文件时
        // performCopy 会用 createDirectory(withIntermediateDirectories:) 自动建出父目录。
        // 只有空目录（无任何待复制文件）才需显式建，避免远程盘上对每个非空目录都做一次 createDirectory 往返。
        var directoriesWithFiles = Set<String>()
        for item in orderedItems {
            guard item.sourceURL != nil,
                  !item.isDirectory,
                  item.status == .onlyInSource || item.status == .different || item.status == .typeMismatch else { continue }
            // 该文件的所有祖先目录前缀都「有文件」，标记之。
            var prefix = (item.relativePath as NSString).deletingLastPathComponent
            while !prefix.isEmpty {
                directoriesWithFiles.insert(prefix)
                let parent = (prefix as NSString).deletingLastPathComponent
                if parent == prefix { break }
                prefix = parent
            }
        }

        for item in orderedItems {
            try Task.checkCancellation()

            // 独立的普通文件复制：延后到并发阶段，重叠每文件的固定网络往返开销。
            let isCleanFileCopy = item.sourceURL != nil
                && !item.isDirectory
                && (item.status == .onlyInSource || item.status == .different)
            if isCleanFileCopy {
                pendingFileCopies.append(item)
                continue
            }

            let index = Int(completedItemsCounter.add(1))
            let phase: FileProgressPhase
            if item.sourceURL == nil {
                phase = .deleting
            } else if !item.isDirectory && item.status != .same {
                phase = .copying
            } else {
                phase = .applyingChanges
            }

            progress?(FileOperationProgress(
                phase: phase,
                completedItems: index,
                totalItems: totalItemsCount,
                completedBytes: completedCopyBytes.current,
                totalBytes: totalCopyBytes > 0 ? totalCopyBytes : nil,
                currentPath: item.relativePath,
                message: phase.defaultMessage
            ))

            if item.sourceURL == nil {
                if deletesDestinationOnlyItems {
                    do {
                        try deleteDestinationOnlyItem(item: item, summary: &summary, isRemote: destinationIsRemote)
                        // 删除后两侧均无该项，视为一致。
                        finalStatus[item.id] = .same
                    } catch {
                        let msg = Self.friendlyMessage(for: error, isRemote: destinationIsRemote)
                        summary.errors.append("\(item.relativePath)：删除失败：\(msg)")
                        finalStatus[item.id] = .error
                        finalMessage[item.id] = msg
                    }
                }
                continue
            }

            guard let sourceURL = item.sourceURL else { continue }
            let destinationURL = destinationRoot.appendingPathComponent(item.relativePath)

            do {
                if item.isDirectory {
                    // 非空目录跳过显式创建（文件复制阶段会自动建父目录）；空目录与 typeMismatch 仍显式处理。
                    let needsExplicit = item.status == .typeMismatch || !directoriesWithFiles.contains(item.relativePath)
                    if needsExplicit {
                        try mergeDirectory(item: item, destinationURL: destinationURL, summary: &summary, dirCache: dirCache)
                    }
                    finalStatus[item.id] = .same
                } else {
                    // 顺序阶段文件（typeMismatch 等）：回调给出该文件累计已拷贝字节，
                    // 叠加本文件起始偏移得到全局进度。
                    let bytesBefore = completedCopyBytes.current
                    try mergeFile(item: item, sourceURL: sourceURL, destinationURL: destinationURL, summary: &summary, dirCache: dirCache, isRemote: destinationIsRemote) { bytesCopied in
                        let total = completedCopyBytes.setValue(bytesBefore + bytesCopied)
                        progress?(FileOperationProgress(
                            phase: .copying,
                            completedItems: index,
                            totalItems: totalItemsCount,
                            completedBytes: total,
                            totalBytes: totalCopyBytes > 0 ? totalCopyBytes : nil,
                            currentPath: item.relativePath,
                            message: FileProgressPhase.copying.defaultMessage
                        ))
                    }
                    // 非复制类文件（跳过/错误）不会回调，确保字节计数对齐实际大小。
                    if item.status == .same {
                        _ = completedCopyBytes.add(item.sourceSize ?? 0)
                    }
                    // 实际发生复制/覆盖的项，同步后两侧一致。
                    if item.status == .onlyInSource || item.status == .different || item.status == .typeMismatch {
                        finalStatus[item.id] = .same
                    }
                }
            } catch {
                let msg = Self.friendlyMessage(for: error, isRemote: destinationIsRemote)
                summary.errors.append("\(item.relativePath)：\(msg)")
                finalStatus[item.id] = .error
                finalMessage[item.id] = msg
            }
        }

        // 并发阶段：独立文件复制。结构性操作已完成（父目录均已就绪），各文件路径互不重叠，可安全并行。
        if !pendingFileCopies.isEmpty {
            let results = try await copyFilesConcurrently(
                items: pendingFileCopies,
                destinationRoot: destinationRoot,
                totalCopyBytes: totalCopyBytes,
                totalItemsCount: totalItemsCount,
                completedCopyBytes: completedCopyBytes,
                completedItemsCounter: completedItemsCounter,
                dirCache: dirCache,
                isRemote: destinationIsRemote,
                progress: progress
            )
            for result in results {
                if result.overwritten {
                    summary.overwrittenFiles += 1
                } else {
                    summary.copiedFiles += 1
                }
                finalStatus[result.itemID] = result.status
                if let msg = result.message { finalMessage[result.itemID] = msg }
            }
        }

        progress?(FileOperationProgress(
            phase: .applyingChanges,
            completedItems: totalItemsCount,
            totalItems: totalItemsCount,
            completedBytes: totalCopyBytes > 0 ? totalCopyBytes : nil,
            totalBytes: totalCopyBytes > 0 ? totalCopyBytes : nil,
            message: "同步完成。"
        ))

        // 按执行结果更新各 item 状态，随 summary 回传，免去调用方重新扫描。
        if !finalStatus.isEmpty {
            summary.items = items.map { item in
                guard let status = finalStatus[item.id] else { return item }
                var copy = item
                copy.status = status
                if let msg = finalMessage[item.id] { copy.message = msg }
                return copy
            }
        } else {
            summary.items = items
        }
        return summary
    }

    /// 并发复制独立文件集合。各文件路径互不重叠、父目录已就绪，可安全并行；
    /// 重叠每文件的固定网络往返开销，是远程卷吞吐的关键。取消向上传播；单文件失败不中断其余。
    ///
    /// 两点关键设计避免「复制阶段僵死」：
    /// 1. 分批限流（每批并发数 = min(8, CPU 核数)），对齐 hashAll。大目录同步不会一次性灌入海量 Task，
    ///    取消时也只需等当前批次收尾即可跳出，而非等全部文件。
    /// 2. 阻塞 I/O 经 `runBlockingOffCooperativePool` 移到全局并发队列执行，TaskGroup 子任务在
    ///    continuation 处挂起、释放协作线程。否则阻塞 read/write/copyItem 会占满协作线程池，
    ///    导致 `for try await` 与进度回调派发排不上线程——表现为进度停滞、停止按钮失效的僵死。
    private func copyFilesConcurrently(
        items: [FileComparisonItem],
        destinationRoot: URL,
        totalCopyBytes: Int64,
        totalItemsCount: Int,
        completedCopyBytes: AtomicInt64Counter,
        completedItemsCounter: AtomicInt64Counter,
        dirCache: DirectoryCreationCache,
        isRemote: Bool,
        progress: ProgressHandler?
    ) async throws -> [FileCopyResult] {
        var results: [FileCopyResult] = []
        results.reserveCapacity(items.count)
        // 网络卷瓶颈是 RTT 而非 CPU：用固定较高并发（16）重叠更多网络往返；
        // 本地卷瓶颈是 CPU/磁盘，按 CPU 核数并发即可，过高反而增加调度开销。
        let concurrency = isRemote ? Self.maxConcurrentRemote : Self.maxConcurrentLocal

        var index = 0
        while index < items.count {
            // 批与批之间检查取消：当前批次一旦收尾即可跳出，避免「等全部文件」式僵死。
            try Task.checkCancellation()
            let batchEnd = min(index + concurrency, items.count)
            let batch = Array(items[index..<batchEnd])

            var batchResults = try await runCopyBatch(
                batch: batch,
                destinationRoot: destinationRoot,
                totalCopyBytes: totalCopyBytes,
                totalItemsCount: totalItemsCount,
                completedCopyBytes: completedCopyBytes,
                completedItemsCounter: completedItemsCounter,
                dirCache: dirCache,
                isRemote: isRemote,
                progress: progress
            )

            // 连接断开恢复：网络卷（SMB/NFS 等）长时间复制后会话可能被服务器/macOS 断开，
            // 表现为整批文件瞬间全失败。检测到「本批全失败」时等待重连，恢复后重试本批，
            // 避免剩余文件雪崩失败、白费已复制的进度。本地卷无此问题，跳过。
            // 全失败恰好保证字节计数无重复（失败未加字节），重试仅需减回 item 计数。
            let allFailed = !batchResults.isEmpty && batchResults.allSatisfy { $0.status == .error }
            if allFailed && isRemote {
                let recovered = await waitForVolumeRecovery(root: destinationRoot, progress: progress)
                if recovered {
                    // 减回本批 item 计数（全失败时每项已 add(1)），清除连接断开导致的目录失败误判，重试本批。
                    _ = completedItemsCounter.add(-Int64(batch.count))
                    dirCache.clearFailures()
                    batchResults = try await runCopyBatch(
                        batch: batch,
                        destinationRoot: destinationRoot,
                        totalCopyBytes: totalCopyBytes,
                        totalItemsCount: totalItemsCount,
                        completedCopyBytes: completedCopyBytes,
                        completedItemsCounter: completedItemsCounter,
                        dirCache: dirCache,
                        isRemote: isRemote,
                        progress: progress
                    )
                } else {
                    // 未恢复：本批结果保留为失败，剩余文件标 error（连接断开），可由「重试失败项」重试。
                    results.append(contentsOf: batchResults)
                    for remainingIndex in (index + batch.count)..<items.count {
                        _ = completedItemsCounter.add(1)
                        results.append(FileCopyResult(itemID: items[remainingIndex].id, overwritten: false, status: .error, message: "网络卷连接断开且未恢复，已跳过。"))
                    }
                    break
                }
            }
            results.append(contentsOf: batchResults)
            index = batchEnd
        }
        return results
    }

    /// 执行一批文件的并发复制，返回每个文件的结果。抽离自 copyFilesConcurrently 以支持连接恢复后整批重试。
    private func runCopyBatch(
        batch: [FileComparisonItem],
        destinationRoot: URL,
        totalCopyBytes: Int64,
        totalItemsCount: Int,
        completedCopyBytes: AtomicInt64Counter,
        completedItemsCounter: AtomicInt64Counter,
        dirCache: DirectoryCreationCache,
        isRemote: Bool,
        progress: ProgressHandler?
    ) async throws -> [FileCopyResult] {
        var batchResults: [FileCopyResult] = []
        batchResults.reserveCapacity(batch.count)

        try await withThrowingTaskGroup(of: FileCopyResult?.self) { group in
            for item in batch {
                group.addTask { [completedCopyBytes, completedItemsCounter, totalCopyBytes, totalItemsCount, progress, dirCache] in
                    guard let sourceURL = item.sourceURL else { return nil }
                    let destinationURL = destinationRoot.appendingPathComponent(item.relativePath)
                    let destinationExists = item.destinationURL != nil
                    let fileSize = item.sourceSize ?? 0

                    let cancellationFlag = AtomicFlag()
                    do {
                        // 阻塞 I/O 在全局并发队列上执行；TaskGroup 子任务在此挂起、不占协作线程。
                        // 体内轮询 cancellationFlag 实现逐块可取消；返回本文件已上报字节数供对齐。
                        let lastReported: Int64 = try await self.runBlockingOffCooperativePool(cancellationFlag: cancellationFlag) {
                            // 按文件累计字节转为全局增量：记录上次上报值，仅把新增部分加进全局计数器。
                            var reported: Int64 = 0
                            let onBytesCopied: (Int64) -> Void = { copiedInFile in
                                let delta = copiedInFile - reported
                                reported = copiedInFile
                                guard delta > 0 else { return }
                                let total = completedCopyBytes.add(delta)
                                progress?(FileOperationProgress(
                                    phase: .copying,
                                    completedItems: Int(completedItemsCounter.current),
                                    totalItems: totalItemsCount,
                                    completedBytes: total,
                                    totalBytes: totalCopyBytes > 0 ? totalCopyBytes : nil,
                                    currentPath: item.relativePath,
                                    message: FileProgressPhase.copying.defaultMessage
                                ))
                            }
                            try self.performCopy(
                                sourceURL: sourceURL,
                                destinationURL: destinationURL,
                                destinationExists: destinationExists,
                                dirCache: dirCache,
                                isCancelled: { cancellationFlag.isSet },
                                isRemote: isRemote,
                                onBytesCopied: onBytesCopied
                            )
                            return reported
                        }
                        // 对齐字节计数（小文件 copyItem 路径已一次性回调 fileSize；分块路径逐块回调，
                        // 末值应等于 fileSize；若因路径不同导致 lastReported < fileSize，补齐）。
                        if lastReported < fileSize {
                            _ = completedCopyBytes.add(fileSize - lastReported)
                        }
                        // 快路径（copyItem 单次阻塞调用）体内不轮询取消，在此补检一次，
                        // 把「复制期间被取消」转成 CancellationError 向上传播。
                        try Task.checkCancellation()
                        _ = completedItemsCounter.add(1)
                        return FileCopyResult(itemID: item.id, overwritten: destinationExists, status: .same, message: nil)
                    } catch is CancellationError {
                        // 取消向上传播：TaskGroup 会自动取消其余子任务并把异常抛给调用方。
                        throw CancellationError()
                    } catch {
                        _ = completedItemsCounter.add(1)
                        return FileCopyResult(itemID: item.id, overwritten: false, status: .error, message: Self.friendlyMessage(for: error, isRemote: isRemote))
                    }
                }
            }
            for try await result in group {
                if let result { batchResults.append(result) }
            }
        }
        return batchResults
    }

    /// 探测目标卷根目录是否可访问（存在且可列举）。连接断开时 fileExists 可能假阳性，
    /// 故用 contentsOfDirectory 二次确认——能列举才算真正恢复。
    private func volumeAvailable(root: URL) -> Bool {
        guard fileManager.fileExists(atPath: root.path) else { return false }
        return (try? fileManager.contentsOfDirectory(atPath: root.path)) != nil
    }

    /// 网络卷连接断开后等待自动重连。指数退避（2s→30s）轮询目标卷可访问性，上限 5 分钟。
    /// 期间通过进度回调告知「等待重连」与已等待秒数，避免界面像卡死。返回是否恢复。
    private func waitForVolumeRecovery(root: URL, progress: ProgressHandler?) async -> Bool {
        let maxWaitSeconds: UInt64 = 5 * 60
        var waitedSeconds: UInt64 = 0
        var delaySeconds: UInt64 = 2
        while waitedSeconds < maxWaitSeconds {
            if Task.isCancelled { return false }
            progress?(FileOperationProgress(
                phase: .copying,
                message: "网络卷无响应，正在等待重连…（已等待 \(waitedSeconds) 秒）"
            ))
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            waitedSeconds += delaySeconds
            if volumeAvailable(root: root) {
                return true
            }
            delaySeconds = min(delaySeconds * 2, 30)
        }
        return false
    }

    /// 把阻塞式文件 I/O 从协作线程池移到全局并发队列上执行：用 `withCheckedThrowingContinuation`
    /// 挂起当前协作任务，I/O 在 dispatch 线程跑完后 resume。协作线程不被阻塞，`for try await`
    /// 与进度回调的续体随时可调度——这是根治复制阶段僵死的关键。
    ///
    /// 取消语义：`withTaskCancellationHandler` 的 `onCancel` 同时做两件事——置位 `cancellationFlag`
    ///（供 body 内的 I/O 循环逐块轮询尽早退出），并尽可能直接 resume(throwing: CancellationError())。
    /// dispatch 线程完成 I/O 后也会尝试 resume；两者经 `resumeBox` 互斥（take 出 continuation 后置空），
    /// 保证 continuation 恰好 resume 一次。这样即便 body 是不可中断的单次阻塞调用（如 copyItem），
    /// 取消也能在 I/O 完成后立即以 CancellationError 返回，而非被静默忽略。
    private func runBlockingOffCooperativePool<T: Sendable>(
        cancellationFlag: AtomicFlag,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        // 持有 continuation 供 onCancel 取用；take 原子取出并置空，保证只 resume 一次。
        let resumeBox = ResumeBox<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                resumeBox.store(continuation)
                // 任务创建时可能已取消：先查标志，已取消则直接抛取消、连 dispatch 都不发，
                // 避免「注册了 continuation 却为已取消任务排队一次无谓 I/O」。
                if cancellationFlag.isSet {
                    resumeBox.resume(.failure(CancellationError()))
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try body()
                        resumeBox.resume(.success(result))
                    } catch {
                        resumeBox.resume(.failure(error))
                    }
                }
            }
        } onCancel: {
            cancellationFlag.set()
            resumeBox.resume(.failure(CancellationError()))
        }
    }

    /// 执行单个独立文件的复制（不含 summary 记账，由调用方汇总）。创建父目录后走带进度的原子复制。
    /// `isCancelled` 由并发路径传入（脱离协作池时的取消标志）；顺序路径走默认 `Task.isCancelled`。
    /// `dirCache` 缓存已创建/失败的目录：同目录只 createDirectory 一次，失败则其下文件直接跳过，
    /// 避免网络卷上逐文件冗余 createDirectory 的 RTT 雪崩。
    private func performCopy(
        sourceURL: URL,
        destinationURL: URL,
        destinationExists: Bool,
        dirCache: DirectoryCreationCache,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        isRemote: Bool? = nil,
        onBytesCopied: ((Int64) -> Void)?
    ) throws {
        let parentURL = destinationURL.deletingLastPathComponent()
        let parentPath = parentURL.path
        // 父目录已知创建失败：直接跳过，不再发起 createDirectory（防雪崩）。
        if dirCache.hasFailed(parentPath) {
            throw ServiceError.parentDirectoryUnavailable(parentPath)
        }
        // 父目录已成功创建（含已存在）：跳过 createDirectory，省一次网络往返。
        if !dirCache.hasSucceeded(parentPath) {
            do {
                try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
                dirCache.markSucceeded(parentPath)
            } catch {
                dirCache.markFailed(parentPath)
                throw error
            }
        }
        try copyFileWithProgress(from: sourceURL, to: destinationURL, destinationExists: destinationExists, isCancelled: isCancelled, isRemote: isRemote, onBytesCopied: onBytesCopied)
    }

    private func validateDirectory(_ url: URL, allowMissing: Bool = false) throws {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if !exists {
            if allowMissing { return }
            throw ServiceError.notDirectory(url.path)
        }
        guard isDirectory.boolValue else {
            throw ServiceError.notDirectory(url.path)
        }
    }

    /// 拒绝源/目标互为父子目录。标准化路径后比较前缀（带路径分隔符边界），
    /// 避免误判 `/x/ab` 与 `/x/a`。任一方尚不存在时跳过该方向检查。
    private func validateNotNested(sourceRoot: URL, destinationRoot: URL) throws {
        let sourcePath = sourceRoot.standardizedFileURL.path
        let destinationPath = destinationRoot.standardizedFileURL.path
        if isAncestor(sourcePath, of: destinationPath) || isAncestor(destinationPath, of: sourcePath) {
            throw ServiceError.nestedDirectory(source: sourcePath, destination: destinationPath)
        }
    }

    /// `ancestor` 是否是 `descendant` 的前缀目录（含相等）。标准化路径无尾斜杠，
    /// 故以 `ancestor + "/"` 作前缀判断，避免 `/x/a` 误判为 `/x` 的后代。
    private func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
        if descendant == ancestor { return true }
        return descendant.hasPrefix(ancestor + "/")
    }

    /// 非严格模式下「快速判定相同」的时间比对：两端修改时间均存在且相等即视为未变。
    /// 容忍 1 秒以内差异——FAT/exFAT/SMB 等文件系统 mtime 精度为 1~2 秒，跨卷复制后可能整秒漂移，
    /// 严格相等会把这些「实际相同」的文件误判为不同而回退全量 MD5，抵消快路径收益。
    private func sameTimestamp(source: FileNode, destination: FileNode) -> Bool {
        guard let sourceDate = source.modificationDate,
              let destinationDate = destination.modificationDate else {
            return false
        }
        return abs(sourceDate.timeIntervalSince(destinationDate)) <= 1
    }

    private func scan(root: URL, includeHiddenItems: Bool, phase: FileProgressPhase, progress: ProgressHandler?) throws -> [String: FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey, .contentModificationDateKey]
        // 收集无法访问的子目录（多为权限不足）：errorHandler 返回 true 跳过该子树继续扫描，
        // 避免 nil 时静默吞掉、用户不知道有目录被跳过；末尾汇总上报一次数量。
        var skippedSubtrees: [String] = []
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, _ in
                skippedSubtrees.append(url.path)
                return true
            }
        ) else {
            return [:]
        }

        var nodes: [String: FileNode] = [:]
        var scannedCount = 0
        // root 标准化一次，循环内只标准化每个 url，避免逐项重复计算。
        let rootPath = root.standardizedFileURL.path
        // resourceValues 的 key 集合在循环外构建一次，避免逐文件重复分配 Set。
        let resourceKeys = Set(keys)
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            // 在 Swift 并发线程上没有 autorelease pool，FileManager/URL 调用产生的
            // autorelease 对象会一直堆积。逐项包 autoreleasepool 及时排空，避免内存随扫描增长。
            let (relativePath, isDirectory, fileSize, modificationDate, isSymbolicLink): (String, Bool, Int64?, Date?, Bool) = try autoreleasepool {
                let values = try url.resourceValues(forKeys: resourceKeys)
                let relativePath = makeRelativePath(for: url, rootPath: rootPath)
                let isDirectory = values.isDirectory == true
                let fileSize = isDirectory ? nil : Int64(values.fileSize ?? 0)
                let modificationDate = values.contentModificationDate
                let isSymbolicLink = values.isSymbolicLink == true
                return (relativePath, isDirectory, fileSize, modificationDate, isSymbolicLink)
            }
            guard !relativePath.isEmpty else { continue }

            // 跳过符号链接：避免跟随目标造成跨目录复制或符号链接环死循环。
            if isSymbolicLink {
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            if !includeHiddenItems, isHidden(relativePath: relativePath) {
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            scannedCount += 1
            if scannedCount.isMultiple(of: 64) || scannedCount == 1 {
                progress?(FileOperationProgress(
                    phase: phase,
                    completedItems: scannedCount,
                    currentPath: relativePath,
                    message: phase.defaultMessage
                ))
            }

            nodes[relativePath] = FileNode(
                relativePath: relativePath,
                url: url,
                isDirectory: isDirectory,
                size: fileSize,
                modificationDate: modificationDate
            )
        }

        let finalMessage: String
        if skippedSubtrees.isEmpty {
            finalMessage = phase.defaultMessage
        } else {
            finalMessage = "扫描完成，跳过 \(skippedSubtrees.count) 个无法访问的子目录（可能无权限）。"
        }
        progress?(FileOperationProgress(
            phase: phase,
            completedItems: scannedCount,
            totalItems: scannedCount,
            currentPath: nil,
            message: finalMessage
        ))
        return nodes
    }

    private func buildComparisonItem(
        relativePath: String,
        source: FileNode?,
        destination: FileNode?,
        hashResult: HashResult? = nil,
        fastSame: Bool = false
    ) -> FileComparisonItem {
        let isDirectory = source?.isDirectory ?? destination?.isDirectory ?? false

        guard let source else {
            return FileComparisonItem(
                id: relativePath,
                relativePath: relativePath,
                sourceURL: nil,
                destinationURL: destination?.url,
                isDirectory: isDirectory,
                sourceSize: nil,
                destinationSize: destination?.size,
                sourceMD5: nil,
                destinationMD5: nil,
                status: .onlyInDestination,
                message: "路径 B 中存在，路径 A 中不存在；左向右合并时会保留。"
            )
        }

        guard let destination else {
            return FileComparisonItem(
                id: relativePath,
                relativePath: relativePath,
                sourceURL: source.url,
                destinationURL: nil,
                isDirectory: source.isDirectory,
                sourceSize: source.size,
                destinationSize: nil,
                sourceMD5: nil,
                destinationMD5: nil,
                status: .onlyInSource,
                message: "路径 A 中存在，路径 B 中不存在；合并时会复制到 B。"
            )
        }

        guard source.isDirectory == destination.isDirectory else {
            return FileComparisonItem(
                id: relativePath,
                relativePath: relativePath,
                sourceURL: source.url,
                destinationURL: destination.url,
                isDirectory: source.isDirectory,
                sourceSize: source.size,
                destinationSize: destination.size,
                sourceMD5: nil,
                destinationMD5: nil,
                status: .typeMismatch,
                message: "A 与 B 的同名路径类型不同；合并时会用 A 覆盖 B。"
            )
        }

        if source.isDirectory {
            return FileComparisonItem(
                id: relativePath,
                relativePath: relativePath,
                sourceURL: source.url,
                destinationURL: destination.url,
                isDirectory: true,
                sourceSize: nil,
                destinationSize: nil,
                sourceMD5: nil,
                destinationMD5: nil,
                status: .same,
                message: "目录均存在。"
            )
        }

        // 大小不同必然内容不同，直接判为 different，省去两次完整文件读取与 MD5 计算。
        if source.size != destination.size {
            return FileComparisonItem(
                id: relativePath,
                relativePath: relativePath,
                sourceURL: source.url,
                destinationURL: destination.url,
                isDirectory: false,
                sourceSize: source.size,
                destinationSize: destination.size,
                sourceMD5: nil,
                destinationMD5: nil,
                status: .different,
                message: "文件大小不同，合并时用 A 覆盖 B。"
            )
        }

        // 大小相同且（非严格模式下）修改时间一致：跳过 MD5，直接判相同。
        // 这是重扫主流场景——绝大多数文件未变，省去两次全量读盘。
        if fastSame {
            return FileComparisonItem(
                id: relativePath,
                relativePath: relativePath,
                sourceURL: source.url,
                destinationURL: destination.url,
                isDirectory: false,
                sourceSize: source.size,
                destinationSize: destination.size,
                sourceMD5: nil,
                destinationMD5: nil,
                status: .same,
                message: "大小与修改时间相同，跳过内容校验。"
            )
        }

        // 大小相同：使用并发哈希阶段预计算的结果。hashResult 理论上必存在（所有大小相同的
        // 同名文件都已纳入候选）；读取失败时记录为错误，MD5 留空。
        if let error = hashResult?.error {
            return FileComparisonItem(
                id: relativePath,
                relativePath: relativePath,
                sourceURL: source.url,
                destinationURL: destination.url,
                isDirectory: false,
                sourceSize: source.size,
                destinationSize: destination.size,
                sourceMD5: nil,
                destinationMD5: nil,
                status: .error,
                message: error.localizedDescription
            )
        }

        // 优先用逐块对比结果（非严格模式）；否则回退 MD5 相等判定（严格模式）。
        let sourceMD5 = hashResult?.sourceMD5
        let destinationMD5 = hashResult?.destinationMD5
        let same: Bool
        let sameMessage: String
        if let areEqual = hashResult?.areEqual {
            same = areEqual
            sameMessage = areEqual ? "文件内容相同（逐块比对），合并时跳过。" : "文件内容不同（逐块比对），合并时用 A 覆盖 B。"
        } else {
            same = sourceMD5 != nil && sourceMD5 == destinationMD5
            sameMessage = same ? "文件 MD5 相同，合并时跳过。" : "文件 MD5 不同，合并时用 A 覆盖 B。"
        }

        return FileComparisonItem(
            id: relativePath,
            relativePath: relativePath,
            sourceURL: source.url,
            destinationURL: destination.url,
            isDirectory: false,
            sourceSize: source.size,
            destinationSize: destination.size,
            sourceMD5: sourceMD5,
            destinationMD5: destinationMD5,
            status: same ? .same : .different,
            message: sameMessage
        )
    }

    private func mergeDirectory(item: FileComparisonItem, destinationURL: URL, summary: inout MergeSummary, dirCache: DirectoryCreationCache) throws {
        if item.status == .same {
            return
        }

        // 目标是否存在由对比结果得知（item.destinationURL 非空即存在），免去每次 fileExists 的网络往返。
        // 远程盘上目录多时，原先每目录 2 次 fileExists + 1 次 createDirectory 的 RTT 累积是主要瓶颈。
        let destinationExists = item.destinationURL != nil

        // typeMismatch：目标是同名文件，先删除再建目录。
        if item.status == .typeMismatch, destinationExists {
            try fileManager.removeItem(at: destinationURL)
        }

        // 目标不存在（或刚因 typeMismatch 删除）时创建目录。命中缓存则跳过 createDirectory。
        if !destinationExists || item.status == .typeMismatch {
            let path = destinationURL.path
            if dirCache.hasFailed(path) {
                throw ServiceError.parentDirectoryUnavailable(path)
            }
            if !dirCache.hasSucceeded(path) {
                do {
                    try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                    dirCache.markSucceeded(path)
                } catch {
                    dirCache.markFailed(path)
                    throw error
                }
            }
            summary.createdDirectories += 1
        }
    }

    private func mergeFile(
        item: FileComparisonItem,
        sourceURL: URL,
        destinationURL: URL,
        summary: inout MergeSummary,
        dirCache: DirectoryCreationCache,
        isRemote: Bool? = nil,
        onBytesCopied: ((Int64) -> Void)? = nil
    ) throws {
        switch item.status {
        case .same:
            summary.skippedFiles += 1
            return
        case .onlyInDestination, .error:
            return
        case .onlyInSource, .different, .typeMismatch:
            break
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        let parentPath = parentURL.path
        if dirCache.hasFailed(parentPath) {
            throw ServiceError.parentDirectoryUnavailable(parentPath)
        }
        if !dirCache.hasSucceeded(parentPath) {
            do {
                try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
                dirCache.markSucceeded(parentPath)
            } catch {
                dirCache.markFailed(parentPath)
                throw error
            }
        }

        // 目标是否已存在可由对比结果直接得知（destinationURL 非空即存在），免去一次网络 fileExists 往返。
        let destinationExists = item.destinationURL != nil
        try copyFileWithProgress(from: sourceURL, to: destinationURL, destinationExists: destinationExists, isRemote: isRemote, onBytesCopied: onBytesCopied)
        if destinationExists {
            summary.overwrittenFiles += 1
        } else {
            summary.copiedFiles += 1
        }
    }

    private func deleteDestinationOnlyItem(item: FileComparisonItem, summary: inout MergeSummary, isRemote: Bool) throws {
        guard let destinationURL = item.destinationURL else { return }
        guard fileManager.fileExists(atPath: destinationURL.path) else { return }

        do {
            try fileManager.removeItem(at: destinationURL)
            if item.isDirectory {
                summary.deletedDirectories += 1
            } else {
                summary.deletedFiles += 1
            }
        } catch {
            summary.errors.append("\(item.relativePath)：删除失败：\(Self.friendlyMessage(for: error, isRemote: isRemote))")
        }
    }

    private func isHidden(relativePath: String) -> Bool {
        // 任一路径组件以 "." 开头即为隐藏。等价于：相对路径自身以 "." 开头，
        // 或某处出现 "/."（分隔符后紧跟点，即下一个组件以点开头）。子串判断免去逐项 split 分配。
        relativePath.hasPrefix(".") || relativePath.contains("/.")
    }

    private func md5Hex(of url: URL, isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }, onBytesRead: ((Int64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = Insecure.MD5()
        while true {
            if isCancelled() { throw CancellationError() }
            let data = try autoreleasepool { try handle.read(upToCount: Self.ioChunkSize) ?? Data() }
            if data.isEmpty { break }
            hasher.update(data: data)
            onBytesRead?(Int64(data.count))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 逐块对比两端文件内容是否相同：同位置读等长块、逐块比较，首块不同即返回 false。
    /// 与「两端全量 MD5 再比」相比：差异文件首块即停、省下几乎全部读盘与哈希计算；
    /// 相同文件两端都需完整读一次（读盘量与两端 MD5 相同，但省去哈希计算）。
    /// 调用方已保证两端大小相同，故任一端读到末尾即视为比对完毕且相同。
    /// `sourceSize`/`destinationSize` 用于在差异文件提前退出时补报两端未读字节，
    /// 使 hashing 字节进度能收尾到 100%（与 totalHashBytes 的源+目口径对齐）。
    private func streamsEqual(
        sourceURL: URL,
        destinationURL: URL,
        sourceSize: Int64,
        destinationSize: Int64,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        onBytesRead: ((Int64) -> Void)? = nil
    ) throws -> Bool {
        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? sourceHandle.close() }
        let destinationHandle = try FileHandle(forReadingFrom: destinationURL)
        defer { try? destinationHandle.close() }

        var sourceRead: Int64 = 0
        var destRead: Int64 = 0
        while true {
            // 两端各读满一个块（或到 EOF）。readFullChunk 内部循环补齐短读，保证两端每次拿到等长块——
            // 直接 != 比较才不会被短读导致的长度差误判为内容不同（网络卷上短读常见）。
            let sourceData = try readFullChunk(from: sourceHandle, count: Self.ioChunkSize, isCancelled: isCancelled)
            let destData = try readFullChunk(from: destinationHandle, count: Self.ioChunkSize, isCancelled: isCancelled)
            // 双端大小相同：任一到末尾即比对完毕且此前各块均相同。
            if sourceData.isEmpty || destData.isEmpty {
                // 相同文件正常读到末尾，逐块已上报；空文件（首块即空）需补报两端 0 字节，无副作用。
                return true
            }
            sourceRead += Int64(sourceData.count)
            destRead += Int64(destData.count)
            // 上报双端字节数，使进度与 totalHashBytes（源+目）口径一致。
            onBytesRead?(Int64(sourceData.count))
            onBytesRead?(Int64(destData.count))
            if sourceData != destData {
                // 差异文件提前退出：补报两端未读字节，避免 hashing 字节进度卡在 <100%。
                let sourceRemain = max(0, sourceSize - sourceRead)
                let destRemain = max(0, destinationSize - destRead)
                if sourceRemain > 0 { onBytesRead?(sourceRemain) }
                if destRemain > 0 { onBytesRead?(destRemain) }
                return false
            }
        }
    }

    /// 从 handle 读取恰好 `count` 字节，或读到 EOF 返回剩余字节。
    /// `read(upToCount:)` 允许短读（返回少于请求数），SMB/NFS 等网络卷上尤其常见。
    /// 本函数内部循环补齐到 count（或 EOF），供 `streamsEqual` 两端读等长块比较，
    /// 避免短读导致块长度不等被 `!=` 误判为内容不同。本地卷一般一次读满，循环仅执行一次。
    private func readFullChunk(from handle: FileHandle, count: Int, isCancelled: @escaping @Sendable () -> Bool) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            if isCancelled() { throw CancellationError() }
            let chunk = try autoreleasepool { try handle.read(upToCount: count - data.count) ?? Data() }
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }

    /// 小文件直接整体复制的阈值（字节）：低于此值且目标在本地卷时走 `FileManager.copyItem`
    ///（底层 copyfile(2)，内核单次完成、属性随附保留），省去逐块读写与进度回调开销；
    /// 高于此值或目标在远程/网络卷时走分块路径以提供实时字节进度。
    private static let smallFileThreshold: Int64 = 4 * 1024 * 1024

    /// 流式读写块大小（字节）：哈希与分块复制共用。取 8MB 是为了在网络/远程卷上减少往返次数
    /// （SMB/NFS 每次读/写都是一次网络 RTT，块越大同等数据量 RTT 越少、吞吐越高）；
    /// 本地 SSD 同样受益于更少的 syscall 与内存分配。内存峰值受 hashAll 并发数约束，可控。
    private static let ioChunkSize = 8 * 1024 * 1024

    /// 网络/远程文件系统类型：这些卷 I/O 慢，小文件走 copyItem 会长时间无进度回调，
    /// 故强制走分块路径以提供实时字节进度与速度。
    private static let networkFilesystems: Set<String> = ["smbfs", "nfs", "afpfs", "cifs", "webdav", "osxfuse"]

    /// 复制单个文件，保证属性完整与失败时数据安全。
    ///
    /// - 本地小文件（≤阈值）走 `FileManager.copyItem`：内核 copyfile(2) 单次完成，属性（权限/属主/
    ///   xattr/时间）随附保留。copyItem 要求目标不存在，故先写临时文件再原子 rename 覆盖。
    /// - 大文件或远程/网络卷文件走 1MB 分块写入临时文件（提供实时字节进度），写完后补齐
    ///   POSIX 权限、修改时间、备份标志与扩展属性，最后原子 rename 覆盖目标。
    ///
    /// 任意阶段失败或取消都只清理临时文件，原目标完好无损；rename 在同卷上原子，
    /// 杜绝“原目标已删、新文件没写完”的数据丢失。
    private func copyFileWithProgress(from sourceURL: URL, to destinationURL: URL, destinationExists: Bool, isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }, isRemote: Bool? = nil, onBytesCopied: ((Int64) -> Void)? = nil) throws {
        let fileSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        // 目标卷是否远程：优先用调用方预算值（整个同步算一次），否则按目标路径 statfs。
        let remote = isRemote ?? isRemoteVolume(destinationURL)

        // 网络卷小文件、目标不存在时，直接 copyItem 到最终目标：内核 copyfile 单次完成、属性随附，
        // 省去「建 temp + 开关句柄 + 逐块读写 + 属性同步 + xattr 复制 + rename」的十余次网络往返。
        // 网络卷小文件瓶颈正是这些元数据往返而非数据量——一个 2KB 文件走分块路径要 12+ 次 RTT，
        // 实测吞吐仅 10~20KB/s；直接 copyItem 一步到位可提升一个数量级以上。
        // 进度上小文件本就该一次性完成，无需逐块回调。
        if remote && fileSize <= Self.smallFileThreshold && !destinationExists {
            do {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                onBytesCopied?(fileSize)
                return
            } catch {
                // copyItem 失败（如偶发连接抖动）回退到分块路径，保证健壮性。
            }
        }

        // 临时文件与目标同目录（同卷），确保 rename 原子。成功后回收句柄由各路径自行处理。
        let tempURL = makeTempURL(nextTo: destinationURL)

        // 本地小文件走 copyItem（内核 copyfile，属性随附）；大文件或网络卷覆盖场景走分块路径。
        let useFastPath = fileSize <= Self.smallFileThreshold && !remote
        var usedFastPath = false

        do {
            if useFastPath {
                // 小文件快路径：copyItem 完整保留属性。失败则回退到分块路径统一处理。
                do {
                    try fileManager.copyItem(at: sourceURL, to: tempURL)
                    onBytesCopied?(fileSize)
                    usedFastPath = true
                } catch {
                    try copyLargeFile(from: sourceURL, to: tempURL, fileSize: fileSize, isCancelled: isCancelled, onBytesCopied: onBytesCopied)
                }
            } else {
                try copyLargeFile(from: sourceURL, to: tempURL, fileSize: fileSize, isCancelled: isCancelled, onBytesCopied: onBytesCopied)
            }

            // 分块路径需补齐属性（权限/时间/xattr）；快路径 copyItem 已完整保留，跳过以省 I/O。
            if !usedFastPath {
                try syncFileAttributes(from: sourceURL, to: tempURL)
            }

            // 同卷原子 rename 覆盖目标。失败/取消至此为止原目标完好。
            _ = try replaceItem(at: destinationURL, with: tempURL, destinationExists: destinationExists)
        } catch {
            // 任何失败/取消：清理临时文件，原目标不受影响。
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    /// 大文件分块写入：1MB 读、写、实时回调已拷贝字节数。取消或写入失败时清理临时文件并抛出。
    /// `isCancelled` 由调用方传入：并发路径传脱离协作池后的取消标志，顺序路径默认 `Task.isCancelled`。
    /// 不用 `Task.checkCancellation()` 是因为本函数在并发路径下跑在全局并发队列上，那里读不到任务上下文。
    private func copyLargeFile(from sourceURL: URL, to tempURL: URL, fileSize: Int64, isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }, onBytesCopied: ((Int64) -> Void)?) throws {
        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? sourceHandle.close() }

        fileManager.createFile(atPath: tempURL.path, contents: nil)
        let destinationHandle = try FileHandle(forWritingTo: tempURL)
        defer { try? destinationHandle.close() }

        var copied: Int64 = 0
        while true {
            if isCancelled() { throw CancellationError() }
            let data = try autoreleasepool { try sourceHandle.read(upToCount: Self.ioChunkSize) ?? Data() }
            if data.isEmpty { break }
            try destinationHandle.write(contentsOf: data)
            copied += Int64(data.count)
            onBytesCopied?(copied)
        }
        // 确保数据落盘后再 rename。本地卷尽力 fsync（失败不致命）；远程/网络卷跳过 fsync——
        // 其代价高、语义不一，且可能抛错导致整文件复制失败，数据改由内核/网络栈异步刷盘。
        if !isRemoteVolume(tempURL) {
            try? destinationHandle.synchronize()
        }
    }

    /// 把底层文件错误翻译成对用户更友好的中文提示。系统默认的 `localizedDescription` 对网络卷上的权限
    /// 错误常显示成含糊的“你没有将文件……保存到文件夹……中的权限”，无法区分是只读共享、属主不符，
    /// 还是空间不足。这里按错误域与错误码归因，并在网络卷场景下点明“服务器侧拒绝写入”这一常见根因。
    ///
    /// `isRemote`：目标是否为网络/远程卷，由调用方按同步批次预算传入，决定权限类错误的措辞侧重。
    private static func friendlyMessage(for error: Error, isRemote: Bool) -> String {
        let nsError = error as NSError

        // POSIX 域：FileManager 在某些路径下直接抛 errno。先判此类，错误码语义稳定。
        if nsError.domain == NSPOSIXErrorDomain {
            let code = Int(nsError.code)
            switch code {
            case Int(EACCES), Int(EPERM):
                return isRemote
                    ? "网络共享卷拒绝写入（共享可能以只读权限挂载，或服务器账号无写权限）"
                    : "无写入权限（目标为只读，或属主不是当前用户）"
            case Int(EROFS):
                return "目标卷为只读"
            case Int(ENOSPC):
                return "目标卷剩余空间不足"
            case Int(ENOENT):
                return "文件或目录不存在（可能已被移动或删除）"
            default:
                break
            }
        }

        // Cocoa 域：NSFileWriteNoPermissionError 等是同步工具最常见的失败码。
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case 510: // NSFileWriteNoPermissionError
                return isRemote
                    ? "网络共享卷拒绝写入（共享可能以只读权限挂载，或服务器账号无写权限）"
                    : "无写入权限（目标为只读，或属主不是当前用户）"
            case 642: // NSFileWriteVolumeReadOnlyError
                return "目标卷为只读"
            case 640: // NSFileWriteOutOfSpaceError
                return "目标卷剩余空间不足"
            case 4:   // NSFileNoSuchFileError
                return "文件或目录不存在（可能已被移动或删除）"
            default:
                break
            }
            // 兜底：未明确匹配的写类错误（NSFileWrite* 错误码落在 512~660 区间），按文案归因，
            // 避免干巴巴地抛系统原文。含「权限」字样按权限问题提示，其余按通用写入失败提示。
            let code = nsError.code
            if code >= 512 && code <= 660 {
                let detail = error.localizedDescription
                if detail.contains("权限") || detail.lowercased().contains("permission") {
                    return isRemote
                        ? "网络共享卷拒绝写入（共享可能以只读权限挂载，或服务器账号无写权限）"
                        : "无写入权限（目标为只读，或属主不是当前用户）"
                }
                return "写入失败：\(detail)"
            }
        }

        return error.localizedDescription
    }

    /// 把源文件的 POSIX 权限位、修改时间、备份标志与扩展属性同步到目标。
    /// 小文件 copyItem 已保留这些，重复同步属幂等无副作用；大文件路径依赖此步补齐属性。
    private func syncFileAttributes(from sourceURL: URL, to destinationURL: URL) throws {
        // 权限位与修改时间走 FileManager 属性 API（URLResourceValues 的 posixPermissions 在部分 SDK 不可用）。
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        var toApply: [FileAttributeKey: Any] = [:]
        if let permissions = attributes[.posixPermissions] {
            toApply[.posixPermissions] = permissions
        }
        if let modificationDate = attributes[.modificationDate] {
            toApply[.modificationDate] = modificationDate
        }
        if !toApply.isEmpty {
            // 属性同步属“尽力而为”：网络卷（SMB/NFS 等）无真正 POSIX 权限，setAttributes 设权限位
            // 常抛 NSFileWriteNoPermissionError。此时数据已写入临时文件，不应因属性设不上而让整文件复制失败。
            try? fileManager.setAttributes(toApply, ofItemAtPath: destinationURL.path)
        }

        // 备份标志（isExcludedFromBackup）只能通过 URLResourceValues 设置。
        let sourceValues = try sourceURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        if let excluded = sourceValues.isExcludedFromBackup {
            var values = URLResourceValues()
            values.isExcludedFromBackup = excluded
            var mutableDestinationURL = destinationURL
            // 网络卷上设置备份标志同样可能失败，非关键属性，失败静默忽略。
            try? mutableDestinationURL.setResourceValues(values)
        }

        // 扩展属性（xattr）：copyItem 会保留，分块路径需手动复制，否则 quarantine、标签、自定义元数据丢失。
        try copyExtendedAttributes(from: sourceURL, to: destinationURL)
    }

    /// 复制源文件的全部扩展属性（xattr）到目标。属性已存在则覆盖，保证与源一致。
    private func copyExtendedAttributes(from sourceURL: URL, to destinationURL: URL) throws {
        let sourcePath = sourceURL.path
        let destinationPath = destinationURL.path

        // listxattr 返回以 NUL 分隔的属性名缓冲区；返回 0 表示无 xattr。
        let bufferSize = listxattr(sourcePath, nil, 0, 0)
        guard bufferSize > 0 else { return }
        var nameBuffer = [CChar](repeating: 0, count: bufferSize)
        let actual = listxattr(sourcePath, &nameBuffer, bufferSize, 0)
        guard actual > 0 else { return }

        // 拆分属性名并逐个复制值。注意：不能用 String(cString:)——它只读到第一个 NUL 就停，
        // 会丢掉后续所有属性名。把整个缓冲区按 UTF-8 解码后按 NUL 切分，才能拿到全部属性。
        let namesData = Data(bytes: nameBuffer, count: actual)
        let names = namesData.split(separator: 0, omittingEmptySubsequences: true).map { slice in
            String(decoding: slice, as: UTF8.self)
        }
        for name in names {
            let attrName = String(name)
            let valueSize = getxattr(sourcePath, attrName, nil, 0, 0, 0)
            guard valueSize >= 0 else { continue }
            var valueBuffer = [UInt8](repeating: 0, count: valueSize)
            let read = valueBuffer.withUnsafeMutableBufferPointer { ptr -> Int in
                getxattr(sourcePath, attrName, ptr.baseAddress, valueSize, 0, 0)
            }
            guard read >= 0 else { continue }
            valueBuffer.withUnsafeBufferPointer { ptr in
                _ = setxattr(destinationPath, attrName, ptr.baseAddress, valueSize, 0, 0)
            }
        }
    }

    /// 在目标同目录生成临时文件 URL（同卷，保证 rename 原子）。名字带固定前缀 + 进程级自增序号，
    /// 既便于辨识，又避免并发复制或残留 temp 文件撞名覆盖。序号比每文件生成 UUID 更轻。
    private func makeTempURL(nextTo destinationURL: URL) -> URL {
        let directory = destinationURL.deletingLastPathComponent()
        let baseName = destinationURL.lastPathComponent
        let token = Self.tempCounter.add(1)
        return directory.appendingPathComponent(".\(baseName).filesync-\(token)-tmp")
    }

    /// 网络卷 replaceItem 回退时旧目标的备份名：同目录、带固定前缀 + 进程级序号，便于辨识与清理。
    /// 序号避免并发复制或上次回退残留的 backup 撞名，导致 moveItem 覆盖失败。
    private func makeBackupURL(for destinationURL: URL) -> URL {
        let directory = destinationURL.deletingLastPathComponent()
        let baseName = destinationURL.lastPathComponent
        let token = Self.tempCounter.add(1)
        return directory.appendingPathComponent(".\(baseName).filesync-\(token)-backup")
    }

    /// 判断目标所在卷是否为网络/远程文件系统（SMB/NFS/AFP/WebDAV 等）。用父目录查询 statfs，
    /// 因为目标文件可能尚未创建；父目录在复制前已确保存在。
    private func isRemoteVolume(_ url: URL) -> Bool {
        let path = url.deletingLastPathComponent().path
        var buf = statfs()
        guard statfs(path, &buf) == 0 else { return false }
        let fstype = withUnsafePointer(to: &buf.f_fstypename) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        return Self.networkFilesystems.contains(fstype)
    }

    /// 用临时文件原子覆盖目标。`destinationExists` 由对比结果得知，免去一次 fileExists 网络往返：
    /// 目标存在时走 `FileManager.replaceItem`（同卷原子替换，无「先删后移」的目标缺失窗口）；
    /// 目标不存在时直接 move。
    @discardableResult
    private func replaceItem(at destinationURL: URL, with tempURL: URL, destinationExists: Bool) throws -> URL {
        if destinationExists {
            // 同卷原子替换优先：replaceItem 把 temp 整体替换到目标位置，无「先删后移」的目标缺失窗口。
            // 但网络卷（SMB/NFS 等）不支持原子替换语义，replaceItem 常抛 NSFileWriteNoPermissionError。
            // 安全回退：先把旧目标改名备份，再把 temp 移到位；移动失败则恢复备份——
            // 杜绝「旧文件已删、新文件没移成」的数据丢失（直接 remove+move 会有此窗口）。
            var resultingURL: NSURL?
            do {
                try fileManager.replaceItem(at: destinationURL, withItemAt: tempURL, backupItemName: nil, options: [], resultingItemURL: &resultingURL)
            } catch {
                let backupURL = makeBackupURL(for: destinationURL)
                // 旧目标改不动（只读/锁定）：直接尝试覆盖式移动，多数 SMB 实现支持 move 覆盖。
                // 此分支若失败，原目标仍在（备份没移走），temp 由外层清理，无数据丢失。
                do {
                    try fileManager.moveItem(at: destinationURL, to: backupURL)
                } catch {
                    try fileManager.moveItem(at: tempURL, to: destinationURL)
                    return destinationURL
                }
                // 旧目标已备份移走，目标位置此刻为空，temp 移入应成功；失败则恢复备份保住原数据。
                do {
                    try fileManager.moveItem(at: tempURL, to: destinationURL)
                    try? fileManager.removeItem(at: backupURL)
                } catch {
                    try? fileManager.moveItem(at: backupURL, to: destinationURL)
                    throw error
                }
            }
        } else {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }
        return destinationURL
    }

    private func makeRelativePath(for url: URL, rootPath: String) -> String {
        let fullPath = url.standardizedFileURL.path
        guard fullPath.hasPrefix(rootPath) else { return url.lastPathComponent }

        var relative = String(fullPath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative
    }
}
