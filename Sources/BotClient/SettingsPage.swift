import SwiftUI
import AppKit
import UserNotifications
import HermesClient

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, bots, models, channels, tools, skills, mcp, connection
    var id: String { rawValue }
    var title: String { ["appearance":"外观与文字", "bots":"Bot 与角色", "models":"模型配置", "channels":"消息平台", "tools":"工具", "skills":"Skills", "mcp":"MCP 连接", "connection":"连接与通知"][rawValue]! }
    var icon: String { ["appearance":"paintpalette", "bots":"face.smiling", "models":"cpu", "channels":"bubble.left.and.bubble.right", "tools":"wrench.and.screwdriver", "skills":"sparkles", "mcp":"point.3.connected.trianglepath.dotted", "connection":"network"][rawValue]! }
    var subtitle: String {
        switch self {
        case .appearance: return "让 MOS 更合你的习惯"
        case .bots: return "为每位伙伴配置角色与默认模型"
        case .models: return "配置这个 Bot 的默认、辅助与备用模型"
        case .channels: return "连接这个 Bot 使用的消息平台"
        case .tools: return "管理当前 profile 可用的工具与服务商"
        case .skills: return "启用、编辑与添加助手的技能"
        case .mcp: return "连接远端工具，管理授权与凭据"
        case .connection: return "连接状态、通知和聊天显示"
        }
    }
    var profileScoped: Bool { ![.appearance, .connection].contains(self) }
}

