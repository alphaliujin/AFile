import SwiftUI

@main
struct Alpha的文件同步工具App: App {
    // 注入 AppDelegate，用于在启动后预热 NSOpenPanel 共享子系统，
    // 避免用户第一次点击「选择 A/B」时承担系统框架的首次懒加载开销。
    @NSApplicationDelegateAdaptor private var appDelegate: OpenPanelPreheater
    // 主窗口与设置窗口共享同一 viewModel：设置里改的「严格 MD5」等选项立即作用于主窗口的对比/同步。
    @StateObject private var viewModel = FileCompareViewModel()

    var body: some Scene {
        WindowGroup("Alpha的文件同步工具") {
            // 不在此设固定 frame：ContentView 内部已用 min/ideal/max 控制尺寸与全屏自适应，
            // 外层固定 width/height 会盖住内部约束，导致全屏后内容不扩展。
            ContentView(viewModel: viewModel)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}

/// 在 App 启动后、窗口空闲的下一个 runloop tick 预热 NSOpenPanel：
/// 仅实例化并立即释放，触发底层共享服务（文件枚举、本地化、沙盒作用域等）的首次懒加载初始化，
/// 不弹窗、不阻塞首次窗口显示。代价挪到用户不可感知的启动阶段。
private final class OpenPanelPreheater: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            // 仅实例化即触发共享子系统初始化；不调用 runModal()，不弹窗。
            _ = NSOpenPanel()
        }
    }
}
