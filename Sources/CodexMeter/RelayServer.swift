import CryptoKit
import Foundation
import Network

enum CodexRelayError: LocalizedError {
    case invalidRequest
    case missingWebSocketKey
    case upstreamFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "本地转发器收到无效请求"
        case .missingWebSocketKey:
            return "WebSocket 请求缺少握手信息"
        case .upstreamFailure(let message):
            return "连接 OpenAI 上游失败：\(message)"
        }
    }
}

final class CodexRelayServer: @unchecked Sendable {
    static let port: UInt16 = 43187

    private let queue = DispatchQueue(label: "io.github.isaacsu95.CodexQuotaBar.relay")
    private let store: RelayObservationStore
    private var listener: NWListener?
    private var sessions: [UUID: RelayClientSession] = [:]
    private var startCompletion: ((Result<Void, Error>) -> Void)?

    private(set) var isRunning = false
    var stateChanged: (() -> Void)?

    init(store: RelayObservationStore) {
        self.store = store
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            if self.isRunning {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let port = NWEndpoint.Port(rawValue: Self.port)!
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                self.startCompletion = completion
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                listener.start(queue: self.queue)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            sessions.values.forEach { $0.stop() }
            sessions.removeAll()
            setRunning(false)
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let session = RelayClientSession(connection: connection, store: store, queue: queue) { [weak self] in
            self?.queue.async {
                self?.sessions.removeValue(forKey: id)
            }
        }
        sessions[id] = session
        session.start()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            setRunning(true)
            finishStart(.success(()))
        case .failed(let error):
            setRunning(false)
            finishStart(.failure(error))
            listener?.cancel()
            listener = nil
        case .cancelled:
            setRunning(false)
        default:
            break
        }
    }

    private func finishStart(_ result: Result<Void, Error>) {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        DispatchQueue.main.async { completion(result) }
    }

    private func setRunning(_ running: Bool) {
        guard isRunning != running else { return }
        isRunning = running
        DispatchQueue.main.async { [weak self] in
            self?.stateChanged?()
        }
    }
}

private final class RelayClientSession: @unchecked Sendable {
    private static let upstreamBase = "https://chatgpt.com/backend-api/codex"
    private static let maxHeaderBytes = 64 * 1024

    private let connection: NWConnection
    private let store: RelayObservationStore
    private let queue: DispatchQueue
    private let onClose: () -> Void
    private var requestBuffer = Data()
    private var webSocketDecoder = WebSocketFrameDecoder()
    private var fragmentedOpcode: UInt8?
    private var fragmentedPayload = Data()
    private var upstreamSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var requestHead: HTTPRequestHead?
    private var isClosed = false
    private var webSocketOpened = false

    private var requestedModel = ""
    private var requestedEffort: String?
    private var responseModel: String?
    private var serverModel: String?

    init(
        connection: NWConnection,
        store: RelayObservationStore,
        queue: DispatchQueue,
        onClose: @escaping () -> Void
    ) {
        self.connection = connection
        self.store = store
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequestHead()
    }

    func stop() {
        finish()
    }

