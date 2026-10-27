import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import HermesClient

struct ProfileChannelsPane: View {
    @Bindable var configuration: ProfileMessagingConfiguration
    @State private var selected = ""
    @State private var advanced = false
    private var platform: JSON { configuration.platforms.first { $0["id"].string == selected } ?? .null }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsNotice(text: "只配置 \(configuration.profile)。保存会改写这个 Bot 在 Hermes 中的平台配置与凭据；运行中的 Hermes 可能立即重新加载连接。")
            HStack {
                ChoicePicker(title:"选择消息平台", selection:$selected, options:configuration.platforms.map { Choice($0["id"].string, $0["name"].string) }).disabled(!configuration.pairingID.isEmpty)
                Button("刷新平台状态") { Task { await configuration.load() } }.buttonStyle(SecondaryButton())
            }.disabled(configuration.busy)
            if !platform.isNull {
                SettingsCard(platform["name"].string, subtitle: platform["description"].string) {
                    HStack {
                        Circle().fill(platform["state"].string == "connected" ? Color.green : Color.muted).frame(width:7,height:7)
                        Text(stateTitle(platform["state"].string)).font(.ui(size:13,weight:.medium)); Spacer()
                        Text(platform["configured"].bool ? "凭据已配置" : "尚未完成配置").font(.ui(size:12)).foregroundStyle(Color.muted)
                    }
                    if !platform["error_message"].string.isEmpty { SettingsNotice(text:platform["error_message"].string,problem:true) }
                    if !platform["ingress_url"].string.isEmpty { Text("平台回调地址：" + platform["ingress_url"].string).font(.ui(size:12)).textSelection(.enabled) }
                    Toggle("启用此消息平台", isOn:enabled).toggleStyle(BotsToggleStyle())
                    ForEach(platform["env_vars"].array.filter { advanced || !$0["advanced"].bool }, id:\.self) { field in fieldView(field) }
                    if platform["env_vars"].array.contains(where: { $0["advanced"].bool }) {
                        Button(advanced ? "收起高级字段" : "显示高级字段") { advanced.toggle() }.buttonStyle(SecondaryButton())
                    }
                    HStack {
                        Button("保存到这个 Bot") { Task { await configuration.save(selected) } }.buttonStyle(FilledButton())
                        Button("检查连接") { Task { await configuration.check(selected) } }.buttonStyle(SecondaryButton())
                        Spacer()
                        if let url = docsURL { Button("官方配置指引") { NSWorkspace.shared.open(url) }.buttonStyle(SecondaryButton()) }
                    }
                    Button("重新载入此平台（放弃草稿）") { Task { await configuration.reloadPlatform(selected) } }.buttonStyle(SecondaryButton())
                }.disabled(configuration.busy || configuration.pairingPlatform == selected)
                if ["telegram", "whatsapp"].contains(selected) { pairingCard }
                else { Text("需要平台侧创建应用、安装插件或运行桥接服务时，请按官方指引完成，再在上面保存参数。").font(.ui(size:12)).foregroundStyle(Color.muted) }
            } else if configuration.loaded { SettingsNotice(text:"这个 profile 当前未提供可配置消息平台；可按 Hermes 官方指引安装所需的平台插件。") }
            if configuration.busy { ProgressView().controlSize(.small) }
            if let error = configuration.error { SettingsNotice(text:error,problem:true) }
            if let message = configuration.notice { SettingsNotice(text:message,problem:configuration.problem) }
        }.task {
            if !configuration.loaded { await configuration.load() }
            if selected.isEmpty { selected = configuration.platforms.first?["id"].string ?? "" }
        }.onChange(of: configuration.platforms) { _, rows in
            if !rows.contains(where: { $0["id"].string == selected }) { selected = rows.first?["id"].string ?? "" }
        }
    }
    private var enabled: Binding<Bool> { Binding(get: { configuration.drafts[selected]?.enabled ?? false }, set: { value in if var draft = configuration.drafts[selected] { draft.enabled = value; configuration.drafts[selected] = draft } }) }
    private func value(_ key: String) -> Binding<String> { Binding(get:{ configuration.drafts[selected]?.values[key] ?? "" },set:{ value in if var draft = configuration.drafts[selected] { draft.values[key] = value; configuration.drafts[selected] = draft } }) }
    private var docsURL: URL? { guard let url = URL(string: platform["docs_url"].string), ["https","http"].contains(url.scheme?.lowercased() ?? "") else { return nil }; return url }
    private func fieldView(_ field: JSON) -> some View {
        let key = field["key"].string
        let clearing = configuration.drafts[selected]?.clear.contains(key) == true
        let secret = field["is_password"].bool || ["TOKEN","SECRET","PASSWORD","API_KEY","CREDENTIAL"].contains(where: { key.contains($0) })
        return VStack(alignment:.leading,spacing:8) {
            HStack {
                Text(field["prompt"].string.isEmpty ? key : field["prompt"].string).font(.ui(size:13,weight:.medium))
                if field["required"].bool { Text("必填").font(.ui(size:11)).foregroundStyle(Color.muted) }
                Spacer()
                if field["is_set"].bool {
                    Button(clearing ? "取消清除" : "清除已保存值") {
                        if var draft = configuration.drafts[selected] {
                            if clearing { draft.clear.remove(key) } else { draft.clear.insert(key) }
                            configuration.drafts[selected] = draft
                        }
                    }.buttonStyle(ResponsiveButton()).font(.ui(size:11)).foregroundStyle(clearing ? Color.orange : Color.muted)
                }
            }
            Group {
                if secret { SecureField(field["is_set"].bool ? "已配置，留空保留原值" : "填写新的凭据", text:value(key)) }
                else { TextField(field["is_set"].bool ? "已配置，留空保留；清空请用右侧清除" : "填写配置值", text:value(key)) }
            }.textFieldStyle(BotsTextFieldStyle()).disabled(clearing)
            if !field["description"].string.isEmpty { Text(field["description"].string).font(.ui(size:12)).foregroundStyle(Color.muted).fixedSize(horizontal:false,vertical:true) }
        }
    }
    private var pairingCard: some View {
        SettingsCard(selected == "telegram" ? "Telegram 扫码连接" : "WhatsApp 扫码连接", subtitle:"扫码完成后，点击应用连接才写入所选 Bot；Hermes 随后可能重载消息网关。") {
            if configuration.pairingID.isEmpty {
                if selected == "whatsapp" {
                    ChoiceTabs(selection:$configuration.whatsappMode, options:[Choice("bot","Bot 模式"),Choice("self-chat","自聊模式")])
                }
                Button("开始连接流程") { Task { await configuration.startPairing(selected) } }.buttonStyle(FilledButton()).disabled(configuration.busy)
            } else {
                let payload = configuration.pairing
                if let image = qrImage(payload["qr_payload"].string) { Image(nsImage:image).interpolation(.none).resizable().frame(width:188,height:188).padding(12).background(.white,in:OpticalRoundedRectangle()) }
                Text(pairingTitle(payload["status"].string)).font(.ui(size:13,weight:.medium))
                if !payload["expires_at"].string.isEmpty { Text("有效期至 " + payload["expires_at"].string).font(.ui(size:12)).foregroundStyle(Color.muted) }
                if !payload["error"].string.isEmpty { SettingsNotice(text:payload["error"].string,problem:true) }
                TextField(selected == "telegram" ? "允许的 Telegram 用户 ID，逗号分隔" : "允许的手机号或账号，逗号分隔", text:$configuration.allowedUsers).textFieldStyle(BotsTextFieldStyle())
                HStack {
                    if selected == "telegram", let url = URL(string:payload["deep_link"].string), ["https","tg"].contains(url.scheme?.lowercased() ?? "") {
                        Button("在 Telegram 中打开") { NSWorkspace.shared.open(url) }.buttonStyle(SecondaryButton())
                    }
                    Button("刷新扫码状态") { Task { await configuration.refreshPairing() } }.buttonStyle(SecondaryButton())
                    Button("取消连接") { Task { await configuration.cancelPairing() } }.buttonStyle(SecondaryButton())
                    Button("应用连接") { Task { await configuration.applyPairing() } }.buttonStyle(FilledButton()).disabled(!["ready","connected"].contains(payload["status"].string))
                }.disabled(configuration.busy)
            }
        }.disabled(configuration.busy)
    }
    private func qrImage(_ payload: String) -> NSImage? {
        guard !payload.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(payload.utf8)
        guard let output = filter.outputImage?.transformed(by:CGAffineTransform(scaleX:6,y:6)), let image = CIContext().createCGImage(output,from:output.extent) else { return nil }
        return NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))
    }
    private func pairingTitle(_ value: String) -> String { ["ready":"扫码已确认，可以应用连接", "connected":"账号已关联，可以应用连接", "waiting":"等待扫码确认", "starting":"正在准备二维码", "expired":"二维码已过期，请取消后重新开始", "error":"连接流程失败"][value] ?? "等待完成平台连接" }
    private func stateTitle(_ value: String) -> String { ["connected":"已连接", "disabled":"未启用", "not_configured":"待配置", "pending_restart":"配置已保存，等待重载", "gateway_stopped":"消息网关未运行", "startup_failed":"启动失败", "connecting":"连接中"][value] ?? (value.isEmpty ? "尚未确认连接状态" : value) }
}
