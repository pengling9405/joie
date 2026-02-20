import CryptoKit
import Foundation

private enum GatewayProtocol {
    static let version = 3
}

private enum GatewayLocalDefaults {
    static let url = "ws://127.0.0.1:18789"
    static let sessionKey = "main"
    static let token = "45bb7977c567e0b9403b89416fa3eeeeb4738efe9d48fc05"
}

private enum GatewayStatePaths {
    static func stateDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["OPENCLAW_STATE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }

        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("OpenClaw", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("openclaw", isDirectory: true)
    }

    static func identityDirectory() -> URL {
        stateDirectory().appendingPathComponent("identity", isDirectory: true)
    }
}

struct GatewayHostConfig {
    let url: URL
    let token: String?
    let password: String?
    let sessionKey: String

    static func load() -> GatewayHostConfig {
        let env = ProcessInfo.processInfo.environment
        let config = OpenClawConfigSnapshot.load()

        let sessionKey = firstNonEmpty([
            env["JOIE_GATEWAY_SESSION_KEY"],
            GatewayLocalDefaults.sessionKey,
        ]) ?? "main"

        let token = firstNonEmpty([
            env["JOIE_GATEWAY_TOKEN"],
            env["OPENCLAW_GATEWAY_TOKEN"],
            config.gatewayAuthToken,
            GatewayLocalDefaults.token,
        ])
        let password = firstNonEmpty([
            env["JOIE_GATEWAY_PASSWORD"],
            env["OPENCLAW_GATEWAY_PASSWORD"],
            config.gatewayAuthPassword,
        ])

        let url: URL
        if let rawURL = firstNonEmpty([env["JOIE_GATEWAY_URL"]]),
           let parsed = URL(string: rawURL)
        {
            url = parsed
        } else {
            let scheme: String
            if let tlsEnv = firstNonEmpty([env["JOIE_GATEWAY_TLS"], env["OPENCLAW_GATEWAY_TLS"]]) {
                let normalized = tlsEnv.lowercased()
                scheme = (normalized == "1" || normalized == "true") ? "wss" : "ws"
            } else if config.gatewayTLSEnabled == true {
                scheme = "wss"
            } else {
                scheme = "ws"
            }

            let host = firstNonEmpty([env["JOIE_GATEWAY_HOST"]]) ?? "127.0.0.1"
            let port = firstInt([
                env["JOIE_GATEWAY_PORT"],
                env["OPENCLAW_GATEWAY_PORT"],
                config.gatewayPort.map(String.init),
            ]) ?? 18789
            url = URL(string: "\(scheme)://\(host):\(port)") ?? URL(string: "ws://127.0.0.1:18789")!
        }

        return GatewayHostConfig(url: url, token: token, password: password, sessionKey: sessionKey)
    }
}

private struct OpenClawConfigSnapshot {
    let gatewayPort: Int?
    let gatewayAuthToken: String?
    let gatewayAuthPassword: String?
    let gatewayTLSEnabled: Bool?

    static func load() -> OpenClawConfigSnapshot {
        let env = ProcessInfo.processInfo.environment
        let explicitPath = env["OPENCLAW_CONFIG_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        var candidates: [URL] = []
        if let explicitPath, !explicitPath.isEmpty {
            candidates.append(URL(fileURLWithPath: explicitPath))
        }
        candidates.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".openclaw", isDirectory: true)
                .appendingPathComponent("config.json", isDirectory: false)
        )

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            let gateway = json["gateway"] as? [String: Any]
            let auth = gateway?["auth"] as? [String: Any]
            let tls = gateway?["tls"] as? [String: Any]

