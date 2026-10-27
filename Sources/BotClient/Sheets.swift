import SwiftUI
import UserNotifications
import HermesClient

struct PendingCardView: View {
    let card: PendingCard
    var answer: (JSON) async throws -> Void
    @State private var values: [String: String] = [:]
    @State private var selectedChoices: [String: Set<String>] = [:]
    @State private var busy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(card.title, systemImage: card.isApproval ? "hand.raised" : card.isSecret ? "lock" : "text.bubble")
                .font(.ui(size: 12, weight: .semibold)).foregroundStyle(card.isApproval ? Color.orange : Color.accent)
            if !card.params["description"].string.isEmpty { Text(card.params["description"].string).font(.ui(size: 12)).textSelection(.enabled) }
            if card.isApproval {
                if !card.params["command"].string.isEmpty {
                    ScrollView(.horizontal) { Text(card.params["command"].string).font(.ui(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }.padding(10).background(.primary.opacity(0.04), in: OpticalRoundedRectangle())
                }
                HStack(spacing: 8) {
                    ForEach(card.choices, id: \.self) { choice in
                        Button(choiceLabel(choice)) { submit(.object(["choice": .string(choice)])) }.buttonStyle(SecondaryButton()).controlSize(.small).disabled(busy)
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
            } else if card.isSecret {
                Text(card.params["prompt"].string.isEmpty ? "安全输入不会加入聊天消息。" : card.params["prompt"].string).font(.ui(size: 11)).foregroundStyle(Color.muted)
                SecureField("安全输入", text: Binding(get: { values["value"] ?? "" }, set: { values["value"] = $0 })).textFieldStyle(BotsTextFieldStyle())
                HStack {
                    Button("跳过") { submit(.object(["value": ""])) }
                    Button("提交") { let value = values["value"] ?? ""; values = [:]; submit(.object(["value": .string(value)])) }.buttonStyle(FilledButton())
                }.controlSize(.small).disabled(busy)
            } else {
                ForEach(Array(card.questions.enumerated()), id: \.offset) { index, question in
                    let qid = question["qid"].string.isEmpty ? "q\(index)" : question["qid"].string
                    VStack(alignment: .leading, spacing: 8) {
                        Text(question["question"].string).font(.ui(size: 12)).textSelection(.enabled)
                        if !question["choices"].array.isEmpty {
                            FlowChoices(choices: question["choices"].array.map(\.string), selected: selectedChoices[qid] ?? []) { choice in
                                if question["multi_select"].bool {
                                    var set = selectedChoices[qid] ?? []; if set.contains(choice) { set.remove(choice) } else { set.insert(choice) }; selectedChoices[qid] = set
                                    values[qid] = set.sorted().joined(separator: ", ")
                                } else { selectedChoices[qid] = [choice]; values[qid] = choice }
                            }
                        }
                        TextField("输入回答，也可以补充自己的想法", text: Binding(get: { values[qid] ?? "" }, set: { values[qid] = $0 })).textFieldStyle(BotsTextFieldStyle()).font(.ui(size: 12))
                    }
                }
                HStack {
                    Button("暂时跳过") { submit(.object(["answers": .object([:]), "outcome": "cancelled"])) }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("发送回答") {
                        var answers: [String: JSON] = [:]
                        for (index, q) in card.questions.enumerated() { let qid = q["qid"].string.isEmpty ? "q\(index)" : q["qid"].string; answers[qid] = .string(values[qid] ?? "") }
                        submit(.object(["answers": .object(answers), "outcome": "submitted", "answer": .string(values.values.first ?? "")]))
                    }.buttonStyle(FilledButton())
                }.controlSize(.small).disabled(busy)
            }
            if let error { Text(error).font(.ui(size: 11)).foregroundStyle(.red) }
        }.padding(16).frame(maxWidth: 700, alignment: .leading)
            .background(Color.soft, in: OpticalRoundedRectangle())
            .overlay(OpticalRoundedRectangle().strokeBorder(card.isApproval ? Color.orange.opacity(0.25) : Color.accent.opacity(0.15)))
            .animation(reduceMotion ? nil : BotMotion.quick, value: busy)
            .animation(reduceMotion ? nil : BotMotion.quick, value: error)
    }
    func choiceLabel(_ choice: String) -> String { ["once": "允许一次", "session": "本次会话允许", "always": "始终允许", "deny": "拒绝"][choice] ?? choice }
    func submit(_ result: JSON) {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await answer(result) } catch { self.error = error.localizedDescription } }
    }
}

private struct FlowChoices: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let choices: [String]
    let selected: Set<String>
    var choose: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(choices, id: \.self) { choice in
                Button { choose(choice) } label: { HStack(spacing: 6) { Image(systemName: selected.contains(choice) ? "checkmark.circle.fill" : "circle"); Text(choice).multilineTextAlignment(.leading); Spacer(minLength: 0) }.font(.ui(size: 11)).foregroundStyle(selected.contains(choice) ? Color.accent : Color.ink).padding(8).background(selected.contains(choice) ? Color.selectionFill : Color.primary.opacity(0.035), in: OpticalRoundedRectangle()) }.buttonStyle(ResponsiveButton()).animation(reduceMotion ? nil : BotMotion.quick, value: selected.contains(choice))
            }
        }
    }
}