struct SettingsPage: View {
    @Bindable var store: ChatStore
    var back: () -> Void
    @State private var section: SettingsSection = .appearance
    @State private var selected = ""
    @State private var editors: [String: ProfileConfiguration] = [:]
    @State private var owner: GatewayTransport?
    @State private var creating = false
    @State private var error: String?
    @State private var showDiscard = false
    private var editor: ProfileConfiguration? { editors[selected] }
    private var dirty: Bool { editors.values.contains { $0.hasDraft } }
    private var saving: Bool { editors.values.contains { $0.busy || $0.routing.busy || $0.messaging.busy } }
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 38, height: 38)
                    BrandWordmark()
                }.padding(.leading, 10)
                VStack(spacing: 5) {
                    ForEach(SettingsSection.allCases) { item in
                        Button { section = item; creating = false; error = nil } label: {
                            HStack(spacing: 11) {
                                Image(systemName: item.icon).font(.ui(size: 16)).frame(width: 24)
                                Text(item.title).font(.ui(size: 14, weight: section == item ? .semibold : .regular))
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 13).padding(.vertical, 12)
                                .foregroundStyle(section == item ? Color.selectionInk : Color.muted)
                                .background(section == item ? Color.selectionFill : .clear, in: OpticalRoundedRectangle())
                        }.buttonStyle(ResponsiveButton())
                    }
                }
                Spacer()
                Button { if dirty { showDiscard = true } else { back() } } label: { Label("返回聊天", systemImage: "arrow.left").frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                    .buttonStyle(ResponsiveButton()).disabled(saving)
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.ui(size: 11)).foregroundStyle(Color.muted).padding(.leading, 12)
            }.padding(.horizontal, 16).padding(.top, 53).padding(.bottom, 24).frame(width: 208)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(creating ? "创建 Bot" : section.title).font(.ui(size: 24, weight: .semibold))
                        Text(creating ? "一个独立的 profile，一位新的伙伴" : section.subtitle).font(.ui(size: 12)).foregroundStyle(Color.muted)
                    }
                    Spacer()
                    if section.profileScoped && !creating {
                        ChoicePicker(title: "配置的 profile", selection: $selected, options: store.bots.map { Choice($0.profile, $0.name + "  /  " + $0.profile) }).frame(maxWidth: 240)
                    }
                }.padding(27)
                ScrollView {
                    VStack(alignment: .leading, spacing: 21) {
                        if showDiscard {
                            SettingsCard("有尚未保存的配置", subtitle: "可以留在这里继续编辑，或放弃草稿返回聊天。") {
                                HStack {
                                    Button("继续编辑") { showDiscard = false }.buttonStyle(SecondaryButton())
                                    Button("放弃并返回") { Task { for editor in editors.values { await editor.messaging.cancelPairing() }; back() } }.buttonStyle(FilledButton())
                                }
                            }
                        }
                        if let error { SettingsNotice(text: error, problem: true) }
                        if creating {
                            CreateBotPane(store: store, cancel: { creating = false }, created: { profile in
                                creating = false; selected = profile; section = .bots
                            })
                        } else if section == .appearance { AppearancePane() }
                        else if section == .connection { ConnectionPane(store: store, exit: back) }
                        else {
                            HStack {
                                Label("仅配置 \(selected.isEmpty ? "所选 profile" : selected)", systemImage: "person.crop.circle").font(.ui(size: 12)).foregroundStyle(Color.muted)
                                Spacer()
                                if section == .bots { Button { creating = true } label: { Label("创建 Bot", systemImage: "plus") }.buttonStyle(FilledButton()).disabled(store.demo || store.phase != .connected) }
                            }
                            if store.demo { SettingsNotice(text: "当前为界面预览。连接 Hermes 后可读取和保存 Bot 配置。") }
                            else if let editor {
                                if !editor.active {
                                    SettingsCard("连接已变化", subtitle: "草稿仍保留。重新载入会丢弃当前 profile 的未保存内容。") {
                                        Button("重新载入配置") { editors[selected] = nil; prepareEditor() }.buttonStyle(SecondaryButton()).disabled(store.phase != .connected)
                                    }
                                }
                                RemoteProfilePane(configuration: editor, store: store, section: section, renamed: { name in editors[selected] = nil; selected = name })
                                    .disabled(!editor.active).id(editor.profile)
                            } else if store.phase != .connected { SettingsNotice(text: "连接恢复后可继续读取配置。") }
                            else { ProgressView("正在读取 profile…").padding(25) }
                        }
                    }.frame(maxWidth: 820, alignment: .leading).padding(.horizontal, 27).padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .topLeading)
                }.id(section.rawValue + ":" + selected)
            }.background(Color.canvas, in: OpticalRoundedRectangle()).clipShape(OpticalRoundedRectangle()).padding(.vertical, 14).padding(.trailing, 14)
        }.background(Color.rail).foregroundStyle(Color.ink).appTheme()
            .task {
                if selected.isEmpty { selected = store.selected ?? store.bots.first?.profile ?? "" }
                prepareEditor()
            }
            .onChange(of: selected) { _, _ in prepareEditor() }
            .onChange(of: section) { _, _ in prepareEditor() }
    }
    private func prepareEditor() {
        guard section.profileScoped, !selected.isEmpty, !store.demo, store.phase == .connected, let api = store.transport else { return }
        if owner !== api { owner = api }
        if editors[selected] == nil {
            editors[selected] = ProfileConfiguration(api: api, profile: selected, isActive: { store.transport === api && store.phase == .connected && !store.demo })
        }
    }
}

