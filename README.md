# Alpha的文件同步工具

一个完整的纯 SwiftUI macOS 13+ 桌面项目，用于文件夹 A / 文件夹 B 的目录结构对比、文件 MD5 对比，以及双向合并与覆盖。项目包含 Xcode 工程与一键 DMG 打包脚本，脚本会编译 Universal 2 通用二进制（arm64 + x86_64），并生成标准拖拽安装 DMG（`.app` + `Applications` 快捷链接）。

## 功能说明

- 左右双栏路径选择：左边为路径 A（源目录），右边为路径 B（目标目录）。
- 对比路径 A 与路径 B 下的文件和目录结构。
- MD5 相同：标记为“相同”，合并/覆盖时跳过；
  - MD5 不同：标记为“MD5 不同”，合并/覆盖时用源路径覆盖目标路径。
- 路径 A 独有文件：A → B 时复制到路径 B。
- 路径 B 独有文件：A → B 合并时保留，A → B 覆盖时删除。
- 同名路径类型冲突（例如 A 是文件、B 是目录）：合并时用 A 覆盖 B。
- 合并/覆盖前弹出确认提示，降低误操作风险。

> 重要：覆盖会删除目标路径独有的文件和文件夹。正式使用前建议先备份目标路径。

## 更新历史

### 1.4.x

自 1.3.7 起的累积更新（1.4.0 – 1.4.2）。本项目无独立版本历史记录，以下按特性汇总。

- **新增「严格 MD5 校验」开关（设置窗口，默认关闭）**：关闭时「大小 + 修改时间一致」即判相同、跳过内容读盘，重扫极快；开启时对所有大小相同的文件两端全量 MD5，最稳但慢。对比与同步共用此设置，已持久化到 UserDefaults。
- **非严格模式改用逐块内容对比替代两端全量 MD5**：同位置读等长块比较，首块不同即停，差异文件省下几乎全部读盘与哈希计算；两端块内部补齐短读，避免网络卷短读导致相同文件被误判为不同。
- **新增「包含本目录」开关**：开启后同步时把源目录以其自身文件夹名放入目标目录下（如 A→B 得 `B/<A 名>/…`），而非直接铺到目标根；独立「对比」按该方向预览。
- **新增「重试失败项」**：用上次同步的完整配置快照（路径、选项、方向）重新执行，已成功项自动跳过，仅重试失败项；修复权限或网络重连后可重试成功。
- **网络卷连接断开恢复**：整批复制全失败时（SMB/NFS 会话被服务器或 macOS 断开）指数退避等待重连（2s→30s，上限 5 分钟），恢复后清除目录创建的失败误判并重试本批，避免剩余文件雪崩失败、白费已复制进度。
- **目录创建缓存**：贯穿顺序与并发阶段记录「已成功 / 已失败」目录，同目录只 `createDirectory` 一次；某目录创建失败则其下文件直接跳过，防止逐文件重复失败的雪崩与错误刷屏；断连恢复后清除失败标记重试。
- **网络卷小文件直接 `copyItem`**：≤ 4MB 且目标不存在时一步到位（内核 copyfile 单次完成、属性随附），省去「建 temp + 开关句柄 + 逐块读写 + 属性同步 + xattr + rename」的十余次网络往返，小文件吞吐提升约一个数量级。
- **操作统计胶囊**：右上角显示总用时与拷贝速度，过程中为瞬时速度、完成后切为全过程平均速度并保留；计时放后台任务，避免被高频进度回调挤占主线程导致耗时停滞。
- **错误提示友好化**：按 POSIX/Cocoa 错误域与错误码归因，把网络卷上含糊的系统原文翻译为「网络共享卷拒绝写入」「目标卷剩余空间不足」等可操作提示，并按本地 / 网络卷区分措辞。
- **原子覆盖回退**：`replaceItem` 在网络卷不支持原子替换时，改为「旧目标改名备份 → 移入新文件 → 失败则恢复备份」，杜绝「旧文件已删、新文件没移成」的数据丢失窗口。
- **启动预热 NSOpenPanel**：App 启动后预热 NSOpenPanel 共享子系统，消除首次点击「选择 A/B」的系统框架懒加载开销。

### 1.3.7

- 大幅加速目录结构创建：非空目录不再逐一显式创建（由文件复制自动建出父目录），仅空目录与类型冲突项显式处理，消除远程盘上每个目录的冗余网络往返。
- 目录创建去除冗余 `fileExists` 探测，目标是否存在由对比结果直接得知。
- 修复并发复制阶段总耗时计时停滞：计时循环改到后台任务，避免被高频进度回调挤占主线程。

### 1.3.1

- 采用并发传输模式：合并/覆盖时对独立文件并发复制，显著提升大量小文件（尤其向网络共享盘）的同步速度。
- 复制改为临时文件 + 原子 rename，失败或取消时原目标不受影响，杜绝数据丢失。
- 大文件复制补齐 POSIX 权限与扩展属性（xattr），与源文件保持一致。
- 拒绝源/目标互为父子目录的同步，避免目录无限嵌套复制。
- 进度回调加操作 token，修复连续操作时进度条闪回的竞态。
- I/O 块由 1MB 提升至 8MB，减少网络往返次数。

