import SwiftUI
import HermesClient

struct ConversationActivityView: View {
    @Bindable var activity: ConversationActivity
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "ellipsis").font(.ui(size: 14, weight: .medium)).frame(width: 20)
                    Text(activity.title).font(.ui(size: 12)).lineLimit(1)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.ui(size: 9, weight: .semibold))
                    Spacer(minLength: 0)
                }.padding(.horizontal, 9).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(ResponsiveButton()).foregroundStyle(Color.activityInk)
                .accessibilityLabel(activity.title).accessibilityValue(expanded ? "已展开" : "已收起")
                .help(expanded ? "收起处理详情" : "展开处理详情")
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if activity.details.isEmpty { Text("等待 Hermes 返回处理详情…") }
                        ForEach(activity.details) { detail in Text(verbatim: detail.text).frame(maxWidth: .infinity, alignment: .leading) }
                    }.font(.ui(size: 12)).lineSpacing(4).foregroundStyle(Color.activityInk).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(maxHeight: 220).background(Color.soft, in: OpticalRoundedRectangle())
                    .padding(.leading, 10)
            }
        }.frame(maxWidth: 660, alignment: .leading)
    }
}

/// Only a local send can issue a ticket. Recycled rows and loaded history stay static.
struct SendBubbleEntrance: ViewModifier {
    let chat: BotConversation
    let id: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var scale: CGFloat = 1
    func body(content: Content) -> some View {
        content.offset(y: offset).scaleEffect(scale, anchor: .bottomTrailing)
            .task(id: id) {
                guard chat.claimOutgoingEntrance(id), !reduceMotion else { return }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { offset = 7; scale = 0.985 }
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { offset = 0; scale = 1; return }
                withAnimation(.easeOut(duration: 0.22)) { offset = 0; scale = 1 }
            }
            .onDisappear { offset = 0; scale = 1 }
    }
}

struct ConversationMessageRow: View, Equatable {
    static func == (a: Self, b: Self) -> Bool { a.message == b.message && a.bot == b.bot && a.showTime == b.showTime && a.chat === b.chat && a.store === b.store }
    let message: ChatMessage
    let bot: Bot
    let showTime: Bool
    let chat: BotConversation
    let store: ChatStore
    var download: (String) -> Void
    var preview: (String) -> Void
    var body: some View {
        VStack(spacing: 18) {
            if showTime {
                Text(message.timestamp.timeIntervalSince1970 > 0 ? message.timestamp.formatted(.dateTime.month().day().hour().minute()) : "历史消息")
                    .font(.ui(size: 10, weight: .medium)).foregroundStyle(Color.muted).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            if message.role == "user" {
                bubble.modifier(SendBubbleEntrance(chat: chat, id: message.id))
            } else { bubble }
        }
    }
    private var bubble: some View {
        MessageBubble(message: message, bot: bot, profile: chat.profile, store: store, download: download, preview: preview).equatable()
    }
}