struct SettingsCard<Content: View>: View {
    var title: String
    var subtitle: String
    let content: Content
    init(_ title: String, subtitle: String = "", @ViewBuilder content: () -> Content) { self.title = title; self.subtitle = subtitle; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.ui(size: 15, weight: .semibold))
                if !subtitle.isEmpty { Text(subtitle).font(.ui(size: 12)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true) }
            }
            content
        }.padding(21).frame(maxWidth: .infinity, alignment: .leading).background(Color.soft.opacity(0.55), in: OpticalRoundedRectangle())
    }
}
struct SettingsNotice: View {
    let text: String
    var problem = false
    var body: some View {
        Label(text, systemImage: problem ? "exclamationmark.circle" : "info.circle")
            .font(.ui(size: 12)).foregroundStyle(problem ? Color.orange : Color.muted).textSelection(.enabled)
            .padding(13).frame(maxWidth: .infinity, alignment: .leading).background(problem ? Color.orange.opacity(0.07) : Color.inputSurface, in: OpticalRoundedRectangle())
    }
}
struct AppearancePane: View {
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @Bindable private var preferences = VisualPreferences.shared
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        SettingsCard("主题模式", subtitle: "跟随系统，或为 MOS 选择固定的明暗外观。") {
            HStack(spacing: 11) {
                ForEach(AppAppearance.allCases) { mode in
                    Button { appearance = mode } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            ThemePreview(theme: preferences.theme, dark: mode == .dark || mode == .system && scheme == .dark, automatic: mode == .system)
                            HStack {
                                Image(systemName: mode == .system ? "circle.lefthalf.filled" : mode == .light ? "sun.max" : "moon")
                                Text(mode.title); Spacer(minLength: 0)
                                if appearance == mode { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accent) }
                            }.font(.ui(size: 12, weight: .medium))
                        }.padding(9).background(appearance == mode ? Color.selectionFill : Color.canvas, in: OpticalRoundedRectangle())
                    }.buttonStyle(ResponsiveButton()).accessibilityAddTraits(appearance == mode ? .isSelected : [])
                }
            }
        }
        SettingsCard("主题色", subtitle: "六种配色都适配浅色与深色，选择后立即生效。") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                ForEach(ThemeColor.allCases) { color in
                    Button { preferences.theme = color } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            ThemePreview(theme: color, dark: scheme == .dark)
                            HStack {
                                Circle().fill(color.swatch).frame(width: 12, height: 12)
                                Text(color.title).font(.ui(size: 12, weight: .medium)); Spacer()
                                if preferences.theme == color { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accent) }
                            }
                        }.padding(10).background(preferences.theme == color ? Color.selectionFill : Color.canvas, in: OpticalRoundedRectangle())
                    }.buttonStyle(ResponsiveButton())
                }
            }
        }
        SettingsCard("文字大小", subtitle: "调整整个应用的文字和输入内容。默认已比上一版收紧。") {
            HStack(spacing: 16) {
                Button { preferences.textScale = max(0.8, (preferences.textScale * 100 - 5).rounded() / 100) } label: { Image(systemName: "textformat.size.smaller").frame(width: 31, height: 28) }.buttonStyle(SecondaryButton()).disabled(preferences.textScale <= 0.8)
                HStack(spacing: 4) {
                    ForEach(0..<10) { i in
                        Button { preferences.textScale = 0.8 + Double(i) * 0.05 } label: {
                            Capsule().fill(preferences.textScale >= 0.8 + Double(i) * 0.05 - 0.001 ? Color.accent : Color.hairline).frame(maxWidth: .infinity).frame(height: 8).padding(.vertical, 12)
                        }.buttonStyle(ResponsiveButton()).accessibilityLabel("字号 \(80 + i * 5)%")
                    }
                }
                Button { preferences.textScale = min(1.25, (preferences.textScale * 100 + 5).rounded() / 100) } label: { Image(systemName: "textformat.size.larger").frame(width: 31, height: 28) }.buttonStyle(SecondaryButton()).disabled(preferences.textScale >= 1.25)
                Text("\(Int((preferences.textScale * 100).rounded()))%").font(.ui(size: 12)).monospacedDigit().frame(width: 42)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("熟悉的伙伴，舒服的阅读节奏。").font(.ui(size: 15, weight: .medium))
                Text("消息、角色说明、菜单与输入文字会一起调整。").font(.ui(size: 13)).foregroundStyle(Color.muted)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.canvas, in: OpticalRoundedRectangle())
            Button("恢复默认字号") { preferences.textScale = 0.9 }.buttonStyle(SecondaryButton())
        }
    }
}