### 1.2.x

- 远程/网络卷强制走分块复制路径，修复进度与速度显示为 0 的问题。
- 对比阶段 MD5 并发计算；扫描跳过符号链接，避免目录环。
- 任务进行中禁用全部控件，仅保留「停止」可用。

## 环境要求

- macOS 13 Ventura 或以上
- Xcode 14 或以上（建议 Xcode 15+）
- Command Line Tools 已正确选择：

```bash
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -version
```

## 工程结构

```text
.
├── Alpha的文件同步工具.xcodeproj/
│   ├── project.pbxproj                         # Xcode 工程配置
│   └── xcshareddata/xcschemes/Alpha的文件同步工具.xcscheme
├── Alpha的文件同步工具/
│   ├── Alpha的文件同步工具App.swift                   # App 入口
│   ├── ContentView.swift                       # SwiftUI 主界面：左右路径、对比表、合并按钮
│   ├── FileComparisonModels.swift              # 对比状态、对比项、统计与合并结果模型
│   ├── FileCompareViewModel.swift              # 界面状态、路径选择、对比/合并调度
│   ├── FileMergeService.swift                  # 目录扫描、MD5 计算、A → B 合并逻辑
│   ├── SettingsView.swift                      # 设置窗口示例
│   ├── Info.plist                              # App 元信息
│   └── Alpha的文件同步工具.entitlements               # 签名/权限配置
├── build_dmg.sh                                # 一键构建并生成 DMG
├── build/                                      # 构建输出，脚本运行后生成
└── README.md
```

## 本地运行和测试

### 方式一：Xcode 运行

1. 双击打开 `Alpha的文件同步工具.xcodeproj`。
2. 选择 `Alpha的文件同步工具` Scheme。
3. 选择 `My Mac` 作为运行目标。
4. 按 `⌘R` 运行。
5. 在界面中分别点击 `选择 A`、`选择 B`，选择两个目录。
6. 点击 `对比`。
7. 确认结果后点击对应方向的 `合并` 或 `覆盖` 按钮。

### 方式二：命令行 Debug 编译

```bash
xcodebuild \
  -project Alpha的文件同步工具.xcodeproj \
  -scheme Alpha的文件同步工具 \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

### 方式三：一键生成 DMG

首次运行前给脚本执行权限：

```bash
chmod +x build_dmg.sh
```

生成安装包：

```bash
./build_dmg.sh
```

输出位置：

```text
build/Export/Alpha的文件同步工具.app
build/Alpha的文件同步工具.dmg
```

脚本会自动执行以下步骤：

1. 清理 `build/`。
2. 使用 `xcodebuild` 编译 Release App。
3. 强制构建 `ARCHS="arm64 x86_64"`，并设置 `ONLY_ACTIVE_ARCH=NO`。
4. 使用 `lipo -info` 校验 App 主二进制同时包含 arm64 与 x86_64。
5. 创建 DMG 临时目录。
6. 放入 `Alpha的文件同步工具.app`。
7. 创建 `/Applications` 快捷链接。
8. 使用 `hdiutil` 创建并压缩为 `UDZO` 格式 DMG。

验证架构：

```bash
lipo -info build/Export/Alpha的文件同步工具.app/Contents/MacOS/Alpha的文件同步工具
```

预期输出包含：

```text
Architectures in the fat file: ... are: x86_64 arm64
```

## 合并与覆盖规则详解

点击 `合并` 或 `覆盖` 后，程序会重新扫描并按所选方向执行。方向可以是 A → B，也可以是 B → A。

| 状态 | 合并动作 | 覆盖动作 |
| --- | --- | --- |
| 仅源路径存在 | 复制到目标路径 | 复制到目标路径 |
| 仅目标路径存在 | 保留，不删除 | 删除目标路径独有文件/文件夹 |
| 相同 | MD5 相同，跳过 | MD5 相同，跳过 |
| MD5 不同 | 用源路径覆盖目标路径 | 用源路径覆盖目标路径 |
| 类型冲突 | 删除目标中同名路径，再复制/创建源路径 | 删除目标中同名路径，再复制/创建源路径 |
| 错误 | 跳过并记录错误 | 跳过并记录错误 |

目录会优先创建；删除目标独有目录时会先删除子项，再删除父目录。

## Developer ID 签名

如只是本机开发测试，可以直接运行 `./build_dmg.sh` 生成未签名 DMG。

如果要分发给其他 Mac 用户，建议使用 Apple Developer Program 的 `Developer ID Application` 证书进行签名和公证。

### 1. 查看本机可用证书

```bash
security find-identity -v -p codesigning
```

找到类似以下证书名称：

```text
Developer ID Application: Your Name (TEAMID)
```

### 2. 使用 Developer ID 构建并签名

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
TEAM_ID="TEAMID" \
./build_dmg.sh
```