    private func receiveRequestHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.requestBuffer.append(data) }
            if self.requestBuffer.count > Self.maxHeaderBytes {
                self.sendHTTPError(status: 431, reason: "Request Header Fields Too Large")
                return
            }
            if let headerRange = self.requestBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = self.requestBuffer[..<headerRange.upperBound]
                let remainder = Data(self.requestBuffer[headerRange.upperBound...])
                guard let head = HTTPRequestHead(data: Data(headerData)) else {
                    self.sendHTTPError(status: 400, reason: "Bad Request")
                    return
                }
                self.requestHead = head
                if head.isWebSocket {
                    self.openWebSocket(head: head)
                } else {
                    self.receiveHTTPBody(head: head, current: remainder)
                }
                return
            }
            if complete || error != nil {
                self.finish()
                return
            }
            self.receiveRequestHead()
        }
    }

    private func receiveHTTPBody(head: HTTPRequestHead, current: Data) {
        let expected = Int(head.header("content-length") ?? "0") ?? 0
        guard current.count < expected else {
            forwardHTTP(head: head, body: Data(current.prefix(expected)))
            return
        }
        var body = current
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(64 * 1024, expected - body.count)) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { body.append(data) }
            if body.count >= expected {
                self.forwardHTTP(head: head, body: Data(body.prefix(expected)))
            } else if complete || error != nil {
                self.finish()
            } else {
                self.receiveHTTPBody(head: head, current: body)
            }
        }
    }

    private func forwardHTTP(head: HTTPRequestHead, body: Data) {
        guard let url = upstreamURL(for: head.target, scheme: "https") else {
            sendHTTPError(status: 400, reason: "Bad Request")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = head.method
        request.httpBody = body.isEmpty ? nil : body
        copyUpstreamHeaders(from: head, to: &request)

        let configuration = Self.upstreamSessionConfiguration()
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration)
        upstreamSession = session
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard let response = response as? HTTPURLResponse, error == nil else {
                    self.sendHTTPError(status: 502, reason: "Bad Gateway")
                    return
                }
                self.sendHTTPResponse(response, body: data ?? Data())
            }
        }.resume()
    }

    private func openWebSocket(head: HTTPRequestHead) {
        guard let key = head.header("sec-websocket-key"),
              let url = upstreamURL(for: head.target, scheme: "wss") else {
            sendHTTPError(status: 400, reason: "Bad Request")
            return
        }
        var request = URLRequest(url: url)
        copyUpstreamHeaders(from: head, to: &request)

        let delegate = UpstreamWebSocketDelegate(owner: self, localKey: key)
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: Self.upstreamSessionConfiguration(), delegate: delegate, delegateQueue: delegateQueue)
        upstreamSession = session
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
    }

    fileprivate func upstreamDidOpen(localKey: String, response: HTTPURLResponse?) {
        queue.async {
            self.webSocketOpened = true
            if let headers = response?.allHeaderFields {
                self.serverModel = Self.modelHeader(in: headers) ?? self.serverModel
            }
            let accept = Self.webSocketAccept(for: localKey)
            var responseHead = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n"
            let excluded = Set(["connection", "upgrade", "sec-websocket-accept", "sec-websocket-extensions", "content-length", "transfer-encoding"])
            if let headers = response?.allHeaderFields {
                for (rawName, rawValue) in headers {
                    let name = String(describing: rawName)
                    guard !excluded.contains(name.lowercased()) else { continue }
                    responseHead += "\(name): \(rawValue)\r\n"
                }
            }
            responseHead += "\r\n"
            self.send(Data(responseHead.utf8)) { [weak self] in
                self?.receiveClientFrames()
                self?.receiveUpstreamMessage()
            }
        }
    }

    fileprivate func upstreamDidFail(_ error: Error?) {
        queue.async {
            guard !self.isClosed else { return }
            if self.webSocketOpened {
                self.send(WebSocketFrameEncoder.encode(opcode: 0x8, payload: Data())) { [weak self] in
                    self?.finish()
                }
            } else if self.requestHead?.isWebSocket == true {
                self.sendHTTPError(status: 502, reason: "Bad Gateway")
            } else {
                self.finish()
            }
        }
    }

    private func receiveClientFrames() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data {
                self.webSocketDecoder.append(data)
                do {
                    while let frame = try self.webSocketDecoder.nextFrame() {
                        self.handleClientFrame(frame)
                    }
                } catch {
                    self.finish()
                    return
                }
            }
            if complete || error != nil {
                self.finish()
            } else {
                self.receiveClientFrames()
            }
        }
    }

    private func handleClientFrame(_ frame: WebSocketFrame) {
        switch frame.opcode {
        case 0x0:
            guard fragmentedOpcode != nil else { return }
            fragmentedPayload.append(frame.payload)
            if frame.isFinal {
                sendUpstream(opcode: fragmentedOpcode!, payload: fragmentedPayload)
                fragmentedOpcode = nil
                fragmentedPayload.removeAll(keepingCapacity: true)
            }
        case 0x1, 0x2:
            if frame.isFinal {
                sendUpstream(opcode: frame.opcode, payload: frame.payload)
            } else {
                fragmentedOpcode = frame.opcode
                fragmentedPayload = frame.payload
            }
        case 0x8:
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
            finish()
        case 0x9:
            send(WebSocketFrameEncoder.encode(opcode: 0xA, payload: frame.payload))
        default:
            break
        }
    }

    private func sendUpstream(opcode: UInt8, payload: Data) {
        guard let task = webSocketTask else { return }
        if opcode == 0x1, let text = String(data: payload, encoding: .utf8) {
            inspectClientJSON(text)
            task.send(.string(text)) { [weak self] error in
                if let error { self?.upstreamDidFail(error) }
            }
        } else {
            task.send(.data(payload)) { [weak self] error in
                if let error { self?.upstreamDidFail(error) }
            }
        }
    }

    private func receiveUpstreamMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(.string(let text)):
                    self.inspectUpstreamJSON(text)
                    self.send(WebSocketFrameEncoder.encode(opcode: 0x1, payload: Data(text.utf8))) {
                        self.receiveUpstreamMessage()
                    }
                case .success(.data(let data)):
                    if let text = String(data: data, encoding: .utf8) {
                        self.inspectUpstreamJSON(text)
                    }
                    self.send(WebSocketFrameEncoder.encode(opcode: 0x2, payload: data)) {
                        self.receiveUpstreamMessage()
                    }
                case .failure:
                    self.finish()
                @unknown default:
                    self.finish()
                }
            }
        }
    }

    private func inspectClientJSON(_ text: String) {
        guard let object = jsonObject(text), object["type"] as? String == "response.create" else { return }
        requestedModel = object["model"] as? String ?? ""
        if let reasoning = object["reasoning"] as? [String: Any] {
            requestedEffort = reasoning["effort"] as? String
        }
        responseModel = nil
        serverModel = nil
    }

    private func inspectUpstreamJSON(_ text: String) {
        guard let object = jsonObject(text), let type = object["type"] as? String else { return }
        if let response = object["response"] as? [String: Any] {
            responseModel = response["model"] as? String ?? responseModel
            serverModel = Self.modelHeader(in: response["headers"]) ?? serverModel
        }
        serverModel = Self.modelHeader(in: object["headers"]) ?? serverModel

        if type == "model/rerouted" || type == "model.rerouted" {
            serverModel = object["toModel"] as? String ?? object["to_model"] as? String ?? serverModel
        }
        guard type == "response.completed", !requestedModel.isEmpty else { return }
        store.append(RelayObservation(
            observedAt: Date(),
            requestedModel: requestedModel,
            responseModel: responseModel,
            serverModel: serverModel,
            effort: requestedEffort
        ))
    }

    private func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func modelHeader(in value: Any?) -> String? {
        guard let headers = value as? [AnyHashable: Any] else { return nil }
        for (rawKey, value) in headers {
            let key = String(describing: rawKey).lowercased()
            if key == "openai-model" || key == "x-openai-model" {
                return value as? String
            }
        }
        return nil
    }

    private static func upstreamSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    private func copyUpstreamHeaders(from head: HTTPRequestHead, to request: inout URLRequest) {
        let excluded = Set([
            "host", "connection", "upgrade", "content-length", "sec-websocket-key",
            "sec-websocket-version", "sec-websocket-extensions"
        ])
        for (name, value) in head.headers where !excluded.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func upstreamURL(for target: String, scheme: String) -> URL? {
        let path: String
        if target.hasPrefix("/backend-api/codex/") {
            path = target
        } else {
            path = "/backend-api/codex/" + target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return URL(string: "\(scheme)://chatgpt.com\(path)")
    }

    private func sendHTTPResponse(_ response: HTTPURLResponse, body: Data) {
        var head = "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))\r\n"
        for (rawName, rawValue) in response.allHeaderFields {
            let name = String(describing: rawName)
            if ["content-length", "transfer-encoding", "connection"].contains(name.lowercased()) { continue }
            head += "\(name): \(rawValue)\r\n"
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var output = Data(head.utf8)
        output.append(body)
        send(output) { [weak self] in self?.finish() }
    }

    private func sendHTTPError(status: Int, reason: String) {
        let body = Data("local relay error".utf8)
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var output = Data(response.utf8)
        output.append(body)
        send(output) { [weak self] in self?.finish() }
    }

    private func send(_ data: Data, completion: (() -> Void)? = nil) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.finish()
            } else {
                completion?()
            }
        })
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        upstreamSession?.invalidateAndCancel()
        connection.cancel()
        onClose()
    }

    private static func webSocketAccept(for key: String) -> String {
        let source = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        return Data(Insecure.SHA1.hash(data: source)).base64EncodedString()
    }
}

