import SwiftUI
import HermesClient

struct ChatModelPicker: View {
    @Bindable var store: ChatStore
    @Bindable var chat: BotConversation
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var warning: ModelSwitchWarning?
    @State private var pendingChoice: ChatModelOption?
    private var filtered: [ChatModelOption] {
        chat.models.filter { search.isEmpty || ($0.name + " " + $0.model + " " + $0.providerName).localizedCaseInsensitiveContains(search) }
    }
    private var providers: [String] { filtered.map(\.provider).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("切换模型").font(.ui(size: 15, weight: .semibold))
                    Text("仅用于当前 Bot Chat").font(.ui(size: 11)).foregroundStyle(Color.muted)
                }
                Spacer()
                if chat.loadingModels || chat.switchingModel { ProgressView().controlSize(.small) }
                Button { Task { await store.loadModels(for: chat, refresh: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(ResponsiveButton()).help("刷新远端模型列表").accessibilityLabel("刷新模型列表").disabled(chat.loadingModels || chat.switchingModel || store.phase != .connected)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.muted)
                TextField("搜索模型或服务商", text: $search).textFieldStyle(.plain)
            }.padding(10).background(Color.inputSurface, in: OpticalRoundedRectangle())
            if let error = chat.modelError {
                HStack(alignment: .top, spacing: 7) { Image(systemName: "exclamationmark.circle"); Text(error).textSelection(.enabled) }.font(.ui(size: 11)).foregroundStyle(.orange)
            }
            if chat.running { Text("回复完成后即可切换模型。").font(.ui(size: 11)).foregroundStyle(Color.muted) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(providers, id: \.self) { provider in
                        Text(filtered.first(where: { $0.provider == provider })?.providerName ?? provider)
                            .font(.ui(size: 10, weight: .semibold)).foregroundStyle(Color.muted).padding(.top, 9).padding(.horizontal, 8)
                        ForEach(filtered.filter { $0.provider == provider }) { choice in
                            let selected = chat.modelLabel == choice.model && chat.modelProvider == choice.provider
                            Button { select(choice) } label: {
                                HStack(spacing: 9) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(choice.name).font(.ui(size: 12, weight: selected ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                                        if choice.name != choice.model { Text(choice.model).font(.ui(size: 10)).foregroundStyle(Color.muted).lineLimit(1) }
                                    }
                                    Spacer(minLength: 10)
                                    if !choice.available { Text("暂不可用").font(.ui(size: 10)).foregroundStyle(Color.muted) }
                                    if selected { Image(systemName: "checkmark").font(.ui(size: 11, weight: .semibold)).foregroundStyle(Color.accent) }
                                }.frame(maxWidth: .infinity).padding(10).contentShape(OpticalRoundedRectangle())
                            }.buttonStyle(ResponsiveButton()).background(selected ? Color.selectionFill : .clear, in: OpticalRoundedRectangle())
                                .overlay(OpticalRoundedRectangle().strokeBorder(selected ? Color.selectionBorder : .clear))
                                .disabled(!choice.available || chat.switchingModel || chat.running || chat.uploading || !chat.canSubmit || store.phase != .connected)
                                .accessibilityLabel("\(choice.providerName)，\(choice.name)").accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    if filtered.isEmpty && !chat.loadingModels {
                        VStack(spacing: 9) {
                            Image(systemName: "cpu").font(.ui(size: 25)).foregroundStyle(Color.muted)
                            Text(search.isEmpty ? "没有可用模型" : "没有找到匹配的模型").font(.ui(size: 12))
                            if search.isEmpty { Text("请先在远端 Hermes 配置模型服务商，再刷新列表。").font(.ui(size: 11)).foregroundStyle(Color.muted).multilineTextAlignment(.center) }
                        }.frame(maxWidth: .infinity).padding(.vertical, 45)
                    }
                }
            }.frame(height: 300)
            Divider()
            Text("模型来自远端 Hermes，切换会保留当前对话和草稿。").font(.ui(size: 10)).foregroundStyle(Color.muted)
        }.padding(18).frame(width: 390).background(Color.canvas).appTheme()
        .task { await store.loadModels(for: chat) }
        .overlay {
            if let warning {
                InPageDialog("Hermes 需要确认", message: warning.message) {
                    Button("取消") { self.warning = nil; pendingChoice = nil }.buttonStyle(SecondaryButton()).keyboardShortcut(.cancelAction)
                    if let choice = pendingChoice {
                        Button("确认切换") { select(choice, confirmed: true, token: warning.token) }.buttonStyle(FilledButton())
                    }
                }
            }
        }
    }
    private func select(_ choice: ChatModelOption, confirmed: Bool = false, token: String = "") {
        Task {
            do {
                if let result = try await store.switchModel(choice, for: chat, confirmed: confirmed, token: token) {
                    pendingChoice = choice; warning = result
                } else { warning = nil; pendingChoice = nil; dismiss() }
            } catch { chat.modelError = store.readable(error) }
        }
    }
}