struct ConnectionPane: View {
    @Bindable var store: ChatStore
    var exit: () -> Void
    @State private var permissionError: String?
    @State private var logout = false
    var body: some View {
        SettingsCard("当前连接") {
            HStack { Circle().fill(store.phase == .connected ? Color.green : Color.orange).frame(width: 7, height: 7); Text(store.demo ? "界面预览" : store.phase.label).font(.ui(size: 13)); Spacer(); Button("重新连接") { store.reconnectNow() }.buttonStyle(SecondaryButton()).disabled(store.demo) }
            Text(store.demo ? "未连接 Hermes" : store.addressText).font(.ui(size: 12, design: .monospaced)).foregroundStyle(Color.muted).textSelection(.enabled)
            if !store.serverVersion.isEmpty { Text("Hermes \(store.serverVersion)").font(.ui(size: 12)).foregroundStyle(Color.muted) }
        }
        SettingsCard("聊天与通知") {
            Text("思考与工具状态默认收起，点击聊天中的箭头展开；回复正文开始后自动隐藏。").font(.ui(size: 12)).foregroundStyle(Color.muted)
            Toggle("回复完成或需要处理时通知我", isOn: Binding(get: { store.notificationsEnabled }, set: { value in
                if value {
                    Task { do { store.notificationsEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]); if !store.notificationsEnabled { permissionError = "通知未开启，可在系统设置中允许 MOS 通知。" } } catch { permissionError = error.localizedDescription } }
                } else { store.notificationsEnabled = false }
            })).disabled(store.demo)
            Text("关闭窗口后，MOS 仍在菜单栏保持连接；完全退出后停止通知。").font(.ui(size: 12)).foregroundStyle(Color.muted)
            if let permissionError { SettingsNotice(text: permissionError, problem: true) }
        }
        SettingsCard("账号") {
            if logout {
                Text("退出登录将清除当前账号的本机显示缓存。").font(.ui(size: 12)).foregroundStyle(Color.muted)
                HStack { Button("保留登录") { logout = false }.buttonStyle(SecondaryButton()); Button("确认退出") { store.logout(); exit() }.buttonStyle(FilledButton()) }
            } else { Button(store.demo ? "返回登录" : "退出登录") { logout = true }.buttonStyle(SecondaryButton()) }
        }
    }
}

