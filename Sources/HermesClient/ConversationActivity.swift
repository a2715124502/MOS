import Foundation
import Observation

public struct ActivityDetail: Identifiable, Equatable, Sendable {
    public let id: String
    public var text: String
}

/// Transient, bounded display state. Never serialized into the transcript or disk cache.
@MainActor @Observable public final class ConversationActivity {
    public var phaseID = UUID()
    public private(set) var title = ""
    public private(set) var details: [ActivityDetail] = []
    public var visible: Bool { !title.isEmpty }
    @ObservationIgnored private var tools: Set<String> = []
    @ObservationIgnored private var reasoningBuffer = ""
    @ObservationIgnored private var reasoningTask: Task<Void, Never>?
    private func begin(_ title: String) {
        if !visible { phaseID = UUID() }
        if self.title != title { self.title = title }
    }
    public func clear() {
        guard visible || !details.isEmpty || !tools.isEmpty || !reasoningBuffer.isEmpty else { return }
        reasoningTask?.cancel(); reasoningTask = nil; reasoningBuffer = ""
        title = ""; details = []; tools = []
    }
    func waiting(_ title: String = "正在加载中") { begin(title) }
    private func put(_ id: String, _ text: String, append: Bool = false) {
        let chunk = String(text.suffix(12_000))
        if let i = details.firstIndex(where: { $0.id == id }) {
            details[i].text = append ? String((details[i].text + chunk).suffix(24_000)) : chunk
        } else {
            details.append(ActivityDetail(id: id, text: chunk))
            if details.count > 20 { details.removeFirst(details.count - 20) }
        }
        while details.count > 1 && details.reduce(0, { $0 + $1.text.count }) > 32_000 { details.removeFirst() }
    }
    func reasoning(_ text: String) {
        guard !text.isEmpty else { return }
        begin(tools.isEmpty ? "思考中" : "工具调用中")
        reasoningBuffer = String((reasoningBuffer + text).suffix(24_000))
        guard reasoningTask == nil else { return }
        reasoningTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            let chunk = self.reasoningBuffer; self.reasoningBuffer = ""; self.reasoningTask = nil
            self.put("reasoning", chunk, append: true)
        }
    }
    func thinking(_ text: String) {
        if text.isEmpty { details.removeAll { $0.id == "thinking" }; if visible { begin(tools.isEmpty ? "正在加载中" : "工具调用中") }; return }
        begin(tools.isEmpty ? "思考中" : "工具调用中"); put("thinking", text)
    }
    func tool(_ payload: JSON, completed: Bool = false) {
        let name = [payload["name"].string, payload["tool_name"].string, "工具"].first { !$0.isEmpty } ?? "工具"
        let id = [payload["tool_id"].string, payload["tool_call_id"].string, name].first { !$0.isEmpty } ?? name
        if completed { tools.remove(id) } else { tools.insert(id) }
        begin(tools.isEmpty && completed ? "思考中" : "工具调用中")
        let state = completed ? (payload["is_error"].bool ? "调用结束，工具返回错误" : "已完成") : "调用中"
        let context = String(payload["context"].string.prefix(300))
        put("tool-" + id, name + " · " + state + (context.isEmpty ? "" : "\n" + context))
    }
    func status(_ title: String, detail: String = "") {
        begin(title); if !detail.isEmpty { put("status", detail) }
    }
}
