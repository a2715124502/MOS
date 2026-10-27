import SwiftUI
import HermesClient

struct DefaultProfileModelCard: View {
    @Bindable var configuration: ProfileConfiguration
    var body: some View {
            SettingsCard("默认模型", subtitle: "用于这个 profile 的默认配置。聊天中的模型可在输入区单独切换。") {
                HStack { TextField("模型 ID", text: $configuration.model).textFieldStyle(BotsTextFieldStyle()).disabled(configuration.pendingModelWarning != nil); Button("选择模型") { Task { await configuration.loadModels() } }.buttonStyle(SecondaryButton()).disabled(configuration.busy) }
                TextField("服务商，例如 openrouter", text: $configuration.provider).textFieldStyle(BotsTextFieldStyle()).disabled(configuration.pendingModelWarning != nil)
                if !configuration.models.isEmpty {
                    ChoicePicker(title: "可用模型", selection: Binding(get: { configuration.models.first(where: { $0.model == configuration.model && $0.provider == configuration.provider })?.id ?? "" }, set: { id in
                        if let value = configuration.models.first(where: { $0.id == id }) { configuration.model = value.model; configuration.provider = value.provider }
                    }), options: configuration.models.filter(\.available).map { Choice($0.id, $0.providerName + " / " + $0.name) }).disabled(configuration.pendingModelWarning != nil)
                }
                if let warning = configuration.pendingModelWarning {
                    SettingsNotice(text: warning)
                    HStack { Button("取消切换") { configuration.pendingModelWarning = nil }.buttonStyle(SecondaryButton()); Button("确认使用该模型") { Task { await configuration.saveModel(confirmed: true) } }.buttonStyle(FilledButton()) }
                } else {
                    HStack {
                        Button("保存默认模型") { Task { await configuration.saveModel() } }.buttonStyle(FilledButton()).disabled(!configuration.modelLoaded || configuration.busy)
                        Button("重新载入默认（放弃模型草稿）") { Task { await configuration.loadModelBase() } }.buttonStyle(SecondaryButton())
                    }
                }
            }.disabled(configuration.busy || !configuration.modelLoaded)
    }
}
