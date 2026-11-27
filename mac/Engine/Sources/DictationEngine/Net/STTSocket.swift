import Foundation

enum STTEvent: Sendable, Equatable {
    case committed(item: String, previous: String?)
    case delta(item: String, text: String)
    case completed(item: String, transcript: String)
    case failed
    case error(code: String)
    case disconnected
}

/// The transcription socket as the turn pipeline sees it (fake in tests).
@MainActor
protocol TranscriptionSocket: AnyObject {
    var isReady: Bool { get }
    var onEvent: ((STTEvent) -> Void)? { get set }
    func connect() async throws
    func append(_ pcm: Data)
    func commit()
    func close()
    var connectedAt: Double { get }
    /// Speech hints the server issued for this user (dictionary + voice terms).
    var keywords: [String] { get }
    /// Personal replacement map issued with the session (applied to transcripts before rewrite).
    var replacements: [(String, String)] { get }
    /// The server's prompt for this session, and the prompt the session currently uses.
    var basePrompt: String { get }
    var prompt: String { get }
    var preferredPauseSeconds: Double? { get }
    var maximumIdleAge: Double { get }
    var maximumTurns: Int { get }
    /// Change the transcription prompt for the next audio (e.g. recent-dictation context).
    /// A rejected update never fails a dictation; the session keeps its previous prompt.
    func updatePrompt(_ prompt: String)
    func setTurnContext(id: String, app: String?)
}
extension TranscriptionSocket {
    func setTurnContext(id: String, app: String?) {}
    var preferredPauseSeconds: Double? { nil }
    var maximumIdleAge: Double { .infinity }
    var maximumTurns: Int { .max }
}

/// Realtime transcription through the bounded Sunday Voice relay. The grant is single-use and
/// contains no provider key. Legacy server and bounded-HTTP transports remain compatible.
@MainActor
final class RealtimeSTTSocket: TranscriptionSocket {
    private let mintSession: @Sendable () async throws -> STTSessionGrant
    private let makeWebSocket: (URLRequest) throws -> URLSessionWebSocketTask
    private var task: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var connecting: Task<Void, Error>?
    private var connectionGeneration: UInt64 = 0
    private(set) var isReady = false
    private(set) var connectedAt = 0.0
    private(set) var keywords: [String] = []
    private(set) var replacements: [(String, String)] = []
    private(set) var basePrompt = ""
    private(set) var prompt = ""
    private var grant: STTSessionGrant?
    private var bounded: BoundedSTTTransport?
    private let transcribePCM: @Sendable (Data, @escaping @Sendable (String) -> Void) async throws -> String
    var preferredPauseSeconds: Double? { bounded != nil || grant?.transport == "relay-v1" ? 6 : nil }
    var maximumIdleAge: Double { grant?.transport == "relay-v1" ? 50 : 600 }
    var maximumTurns: Int { grant?.transport == "relay-v1" ? 1 : .max }
    private var promptUpdates = 0
    var onEvent: ((STTEvent) -> Void)?
    init(server: ServerClient) {
        let session = URLSession(configuration: .ephemeral)
        mintSession = { try await server.mintSTTSession() }
        transcribePCM = { pcm, delta in try await server.transcribePCM(pcm, onDelta: delta) }
        makeWebSocket = { request in
            // Same-origin relays share the API session's network configuration. Never forward its
            // authentication/cookies to a legacy third-party provider URL.
            (request.url?.host == server.baseURL.host ? server.session : session).webSocketTask(with: request)
        }
    }

    /// Offline tests control the grant suspension and reject any attempt to create a live socket.
    init(mintSession: @escaping @Sendable () async throws -> STTSessionGrant,
         makeWebSocket: @escaping (URLRequest) throws -> URLSessionWebSocketTask,
         transcribePCM: @escaping @Sendable (Data) async throws -> String = { _ in throw FailureCode("unconfigured_transport") }) {
        self.mintSession = mintSession; self.makeWebSocket = makeWebSocket
        self.transcribePCM = { pcm, _ in try await transcribePCM(pcm) }
    }

    func setTurnContext(id: String, app: String?) {
        bounded?.context = .init(id: id, app: app)
        if grant?.transport == "relay-v1" {
            let suffix = prompt.hasPrefix(basePrompt) ? String(prompt.dropFirst(basePrompt.count)) : ""
            var value: [String: Any] = ["type": "sv.turn", "id": id,
                "context": String(decoding: suffix.utf16.prefix(400), as: UTF16.self)]
            if let app { value["app"] = app }
            send(value)
        }
    }

    func connect() async throws {
        if isReady { return }
        if let connecting { return try await connecting.value }
        close()
        let generation = connectionGeneration
        let job = Task { @MainActor in try await self.open(generation: generation) }
        connecting = job
        defer { if connectionGeneration == generation { connecting = nil } }
        do { try await job.value }
        catch {
            if connectionGeneration == generation { close() }
            throw error
        }
    }