private final class UpstreamWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private weak var owner: RelayClientSession?
    private let localKey: String

    init(owner: RelayClientSession, localKey: String) {
        self.owner = owner
        self.localKey = localKey
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        owner?.upstreamDidOpen(localKey: localKey, response: webSocketTask.response as? HTTPURLResponse)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        owner?.upstreamDidFail(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { owner?.upstreamDidFail(error) }
    }
}

private struct HTTPRequestHead {
    let method: String
    let target: String
    let headers: [(String, String)]

    init?(data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count == 3 else { return nil }
        method = requestLine[0]
        target = requestLine[1]
        headers = lines.dropFirst().compactMap { line in
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return (name, value)
        }
    }

    var isWebSocket: Bool {
        header("upgrade")?.lowercased() == "websocket"
    }

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
}

private struct WebSocketFrame {
    let isFinal: Bool
    let opcode: UInt8
    let payload: Data
}

private struct WebSocketFrameDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func nextFrame() throws -> WebSocketFrame? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.startIndex + 1]
        let isFinal = first & 0x80 != 0
        let opcode = first & 0x0F
        let masked = second & 0x80 != 0
        var payloadLength = UInt64(second & 0x7F)
        var cursor = 2

        if payloadLength == 126 {
            guard buffer.count >= cursor + 2 else { return nil }
            payloadLength = UInt64(buffer[cursor]) << 8 | UInt64(buffer[cursor + 1])
            cursor += 2
        } else if payloadLength == 127 {
            guard buffer.count >= cursor + 8 else { return nil }
            payloadLength = 0
            for byte in buffer[cursor..<(cursor + 8)] {
                payloadLength = payloadLength << 8 | UInt64(byte)
            }
            cursor += 8
        }
        guard payloadLength <= 32 * 1024 * 1024 else { throw CodexRelayError.invalidRequest }

        var mask: [UInt8] = []
        if masked {
            guard buffer.count >= cursor + 4 else { return nil }
            mask = Array(buffer[cursor..<(cursor + 4)])
            cursor += 4
        }
        guard buffer.count >= cursor + Int(payloadLength) else { return nil }

        var payload = Data(buffer[cursor..<(cursor + Int(payloadLength))])
        if masked {
            let count = payload.count
            payload.withUnsafeMutableBytes { raw in
                guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for index in 0..<count {
                    bytes[index] ^= mask[index % 4]
                }
            }
        }
        buffer.removeSubrange(0..<(cursor + Int(payloadLength)))
        return WebSocketFrame(isFinal: isFinal, opcode: opcode, payload: payload)
    }
}

private enum WebSocketFrameEncoder {
    static func encode(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            var length = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        return frame
    }
}
