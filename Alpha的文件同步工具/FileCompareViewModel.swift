import AppKit
import Foundation

@MainActor
final class FileCompareViewModel: ObservableObject {
    enum PathSide {
        case source
        case destination
    }

    private enum SyncMode {
        case merge
        case overwrite
    }

    private enum MergeDirection {
        case leftToRight
        case rightToLeft
    }

    /// 上次同步的完整配置快照：重试时复用，确保「重试失败项」精确针对上次失败的那批，
    /// 而非用户改路径/选项后的新配置。所有字段在 sync 启动时一次性快照。
    private struct SyncConfig: Sendable {
        let mode: SyncMode
        let direction: MergeDirection
        let sourcePath: String
        let destinationPath: String
        let includeHiddenItems: Bool
        let includeRootDirectory: Bool
        let strictMD5: Bool
    }

    @Published var sourcePath = ""
    @Published var destinationPath = ""
    @Published var includeHiddenItems = false
    /// 严格 MD5 校验：关闭（默认）时，「大小+修改时间一致」即判相同、跳过内容读盘，重扫极快；
    /// 开启时对所有大小相同的文件两端全量 MD5，最稳但慢。对比与同步共用同一设置，保证两者判定一致。
    @Published var strictMD5 = UserDefaults.standard.object(forKey: "strictMD5") as? Bool ?? false {
        didSet { UserDefaults.standard.set(strictMD5, forKey: "strictMD5") }
    }
    /// 开启后：同步时把源目录以其自身文件夹名放入目标目录（如 A→B 得到 B/<A名>/…），而非直接铺到目标根。
    /// 独立“对比”按 A→B 方向预览（对比 A 根 vs B/<A名>）。
    @Published var includeRootDirectory = false {
        didSet {
            // 对比基准变了，旧结果作废。
            items = []
            mergeSummary = nil
            errorMessage = nil
            statusMessage = "“包含本目录”已\(includeRootDirectory ? "开启" : "关闭")，请重新对比。"
        }
    }
    @Published var items: [FileComparisonItem] = []
    @Published var isWorking = false
    @Published var statusMessage = "请选择路径 A 和路径 B，然后点击“开始对比”。"
    @Published var errorMessage: String?
    @Published var mergeSummary: MergeSummary?
    @Published var operationProgress: FileOperationProgress?
    /// 右上角显示的拷贝速度（字节/秒）：过程中为瞬时速度（仅拷贝阶段有值，非拷贝阶段为 0），
    /// 操作完成后替换为全过程平均速度（累计已拷贝字节 / 总用时）并保留，直至下次操作重置。
    @Published var displaySpeed: Double?
    /// 当前操作总用时（秒）。操作开始即有值，结束后保留最终值，直至下次操作开始重置。
    @Published var operationElapsed: TimeInterval?
    /// 操作是否已完成（用于界面区分瞬时/平均速度与是否仍在计时）。
    @Published var isOperationFinished = false

    /// 整个操作累计已拷贝字节数（取拷贝阶段 completedBytes 的高水位）。
    private var operationCopiedBytes: Int64 = 0
    /// 瞬时速度计算的滑动窗口样本：(时间点, 累计已拷贝字节)。
    private var instantSpeedSamples: [(ContinuousClock.Instant, Int64)] = []
    /// 总用时计时起点与刷新任务。
    private var operationStartTime: ContinuousClock.Instant?
    private var elapsedRefreshTask: Task<Void, Never>?

    /// 当前后台操作的取消句柄，供"停止"按钮调用。
    private var cancelCurrentWork: (@Sendable () -> Void)?
    /// 递增的操作标识：进度回调携带此 token，主线程只接受当前 token 的回调，
    /// 避免上一轮操作尚未派发完的进度回调污染新一轮的 operationProgress。
    private var currentOperationToken: UInt64 = 0
    /// 上次同步配置快照，供「重试失败项」复用。仅同步成功启动后才有值。
    private var lastSyncConfig: SyncConfig?
    /// App 退出通知观察者，退出时取消后台操作并停计时，避免 detached task 阻止退出。
    private var terminateObserver: NSObjectProtocol?