            return OpenClawConfigSnapshot(
                gatewayPort: gateway?["port"] as? Int,
                gatewayAuthToken: (auth?["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                gatewayAuthPassword: (auth?["password"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                gatewayTLSEnabled: tls?["enabled"] as? Bool
            )
        }

        return OpenClawConfigSnapshot(
            gatewayPort: nil,
            gatewayAuthToken: nil,
            gatewayAuthPassword: nil,
            gatewayTLSEnabled: nil
        )
    }
}

private func firstNonEmpty(_ candidates: [String?]) -> String? {
    for value in candidates {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
    }
    return nil
}

private func firstInt(_ candidates: [String?]) -> Int? {
    for value in candidates {
        guard let value else { continue }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Int(trimmed), parsed > 0 {
            return parsed
        }
    }
    return nil
}

private struct DeviceIdentity: Codable {
    let deviceId: String
    let publicKey: String
    let privateKey: String
    let createdAtMs: Int
}

private enum DeviceIdentityStore {
    private static let fileName = "device.json"

    static func loadOrCreate() -> DeviceIdentity {
        let url = fileURL()
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(DeviceIdentity.self, from: data),
           !decoded.deviceId.isEmpty,
           !decoded.publicKey.isEmpty,
           !decoded.privateKey.isEmpty
        {
            return decoded
        }

        let generated = generate()
        save(generated)
        return generated
    }

    static func signPayload(_ payload: String, identity: DeviceIdentity) -> String? {
        guard let rawPrivate = Data(base64Encoded: identity.privateKey) else { return nil }
        do {
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivate)
            let signature = try privateKey.signature(for: Data(payload.utf8))
            return base64URLEncode(signature)
        } catch {
            return nil
        }
    }

    static func publicKeyBase64URL(_ identity: DeviceIdentity) -> String? {
        guard let rawPublic = Data(base64Encoded: identity.publicKey) else { return nil }
        return base64URLEncode(rawPublic)
    }

    private static func generate() -> DeviceIdentity {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let privateKeyData = privateKey.rawRepresentation
        let deviceID = SHA256.hash(data: publicKeyData).map { String(format: "%02x", $0) }.joined()
        return DeviceIdentity(
            deviceId: deviceID,
            publicKey: publicKeyData.base64EncodedString(),
            privateKey: privateKeyData.base64EncodedString(),
            createdAtMs: Int(Date().timeIntervalSince1970 * 1000)
        )
    }

    private static func fileURL() -> URL {
        GatewayStatePaths.identityDirectory().appendingPathComponent(fileName, isDirectory: false)
    }

    private static func save(_ identity: DeviceIdentity) {
        let url = fileURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(identity)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // best-effort
        }
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct DeviceAuthEntry: Codable {
    let token: String
    let role: String
    let scopes: [String]
    let updatedAtMs: Int
}

private struct DeviceAuthStoreFile: Codable {
    let version: Int
    let deviceId: String
    var tokens: [String: DeviceAuthEntry]
}

private enum DeviceAuthStore {
    private static let fileName = "device-auth.json"

    static func loadToken(deviceId: String, role: String) -> DeviceAuthEntry? {
        guard let store = readStore(), store.deviceId == deviceId else { return nil }
        let normalizedRole = normalizeRole(role)
        return store.tokens[normalizedRole]
    }

    static func storeToken(
        deviceId: String,
        role: String,
        token: String,
        scopes: [String]
    ) {
        var store = readStore()
        if store?.deviceId != deviceId {
            store = DeviceAuthStoreFile(version: 1, deviceId: deviceId, tokens: [:])
        }

        let normalizedRole = normalizeRole(role)
        let normalizedScopes = normalizeScopes(scopes)
        let entry = DeviceAuthEntry(
            token: token,
            role: normalizedRole,
            scopes: normalizedScopes,
            updatedAtMs: Int(Date().timeIntervalSince1970 * 1000)
        )

        if store == nil {
            store = DeviceAuthStoreFile(version: 1, deviceId: deviceId, tokens: [:])
        }
        store?.tokens[normalizedRole] = entry
        if let store {
            writeStore(store)
        }
    }

    static func clearToken(deviceId: String, role: String) {
        guard var store = readStore(), store.deviceId == deviceId else { return }
        let normalizedRole = normalizeRole(role)
        guard store.tokens[normalizedRole] != nil else { return }
        store.tokens.removeValue(forKey: normalizedRole)
        writeStore(store)
    }

