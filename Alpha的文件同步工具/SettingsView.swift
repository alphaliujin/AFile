import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: FileCompareViewModel

    var body: some View {
        Form {
            Section("对比与同步") {
                Toggle("严格 MD5 校验", isOn: $viewModel.strictMD5)
                    .help("关闭（默认）：大小与修改时间一致的文件直接判为相同，跳过内容读盘，重扫极快。开启：对所有大小相同的文件两端全量 MD5，最稳但慢。对比与同步共用此设置。")
                if viewModel.strictMD5 {
                    Text("已开启严格校验：所有大小相同的文件都将计算两端 MD5。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("已关闭：大小与修改时间一致的文件跳过 MD5，重扫更快。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("关于") {
                LabeledContent("版本", value: appVersion)
                LabeledContent("最低系统版本", value: "macOS 13 Ventura")
                LabeledContent("界面框架", value: "SwiftUI")
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(width: 460)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }
}

#if DEBUG
#Preview {
    SettingsView(viewModel: FileCompareViewModel())
}
#endif