struct RemoteProfilePane: View {
    @Bindable var configuration: ProfileConfiguration
    @Bindable var store: ChatStore
    var section: SettingsSection
    var renamed: (String) -> Void
    @State private var skillCreating = false
    @State private var newSkillName = ""
    @State private var discardSkill = false
    @State private var installIdentifier = ""
    @State private var selectedTool: String?
    @State private var toolProvider = ""
    @State private var toolSecrets: [String:String] = [:]
    @State private var editingServer: JSON?
    @State private var addingServer = false
    @State private var removingServer: String?
    @State private var newProfileName = ""
    @State private var confirmRename = false
    @State private var renameBusy = false
    @State private var renameError: String?
    var body: some View {
        Group {
            if let message = configuration.error { SettingsNotice(text: message, problem: true) }
            if let message = configuration.notice { SettingsNotice(text: message) }
            if configuration.loading || configuration.busy { ProgressView().controlSize(.small) }
            if section == .bots { basics }
            else if section == .models { ProfileModelsPane(configuration: configuration) }
            else if section == .channels { ProfileChannelsPane(configuration: configuration.messaging) }
            else if section == .tools { toolSettings }
            else if section == .skills { skillSettings }
            else { mcpSettings }
        }.task(id: section.rawValue + configuration.profile) {
            if section == .bots { if !configuration.loaded { await configuration.load() } }
            else if ![.models, .channels].contains(section) { await configuration.loadCapabilities(section.rawValue) }
        }
    }
    private var basics: some View {
        VStack(spacing: 20) {
            SettingsCard("角色", subtitle: "修改 Bot 显示名称与角色说明。profile：\(configuration.profile)") {
                TextField("Bot 名称", text: $configuration.title).textFieldStyle(BotsTextFieldStyle())
                TextField("这个伙伴主要负责什么", text: $configuration.description).textFieldStyle(BotsTextFieldStyle())
                Button("保存角色") { Task { await configuration.saveIdentity(); try? await store.loadBots() } }.buttonStyle(FilledButton()).disabled(!configuration.loaded || configuration.busy)
            }
            DefaultProfileModelCard(configuration: configuration)
            SettingsCard("SOUL.md", subtitle: "定义角色、语气与工作方式。保存前会检查是否被其他客户端修改。") {
                TextEditor(text: $configuration.soul).font(.ui(size: 13, design: .monospaced)).scrollContentBackground(.hidden).padding(11).frame(minHeight: 260).background(Color.canvas, in: OpticalRoundedRectangle())
                HStack { Button("保存 SOUL.md") { Task { await configuration.saveSoul() } }.buttonStyle(FilledButton()).disabled(!configuration.loaded || configuration.busy); Spacer(); Text("\(configuration.soul.count) 字符").font(.ui(size: 11)).foregroundStyle(Color.muted) }
            }
            SettingsCard("profile 标识", subtitle: "重命名会修改远端 profile 标识与目录；Hermes 可能停止该 profile 正在运行的 gateway。") {
                TextField(configuration.profile, text: $newProfileName).textFieldStyle(BotsTextFieldStyle())
                if let renameError { SettingsNotice(text: renameError, problem: true) }
                if confirmRename {
                    HStack { Button("取消") { confirmRename = false }.buttonStyle(SecondaryButton()); Button("确认重命名") { renameProfile() }.buttonStyle(FilledButton()) }
                } else { Button("重命名 profile") { confirmRename = true }.buttonStyle(SecondaryButton()).disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newProfileName == configuration.profile || configuration.hasDraft) }
            }.disabled(configuration.busy || renameBusy)
        }
    }
    private var toolSettings: some View {
        VStack(spacing: 17) {
            refresh { await configuration.loadCapabilities("tools") }
            ForEach(configuration.tools, id: \.self) { row in
                SettingsCard(row["label"].string.isEmpty ? row["name"].string : row["label"].string, subtitle: row["description"].string) {
                    HStack {
                        Toggle("启用工具", isOn: Binding(get: { row["enabled"].bool }, set: { value in Task { await configuration.toggle("tools", name: row["name"].string, enabled: value) } }))
                        Button("配置") { selectedTool = row["name"].string; toolSecrets = [:]; Task { await configuration.loadTool(row["name"].string); toolProvider = configuration.toolConfiguration["active_provider"].string } }.buttonStyle(SecondaryButton())
                    }.disabled(configuration.busy)
                    if !row["configured"].bool { Text("尚需配置服务商或凭据").font(.ui(size: 12)).foregroundStyle(Color.muted) }
                    if selectedTool == row["name"].string { toolEditor(row["name"].string) }
                }
            }
            if configuration.tools.isEmpty && !configuration.busy { SettingsNotice(text: "尚未读取到工具。可点击刷新；接口不兼容时会显示具体错误。") }
        }
    }
    private func toolEditor(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let providers = configuration.toolConfiguration["providers"].array
            if providers.isEmpty { Text("这个工具没有额外的服务商配置。").font(.ui(size: 12)).foregroundStyle(Color.muted) }
            else {
                ChoicePicker(title: "选择服务商", selection: $toolProvider, options: providers.map { Choice($0["name"].string, $0["name"].string + ($0["is_active"].bool ? "（当前）" : "")) })
                ForEach((providers.first { $0["name"].string == toolProvider } ?? .null)["env_vars"].array, id: \.self) { env in
                    SecureField(env["prompt"].string + (env["is_set"].bool ? "（已配置，留空保留）" : ""), text: Binding(get: { toolSecrets[env["key"].string] ?? "" }, set: { toolSecrets[env["key"].string] = $0 })).textFieldStyle(BotsTextFieldStyle())
                }
                Button("保存工具配置") { let values = toolSecrets.filter { !$0.value.isEmpty }; toolSecrets = [:]; Task { await configuration.saveTool(name, provider: toolProvider, env: values) } }.buttonStyle(FilledButton()).disabled(configuration.busy)
            }
        }
    }
    private var skillSettings: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack { refresh { await configuration.loadCapabilities("skills") }; Spacer(); Button("新建 Skill") { guard !configuration.hasSkillDraft else { discardSkill = true; return }; skillCreating = true; newSkillName = ""; configuration.skillName = nil; configuration.skillPath = ""; configuration.skillContent = "---\nname: my-skill\ndescription: 这个技能做什么\n---\n\n# 工作步骤\n\n" }.buttonStyle(SecondaryButton()) }
            SettingsCard("安装 Skill", subtitle: "填写 Hermes Skills Hub 中的技能标识。安装在远端执行。") {
                HStack { TextField("技能标识或来源", text: $installIdentifier).textFieldStyle(BotsTextFieldStyle()); Button("安装") { Task { await configuration.installSkill(installIdentifier) } }.buttonStyle(FilledButton()).disabled(installIdentifier.isEmpty || configuration.busy) }
            }
            Text("技能开关仅影响所选 profile；内容编辑会保存到 Hermes 返回的实际技能文件。")
                .font(.ui(size: 12)).foregroundStyle(Color.muted)
            if discardSkill {
                SettingsCard("保留还是放弃 Skill 草稿？") {
                    HStack { Button("继续编辑") { discardSkill = false }.buttonStyle(SecondaryButton()); Button("放弃当前草稿") { configuration.discardSkill(); skillCreating = false; discardSkill = false }.buttonStyle(FilledButton()) }
                }
            }
            if skillCreating || configuration.skillName != nil {
                SettingsCard(skillCreating ? "新建 Skill" : configuration.skillName ?? "Skill") {
                    if skillCreating { TextField("Skill 名称", text: $newSkillName).textFieldStyle(BotsTextFieldStyle()) }
                    if !configuration.skillPath.isEmpty { Text(configuration.skillPath).font(.ui(size: 11, design: .monospaced)).foregroundStyle(Color.muted).textSelection(.enabled) }
                    TextEditor(text: $configuration.skillContent).font(.ui(size: 13, design: .monospaced)).scrollContentBackground(.hidden).padding(10).frame(height: 280).background(Color.canvas, in: OpticalRoundedRectangle())
                    HStack {
                        Button("关闭编辑") { if configuration.hasSkillDraft { discardSkill = true } else { skillCreating = false; configuration.discardSkill() } }.buttonStyle(SecondaryButton())
                        Button("保存 Skill") { Task { await configuration.saveSkill(create: skillCreating, name: skillCreating ? newSkillName : nil); if configuration.error == nil { skillCreating = false } } }.buttonStyle(FilledButton()).disabled(configuration.busy)
                    }
                }
            }
            ForEach(configuration.skills, id: \.self) { skill in
                SettingsCard(skill["name"].string, subtitle: skill["description"].string) {
                    Text(["bundled":"内置技能", "external":"外部目录技能（原位编辑）", "hub":"已安装技能", "agent":"自定义技能"][skill["provenance"].string] ?? "技能文件").font(.ui(size: 11)).foregroundStyle(Color.muted)
                    HStack {
                        Toggle("启用技能", isOn: Binding(get: { skill["enabled"].bool }, set: { value in Task { await configuration.toggle("skills", name: skill["name"].string, enabled: value) } }))
                        Button("编辑 SKILL.md") { guard !configuration.hasSkillDraft else { discardSkill = true; return }; skillCreating = false; Task { await configuration.loadSkill(skill["name"].string) } }.buttonStyle(SecondaryButton())
                    }.disabled(configuration.busy)
                }
            }
        }
    }
    private var mcpSettings: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack { refresh { await configuration.loadCapabilities("mcp") }; Spacer(); Button { addingServer = true; editingServer = nil } label: { Label("添加连接", systemImage: "plus") }.buttonStyle(FilledButton()) }
            if addingServer || editingServer != nil {
                MCPServerForm(configuration: configuration, existing: editingServer, close: { addingServer = false; editingServer = nil }).id(editingServer?["name"].string ?? "new")
            }
            if !configuration.oauth.isNull {
                SettingsCard("MCP 授权", subtitle: configuration.oauth["error"].string) {
                    Text(["approved":"授权完成", "authorization_required":"等待浏览器授权", "starting":"正在准备授权", "error":"授权未完成"][configuration.oauth["status"].string] ?? configuration.oauth["status"].string).font(.ui(size: 13))
                    HStack {
                        if let url = URL(string: configuration.oauth["authorization_url"].string), ["http", "https"].contains(url.scheme ?? "") { Button("打开授权网页") { NSWorkspace.shared.open(url) }.buttonStyle(FilledButton()) }
                        Button("刷新授权状态") { Task { await configuration.refreshOAuth() } }.buttonStyle(SecondaryButton()).disabled(configuration.busy)
                        if ["approved", "error"].contains(configuration.oauth["status"].string) { Button("关闭") { configuration.oauth = .null }.buttonStyle(SecondaryButton()) }
                        else { Button("取消授权") { Task { await configuration.cancelOAuth() } }.buttonStyle(SecondaryButton()).disabled(configuration.busy) }
                    }
                }
            }
            ForEach(configuration.servers, id: \.self) { server in
                SettingsCard(server["name"].string, subtitle: server["url"].string.isEmpty ? ([server["command"].string] + server["args"].array.map(\.string)).joined(separator: " ") : server["url"].string) {
                    Toggle("启用连接", isOn: Binding(get: { server["enabled"].bool }, set: { value in Task { await configuration.toggle("mcp", name: server["name"].string, enabled: value) } })).disabled(configuration.busy || server["source"].string == "plugin")
                    HStack {
                        Button("配置") { editingServer = server; addingServer = false }.buttonStyle(SecondaryButton()).disabled(server["source"].string == "plugin")
                        Button("检查连接") { Task { await configuration.checkServer(server["name"].string) } }.buttonStyle(SecondaryButton())
                        if !server["url"].string.isEmpty { Button("授权") { Task { await configuration.beginOAuth(server["name"].string) } }.buttonStyle(SecondaryButton()) }
                        Spacer()
                        Button("移除") { removingServer = server["name"].string }.buttonStyle(ResponsiveButton()).foregroundStyle(Color.muted).disabled(server["source"].string == "plugin")
                    }.disabled(configuration.busy)
                    if removingServer == server["name"].string {
                        HStack { Text("移除这个 MCP 连接？").font(.ui(size: 12)); Spacer(); Button("取消") { removingServer = nil }.buttonStyle(SecondaryButton()); Button("确认移除") { Task { await configuration.removeServer(server["name"].string); removingServer = nil } }.buttonStyle(FilledButton()) }
                    }
                }
            }
            if configuration.servers.isEmpty && !configuration.busy { SettingsNotice(text: "还没有 MCP 连接。添加 HTTP 服务或远端 stdio 命令开始配置。") }
        }
    }
    private func refresh(_ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Label("刷新", systemImage: "arrow.clockwise") }.buttonStyle(SecondaryButton()).disabled(configuration.busy)
    }
    private func renameProfile() {
        guard let api = store.transport, configuration.active else { return }
        let target = configuration.profile, newName = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        renameBusy = true
        Task {
            defer { renameBusy = false }
            do {
                let r = try await api.request("/api/profiles/\(target)", method: "PATCH", profile: target, body: .object(["new_name": .string(newName)]))
                guard store.transport === api else { throw ClientError.message("连接已变化，请重新载入 Bot 列表") }
                guard r["ok"].bool else { throw ClientError.message("Hermes 未确认 profile 已重命名") }
                try await store.loadBots(); renamed(r["name"].string.isEmpty ? newName : r["name"].string)
            } catch { renameError = error.localizedDescription }
        }
    }
}

