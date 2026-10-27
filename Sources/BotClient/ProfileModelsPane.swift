import SwiftUI
import HermesClient

struct ModelRouteFields: View {
    @Binding var provider: String
    @Binding var model: String
    var choices: [ChatModelOption]
    var providerChanged: (() -> Void)? = nil
    private var editedProvider: Binding<String> { Binding(get: { provider }, set: { value in let changed = provider != value; provider = value; if changed { providerChanged?() } }) }
    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                TextField("服务商，例如 openrouter", text: editedProvider).textFieldStyle(BotsTextFieldStyle())
                TextField("模型 ID", text: $model).textFieldStyle(BotsTextFieldStyle())
            }
            if !choices.isEmpty {
                ChoicePicker(title: "从可用模型选择", selection: Binding(get: { choices.first(where: { $0.provider == provider && $0.model == model })?.id ?? "" }, set: { id in
                    if let c = choices.first(where: { $0.id == id }) { editedProvider.wrappedValue = c.provider; model = c.model }
                }), options: [Choice("", "从可用模型选择")] + choices.filter(\.available).map { Choice($0.id, $0.providerName + " / " + $0.name) })
            }
        }
    }
}

struct ProfileModelsPane: View {
    @Bindable var configuration: ProfileConfiguration
    var body: some View {
        VStack(spacing: 20) {
            SettingsNotice(text: "保存会直接改写 \(configuration.profile) 的 Hermes 配置；当前聊天的模型仍可在输入区单独切换。")
            HStack { Button("刷新模型目录") { Task { await configuration.loadModels() } }.buttonStyle(SecondaryButton()).disabled(configuration.busy); Spacer() }
            DefaultProfileModelCard(configuration: configuration)
            if !configuration.modelLoaded && !configuration.busy {
                Button("重试读取默认模型") { Task { await configuration.loadModelBase() } }.buttonStyle(SecondaryButton())
            }
            AuxiliaryModelsPane(configuration: configuration.routing, choices: configuration.models)
            FallbackModelsPane(configuration: configuration.routing, choices: configuration.models)
        }.task {
            if !configuration.modelLoaded { await configuration.loadModelBase() }
            if configuration.models.isEmpty { await configuration.loadModels() }
            if !configuration.routing.auxiliaryLoaded { await configuration.routing.loadAuxiliary() }
            if !configuration.routing.fallbackLoaded { await configuration.routing.loadFallbacks() }
        }
    }
}
private struct AuxiliaryModelsPane: View {
    @Bindable var configuration: ProfileModelConfiguration
    let choices: [ChatModelOption]
    @State private var selectedTask = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("辅助模型").font(.ui(size: 17, weight: .semibold)); Spacer()
                Button("重新载入辅助（放弃草稿）") { Task { await configuration.loadAuxiliary() } }.buttonStyle(SecondaryButton()).disabled(configuration.busy || configuration.pendingWarning != nil)
            }
            Text("按任务分别设置；自动模式交给 Hermes 选择，跟随主模型沿用这个 Bot 的主路由。").font(.ui(size: 12)).foregroundStyle(Color.muted)
            if !configuration.auxiliaryLoaded && !configuration.busy { SettingsNotice(text: "辅助目录尚未载入；点击重新载入，当前 Hermes 不支持时会显示原因。") }
            if !configuration.auxiliary.isEmpty {
                ChoicePicker(title: "辅助任务", selection: $selectedTask, options: configuration.auxiliary.map { Choice($0.id, $0.title) }).disabled(configuration.busy || configuration.pendingWarning != nil)
            }
            ForEach($configuration.auxiliary) { $row in
                if row.id == selectedTask {
                SettingsCard(row.title, subtitle: row.hint.isEmpty ? "配置 \(configuration.profile) 的这个辅助任务" : row.hint) {
                    ChoiceTabs(selection: Binding(get: { ["auto", "main"].contains(row.provider) ? row.provider : "fixed" }, set: { value in
                        row.provider = value == "fixed" ? "" : value; row.model = ""; row.baseURL = ""; row.apiKey = ""
                    }), options: [Choice("auto", "自动"), Choice("main", "跟随主模型"), Choice("fixed", "指定模型")])
                    ModelRouteFields(provider: $row.provider, model: $row.model, choices: choices, providerChanged: { row.baseURL = ""; row.apiKey = "" })
                    TextField("自定义 API 地址（可选）", text: $row.baseURL).textFieldStyle(BotsTextFieldStyle())
                    SecureField("新 API Key（留空保留已有凭据）", text: $row.apiKey).textFieldStyle(BotsTextFieldStyle())
                    Button("保存此辅助模型") { Task { await configuration.saveAuxiliary(row.id) } }.buttonStyle(FilledButton()).disabled(configuration.busy || configuration.pendingWarning != nil)
                }.disabled(configuration.busy || configuration.pendingWarning != nil)
                }
            }
            if let warning = configuration.pendingWarning {
                SettingsNotice(text: warning)
                HStack {
                    Button("取消选择") { configuration.cancelWarning() }.buttonStyle(SecondaryButton())
                    Button("确认使用") { Task { await configuration.confirmAuxiliary() } }.buttonStyle(FilledButton()).disabled(configuration.busy)
                }
            }
            if configuration.busy { ProgressView().controlSize(.small) }
            if let error = configuration.error { SettingsNotice(text: error, problem: true) }
            if let message = configuration.notice { SettingsNotice(text: message) }
        }.onChange(of: configuration.auxiliary.map(\.id), initial: true) { _, ids in
            if !ids.contains(selectedTask) { selectedTask = ids.first ?? "" }
        }
    }
}
private struct FallbackModelsPane: View {
    @Bindable var configuration: ProfileModelConfiguration
    let choices: [ChatModelOption]
    var body: some View {
        SettingsCard("备用模型", subtitle: "主模型不可用时按顺序尝试；不同节点可能产生不同费用。原节点的地址、凭据引用和其他路由选项会保留。") {
            if configuration.hasLegacyFallback { SettingsNotice(text: "发现旧版备用设置。保存时会一并迁入下面的有序列表。") }
            ForEach($configuration.fallbacks) { $row in
                VStack(spacing: 10) {
                    HStack {
                        Text("备用 \((configuration.fallbacks.firstIndex(where: { $0.id == row.id }) ?? 0) + 1)").font(.ui(size: 13, weight: .semibold)); Spacer()
                        Button { move(row.id, -1) } label: { Image(systemName:"arrow.up") }.buttonStyle(ResponsiveButton(round:true)).help("上移")
                        Button { move(row.id, 1) } label: { Image(systemName:"arrow.down") }.buttonStyle(ResponsiveButton(round:true)).help("下移")
                        Button { configuration.fallbacks.removeAll { $0.id == row.id } } label: { Image(systemName:"minus.circle") }.buttonStyle(ResponsiveButton(round:true)).help("移除备用节点")
                    }
                    ModelRouteFields(provider:$row.provider, model:$row.model, choices:choices)
                    if row.hasExtraRouting { Text(row.endpoint.isEmpty ? "保留此节点已有的额外路由配置" : "保留节点地址：" + row.endpoint).font(.ui(size:12)).foregroundStyle(Color.muted) }
                }.padding(13).background(Color.inputSurface, in:OpticalRoundedRectangle())
            }
            if configuration.fallbackLoaded && configuration.fallbacks.isEmpty { Text("尚未设置备用模型。空列表保存后关闭这个 Bot 的模型备用链。").font(.ui(size:12)).foregroundStyle(Color.muted) }
            HStack {
                Button("添加备用模型") { configuration.fallbacks.append(FallbackModel()) }.buttonStyle(SecondaryButton()).disabled(!configuration.fallbackLoaded)
                Button("重新载入列表（放弃草稿）") { Task { await configuration.loadFallbacks() } }.buttonStyle(SecondaryButton())
                Spacer()
                Button("保存备用列表") { Task { await configuration.saveFallbacks() } }.buttonStyle(FilledButton()).disabled(!configuration.fallbackLoaded)
            }.disabled(configuration.busy || configuration.pendingWarning != nil)
        }.disabled(configuration.busy || configuration.pendingWarning != nil)
    }
    private func move(_ id: UUID, _ offset: Int) {
        guard let i = configuration.fallbacks.firstIndex(where: { $0.id == id }), configuration.fallbacks.indices.contains(i + offset) else { return }
        configuration.fallbacks.swapAt(i, i + offset)
    }
}