脚本会：

- 启用 Manual Code Signing；
- 启用 Hardened Runtime；
- 给 App 添加 timestamp；
- 校验 App 签名；
- 对最终 DMG 签名。

检查 App 签名：

```bash
codesign --verify --deep --strict --verbose=2 build/Export/Alpha的文件同步工具.app
codesign -dv --verbose=4 build/Export/Alpha的文件同步工具.app
```

检查 DMG 签名：

```bash
codesign --verify --verbose=2 build/Alpha的文件同步工具.dmg
```

## 公证 Notarization

Apple 公证需要 Apple ID、Team ID，以及 App Store Connect 中创建的 app-specific password，或使用已保存的 notarytool profile。

### 方式一：保存 notarytool 凭据（推荐）

```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "your-apple-id@example.com" \
  --team-id "TEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

提交公证：

```bash
xcrun notarytool submit build/Alpha的文件同步工具.dmg \
  --keychain-profile "AC_PASSWORD" \
  --wait
```

公证成功后 stapler 到 DMG：

```bash
xcrun stapler staple build/Alpha的文件同步工具.dmg
xcrun stapler validate build/Alpha的文件同步工具.dmg
```

### 方式二：直接传 Apple ID 参数

```bash
xcrun notarytool submit build/Alpha的文件同步工具.dmg \
  --apple-id "your-apple-id@example.com" \
  --team-id "TEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx" \
  --wait

xcrun stapler staple build/Alpha的文件同步工具.dmg
```

### 查看公证失败日志

如果公证失败，notarytool 会返回 submission id。使用：

```bash
xcrun notarytool log <submission-id> --keychain-profile "AC_PASSWORD"
```

常见原因：

- 没有使用 `Developer ID Application` 证书；
- 未启用 Hardened Runtime；
- 嵌套 helper、framework、工具未逐个签名；
- Bundle ID、Team ID、证书不匹配；
- DMG 或 App 在签名后又被修改。

## 解决 “无法验证开发者” 弹窗

### 对最终用户的推荐解决方式

最理想方式是开发者完成：

1. Developer ID 签名；
2. Apple Notarization 公证；
3. `stapler` 将公证票据装订到 DMG；
4. 重新分发已公证的 DMG。

这样用户双击打开时通常不会出现 “无法验证开发者”。

### 用户临时打开未签名版本

如果是内部测试包或未签名包，用户可能看到：

> macOS 无法验证此 App 是否包含恶意软件

可使用以下方式打开：

1. 打开 `系统设置` → `隐私与安全性`。
2. 在安全提示区域点击 `仍要打开`。
3. 或者在 Finder 中按住 `Control` 点击 App，选择 `打开`，再确认。

也可以对本地测试文件移除 quarantine 标记：

```bash
xattr -dr com.apple.quarantine /Applications/Alpha的文件同步工具.app
```

如果是直接测试 DMG：

```bash
xattr -dr com.apple.quarantine build/Alpha的文件同步工具.dmg
```

> 注意：`xattr -dr com.apple.quarantine` 仅适合可信来源的内部测试，不应作为公开分发方案。公开分发应使用 Developer ID 签名和 Apple 公证。

## 修改 App 名称与 Bundle ID

如需改名，请同步修改：

- `build_dmg.sh` 中的 `APP_NAME`、`SCHEME`、`BUNDLE_ID`；
- `Alpha的文件同步工具.xcodeproj/project.pbxproj` 中的 `PRODUCT_BUNDLE_IDENTIFIER`、target 名称；
- 源码目录和 Swift App 入口结构体名（可选，但建议一致）。

## 常见问题

### xcodebuild 找不到 Scheme

确认存在共享 Scheme：

```text
Alpha的文件同步工具.xcodeproj/xcshareddata/xcschemes/Alpha的文件同步工具.xcscheme
```

也可执行：

```bash
xcodebuild -list -project Alpha的文件同步工具.xcodeproj
```

### 生成的不是 Universal 2

请确认脚本输出的 `lipo -info` 包含 `arm64` 和 `x86_64`。脚本已设置：

```bash
ARCHS="arm64 x86_64"
ONLY_ACTIVE_ARCH=NO
```

本项目无第三方依赖，因此应可直接生成 Universal 2。

### Intel Mac 上构建 arm64 失败

请使用较新的 Xcode 和 macOS SDK。若 SDK 不完整，先打开 Xcode 完成组件安装，或运行：

```bash
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```

### 无法访问某些目录

如果选择了桌面、文稿、下载、外接盘或网络盘，macOS 可能弹出权限请求。请允许访问；若仍失败，到 `系统设置` → `隐私与安全性` 中检查 App 的文件访问权限。

## 交付文件

对外分发时通常只需要：

```text
build/Alpha的文件同步工具.dmg
```

开发交付或二次开发时保留完整工程：

```text
Alpha的文件同步工具.xcodeproj
Alpha的文件同步工具/
build_dmg.sh
README.md
```