    private static func normalizeRole(_ role: String) -> String {
        role.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeScopes(_ scopes: [String]) -> [String] {
        let normalized = scopes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(normalized)).sorted()
    }

    private static func fileURL() -> URL {
        GatewayStatePaths.identityDirectory().appendingPathComponent(fileName, isDirectory: false)
    }

    private static func readStore() -> DeviceAuthStoreFile? {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(DeviceAuthStoreFile.self, from: data),
              decoded.version == 1
        else {
            return nil
        }
        return decoded
    }

    private static func writeStore(_ store: DeviceAuthStoreFile) {
        let url = fileURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(store)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // best-effort
        }
    }
}

enum GatewayPush {
    case connected(authSource: String)
    case disconnected(reason: String)
    case event(name: String, payload: Data?)
}

struct GatewayChatSendResult {
    let runID: String
}

enum GatewayClientError: LocalizedError {
    case notConnected
    case invalidURL
    case connectFailed(String)
    case invalidResponse(String)
    case requestFailed(method: String, message: String, code: String?)
    case requestTimedOut(method: String, timeoutMs: Int)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Gateway 未连接"
        case .invalidURL:
            return "Gateway URL 无效"
        case let .connectFailed(message):
            return "Gateway 连接失败：\(message)"
        case let .invalidResponse(message):
            return "Gateway 响应无效：\(message)"
        case let .requestFailed(method, message, code):
            if let code, !code.isEmpty {
                return "\(method) 失败(\(code))：\(message)"
            }
            return "\(method) 失败：\(message)"
        case let .requestTimedOut(method, timeoutMs):
            return "\(method) 超时（\(timeoutMs)ms）"
        }
    }
}

private enum GatewayAuthSource: String {
    case deviceToken = "device-token"
    case sharedToken = "shared-token"
    case password = "password"
    case none = "none"
}