    init() {
        // App 退出时取消进行中的后台操作：detached task 跑在协作线程池外，关闭窗口不会自动取消，
        // 31 万文件级操作若未结束会阻止 App 正常退出。收到 willTerminate 即取消并停计时。
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cleanupForTermination()
        }
    }

    deinit {
        if let observer = terminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var statistics: CompareStatistics {
        CompareStatistics(items: items)
    }

    var mergeableItemCount: Int {
        items.filter(\.canMergeLeftToRight).count
    }

    var canCompare: Bool {
        !sourcePath.isEmpty && !destinationPath.isEmpty && !isWorking
    }

    var canMerge: Bool {
        canCompare && !items.isEmpty && mergeableItemCount > 0
    }

    /// 取消正在进行的对比/覆盖/合并操作。
    func stop() {
        cancelCurrentWork?()
    }

    /// 是否可重试失败项：有失败项、不在操作中、且存在上次同步配置快照。
    var canRetry: Bool {
        !isWorking && lastSyncConfig != nil && items.contains { $0.status == .error }
    }

    /// 重试上次同步中失败的项：用上次的配置快照重新执行完整同步。
    /// 已成功的项会被 compare 判为 .same 自动跳过，仅失败项重新尝试；
    /// dirCache 每次 sync 新建，不缓存上次失败，故修复权限后可重试成功。
    func retryFailed() {
        guard let config = lastSyncConfig, canRetry else { return }
        sync(mode: config.mode, direction: config.direction, configOverride: config)
    }

    /// App 退出时清理：取消后台操作并停计时，避免 detached task 阻止退出。
    private func cleanupForTermination() {
        cancelCurrentWork?()
        elapsedRefreshTask?.cancel()
        elapsedRefreshTask = nil
    }

    func choosePath(_ side: PathSide) {
        let panel = NSOpenPanel()
        panel.title = side == .source ? "选择路径 A" : "选择路径 B"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            switch side {
            case .source:
                sourcePath = url.path
            case .destination:
                destinationPath = url.path
            }
            items = []
            mergeSummary = nil
            errorMessage = nil
            statusMessage = "路径已更新，请重新对比。"
        }
    }

    /// 计算有效目标 URL：开启“包含本目录”时，把源目录以其自身文件夹名放入目标目录下，
    /// 即 `目标/<源目录名>`；否则直接用目标根。源目录始终以其根参与扫描/同步。
    private func effectiveDestinationURL(sourcePath: String, destinationPath: String) -> URL {
        let base = URL(fileURLWithPath: destinationPath, isDirectory: true)
        guard includeRootDirectory else { return base }
        let sourceName = (sourcePath as NSString).lastPathComponent
        return base.appendingPathComponent(sourceName, isDirectory: true)
    }

    /// 判断两条路径是否指向同一目录：解析符号链接并标准化后比较，避免 `~/a` 与 `/Users/x/a`
    /// 这类字符串不同但实际相同的路径被当作两个目录。
    private func isSameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        let leftURL = URL(fileURLWithPath: lhs, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let rightURL = URL(fileURLWithPath: rhs, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        return leftURL.path == rightURL.path
    }

    /// 进度节流状态，需要被后台线程回调安全访问。
    private final class ProgressThrottleState: @unchecked Sendable {
        private var lastEmit: ContinuousClock.Instant = .now
        private var lastPhase: FileProgressPhase?
        private let lock = NSLock()

        /// 返回是否应更新界面：阶段切换立即更新，否则最多约每 120ms 更新一次。
        func shouldEmit(for phase: FileProgressPhase) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let now = ContinuousClock.now
            let phaseChanged = phase != lastPhase
            let throttled = !phaseChanged && now - lastEmit < .milliseconds(120)
            lastPhase = phase
            if throttled { return false }
            lastEmit = now
            return true
        }
    }

    /// 构造后台进度回调，节流后切回主线程更新界面。携带操作 token，仅当与当前操作一致时才更新，
    /// 防止上一轮操作尚未派发完的回调污染新一轮的 operationProgress（竞态闪回）。
    private func makeProgressHandler(token: UInt64) -> FileMergeService.ProgressHandler {
        let throttle = ProgressThrottleState()
        return { [weak self] progress in
            guard throttle.shouldEmit(for: progress.phase) else { return }
            Task { @MainActor in
                guard let self, self.currentOperationToken == token else { return }
                self.operationProgress = progress
                self.updateInstantSpeed(progress)
                if let message = progress.message, !message.isEmpty {
                    self.statusMessage = message
                }
            }
        }
    }

    /// 跟踪累计已拷贝字节并计算瞬时速度：拷贝阶段取 completedBytes 高水位更新 operationCopiedBytes，
    /// 并用最近约 2 秒的样本计算瞬时吞吐量写入 displaySpeed；离开拷贝阶段则瞬时速度归零。
    private func updateInstantSpeed(_ progress: FileOperationProgress) {
        guard progress.phase == .copying, let completed = progress.completedBytes else {
            instantSpeedSamples.removeAll()
            if isOperationFinished == false { displaySpeed = 0 }
            return
        }

        if completed > operationCopiedBytes {
            operationCopiedBytes = completed
        }

        guard isOperationFinished == false else { return }
        let now = ContinuousClock.now
        instantSpeedSamples.append((now, completed))
        let cutoff = now - .seconds(2)
        while let first = instantSpeedSamples.first, first.0 < cutoff {
            instantSpeedSamples.removeFirst()
        }
        guard let oldest = instantSpeedSamples.first else { return }
        let deltaBytes = completed - oldest.1
        let delta = now - oldest.0
        let seconds = Double(delta.components.seconds) + Double(delta.components.attoseconds) / 1_000_000_000_000_000_000
        guard seconds > 0, deltaBytes >= 0 else { return }
        displaySpeed = Double(deltaBytes) / seconds
    }

    /// 开始总用时计时：重置计数、置初值（总用时与速度胶囊同时出现），启动约每 250ms 刷新一次的循环任务。
    /// 计时循环放在 detached 后台任务里 sleep 并计算耗时，仅最终写回主线程，避免被高频进度回调派生的
    /// 主线程任务挤占、出现「复制开始后耗时停滞」的现象。
    private func startElapsedTimer() {
        operationStartTime = ContinuousClock.now
        operationCopiedBytes = 0
        operationElapsed = 0
        displaySpeed = 0
        isOperationFinished = false
        instantSpeedSamples.removeAll()
        elapsedRefreshTask?.cancel()
        let start = ContinuousClock.now
        elapsedRefreshTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let delta = start.duration(to: ContinuousClock.now)
                let seconds = Double(delta.components.seconds) + Double(delta.components.attoseconds) / 1_000_000_000_000_000_000
                // 用非 self 名绑定强引用，避免 @Sendable 闭包内 guard let self 重绑定触发
                // 「captured var 'self'」警告；强引用仅存活于主线程闭包内，无跨线程持有。
                await MainActor.run { [weak self] in
                    guard let viewModel = self, viewModel.operationStartTime != nil else { return }
                    viewModel.operationElapsed = seconds
                }
            }
        }
    }

    /// 停止计时：取消刷新任务、标记完成，并将显示速度结算为全过程平均速度（累计字节 / 总用时），保留显示。
    private func stopElapsedTimer() {
        elapsedRefreshTask?.cancel()
        elapsedRefreshTask = nil
        operationStartTime = nil
        isOperationFinished = true
        if let elapsed = operationElapsed, elapsed > 0 {
            displaySpeed = Double(operationCopiedBytes) / elapsed
        } else {
            displaySpeed = 0
        }
    }

    func compare() {
        guard canCompare else { return }
        guard !isSameDirectory(sourcePath, destinationPath) else {
            errorMessage = "路径 A 和路径 B 不能是同一个目录。"
            return
        }

        let sourceURL = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let destinationURL = effectiveDestinationURL(sourcePath: sourcePath, destinationPath: destinationPath)
        let includeHiddenItemsSnapshot = includeHiddenItems
        let includeRootSnapshot = includeRootDirectory
        let strictMD5Snapshot = strictMD5
        currentOperationToken &+= 1
        let progressHandler = makeProgressHandler(token: currentOperationToken)

        isWorking = true
        errorMessage = nil
        mergeSummary = nil
        // 对比阶段无拷贝：清除上次同步残留的速度/用时胶囊，避免对比时显示陈旧的平均速度。
        operationElapsed = nil
        displaySpeed = nil
        isOperationFinished = false
        operationCopiedBytes = 0
        instantSpeedSamples.removeAll()
        operationProgress = FileOperationProgress(phase: .validating, message: FileProgressPhase.validating.defaultMessage)
        statusMessage = "正在扫描目录并计算 MD5，请稍候…"

        let compareTask = Task.detached(priority: .userInitiated) {
            try await FileMergeService().compare(
                sourceRoot: sourceURL,
                destinationRoot: destinationURL,
                includeHiddenItems: includeHiddenItemsSnapshot,
                destinationMayNotExist: includeRootSnapshot,
                strictMD5: strictMD5Snapshot,
                progress: progressHandler
            )
        }
        cancelCurrentWork = { @Sendable in compareTask.cancel() }

        Task {
            defer {
                isWorking = false
                cancelCurrentWork = nil
            }
            do {
                let allItems = try await compareTask.value
                let differentItems = allItems.filter { $0.status != .same }
                items = differentItems
                operationProgress = nil
                statusMessage = "对比完成，共发现 \(differentItems.count) 个差异项（已隐藏相同文件/目录）。"
            } catch is CancellationError {
                operationProgress = nil
                statusMessage = "对比已取消。"
            } catch {
                items = []
                operationProgress = nil
                errorMessage = error.localizedDescription
                statusMessage = "对比失败。"
            }
        }
    }

    func mergeLeftToRight() {
        sync(mode: .merge, direction: .leftToRight)
    }

    func mergeRightToLeft() {
        sync(mode: .merge, direction: .rightToLeft)
    }

    func overwriteLeftToRight() {
        sync(mode: .overwrite, direction: .leftToRight)
    }

    func overwriteRightToLeft() {
        sync(mode: .overwrite, direction: .rightToLeft)
    }

    private func sync(mode: SyncMode, direction: MergeDirection, configOverride: SyncConfig? = nil) {
        // configOverride 用于「重试失败项」：用上次同步的路径/选项快照，而非用户当前可能改动的值。
        // 普通同步不传，沿用当前 published 值。
        let effectiveSourcePath = configOverride?.sourcePath ?? sourcePath
        let effectiveDestinationPath = configOverride?.destinationPath ?? destinationPath
        guard !effectiveSourcePath.isEmpty, !effectiveDestinationPath.isEmpty else { return }
        guard !isSameDirectory(effectiveSourcePath, effectiveDestinationPath) else {
            errorMessage = "路径 A 和路径 B 不能是同一个目录。"
            return
        }

        let modeText = mode == .overwrite ? "覆盖" : "合并"
        let isRetry = configOverride != nil
        let includeHiddenItemsSnapshot = configOverride?.includeHiddenItems ?? includeHiddenItems
        let includeRootSnapshot = configOverride?.includeRootDirectory ?? includeRootDirectory
        let strictMD5Snapshot = configOverride?.strictMD5 ?? strictMD5
        currentOperationToken &+= 1
        let progressHandler = makeProgressHandler(token: currentOperationToken)

        let sourceURL: URL
        let destinationURL: URL
        let statusPrefix: String
        let successMessage: String

        switch direction {
        case .leftToRight:
            // A → B：以 A 为源，目标按“包含本目录”决定是否包到 B/<A名> 下。
            sourceURL = URL(fileURLWithPath: effectiveSourcePath, isDirectory: true)
            destinationURL = effectiveDestinationURL(sourcePath: effectiveSourcePath, destinationPath: effectiveDestinationPath)
            statusPrefix = isRetry ? "正在重试失败项（\(modeText)：A → B）…" : "正在执行左向右\(modeText)：A → B…"
            successMessage = isRetry ? "重试完成。" : "\(modeText)完成，路径 B 已按路径 A 更新。"
        case .rightToLeft:
            // B → A：以 B 为源，目标按“包含本目录”决定是否包到 A/<B名> 下。
            sourceURL = URL(fileURLWithPath: effectiveDestinationPath, isDirectory: true)
            destinationURL = effectiveDestinationURL(sourcePath: effectiveDestinationPath, destinationPath: effectiveSourcePath)
            statusPrefix = isRetry ? "正在重试失败项（\(modeText)：B → A）…" : "正在执行右向左\(modeText)：B → A…"
            successMessage = isRetry ? "重试完成。" : "\(modeText)完成，路径 A 已按路径 B 更新。"
        }

        isWorking = true
        errorMessage = nil
        mergeSummary = nil
        // 快照本次同步配置，供「重试失败项」复用：用启动时的路径与选项，而非用户后续可能改动的当前值。
        // 重试本身用覆盖值执行，但仍记录一份（与实际执行一致的覆盖值），保持快照与本次执行同步。
        lastSyncConfig = SyncConfig(
            mode: mode,
            direction: direction,
            sourcePath: effectiveSourcePath,
            destinationPath: effectiveDestinationPath,
            includeHiddenItems: includeHiddenItemsSnapshot,
            includeRootDirectory: includeRootSnapshot,
            strictMD5: strictMD5Snapshot
        )
        operationProgress = FileOperationProgress(phase: .validating, message: statusPrefix)
        statusMessage = statusPrefix
        startElapsedTimer()

        let syncTask = Task.detached(priority: .userInitiated) {
            let service = FileMergeService()
            switch mode {
            case .merge:
                return try await service.mergeLeftToRight(sourceRoot: sourceURL, destinationRoot: destinationURL, includeHiddenItems: includeHiddenItemsSnapshot, destinationMayNotExist: includeRootSnapshot, strictMD5: strictMD5Snapshot, progress: progressHandler)
            case .overwrite:
                return try await service.overwriteLeftToRight(sourceRoot: sourceURL, destinationRoot: destinationURL, includeHiddenItems: includeHiddenItemsSnapshot, destinationMayNotExist: includeRootSnapshot, strictMD5: strictMD5Snapshot, progress: progressHandler)
            }
        }
        cancelCurrentWork = { @Sendable in syncTask.cancel() }

        Task {
            defer {
                isWorking = false
                cancelCurrentWork = nil
                stopElapsedTimer()
            }
            do {
                let summary = try await syncTask.value

                mergeSummary = summary
                // 直接复用同步过程中已按执行结果更新的 items，无需再扫一遍路径/重算 MD5。
                items = summary.items.filter { $0.status != .same }
                operationProgress = nil
                let actionText = isRetry ? "重试" : modeText
                statusMessage = summary.hasErrors ? "\(actionText)完成，但有 \(summary.errors.count) 个错误。" : successMessage
            } catch is CancellationError {
                operationProgress = nil
                statusMessage = isRetry ? "重试已取消。" : "\(modeText)已取消。"
            } catch {
                operationProgress = nil
                errorMessage = error.localizedDescription
                statusMessage = isRetry ? "重试失败。" : "\(modeText)失败。"
            }
        }
    }
}
