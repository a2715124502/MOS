import Foundation
import CryptoKit
import Security
import LocalAuthentication

public enum CredentialStore {
    private static func query(_ account: String) -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.hermes.remote.credentials", kSecAttrAccount as String: account, kSecUseAuthenticationContext as String: context]
    }
    public static func read(_ account: String) throws -> Credentials? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed { throw ClientError.message("保存的登录状态暂不可读取，请重新登录") }
        guard status == errSecSuccess, let data = item as? Data else { throw ClientError.message("无法读取系统钥匙串（\(status)）") }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }
    public static func save(_ value: Credentials, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account); q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let add = SecItemAdd(q as CFDictionary, nil)
            guard add == errSecSuccess else { throw ClientError.message("无法保存登录状态（\(add)）") }; return
        }
        guard status == errSecSuccess else { throw ClientError.message("无法更新登录状态（\(status)）") }
    }
    public static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

@MainActor public final class GatewayTransport {
    public let address: GatewayAddress
    private var credentials: Credentials?
    var credentialsSnapshot: Credentials? { credentials }
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var refreshTask: Task<Credentials, Error>?
    private var generation = 0
    var connectionSerial: Int { generation }
    public private(set) var ready = false
    public private(set) var sessionAuthority = false
    public var onEvent: ((GatewayEvent) -> Void)?
    public var onRequest: ((PendingCard) -> Void)?
    public var onDisconnect: ((Error) -> Void)?
    public var onCredentials: ((Credentials) -> Void)?