actor GatewayClient {
    private let config: GatewayHostConfig
    nonisolated let configuredSessionKey: String
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    private var isConnected = false
    private var isConnecting = false
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []

    private var pending: [String: CheckedContinuation<(ok: Bool, payload: Data?, code: String?, message: String?), Error>] = [:]
    private var subscribers: [UUID: AsyncStream<GatewayPush>.Continuation] = [:]
    private var currentAuthSource: GatewayAuthSource = .none

    private let connectTimeoutSeconds: TimeInterval = 12
    private let challengeTimeoutSeconds: TimeInterval = 6
    private let defaultRequestTimeoutMs = 30_000

    init(config: GatewayHostConfig = .load()) {
        self.config = config
        self.configuredSessionKey = config.sessionKey
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    func subscribe(bufferingNewest: Int = 100) -> AsyncStream<GatewayPush> {
        let id = UUID()
        let client = self
        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferingNewest)) { continuation in
            self.subscribers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await client.removeSubscriber(id) }
            }
        }
    }

    func shutdown() async {
        isConnected = false
        isConnecting = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failAllPending(with: GatewayClientError.notConnected)
    }

    func chatSend(message: String, idempotencyKey: String, timeoutMs: Int = 30_000) async throws -> GatewayChatSendResult {
        let params: [String: Any] = [
            "sessionKey": config.sessionKey,
            "message": message,
            "thinking": "default",
            "idempotencyKey": idempotencyKey,
            "timeoutMs": timeoutMs,
        ]
        let data = try await request(method: "chat.send", params: params, timeoutMs: timeoutMs)
        guard let object = try decodeJSONObject(data),
              let runID = (object["runId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !runID.isEmpty
        else {
            return GatewayChatSendResult(runID: idempotencyKey)
        }
        return GatewayChatSendResult(runID: runID)
    }

    func chatAbort(runID: String) async {
        let params: [String: Any] = [
            "sessionKey": config.sessionKey,
            "runId": runID,
        ]
        _ = try? await request(method: "chat.abort", params: params, timeoutMs: 8_000)
    }

    private func request(method: String, params: [String: Any]?, timeoutMs: Int?) async throws -> Data {
        try await connectIfNeeded()
        guard let task else {
            throw GatewayClientError.notConnected
        }

        let requestID = UUID().uuidString
        var frame: [String: Any] = [
            "type": "req",
            "id": requestID,
            "method": method,
        ]
        if let params {
            frame["params"] = params
        }

        let frameData = try encodeJSONObject(frame)
        let effectiveTimeout = timeoutMs ?? defaultRequestTimeoutMs

        let response = try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation

            Task { [weak self] in
                guard let self else { return }
                do {
                    try await task.send(.data(frameData))
                } catch {
                    await self.failPending(id: requestID, with: error)
                }
            }

            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout) * 1_000_000)
                await self.timeoutPendingRequest(id: requestID, method: method, timeoutMs: effectiveTimeout)
            }
        }

        if response.ok {
            return response.payload ?? Data()
        }
        let message = response.message ?? "unknown error"
        throw GatewayClientError.requestFailed(method: method, message: message, code: response.code)
    }

    private func connectIfNeeded() async throws {
        if isConnected, task?.state == .running { return }
        if isConnecting {
            try await withCheckedThrowingContinuation { continuation in
                connectWaiters.append(continuation)
            }
            return
        }
        isConnecting = true
        defer { isConnecting = false }

        do {
            try await establishConnection(allowTokenFallback: true)
            isConnected = true
            resumeConnectWaiters(with: nil)
            broadcast(.connected(authSource: currentAuthSource.rawValue))
            startListenLoop()
        } catch {
            isConnected = false
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            resumeConnectWaiters(with: error)
            throw error
        }
    }

    private func establishConnection(allowTokenFallback: Bool) async throws {
        guard config.url.scheme?.hasPrefix("ws") == true else {
            throw GatewayClientError.invalidURL
        }

        task?.cancel(with: .goingAway, reason: nil)
        let socket = session.webSocketTask(with: config.url)
        socket.maximumMessageSize = 16 * 1024 * 1024
        socket.resume()
        task = socket

        do {
            try await withTimeout(seconds: connectTimeoutSeconds) {
                try await self.performHandshake(preferStoredDeviceToken: true)
            }
        } catch {
            let shouldRetryWithoutStoredDeviceToken =
                allowTokenFallback &&
                isDeviceTokenMismatch(error) &&
                config.token?.isEmpty == false

            if shouldRetryWithoutStoredDeviceToken {
                let identity = DeviceIdentityStore.loadOrCreate()
                DeviceAuthStore.clearToken(deviceId: identity.deviceId, role: "operator")
                socket.cancel(with: .goingAway, reason: nil)

                let retrySocket = session.webSocketTask(with: config.url)
                retrySocket.maximumMessageSize = 16 * 1024 * 1024
                retrySocket.resume()
                task = retrySocket
                try await withTimeout(seconds: connectTimeoutSeconds) {
                    try await self.performHandshake(preferStoredDeviceToken: false)
                }
                return
            }

            throw GatewayClientError.connectFailed(error.localizedDescription)
        }
    }

    private func performHandshake(preferStoredDeviceToken: Bool) async throws {
        guard let socket = task else {
            throw GatewayClientError.notConnected
        }

        let nonce = try await waitForConnectChallenge(timeoutSeconds: challengeTimeoutSeconds)
        let role = "operator"
        let scopes = ["operator.read", "operator.write"]
        let identity = DeviceIdentityStore.loadOrCreate()

        let storedToken = preferStoredDeviceToken
            ? DeviceAuthStore.loadToken(deviceId: identity.deviceId, role: role)?.token
            : nil
        let authToken = storedToken ?? config.token
        if storedToken != nil {
            currentAuthSource = .deviceToken
        } else if authToken != nil {
            currentAuthSource = .sharedToken
        } else if config.password != nil {
            currentAuthSource = .password
        } else {
            currentAuthSource = .none
        }

        let signedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        let payloadToSign = buildDeviceAuthPayload(
            deviceId: identity.deviceId,
            clientID: "openclaw-macos",
            clientMode: "ui",
            role: role,
            scopes: scopes,
            signedAtMs: signedAtMs,
            token: authToken,
            nonce: nonce
        )

        guard let signature = DeviceIdentityStore.signPayload(payloadToSign, identity: identity),
              let publicKey = DeviceIdentityStore.publicKeyBase64URL(identity)
        else {
            throw GatewayClientError.connectFailed("device identity signature failed")
        }

        var params: [String: Any] = [
            "minProtocol": GatewayProtocol.version,
            "maxProtocol": GatewayProtocol.version,
            "client": [
                "id": "openclaw-macos",
                "displayName": "joie",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
                "platform": "macos",
                "mode": "ui",
                "instanceId": ProcessInfo.processInfo.globallyUniqueString,
            ],
            "role": role,
            "scopes": scopes,
            "caps": [],
            "locale": Locale.preferredLanguages.first ?? Locale.current.identifier,
            "userAgent": ProcessInfo.processInfo.operatingSystemVersionString,
            "device": [
                "id": identity.deviceId,
                "publicKey": publicKey,
                "signature": signature,
                "signedAt": signedAtMs,
            ],
        ]

        if let nonce {
            var device = params["device"] as? [String: Any] ?? [:]
            device["nonce"] = nonce
            params["device"] = device
        }

        if let authToken {
            params["auth"] = ["token": authToken]
        } else if let password = config.password {
            params["auth"] = ["password": password]
        }

        let requestID = UUID().uuidString
        let frame: [String: Any] = [
            "type": "req",
            "id": requestID,
            "method": "connect",
            "params": params,
        ]

        let frameData = try encodeJSONObject(frame)
        try await socket.send(.data(frameData))

        let response = try await waitForConnectResponse(requestID: requestID)
        guard response.ok else {
            let message = response.message ?? "connect failed"
            throw GatewayClientError.requestFailed(method: "connect", message: message, code: response.code)
        }

        if let payload = response.payload,
           let payloadObject = try? decodeJSONObject(payload),
           let auth = payloadObject["auth"] as? [String: Any],
           let deviceToken = auth["deviceToken"] as? String
        {
            let authRole = (auth["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? role
            let authScopes = (auth["scopes"] as? [String]) ?? scopes
            DeviceAuthStore.storeToken(
                deviceId: identity.deviceId,
                role: authRole,
                token: deviceToken,
                scopes: authScopes
            )
        }
    }

    private func waitForConnectChallenge(timeoutSeconds: TimeInterval) async throws -> String? {
        guard let socket = task else { return nil }
        do {
            return try await withTimeout(seconds: timeoutSeconds) { [self] in
                while true {
                    let message = try await socket.receive()
                    guard let frame = try? await self.decodeFrame(message: message),
                          frame.type == "event",
                          frame.event == "connect.challenge"
                    else {
                        continue
                    }
                    if let payload = frame.payloadObject,
                       let nonce = payload["nonce"] as? String,
                       !nonce.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        return nonce
                    }
                    return nil
                }
            }
        } catch is TimeoutError {
            return nil
        }
    }

    private func waitForConnectResponse(requestID: String) async throws -> (ok: Bool, payload: Data?, code: String?, message: String?) {
        guard let socket = task else {
            throw GatewayClientError.notConnected
        }
        while true {
            let message = try await socket.receive()
            guard let frame = try? decodeFrame(message: message) else {
                throw GatewayClientError.invalidResponse("connect response is not valid json")
            }
            if frame.type != "res" {
                continue
            }
            if frame.id == requestID {
                return (frame.ok ?? false, frame.payloadData, frame.errorCode, frame.errorMessage)
            }
        }
    }

    private func startListenLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            Task {
                await self.handleListenResult(result)
            }
        }
    }

    private func handleListenResult(_ result: Result<URLSessionWebSocketTask.Message, Error>) async {
        switch result {
        case let .failure(error):
            await handleDisconnect(error.localizedDescription)
        case let .success(message):
            await handleIncomingMessage(message)
            if isConnected {
                startListenLoop()
            }
        }
    }

    private func handleIncomingMessage(_ message: URLSessionWebSocketTask.Message) async {
        guard let frame = try? decodeFrame(message: message) else {
            return
        }

        if frame.type == "res", let id = frame.id {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            continuation.resume(
                returning: (
                    ok: frame.ok ?? false,
                    payload: frame.payloadData,
                    code: frame.errorCode,
                    message: frame.errorMessage
                )
            )
            return
        }

        if frame.type == "event", let event = frame.event {
            if event == "connect.challenge" {
                return
            }
            broadcast(.event(name: event, payload: frame.payloadData))
        }
    }

    private func handleDisconnect(_ reason: String) async {
        isConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failAllPending(with: GatewayClientError.connectFailed(reason))
        broadcast(.disconnected(reason: reason))
    }

    private func timeoutPendingRequest(id: String, method: String, timeoutMs: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: GatewayClientError.requestTimedOut(method: method, timeoutMs: timeoutMs))
    }

    private func failPending(id: String, with error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        let current = pending
        pending.removeAll()
        for (_, continuation) in current {
            continuation.resume(throwing: error)
        }
    }

    private func resumeConnectWaiters(with error: Error?) {
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: ())
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func broadcast(_ push: GatewayPush) {
        for (_, continuation) in subscribers {
            continuation.yield(push)
        }
    }

    private func decodeFrame(message: URLSessionWebSocketTask.Message) throws -> GatewayFrame {
        let data: Data
        switch message {
        case let .data(raw):
            data = raw
        case let .string(text):
            guard let converted = text.data(using: .utf8) else {
                throw GatewayClientError.invalidResponse("invalid utf8 string frame")
            }
            data = converted
        @unknown default:
            throw GatewayClientError.invalidResponse("unknown websocket frame")
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayClientError.invalidResponse("frame is not a json object")
        }
        return GatewayFrame(object: object)
    }

    private func encodeJSONObject(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw GatewayClientError.invalidResponse("invalid json payload")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private func decodeJSONObject(_ data: Data) throws -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let nanos = UInt64(seconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanos)
                throw TimeoutError()
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func isDeviceTokenMismatch(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("device token mismatch")
    }

    private func buildDeviceAuthPayload(
        deviceId: String,
        clientID: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMs: Int,
        token: String?,
        nonce: String?
    ) -> String {
        let version = (nonce?.isEmpty == false) ? "v2" : "v1"
        var parts = [
            version,
            deviceId,
            clientID,
            clientMode,
            role,
            scopes.joined(separator: ","),
            String(signedAtMs),
            token ?? "",
        ]
        if version == "v2" {
            parts.append(nonce ?? "")
        }
        return parts.joined(separator: "|")
    }
}

