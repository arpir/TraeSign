# TraeSign（macOS 版）

**三合一自动签到托盘助手**：Trae / WorkBuddy / ZCode 三个 AI 编程工具的免费积分与 token，一个常驻菜单栏程序全自动帮你领。

> 本仓库是 [Shuffle-1992/TraeSign](https://github.com/Shuffle-1992/TraeSign) 的 **macOS 版**，用 **Swift** 从原版（C# WinForms / Windows）重写而来，支持 macOS 12+。原版仅支持 Windows，本版为 Apple 平台原生实现。

## 支持的三种签到

| 平台 | 做什么 | 自动频率 | 凭证方式（无需输入密码） |
|---|---|---|---|
| **Trae**（字节的 AI IDE） | 每日签到领积分 | 每天 00:05 | 自动读取本机 Trae 客户端登录态，多账号可切换 |
| **WorkBuddy**（腾讯的 AI 工作台） | 每日签到领积分 | 每天 00:05 | 首次点「登录授权」过一次浏览器，之后 token 自动续期（存于 macOS Keychain） |
| **ZCode**（智谱 Z.ai 编程客户端） | **免费活动套餐自动领取**（如 1 亿 GLM token） | 每 10 分钟检查 | 自动读取本机 ZCode 登录态，完全免授权（阿里云无痕验证码由应用内 WKWebView 处理） |

三个平台独立调度、互不影响；托盘图标一眼看清整体状态（**绿=全部完成 / 红=有异常 / 灰=进行中**）；每个平台一张独立签到日历。

## 环境要求

- macOS 12.0 或更高
- Xcode 命令行工具（提供 `swiftc`，Swift 5.7+）
- 通用二进制：Intel（x86_64）与 Apple Silicon（arm64）均原生运行，无需 Rosetta 2

## 构建与运行

```bash
# 1. 编译为通用二进制并打包成 TraeSign.app
bash makeapp.sh

# 2. 运行（菜单栏出现图标，无 Dock 图标）
open TraeSign.app
```

数据目录：`~/Library/Application Support/TraeSign`（日志、签到历史等）。

> 说明：本机构建使用 `swiftc` 直接编译（仓库内置 `makeapp.sh`）。若你的环境 SwiftPM 正常，也可改用 `swift build -c release` 后手动替换 `.app` 内的可执行文件。

## 使用

1. 启动后点击菜单栏图标打开面板。
2. **Trae / ZCode**：确保本机已登录对应客户端，程序自动读取登录态，无需额外配置。
3. **WorkBuddy**：首次点击「登录授权」，浏览器完成授权后回到应用即可；之后 token 自动续期。
4. 勾选各平台的「自动」开关即可常驻自动签到。

## 项目结构

```
Sources/TraeSign/      # Swift 源码（引擎 / 模型 / 存储 / UI）
Sources/TraeSign/UI/   # SwiftUI 界面（面板、签到日历）
makeapp.sh             # 通用二进制构建 + 打包脚本
Package.swift          # SwiftPM 描述（备用）
```

## 许可

基于 [Shuffle-1992/TraeSign](https://github.com/Shuffle-1992/TraeSign) 用 Swift 重写，沿用原项目 **MIT License**。原作者版权见 [LICENSE](./LICENSE)。
