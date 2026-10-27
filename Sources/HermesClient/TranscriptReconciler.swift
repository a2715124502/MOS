import Foundation

/// A partial/latest REST window is an addition to the visible transcript, never a replacement.
enum TranscriptReconciler {
    static func decode(_ rows: [JSON], offset: Int = 0) async -> [ChatMessage] {
        await Task.detached(priority: .userInitiated) {
            rows.enumerated().compactMap { ChatMessage.from($0.element, index: offset + $0.offset) }
        }.value
    }
    private struct ContentKey: Hashable { let role: String; let text: String }
    static func merge(_ incoming: [ChatMessage], into current: [ChatMessage], activeStreamID: String? = nil) -> [ChatMessage] {
        var output = current
        var byServer: [String:Int] = [:], byContent: [ContentKey:[Int]] = [:]
        for (i, message) in current.enumerated() {
            byServer[message.serverID ?? message.id] = i
            // Only unbound local messages need heuristic receipt matching.
            if message.serverID == nil && !message.id.hasPrefix("row-") && !message.id.hasPrefix("history-") {
                byContent[ContentKey(role: message.role, text: message.text), default: []].append(i)
            }
        }
        var matched = Set<Int>()
        for var message in incoming {
            let key = message.serverID ?? message.id
            var index = byServer[key]
            if index == nil {
                let candidates = byContent[ContentKey(role: message.role, text: message.text)] ?? []
                index = candidates.filter { !matched.contains($0) && current[$0].timestamp.timeIntervalSince1970 > 0 && message.timestamp.timeIntervalSince1970 > 0 && abs(current[$0].timestamp.timeIntervalSince(message.timestamp)) < 120 }
                    .min { abs(current[$0].timestamp.timeIntervalSince(message.timestamp)) < abs(current[$1].timestamp.timeIntervalSince(message.timestamp)) }
            }
            if index == nil, message.role == "assistant" {
                index = current.indices.last(where: { i in
                    let old = current[i]
                    return !matched.contains(i) && old.serverID == nil && old.streaming && !old.text.isEmpty && message.text.hasPrefix(old.text) && message.timestamp.timeIntervalSince1970 > 0 && message.timestamp.timeIntervalSince(old.timestamp) >= -2 && message.timestamp.timeIntervalSince(old.timestamp) < 86_400
                })
            }
            if let i = index {
                let old = output[i]
                message.id = old.id; message.serverID = key
                if old.id == activeStreamID {
                    // A REST window may already contain the final text while its remaining
                    // socket deltas are in flight. Bind the receipt without appending twice.
                    message.text = old.text; message.streaming = old.streaming
                }
                if !old.attachments.isEmpty {
                    message.attachments += old.attachments.filter { a in !message.attachments.contains(where: { $0.id == a.id || $0.name == a.name }) }
                    // The server may include upload references that were not part of the user's text.
                    if old.role == "user" { message.text = old.text }
                }
                output[i] = message; byServer[key] = i; matched.insert(i)
            } else {
                byServer[key] = output.count; output.append(message)
            }
        }
        return ChatMessage.chronological(output)
    }
}