    public init(address: GatewayAddress, credentials: Credentials? = nil, session: URLSession? = nil) {
        self.address = address; self.credentials = credentials
        if let session { self.session = session }
        else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 35; c.timeoutIntervalForResource = 120
            c.httpShouldSetCookies = false
            self.session = URLSession(configuration: c)
        }
    }
    public func request(_ path: String, method: String = "GET", profile: String? = nil, query: [URLQueryItem] = [], body: JSON? = nil, authenticated: Bool = true) async throws -> JSON {
        let (data, _) = try await raw(path, method: method, profile: profile, query: query, body: body.map { try! JSONEncoder().encode($0) }, authenticated: authenticated)
        do { return try await Task.detached(priority: .userInitiated) { try JSON.parse(data) }.value }
        catch { throw ClientError.message("地址返回的不是 Hermes 数据，请确认网关地址和端口") }
    }
    public func raw(_ path: String, method: String = "GET", profile: String? = nil, query: [URLQueryItem] = [], body: Data? = nil, authenticated: Bool = true, retry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        if authenticated, let c = credentials, c.expiresAt < Date().timeIntervalSince1970 + 30, !c.refreshToken.isEmpty { try await refresh() }
        var q = query
        if let profile { q.append(URLQueryItem(name: "profile", value: profile)) }
        var req = URLRequest(url: address.endpoint(path, query: q))
        req.httpMethod = method; req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated, let c = credentials { req.setValue("Bearer " + c.accessToken, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ClientError.message("网关没有返回有效响应") }
        if http.statusCode == 401, authenticated, retry, credentials?.refreshToken.isEmpty == false {
            try await refresh()
            return try await raw(path, method: method, profile: profile, query: query, body: body, authenticated: authenticated, retry: false)
        }
        if http.statusCode == 401 { throw ClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw Self.httpError(data, status: http.statusCode) }
        return (data, http)
    }
    public func downloadFile(path: String, profile: String, to destination: URL, retry: Bool = true) async throws {
        if let c = credentials, c.expiresAt < Date().timeIntervalSince1970 + 30, !c.refreshToken.isEmpty { try await refresh() }
        var req = URLRequest(url: address.endpoint("/api/files/download", query: [.init(name: "path", value: path), .init(name: "profile", value: profile)]))
        if let c = credentials { req.setValue("Bearer " + c.accessToken, forHTTPHeaderField: "Authorization") }
        let (temporary, response) = try await session.download(for: req)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse else { throw ClientError.message("文件下载未收到响应") }
        if http.statusCode == 401, retry { try await refresh(); try await downloadFile(path: path, profile: profile, to: destination, retry: false); return }
        guard (200..<300).contains(http.statusCode) else { throw Self.httpError((try? Data(contentsOf: temporary)) ?? Data(), status: http.statusCode) }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".botclient-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: temporary, to: staging)
        do {
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging) }
            else { try FileManager.default.moveItem(at: staging, to: destination) }
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
    public static func httpError(_ data: Data, status: Int) -> ClientError {
        let j = try? JSON.parse(data)
        let explanation = [j?["detail"].string ?? "", j?["error"].string ?? "", j?["message"].string ?? ""].first { !$0.isEmpty }
        return .message(explanation ?? "网关请求失败（HTTP \(status)）")
    }
    private func refresh() async throws {
        if let refreshTask { credentials = try await refreshTask.value; return }
        guard let c = credentials, !c.refreshToken.isEmpty else { throw ClientError.unauthorized }
        let task = Task { () throws -> Credentials in
            let json = try await request("/auth/native/refresh", method: "POST", body: .object(["refresh_token": .string(c.refreshToken), "provider": .string(c.provider)]), authenticated: false)
            return try Credentials(json, previous: c)
        }
        refreshTask = task
        defer { refreshTask = nil }
        let updated = try await task.value
        credentials = updated; onCredentials?(updated)
    }

    public static func login(address: GatewayAddress, username: String, password: String) async throws -> Credentials {
        let bytes = (0..<48).map { _ in UInt8.random(in: .min ... .max) }
        func b64(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let verifier = b64(Data(bytes)), challenge = b64(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = true; config.httpCookieAcceptPolicy = .always; config.timeoutIntervalForRequest = 30
        let authSession = URLSession(configuration: config)
        defer { authSession.invalidateAndCancel() }
        let url = address.endpoint("/auth/native/authorize", query: [
            .init(name: "provider", value: "basic"), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "redirect_uri", value: "http://127.0.0.1:1/callback"), .init(name: "state", value: state)
        ])
        let (aData, aResponse) = try await authSession.data(from: url)
        if let response = aResponse as? HTTPURLResponse, response.statusCode >= 400 { throw httpError(aData, status: response.statusCode) }
        var req = URLRequest(url: address.endpoint("/auth/password-login"))
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(JSON.object(["provider": "basic", "username": .string(username), "password": .string(password)]))
        let (data, response) = try await authSession.data(for: req)
        guard let response = response as? HTTPURLResponse else { throw ClientError.message("登录未收到响应") }
        guard (200..<300).contains(response.statusCode) else { throw httpError(data, status: response.statusCode) }
        let json = try JSON.parse(data)
        guard let c = URLComponents(string: json["next"].string), let code = c.queryItems?.first(where: { $0.name == "code" })?.value,
              c.queryItems?.first(where: { $0.name == "state" })?.value == state else { throw ClientError.message("登录校验失败，网关没有返回有效授权，请重试") }
        let api = GatewayTransport(address: address)
        return try Credentials(await api.request("/auth/native/token", method: "POST", body: .object(["code": .string(code), "code_verifier": .string(verifier)]), authenticated: false))
    }

    public func connect() async throws {
        disconnect()
        generation += 1
        let current = generation
        let ticket = try await request("/api/auth/ws-ticket", method: "POST", body: .object([:]))
        guard generation == current, !Task.isCancelled else { throw CancellationError() }
        guard !ticket["ticket"].string.isEmpty else { throw ClientError.message("网关未提供连接票据") }
        var c = URLComponents(url: address.endpoint("/api/ws", query: [.init(name: "ticket", value: ticket["ticket"].string)]), resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        let ws = session.webSocketTask(with: c.url!); ws.maximumMessageSize = 64 * 1024 * 1024
        socket = ws; ws.resume()
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let msg = try await ws.receive()
                    let data: Data
                    switch msg { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                    let frame = try await Task.detached(priority: .userInitiated) { try JSON.parse(data) }.value
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    try self.receive(frame)
                }
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.failConnection(error)
            }
        }
        for _ in 0..<200 {
            if ready { break }
            try await Task.sleep(for: .milliseconds(100))
            guard generation == current, socket != nil else { throw ClientError.disconnected }
        }
        guard generation == current, !Task.isCancelled else { throw CancellationError() }
        guard ready else { disconnect(); throw ClientError.timeout("建立连接") }
        _ = try await call("client.capabilities", params: ["server_requests": true], timeout: 15)
        guard generation == current, !Task.isCancelled else { throw CancellationError() }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, self.generation == current else { return }
                do { _ = try await self.call("ping", timeout: 12) }
                catch {
                    // A cancelled ping from the previous socket must not tear down its replacement.
                    guard !Task.isCancelled, self.generation == current else { return }
                    self.failConnection(error); return
                }
            }
        }
    }
    public func disconnect() {
        generation += 1; ready = false; sessionAuthority = false
        reader?.cancel(); reader = nil; heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        let old = pending; pending = [:]
        deadlines.values.forEach { $0.cancel() }; deadlines = [:]
        old.values.forEach { $0.resume(throwing: ClientError.disconnected) }
    }
    private func failConnection(_ error: Error) { disconnect(); onDisconnect?(error) }
    public func call(_ method: String, params: [String: JSON] = [:], profile: String? = nil, timeout: Double = 60) async throws -> JSON {
        guard ready, let socket else { throw ClientError.disconnected }
        var params = params
        if let profile { params["profile"] = .string(profile) }
        nextID += 1; let id = nextID
        let frame = JSON.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": .object(params)])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled, let self else { return }
                    self.deadlines[id] = nil
                    self.pending.removeValue(forKey: id)?.resume(throwing: ClientError.timeout(method))
                }
                Task { [weak self] in
                    do { try await socket.send(.string(frame.text)) }
                    catch { self?.finish(id, result: .failure(error)) }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(id, result: .failure(CancellationError())) } }
    }
    private func finish(_ id: Int, result: Result<JSON, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    public func respond(_ id: JSON, result: JSON) async throws {
        guard let socket, ready else { throw ClientError.disconnected }
        try await socket.send(.string(JSON.object(["jsonrpc": "2.0", "id": id, "result": result]).text))
    }
    private func receive(_ frame: JSON) throws {
        let method = frame["method"].string
        if method == "event" {
            let p = frame["params"]
            if p["type"].string == "gateway.ready" { ready = true; sessionAuthority = p["payload"]["session_authority"].bool }
            onEvent?(GatewayEvent(type: p["type"].string, sessionID: p["session_id"].string, payload: p["payload"], sequence: p["seq"].number.map(Int.init)))
        } else if !method.isEmpty, !frame["id"].isNull {
            let id = frame["id"]
            if ["approval", "clarify", "sudo", "secret", "vault.unlock", "vault.store"].contains(method) {
                onRequest?(PendingCard(id: id.string.isEmpty ? id.text : id.string, method: method, params: frame["params"], requestID: id))
            } else if let socket {
                let error = JSON.object(["jsonrpc": "2.0", "id": id, "error": .object(["code": -32601, "message": "此客户端暂不支持该界面请求"])]).text
                Task { try? await socket.send(.string(error)) }
            }
        } else if let id = frame["id"].number {
            if !frame["error"].isNull { finish(Int(id), result: .failure(ClientError.rpc(Int(frame["error"]["code"].number ?? -1), frame["error"]["message"].string))) }
            else { finish(Int(id), result: .success(frame["result"])) }
        }
    }
}
