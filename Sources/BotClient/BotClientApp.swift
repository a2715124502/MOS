import SwiftUI
import AppKit
import UserNotifications
import HermesClient

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var store: ChatStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = BrandTypography.register
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task { await store.flushCache(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let profile = response.notification.request.content.userInfo["profile"] as? String
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            if let profile { Task { await self.store?.select(profile) } }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [] }
}

@main struct BotClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = ChatStore()
    @State private var avatars = AvatarLibrary()
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    var body: some Scene {
        WindowGroup("MOS", id: "main") {
            RootView(store: store)
                .environment(avatars)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    delegate.store = store
                    store.notify = { profile, name, message in
                        guard !NSApp.isActive || store.selected != profile else { return }
                        let content = UNMutableNotificationContent()
                        content.title = name; content.body = message.isEmpty ? "任务已完成" : message
                        content.userInfo = ["profile": profile]; content.sound = .default
                        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                    }
                    if ProcessInfo.processInfo.arguments.contains("--demo") { store.enterDemo() }
                    else { await store.restore() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appSettings) { Button("设置…") { NotificationCenter.default.post(name: Notification.Name("Bots.openSettings"), object: nil) }.keyboardShortcut(",") }
            CommandMenu("外观") {
                Picker("主题", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
            }
            CommandMenu("对话") {
                Button("刷新连接") { store.reconnectNow() }.keyboardShortcut("r")
                Divider()
                Button("停止回复") { if let chat = store.current { Task { await store.stop(chat) } } }.keyboardShortcut(".")
                    .disabled(store.current?.running != true)
            }
        }
        MenuBarExtra {
            MenuContent(store: store)
        } label: { Image(systemName: store.attentionCount > 0 ? "bubble.left.and.exclamationmark.bubble.right" : "bubble.left.and.bubble.right") }
    }
}

private struct MenuContent: View {
    @Bindable var store: ChatStore
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(store.demo ? "界面预览" : store.phase.label)
        if store.workingCount > 0 { Text("\(store.workingCount) 个助手正在工作") }
        if store.attentionCount > 0 { Text("\(store.attentionCount) 项等待你处理") }
        Divider()
        Button("打开对话") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}


struct RootView: View {
    @Bindable var store: ChatStore
    @State private var showSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Group {
            if (store.phase == .signedOut || store.phase == .connecting) && store.bots.isEmpty {
                LoginView(store: store)
            } else {
                SidebarSplitView {
                    SidebarView(store: store, showSettings: $showSettings)
                } detail: {
                    Group {
                        if let chat = store.current, let bot = store.currentBot { ConversationView(store: store, chat: chat, bot: bot).id(bot.profile) }
                        else { WelcomeView() }
                    }.frame(minWidth: 506, maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.canvas, in: OpticalRoundedRectangle())
                        .clipShape(OpticalRoundedRectangle())
                        .overlay { OpticalRoundedRectangle().strokeBorder(Color.hairline.opacity(0.65), lineWidth: 1).allowsHitTesting(false) }
                        .padding(.vertical, 14).padding(.trailing, 14)
                }
                .background(Color.rail)
            }
            }.allowsHitTesting(!showSettings).accessibilityHidden(showSettings)
            if showSettings { SettingsPage(store: store, back: { showSettings = false }).transition(.opacity) }
        }
        .frame(minWidth: 820, minHeight: 580)
        .background(PreviewCapture(enabled: store.demo).allowsHitTesting(false))
        .foregroundStyle(Color.ink)
        .tint(Color.action)
        .appTheme()
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Bots.openSettings"))) { _ in showSettings = true }
        .sheet(isPresented: $store.requiresLogin) { LoginView(store: store).frame(width: 820, height: 580).appTheme() }
        .environment(store)
        .environment(\.avatarContext, AvatarContext(gateway: store.demo ? "demo" : (store.transport?.address.url.absoluteString ?? store.addressText), user: store.demo ? "demo" : store.username))
    }
}

// Captures only this application's explicitly selected example screen.
// Binding the probe to a real window avoids launching-time NSApp.windows races.
private struct PreviewCapture: NSViewRepresentable {
    var enabled: Bool
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        let args = ProcessInfo.processInfo.arguments
        guard enabled, args.contains("--demo"), let index = args.firstIndex(of: "--snapshot"), args.indices.contains(index + 1) else { return }
        view.target = URL(fileURLWithPath: args[index + 1]); view.schedule()
    }
    final class Probe: NSView {
        var target: URL?
        var scheduled = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        func schedule() {
            guard target != nil, window != nil, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, let target = self.target, let content = self.window?.contentView,
                      content.bounds.width > 10, content.bounds.height > 10,
                      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: target, options: .atomic) }
            }
        }
    }
}


