import SwiftUI

// MARK: - 主界面（菜单栏弹窗内容）
struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var coordinator: Coordinator

    var body: some View {
        TabView {
            PlatformPanel(platform: .trae)
                .tabItem { Label("Trae", systemImage: "1.circle") }
            PlatformPanel(platform: .workbuddy)
                .tabItem { Label("WorkBuddy", systemImage: "2.circle") }
            PlatformPanel(platform: .zcode)
                .tabItem { Label("ZCode", systemImage: "3.circle") }
        }
        .frame(width: 470, height: 560)
        .padding(4)
    }
}

// MARK: - 单平台面板
struct PlatformPanel: View {
    let platform: Platform
    @EnvironmentObject var state: AppState
    @EnvironmentObject var coordinator: Coordinator

    private var s: PState {
        switch platform {
        case .trae: return state.trae
        case .workbuddy: return state.workbuddy
        case .zcode: return state.zcode
        }
    }

    private var enabledBinding: Binding<Bool> {
        switch platform {
        case .trae: return $state.trae.enabled
        case .workbuddy: return $state.workbuddy.enabled
        case .zcode: return $state.zcode.enabled
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头部：平台名 + 账号
            HStack {
                Image(systemName: iconName(s.level))
                    .foregroundColor(iconColor(s.level))
                Text(platform.rawValue).font(.headline)
                Spacer()
                if let acc = s.account {
                    Text(acc).font(.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            // Trae 多账号选择
            if platform == .trae && !state.traeAccounts.isEmpty {
                Picker("账号", selection: traeBrand) {
                    ForEach(state.traeAccounts, id: \.brand) { a in
                        Text(accountLabel(a)).tag(a.brand as String?)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: state.traeBrand) { _ in
                    Task { await coordinator.refresh(.trae, queryOnly: true) }
                }
            }

            // 状态行
            VStack(alignment: .leading, spacing: 2) {
                Text(s.message).font(.subheadline).foregroundColor(.primary)
                if let c = s.creditsText { Text(c).font(.caption).foregroundColor(.secondary) }
                if let n = s.note { Text(n).font(.caption).foregroundColor(.orange) }
                if let t = s.lastRun { Text("最近运行 \(t)").font(.caption2).foregroundColor(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // 按钮区
            HStack(spacing: 8) {
                Button("刷新状态") {
                    Task { await coordinator.refresh(platform, queryOnly: true) }
                }
                .disabled(state.busy)

                if platform == .workbuddy && needsAuth(s) {
                    Button("登录授权") {
                        Task { await coordinator.authorizeWorkbuddy() }
                    }
                    .disabled(state.busy)
                } else {
                    Button(actionLabel) {
                        Task { await coordinator.refresh(platform, queryOnly: false) }
                    }
                    .disabled(state.busy)
                }

                Spacer()
                Toggle("自动", isOn: enabledBinding)
                    .toggleStyle(.checkbox)
                    .help(platform == .zcode ? "每 10 分钟检查免费套餐" : "每日 00:05 自动签到")
            }

            Divider()
            Text("签到日历").font(.caption).foregroundColor(.secondary)
            CalendarView(platform: platform, version: state.calendarVersion)
        }
        .padding(10)
    }

    private var actionLabel: String {
        platform == .zcode ? "检查并领取" : "立即签到"
    }

    private var traeBrand: Binding<String?> {
        Binding(
            get: { state.traeBrand },
            set: { state.traeBrand = $0 }
        )
    }

    private func accountLabel(_ a: AccountInfo) -> String {
        let u = a.username ?? "未命名"
        return "\(a.brand) · \(u)"
    }

    private func needsAuth(_ s: PState) -> Bool {
        s.level == .error || s.message.contains("未授权") || s.message.contains("授权")
    }

    private func iconName(_ l: StatusLevel) -> String {
        switch l {
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .pending: return "circle.fill"
        case .idle: return "circle"
        }
    }

    private func iconColor(_ l: StatusLevel) -> Color {
        switch l {
        case .done: return .green
        case .error: return .red
        case .pending: return .gray
        case .idle: return .secondary
        }
    }
}