private struct TimeoutError: Error {}

private struct GatewayFrame {
    let type: String
    let id: String?
    let event: String?
    let ok: Bool?
    let payloadData: Data?
    let payloadObject: [String: Any]?
    let errorCode: String?
    let errorMessage: String?

    init(object: [String: Any]) {
        type = (object["type"] as? String) ?? ""
        id = object["id"] as? String
        event = object["event"] as? String
        ok = object["ok"] as? Bool

        if let payload = object["payload"] {
            payloadData = GatewayFrame.encodeAnyJSON(payload)
            payloadObject = payload as? [String: Any]
        } else {
            payloadData = nil
            payloadObject = nil
        }

        if let error = object["error"] as? [String: Any] {
            errorCode = error["code"] as? String
            errorMessage = error["message"] as? String
        } else {
            errorCode = nil
            errorMessage = nil
        }
    }

    private static func encodeAnyJSON(_ value: Any) -> Data? {
        if let dict = value as? [String: Any], JSONSerialization.isValidJSONObject(dict) {
            return try? JSONSerialization.data(withJSONObject: dict, options: [])
        }
        if let array = value as? [Any], JSONSerialization.isValidJSONObject(array) {
            return try? JSONSerialization.data(withJSONObject: array, options: [])
        }
        return nil
    }
}