    private func open(generation: UInt64) async throws {
        try Task.checkCancellation()
        guard connectionGeneration == generation else { throw CancellationError() }
        let begin = uptime()
        let grant = try await mintSession()
        try Task.checkCancellation()
        guard connectionGeneration == generation else { throw CancellationError() }
        if grant.transport == "bounded-pcm-v1" {
            let transport = BoundedSTTTransport(streaming: transcribePCM)
            transport.onEvent = { [weak self] event in
                guard let self, self.connectionGeneration == generation else { return }
                self.onEvent?(event)
            }
            bounded = transport; self.grant = grant
            basePrompt = grant.session.prompt; prompt = grant.session.prompt
            keywords = grant.session.keywords; replacements = (grant.replacements ?? []).map { ($0.from, $0.to) }
            isReady = true; connectedAt = uptime()
            return
        }
        guard grant.transport == nil || grant.transport == "relay-v1" else { throw FailureCode("unsupported_transport") }
        var request = URLRequest(url: grant.url)
        request.setValue("Bearer \(grant.client_secret)", forHTTPHeaderField: "Authorization")
        request.setValue(AppVersion.header, forHTTPHeaderField: AppVersion.headerName)
        let socket = try makeWebSocket(request)
        socket.maximumMessageSize = 1 << 23
        task = socket
        socket.resume()
        if grant.transport == nil {
            let update = Self.sessionUpdate(grant, prompt: grant.session.prompt)
            try await socket.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: update), as: UTF8.self)))
        }
        let configured = try await withDeadline(15) { () -> String? in
            while true {
                let message = try await socket.receive()
                guard case .string(let text) = message,
                      let event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                let type = event["type"] as? String
                if type == "error" { return ((event["error"] as? [String: Any])?["code"] as? String) ?? "unknown" }
                if type == "session.updated" { return nil }
            }
        }
        try Task.checkCancellation()
        guard connectionGeneration == generation else { throw CancellationError() }
        if let code = configured { socket.cancel(with: .goingAway, reason: nil); throw FailureCode("stt_rejected_\(code)") }
        isReady = true; connectedAt = uptime(); keywords = grant.session.keywords
        self.grant = grant; basePrompt = grant.session.prompt; prompt = grant.session.prompt
        replacements = (grant.replacements ?? []).map { ($0.from, $0.to) }
        Log.stt.info("stt_ready ms=\(ms(uptime() - begin), privacy: .public)")
        receiver = Task { @MainActor [weak self] in await self?.receiveLoop(socket) }
        pinger = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.task === socket else { return }
                socket.sendPing { error in if error != nil { Task { @MainActor in self.dropped(socket) } } }
            }
        }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard case .string(let text) = message,
                      let event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                switch type {
                case "input_audio_buffer.committed":
                    onEvent?(.committed(item: event["item_id"] as? String ?? "", previous: event["previous_item_id"] as? String))
                case "conversation.item.input_audio_transcription.delta":
                    onEvent?(.delta(item: event["item_id"] as? String ?? "", text: event["delta"] as? String ?? ""))
                case "conversation.item.input_audio_transcription.completed":
                    onEvent?(.completed(item: event["item_id"] as? String ?? "", transcript: event["transcript"] as? String ?? ""))
                case "conversation.item.input_audio_transcription.failed":
                    onEvent?(.failed)
                case "error":
                    let error = event["error"] as? [String: Any]
                    if let id = error?["event_id"] as? String, id.hasPrefix(Self.promptEventPrefix) {
                        // Our own context update was refused: keep dictating with the previous prompt.
                        Log.stt.error("stt_context_rejected code=\((error?["code"] as? String) ?? "unknown", privacy: .public)")
                        prompt = ""
                        continue
                    }
                    onEvent?(.error(code: (error?["code"] as? String) ?? "error"))
                default: break
                }
            } catch {
                dropped(socket); return
            }
        }
    }

    private func dropped(_ socket: URLSessionWebSocketTask) {
        guard task === socket, isReady else { return }
        isReady = false
        onEvent?(.disconnected)
    }

    private func send(_ object: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        // Sends complete in call order on one task, so audio stays ordered.
        task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self, weak task] error in
            guard error != nil else { return }
            Task { @MainActor in if let self, let task { self.dropped(task) } }
        }
    }

    static let promptEventPrefix = "sv_prompt_"

    static func sessionUpdate(_ grant: STTSessionGrant, prompt: String, eventID: String? = nil) -> [String: Any] {
        var update: [String: Any] = ["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": 24000],
            "transcription": ["model": grant.model, "languages": grant.session.languages, "delay": grant.session.delay,
                              "prompt": prompt, "keywords": grant.session.keywords],
            "turn_detection": NSNull()]]]]
        if let eventID { update["event_id"] = eventID }
        return update
    }

    func updatePrompt(_ prompt: String) {
        guard isReady, let grant, prompt != self.prompt else { return }
        // Guest hints are server-owned; never accept arbitrary provider session parameters.
        if bounded != nil || grant.transport == "relay-v1" { self.prompt = prompt; return }
        promptUpdates += 1
        // Sent before this turn's audio on the same ordered socket, so it applies to the whole utterance.
        send(Self.sessionUpdate(grant, prompt: prompt, eventID: "\(Self.promptEventPrefix)\(promptUpdates)"))
        self.prompt = prompt
    }

    func append(_ pcm: Data) {
        if let bounded { bounded.append(pcm) }
        else {
            var offset = 0
            while offset < pcm.count {
                let end = min(pcm.count, offset + 48000)
                send(["type": "input_audio_buffer.append", "audio": pcm.subdata(in: offset..<end).base64EncodedString()])
                offset = end
            }
        }
    }
    func commit() {
        if let bounded { bounded.commit() }
        else { send(["type": "input_audio_buffer.commit"]) }
    }

    func close() {
        connectionGeneration &+= 1
        bounded?.close(); bounded = nil
        connecting?.cancel(); connecting = nil
        receiver?.cancel(); pinger?.cancel(); receiver = nil; pinger = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        isReady = false
    }
}