struct SidebarView: View {
    @State private var editingAvatar: Bot?
    @Bindable var store: ChatStore
    @Binding var showSettings: Bool
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BrandWordmark()
                Spacer()
                Text("\(store.filteredBots.count)").font(.ui(size: 12, weight: .medium)).foregroundStyle(Color.muted)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(Color.soft, in: OpticalRoundedRectangle())
            }.padding(.horizontal, 20).padding(.top, 49).padding(.bottom, 22)
            if !store.pinnedBots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.pinnedBots) { bot in
                            Button { Task { await store.select(bot.profile) } } label: {
                                HStack(spacing: 6) {
                                    BotAvatar(bot: bot, size: 27, data: store.conversations[bot.profile]?.avatar)
                                    Text(bot.name).font(.ui(size: 12, weight: .semibold)).lineLimit(1).frame(maxWidth: 84)
                                }.padding(.horizontal, 9).padding(.vertical, 7)
                                    .background(store.selected == bot.profile ? Color.selectionFill : Color.soft, in: OpticalRoundedRectangle())
                                    .foregroundStyle(store.selected == bot.profile ? Color.selectionInk : Color.ink)
                            }.buttonStyle(ResponsiveButton()).help(bot.name)
                                .accessibilityAddTraits(store.selected == bot.profile ? .isSelected : [])
                                .customContextMenu {
                                    Button("取消置顶", systemImage: "pin.slash") { store.togglePin(bot.profile) }
                                    Button("更换头像", systemImage: "face.smiling") { editingAvatar = bot }
                                }
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 3)
                }.frame(height: 50).padding(.bottom, 9)
            }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(store.unpinnedBots) { bot in
                        Button { Task { await store.select(bot.profile) } } label: { botRow(bot) }.buttonStyle(ResponsiveButton())
                            .accessibilityAddTraits(store.selected == bot.profile ? .isSelected : [])
                            .customContextMenu {
                                Button("置顶助手", systemImage: "pin") { store.togglePin(bot.profile) }
                                Button("更换头像", systemImage: "face.smiling") { editingAvatar = bot }
                            }
                    }
                    if store.filteredBots.isEmpty { Text("暂无 Bot").font(.callout).foregroundStyle(Color.muted).padding(30) }
                }.padding(.horizontal, 10)
                    .animation(reduceMotion ? nil : BotMotion.spring, value: store.selected)
            }
            Spacer(minLength: 12)
            HStack(spacing: 9) {
                Circle().fill(store.phase == .connected ? Color.green.opacity(0.8) : Color.orange).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.demo ? "界面预览" : "Hermes 网关").font(.ui(size: 12, weight: .medium))
                    Text(store.demo ? "示例消息 · 未连接网关" : store.phase.label).font(.ui(size: 10)).foregroundStyle(Color.muted)
                }
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "gearshape").font(.ui(size: 15)).foregroundStyle(Color.muted) }
                    .buttonStyle(ResponsiveButton(round: true)).help("设置").accessibilityLabel("设置")
            }.padding(.horizontal, 22).padding(.vertical, 20)
        }.background(Color.rail)
        .sheet(item: $editingAvatar) { bot in AvatarPickerView(bot: bot, serverData: store.conversations[bot.profile]?.avatar) }
    }
    func botRow(_ bot: Bot) -> some View {
        let chosen = store.selected == bot.profile
        let chat = store.conversations[bot.profile]
        let preview = chat?.messages.last(where: { $0.role != "tool" })?.text ?? bot.preview
        return HStack(alignment: .center, spacing: 12) {
            BotAvatar(bot: bot, size: 43, data: chat?.avatar, busy: chat?.running == true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(bot.name).font(.ui(size: 14, weight: .semibold)).foregroundStyle(chosen ? Color.selectionInk : Color.ink).lineLimit(1)
                    Spacer(minLength: 2)
                    if bot.lastActive > 0 { Text(Date(timeIntervalSince1970: bot.lastActive), style: .time).font(.ui(size: 10)).foregroundStyle(chosen ? Color.selectionMuted : Color.muted) }
                }
                HStack {
                    Text(chat?.cards.isEmpty == false ? "等待你确认" : chat?.running == true ? (chat?.status ?? "正在处理") : preview.isEmpty ? bot.subtitle.isEmpty ? "开始对话" : bot.subtitle : preview.replacingOccurrences(of: "\n", with: " "))
                        .font(.ui(size: 12)).foregroundStyle(chat?.cards.isEmpty == false ? Color.orange : chosen ? Color.selectionMuted : Color.muted).lineLimit(1)
                    if store.unread.contains(bot.profile) { Circle().fill(Color.accent).frame(width: 6, height: 6) }
                }
            }
        }.padding(.horizontal, 11).padding(.vertical, 13)
            .background {
                if chosen {
                    OpticalRoundedRectangle().fill(Color.selectionFill)
                        .matchedGeometryEffect(id: "selected-bot", in: selection)
                }
            }
            .overlay { OpticalRoundedRectangle().strokeBorder(chosen ? Color.selectionBorder.opacity(0.45) : .clear, lineWidth: 1) }
            .contentShape(OpticalRoundedRectangle())
            .accessibilityLabel("\(bot.name)，\(preview)")
    }
}

