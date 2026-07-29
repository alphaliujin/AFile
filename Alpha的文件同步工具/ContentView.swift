import SwiftUI

private extension Color {
    static let compareButtonGreen = Color(red: 0.00, green: 0.36, blue: 0.24)
    static let overwriteButtonOrangeRed = Color(red: 0.90, green: 0.30, blue: 0.16)
    static let mergeButtonLightGreen = Color(red: 0.78, green: 0.92, blue: 0.76)
    static let mergeButtonTextGreen = Color(red: 0.10, green: 0.36, blue: 0.16)
    static let stopButtonRed = Color(red: 0.78, green: 0.18, blue: 0.18)
}

struct ContentView: View {
    @ObservedObject var viewModel: FileCompareViewModel
    @State private var pendingOperation: FileOperation?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            pathSelection
                .padding(20)

            Divider()

            statisticsBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            comparisonTable
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
                .padding(20)
        }
        .frame(
            minWidth: 1120, idealWidth: 1180, maxWidth: .infinity,
            minHeight: 716, idealHeight: 776, maxHeight: .infinity
        )
        .alert("确认执行操作？", isPresented: Binding(
            get: { pendingOperation != nil },
            set: { isPresented in
                if !isPresented {
                    pendingOperation = nil
                }
            }
        )) {
            Button("取消", role: .cancel) {
                pendingOperation = nil
            }
            Button(pendingOperation?.confirmButtonTitle ?? "确认", role: .destructive) {
                let operation = pendingOperation
                pendingOperation = nil
                operation?.execute(using: viewModel)
            }
        } message: {
            Text(pendingOperation?.confirmationMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "arrow.left.arrow.right.square.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text("文件对比与拷贝合并")
                    .font(.largeTitle.bold())
                Text("选择路径 A 与路径 B，对比目录结构和文件 MD5，并支持双向合并与覆盖。")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            operationStatsPills
        }
        .padding(20)
    }

    /// 右上角操作统计胶囊：总用时与拷贝速度同时出现，操作结束后保留最终值。
    /// 速度胶囊过程中显示瞬时速度，完成后切换为全过程平均速度。
    @ViewBuilder
    private var operationStatsPills: some View {
        if let elapsed = viewModel.operationElapsed, let speed = viewModel.displaySpeed {
            HStack(spacing: 8) {
                elapsedPill(elapsed)
                speedPill(speed, isAverage: viewModel.isOperationFinished)
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .animation(.easeInOut(duration: 0.2), value: viewModel.operationElapsed != nil)
        }
    }

    private var pathSelection: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 12) {
                PathCard(
                    title: "路径 A",
                    systemImage: "a.square.fill",
                    path: $viewModel.sourcePath,
                    buttonTitle: "选择 A",
                    isDisabled: viewModel.isWorking,
                    action: { viewModel.choosePath(.source) }
                )

                OperationButtons(
                    direction: .leftToRight,
                    canOperate: viewModel.canCompare,
                    onOverwrite: { pendingOperation = FileOperation(mode: .overwrite, direction: .leftToRight, includeRootDirectory: viewModel.includeRootDirectory) },
                    onMerge: { pendingOperation = FileOperation(mode: .merge, direction: .leftToRight, includeRootDirectory: viewModel.includeRootDirectory) }
                )
            }

            VStack(spacing: 6) {
                Toggle("包含本目录", isOn: $viewModel.includeRootDirectory)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(viewModel.isWorking)
                Text("包含本目录")
                    .font(.caption2)
                    .lineLimit(1)
                    .fixedSize()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .padding(.top, 36)
            .help("开启后：同步时把源目录以其自身文件夹名放入目标目录（如 A→B 得到 B/<A 名>/…），而非直接铺到目标根。独立“对比”按 A→B 方向预览。")

            VStack(spacing: 12) {
                PathCard(
                    title: "路径 B",
                    systemImage: "b.square.fill",
                    path: $viewModel.destinationPath,
                    buttonTitle: "选择 B",
                    isDisabled: viewModel.isWorking,
                    action: { viewModel.choosePath(.destination) }
                )

                OperationButtons(
                    direction: .rightToLeft,
                    canOperate: viewModel.canCompare,
                    onOverwrite: { pendingOperation = FileOperation(mode: .overwrite, direction: .rightToLeft, includeRootDirectory: viewModel.includeRootDirectory) },
                    onMerge: { pendingOperation = FileOperation(mode: .merge, direction: .rightToLeft, includeRootDirectory: viewModel.includeRootDirectory) }
                )
            }
        }
    }

    private var statisticsBar: some View {
        let stats = viewModel.statistics
        return HStack(spacing: 10) {
            StatisticPill(title: "总计", value: stats.total, color: .secondary)
            StatisticPill(title: "仅 A", value: stats.onlyInSource, color: .blue)
            StatisticPill(title: "仅 B", value: stats.onlyInDestination, color: .purple)
            StatisticPill(title: "相同", value: stats.same, color: .green)
            StatisticPill(title: "不同", value: stats.different, color: .orange)
            StatisticPill(title: "类型冲突", value: stats.typeMismatch, color: .red)
            StatisticPill(title: "错误", value: stats.errors, color: .red)

            Spacer()

            if viewModel.isWorking, let progress = viewModel.operationProgress {
                operationProgressView(progress)
            } else if viewModel.isWorking {
                ProgressView()
                    .controlSize(.small)
                Text("处理中…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func operationProgressView(_ progress: FileOperationProgress) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 180)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(progress.message ?? progress.phase.defaultMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let currentPath = progress.currentPath {
                Text(currentPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .help(currentPath)
            }

            if let bytes = formatProgressBytes(progress.completedBytes, progress.totalBytes) {
                Text(bytes)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 拷贝速度胶囊：固定数字区宽度以保证「XXX MB/s」始终完整显示。
    /// 过程中显示瞬时速度、完成后显示全过程平均速度，用图标与提示文案区分。
    @ViewBuilder
    private func speedPill(_ speed: Double, isAverage: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isAverage ? "gauge.with.dots.needle.bottom.50percent" : "speedometer")
            Text(formatSpeed(speed))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)   // 固定数字区宽度，容纳 "999.9 MB/s"
        }
        .font(.callout.weight(.medium))
        .frame(height: 28)
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .help(isAverage ? "全过程平均拷贝速度" : "实时拷贝速度")
    }

    /// 总用时胶囊：显示在速度胶囊左侧，固定数字区宽度以容纳 "h:mm:ss"。
    @ViewBuilder
    private func elapsedPill(_ elapsed: TimeInterval) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
            Text(formatDuration(elapsed))
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)   // 固定数字区宽度，容纳 "59:59" / "1:00:00"
        }
        .font(.callout.weight(.medium))
        .frame(height: 28)
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .help("总用时")
    }

    private var comparisonTable: some View {
        ZStack {
            Table(of: FileComparisonItem.self) {
                TableColumn("状态") { item in
                    StatusBadge(status: item.status)
                }
                .width(min: 96, ideal: 120, max: 140)

                TableColumn("类型") { item in
                    Label(item.displayType, systemImage: item.isDirectory ? "folder" : "doc")
                }
                .width(min: 70, ideal: 80, max: 90)

                TableColumn("相对路径") { item in
                    Text(item.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.relativePath)
                }
                .width(min: 260, ideal: 420)

                TableColumn("A 大小") { item in
                    Text(formatBytes(item.sourceSize))
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100, max: 120)

                TableColumn("B 大小") { item in
                    Text(formatBytes(item.destinationSize))
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100, max: 120)

                TableColumn("说明") { item in
                    Text(item.message ?? "-")
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .help(item.message ?? "")
                }
                .width(min: 180, ideal: 320)
            } rows: {
                ForEach(viewModel.items) { item in
                    TableRow(item)
                }
            }

            if viewModel.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("暂无对比结果")
                        .font(.headline)
                    Text("选择路径 A 和路径 B 后点击“对比”。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                HStack(spacing: 12) {
                    Button {
                        viewModel.compare()
                    } label: {
                        Label("对比", systemImage: "list.bullet.rectangle")
                            .frame(minWidth: 96)
                    }
                    .buttonStyle(FilledButtonStyle(background: .compareButtonGreen, foreground: .white))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canCompare)

                    if viewModel.canRetry {
                        Button {
                            viewModel.retryFailed()
                        } label: {
                            Label("重试失败项", systemImage: "arrow.clockwise")
                                .frame(minWidth: 96)
                        }
                        .buttonStyle(FilledButtonStyle(background: .overwriteButtonOrangeRed, foreground: .white))
                        .help("用上次的同步配置重新执行：已成功的项自动跳过，仅重试失败的项。")
                    }

                    Toggle("包含隐藏文件与文件夹", isOn: $viewModel.includeHiddenItems)
                        .toggleStyle(.checkbox)
                        .disabled(viewModel.isWorking)

                    Text("可操作项：\(viewModel.mergeableItemCount)")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                if viewModel.isWorking {
                    Button {
                        viewModel.stop()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(FilledButtonStyle(background: .stopButtonRed, foreground: .white))
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "-" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatProgressBytes(_ completed: Int64?, _ total: Int64?) -> String? {
        guard let completed else { return nil }
        if let total, total > 0 {
            return "\(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        }
        return ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
    }

    /// 将字节/秒格式化为带 "/s" 后缀的可读速度，例如 "12.3 MB/s"。
    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let bytes = bytesPerSecond.isFinite ? Int64(bytesPerSecond.rounded()) : 0
        return "\(ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file))/s"
    }

    /// 将秒数格式化为 "m:ss" 或 "h:mm:ss"。
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

private struct PathCard: View {
    let title: String
    let systemImage: String
    @Binding var path: String
    let buttonTitle: String
    /// 任务进行中时禁用路径输入框与选择按钮，避免中途修改基准路径。
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            HStack(spacing: 8) {
                TextField("请选择文件夹路径", text: $path)
                    .textFieldStyle(.roundedBorder)

                Button(buttonTitle, action: action)
            }

            Text(path.isEmpty ? "未选择" : path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(path)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .disabled(isDisabled)
    }
}

private struct OperationButtons: View {
    let direction: MergeDirection
    let canOperate: Bool
    let onOverwrite: () -> Void
    let onMerge: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            switch direction {
            case .leftToRight:
                overwriteButton
                mergeButton
            case .rightToLeft:
                mergeButton
                overwriteButton
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var overwriteButton: some View {
        Button(action: onOverwrite) {
            Label("覆盖", systemImage: direction.symbolName)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(FilledButtonStyle(background: .overwriteButtonOrangeRed, foreground: .white))
        .disabled(!canOperate)
    }

    private var mergeButton: some View {
        Button(action: onMerge) {
            Label("合并", systemImage: direction.symbolName)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(FilledButtonStyle(background: .mergeButtonLightGreen, foreground: .mergeButtonTextGreen))
        .disabled(!canOperate)
    }
}

private struct FilledButtonStyle: ButtonStyle {
    let background: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(foreground)
            .padding(.vertical, 6)
            .background(background.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct StatisticPill: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
            Text("\(value)")
                .fontWeight(.semibold)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }
}

private struct StatusBadge: View {
    let status: ComparisonStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(statusColor, in: Capsule())
    }

    private var statusColor: Color {
        switch status {
        case .onlyInSource:
            return .blue
        case .onlyInDestination:
            return .purple
        case .same:
            return .green
        case .different:
            return .orange
        case .typeMismatch, .error:
            return .red
        }
    }
}

private enum FileOperationMode {
    case overwrite
    case merge
}

private enum MergeDirection {
    case leftToRight
    case rightToLeft

    var symbolName: String {
        switch self {
        case .leftToRight:
            return "arrow.right"
        case .rightToLeft:
            return "arrow.left"
        }
    }

    var displayName: String {
        switch self {
        case .leftToRight:
            return "A → B"
        case .rightToLeft:
            return "B → A"
        }
    }

    var sourceName: String {
        switch self {
        case .leftToRight:
            return "路径 A"
        case .rightToLeft:
            return "路径 B"
        }
    }

    var destinationName: String {
        switch self {
        case .leftToRight:
            return "路径 B"
        case .rightToLeft:
            return "路径 A"
        }
    }
}

private struct FileOperation {
    let mode: FileOperationMode
    let direction: MergeDirection
    /// 是否“包含本目录”：开启时源目录以其自身文件夹名放入目标目录下。
    let includeRootDirectory: Bool

    var confirmButtonTitle: String {
        switch mode {
        case .overwrite:
            return "覆盖"
        case .merge:
            return "合并"
        }
    }

    private var rootNote: String {
        includeRootDirectory
            ? "（包含本目录：\(direction.sourceName)会以其自身文件夹名放入\(direction.destinationName)下。）"
            : ""
    }

    var confirmationMessage: String {
        switch mode {
        case .overwrite:
            return "覆盖会按 \(direction.displayName) 执行：用\(direction.sourceName)完全同步\(direction.destinationName)。\(direction.sourceName)独有文件会复制，同名但 MD5 不同的文件会覆盖，\(direction.destinationName)独有的文件和文件夹会被删除。\(rootNote)建议先备份\(direction.destinationName)。"
        case .merge:
            return "合并会按 \(direction.displayName) 执行：把\(direction.sourceName)中新增或不同的文件同步到\(direction.destinationName)；MD5 相同的文件跳过，\(direction.destinationName)独有文件保留。\(rootNote)建议先备份\(direction.destinationName)。"
        }
    }

    @MainActor
    func execute(using viewModel: FileCompareViewModel) {
        switch direction {
        case .leftToRight:
            switch mode {
            case .overwrite:
                viewModel.overwriteLeftToRight()
            case .merge:
                viewModel.mergeLeftToRight()
            }
        case .rightToLeft:
            switch mode {
            case .overwrite:
                viewModel.overwriteRightToLeft()
            case .merge:
                viewModel.mergeRightToLeft()
            }
        }
    }
}
