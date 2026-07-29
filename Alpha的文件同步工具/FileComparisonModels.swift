import Foundation

/// 对比状态。合并会保留目标路径独有内容；覆盖会删除目标路径独有内容。
enum ComparisonStatus: String, CaseIterable, Sendable {
    case onlyInSource
    case onlyInDestination
    case same
    case different
    case typeMismatch
    case error

    var title: String {
        switch self {
        case .onlyInSource:
            return "仅 A 存在"
        case .onlyInDestination:
            return "仅 B 存在"
        case .same:
            return "相同"
        case .different:
            return "MD5 不同"
        case .typeMismatch:
            return "类型冲突"
        case .error:
            return "错误"
        }
    }
}

/// 文件或目录在路径 A / 路径 B 中的一条对比结果。
struct FileComparisonItem: Identifiable, Sendable {
    let id: String
    let relativePath: String
    let sourceURL: URL?
    let destinationURL: URL?
    let isDirectory: Bool
    let sourceSize: Int64?
    let destinationSize: Int64?
    let sourceMD5: String?
    let destinationMD5: String?
    /// 同步过程中会按执行结果就地更新（成功→.same，失败→.error），用于同步后刷新差异列表。
    var status: ComparisonStatus
    var message: String?

    var displayType: String {
        return isDirectory ? "目录" : "文件"
    }

    var canMergeLeftToRight: Bool {
        switch status {
        case .onlyInSource, .different, .typeMismatch:
            return sourceURL != nil
        case .same, .onlyInDestination, .error:
            return false
        }
    }
}

/// 左向右合并结果。
struct MergeSummary: Sendable {
    var copiedFiles = 0
    var overwrittenFiles = 0
    var skippedFiles = 0
    var createdDirectories = 0
    var deletedFiles = 0
    var deletedDirectories = 0
    var errors: [String] = []
    /// 同步后各路径的最新对比结果（已按执行结果更新状态），供调用方直接刷新界面，免去重新扫描。
    var items: [FileComparisonItem] = []

    var hasErrors: Bool {
        !errors.isEmpty
    }

    var userMessage: String {
        var parts = [
            "新增文件 \(copiedFiles)",
            "覆盖文件 \(overwrittenFiles)",
            "跳过相同文件 \(skippedFiles)",
            "创建目录 \(createdDirectories)",
            "删除文件 \(deletedFiles)",
            "删除目录 \(deletedDirectories)"
        ]

        if hasErrors {
            parts.append("错误 \(errors.count)")
        }

        return parts.joined(separator: "，")
    }
}

/// 文件操作的进度阶段。
enum FileProgressPhase: Sendable, Equatable {
    case validating
    case scanningSource
    case scanningDestination
    case comparing
    case hashing
    case applyingChanges
    case copying
    case deleting

    var defaultMessage: String {
        switch self {
        case .validating:
            return "正在校验路径…"
        case .scanningSource:
            return "正在扫描路径 A…"
        case .scanningDestination:
            return "正在扫描路径 B…"
        case .comparing:
            return "正在生成对比结果…"
        case .hashing:
            return "正在计算 MD5…"
        case .applyingChanges:
            return "正在处理目录结构…"
        case .copying:
            return "正在复制文件…"
        case .deleting:
            return "正在删除文件…"
        }
    }
}

/// 对比或同步过程中的一次进度快照。
struct FileOperationProgress: Sendable, Equatable {
    let phase: FileProgressPhase
    let completedItems: Int
    let totalItems: Int?
    let completedBytes: Int64?
    let totalBytes: Int64?
    let currentPath: String?
    let message: String?

    init(
        phase: FileProgressPhase,
        completedItems: Int = 0,
        totalItems: Int? = nil,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        currentPath: String? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentPath = currentPath
        self.message = message
    }

    /// 进度比例，优先按字节计算，其次按条目数；未知总量时为 nil（界面用不确定进度条）。
    var fraction: Double? {
        if let totalBytes, totalBytes > 0, let completedBytes {
            return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
        }
        if let totalItems, totalItems > 0 {
            return min(1, max(0, Double(completedItems) / Double(totalItems)))
        }
        return nil
    }
}

/// 顶部统计卡片展示的数据。
struct CompareStatistics: Sendable {
    let total: Int
    let onlyInSource: Int
    let onlyInDestination: Int
    let same: Int
    let different: Int
    let typeMismatch: Int
    let errors: Int

    init(items: [FileComparisonItem]) {
        var onlyInSource = 0
        var onlyInDestination = 0
        var same = 0
        var different = 0
        var typeMismatch = 0
        var errors = 0
        for item in items {
            switch item.status {
            case .onlyInSource: onlyInSource += 1
            case .onlyInDestination: onlyInDestination += 1
            case .same: same += 1
            case .different: different += 1
            case .typeMismatch: typeMismatch += 1
            case .error: errors += 1
            }
        }
        total = items.count
        self.onlyInSource = onlyInSource
        self.onlyInDestination = onlyInDestination
        self.same = same
        self.different = different
        self.typeMismatch = typeMismatch
        self.errors = errors
    }
}