struct MCPServerForm: View {
    @Bindable var configuration: ProfileConfiguration
    var existing: JSON?
    var close: () -> Void
    @State private var name = ""
    @State private var transport = "http"
    @State private var url = ""
    @State private var command = ""
    @State private var arguments = ""
    @State private var auth = "none"
    @State private var token = ""
    @State private var envKeys: [String] = [""]
    @State private var envValues: [String] = [""]
    var body: some View {
        SettingsCard(existing == nil ? "新建 MCP 连接" : "配置 \(name)", subtitle: "命令运行在 Hermes 所在机器。已保存的密钥不会在此回显。") {
            TextField("连接名称", text: $name).textFieldStyle(BotsTextFieldStyle()).disabled(existing != nil)
            ChoiceTabs(selection: $transport, options: [Choice("http", "HTTP 服务"), Choice("stdio", "stdio 命令")]).disabled(existing != nil)
            if transport == "http" {
                TextField("https://…/mcp", text: $url).textFieldStyle(BotsTextFieldStyle())
                ChoicePicker(title: "授权方式", selection: $auth, options: [Choice("none", "无需授权"), Choice("oauth", "OAuth 浏览器授权"), Choice("header", "API Key / Bearer Token")]).disabled(existing != nil)
                if auth == "header" { SecureField("新的 Token（留空保留已有值）", text: $token).textFieldStyle(BotsTextFieldStyle()) }
            } else {
                TextField("命令，例如 npx / uvx", text: $command).textFieldStyle(BotsTextFieldStyle())
                Text("参数（每行一个，不使用 shell 引号）").font(.ui(size: 12)).foregroundStyle(Color.muted)
                TextEditor(text: $arguments).font(.ui(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(9).frame(height: 90).background(Color.canvas, in: OpticalRoundedRectangle())
                Text("环境变量（留空保留已有值）").font(.ui(size: 12)).foregroundStyle(Color.muted)
                ForEach(envKeys.indices, id: \.self) { index in
                    HStack { TextField("变量名", text: $envKeys[index]).textFieldStyle(BotsTextFieldStyle()); SecureField("新的值", text: $envValues[index]).textFieldStyle(BotsTextFieldStyle()) }
                }
                Button("添加环境变量") { envKeys.append(""); envValues.append("") }.buttonStyle(SecondaryButton())
            }
            HStack {
                Button("取消") { token = ""; envValues = []; close() }.buttonStyle(SecondaryButton())
                Button("保存连接") {
                    var env: [String:String] = [:]
                    for i in envKeys.indices where !envKeys[i].isEmpty && !envValues[i].isEmpty { env[envKeys[i]] = envValues[i] }
                    let secret = token; token = ""; envValues = Array(repeating: "", count: envKeys.count)
                    Task { await configuration.saveServer(name: name, url: transport == "http" ? url : "", command: command, args: arguments.components(separatedBy: .newlines).filter { !$0.isEmpty }, env: env, auth: auth, token: secret, editing: existing != nil); if configuration.error == nil { close() } }
                }.buttonStyle(FilledButton())
            }.disabled(configuration.busy)
        }.task {
            if let existing {
                name = existing["name"].string; url = existing["url"].string; command = existing["command"].string
                arguments = existing["args"].array.map(\.string).joined(separator: "\n"); transport = url.isEmpty ? "stdio" : "http"
                auth = existing["auth"].string.isEmpty ? "none" : existing["auth"].string
                let existingKeys = existing["env"].object.keys.sorted()
                envKeys = existingKeys.isEmpty ? [""] : existingKeys
                envValues = Array(repeating: "", count: envKeys.count)
            }
        }
    }
}

struct CreateBotPane: View {
    @Bindable var store: ChatStore
    var cancel: () -> Void
    var created: (String) -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var soul = ""
    @State private var source = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        SettingsCard("新的伙伴", subtitle: "创建独立 profile。之后可继续配置默认模型、工具、Skills 和 MCP。") {
            TextField("profile 标识，例如 product-helper", text: $name).textFieldStyle(BotsTextFieldStyle())
            TextField("角色说明", text: $description).textFieldStyle(BotsTextFieldStyle())
            ChoicePicker(title: "配置来源", selection: $source, options: [Choice("", "空白创建")] + store.bots.map { Choice($0.profile, "复制配置：" + $0.name) })
            Text("SOUL.md（可选）").font(.ui(size: 13, weight: .medium))
            TextEditor(text: $soul).font(.ui(size: 13, design: .monospaced)).scrollContentBackground(.hidden).padding(10).frame(height: 250).background(Color.canvas, in: OpticalRoundedRectangle())
            if let error { SettingsNotice(text: error, problem: true) }
            HStack { Button("取消") { cancel() }.buttonStyle(SecondaryButton()); Button("创建 Bot") { create() }.buttonStyle(FilledButton()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.demo || store.phase != .connected) }
        }.disabled(busy)
    }
    private func create() {
        guard let api = store.transport, !store.demo else { return }
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else { error = "profile 标识请使用字母、数字、短横线或下划线"; return }
        busy = true
        var body: [String:JSON] = ["name": .string(target), "description": .string(description), "clone_channels": false, "clone_all": false]
        if !soul.isEmpty { body["soul"] = .string(soul) }
        if !source.isEmpty { body["clone_from"] = .string(source) }
        Task {
            defer { busy = false }
            do {
                let r = try await api.request("/api/profiles", method: "POST", profile: "default", body: .object(body))
                guard store.transport === api else { throw ClientError.message("连接已变化，请刷新 Bot 列表确认创建结果，不要重复提交。") }
                guard r["ok"].bool else { throw ClientError.message("Hermes 未确认 Bot 已创建") }
                try await store.loadBots(); created(r["name"].string.isEmpty ? target : r["name"].string)
            } catch { self.error = error.localizedDescription }
        }
    }
}