struct LoginView: View {
    @Bindable var store: ChatStore
    @State private var password = ""
    @FocusState private var field: Int?
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().scaledToFit()
                    .frame(width: 164, height: 164).padding(.bottom, 28)
                BrandWordmark(size: 38).foregroundStyle(Color.ink).padding(.bottom, 18)
                Text("熟悉的助手，\n更自在的对话。")
                    .font(.ui(size: 31, weight: .semibold)).lineSpacing(8).tracking(-0.8)
                Text("连接你的 Hermes。\n每一段对话，都从上次继续。")
                    .font(.ui(size: 14)).foregroundStyle(Color.muted).lineSpacing(7).padding(.top, 22)
                Spacer()
                Label("由你自己的 Hermes 运行", systemImage: "desktopcomputer").font(.ui(size: 11)).foregroundStyle(Color.muted).padding(.bottom, 36)
            }.padding(.horizontal, 48).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.rail)
            VStack(alignment: .leading, spacing: 0) {
                Text("连接 Hermes").font(.ui(size: 24, weight: .semibold)).padding(.bottom, 10)
                Text("使用现有网关与 Hermes 账号登录")
                    .font(.ui(size: 12)).foregroundStyle(Color.muted).padding(.bottom, 30)
                input("网关地址") { TextField("https://hermes.example.com", text: $store.addressText).focused($field, equals: 0) }
                input("用户名") { TextField("Hermes 用户名", text: $store.username).focused($field, equals: 1) }
                input("密码") { SecureField("Hermes 密码", text: $password).focused($field, equals: 2).onSubmit(signIn) }
                if let error = store.loginError { Label(error, systemImage: "exclamationmark.circle").font(.ui(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.bottom, 16) }
                Button(action: signIn) {
                    HStack(spacing: 9) {
                        if store.connecting || store.phase == .connecting { ProgressView().controlSize(.small).tint(.white) }
                        Text(store.connecting || store.phase == .connecting ? "正在连接…" : "连接并继续").fontWeight(.medium)
                        if !store.connecting { Image(systemName: "arrow.right") }
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(FilledButton()).controlSize(.large).disabled(store.connecting || store.phase == .connecting || password.isEmpty || store.username.isEmpty)
                Text("密码仅用于登录。登录状态安全保存在系统钥匙串中。")
                    .font(.ui(size: 10)).foregroundStyle(Color.muted).lineSpacing(4).padding(.top, 14)
                Button("先看看界面") { password = ""; store.enterDemo() }.buttonStyle(ResponsiveButton()).font(.ui(size: 12)).foregroundStyle(Color.muted).padding(.top, 30)
            }.padding(38).frame(width: 396)
                .background(Color.canvas, in: OpticalRoundedRectangle())
                .padding(14)
        }.background(Color.rail).foregroundStyle(Color.ink)
    }
    func input<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.ui(size: 11, weight: .medium)).foregroundStyle(Color.muted)
            content().textFieldStyle(.plain).font(.ui(size: 13)).padding(12)
                .background(Color.soft, in: OpticalRoundedRectangle()).overlay(OpticalRoundedRectangle().strokeBorder(.primary.opacity(0.09)))
        }.padding(.bottom, 18)
    }
    func signIn() { guard !password.isEmpty else { return }; let value = password; password = ""; Task { await store.login(password: value) } }
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "bubble.left.and.bubble.right").font(.ui(size: 39, weight: .ultraLight)).foregroundStyle(Color.muted.opacity(0.6))
            Text("从一段对话开始").font(.ui(size: 19, weight: .medium))
            Text("选择左边的助手，继续你们的对话。").font(.ui(size: 12)).foregroundStyle(Color.muted)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.canvas)
    }
}
