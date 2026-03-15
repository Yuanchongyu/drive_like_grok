//
//  LiveWebSocketNW.swift
//  drive_like_grok
//
//  用 Network 框架建 WebSocket，强制 IPv4，解决 URLSession 在部分网络下 "Socket is not connected"。
//

import Foundation
import Network

/// 基于 NWConnection 的 WebSocket（强制 IPv4），用于 Gemini Live API
final class LiveWebSocketNW: @unchecked Sendable {
    private let host: String
    private let pathWithQuery: String
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "live.ws.nw")
    private var receiveBuffer = Data()
    private var isUpgradeDone = false
    private var onOpen: (() -> Void)?
    private var onMessage: ((Data) -> Void)?
    private var onError: ((Error) -> Void)?
    private var onClose: (() -> Void)?
    private var connectionTimeoutWorkItem: DispatchWorkItem?

    init(host: String, pathWithQuery: String) {
        self.host = host
        self.pathWithQuery = pathWithQuery
    }

    func setCallbacks(onOpen: @escaping () -> Void, onMessage: @escaping (Data) -> Void, onError: @escaping (Error) -> Void, onClose: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onMessage = onMessage
        self.onError = onError
        self.onClose = onClose
    }

    /// - Parameter forceIPv4: 为 true 时强制只用 IPv4（部分网络下更稳）；REST 通但 Live 连不上时可传 false 试试。
    func connect(forceIPv4: Bool = true) {
        connectionTimeoutWorkItem?.cancel()
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 15
        let tlsOptions = NWProtocolTLS.Options()
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        if forceIPv4 {
            (params.defaultProtocolStack.internetProtocol as! NWProtocolIP.Options).version = .v4
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: 443, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            self?.handleState(state, conn: conn)
        }
        conn.start(queue: queue)

        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.connection === conn, !self.isUpgradeDone {
                self.connection?.cancel()
                self.connection = nil
                self.onError?(NSError(domain: "LiveWebSocketNW", code: -1, userInfo: [NSLocalizedDescriptionKey: "连接超时（约 15 秒未就绪）。REST 通但 Live 连不上时，可在设置中关闭「Live 强制 IPv4」后重试。"]))
            }
        }
        connectionTimeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private func cancelConnectionTimeout() {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
    }

    func disconnect() {
        cancelConnectionTimeout()
        connection?.cancel()
        connection = nil
        isUpgradeDone = false
        receiveBuffer.removeAll()
    }

    func send(text: String, completion: ((Error?) -> Void)? = nil) {
        guard isUpgradeDone, let conn = connection else {
            completion?(NSError(domain: "LiveWebSocketNW", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebSocket 未连接"]))
            return
        }
        let frame = encodeWebSocketFrame(opcode: 0x01, payload: Data(text.utf8))
        conn.send(content: frame, completion: .contentProcessed { [weak self] err in
            if let e = err { self?.onError?(e) }
            completion?(err)
        })
    }

    private func handleState(_ state: NWConnection.State, conn: NWConnection) {
        switch state {
        case .ready:
            cancelConnectionTimeout()
            sendUpgradeRequest(conn: conn)
        case .failed(let err):
            cancelConnectionTimeout()
            onError?(err)
        case .cancelled:
            cancelConnectionTimeout()
            onClose?()
        default:
            break
        }
    }

    private func sendUpgradeRequest(conn: NWConnection) {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let req = "GET \(pathWithQuery) HTTP/1.1\r\n" +
            "Host: \(host)\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(key)\r\n" +
            "Sec-WebSocket-Version: 13\r\n" +
            "\r\n"
        let data = Data(req.utf8)
        conn.send(content: data, completion: .contentProcessed { [weak self] err in
            if let e = err {
                self?.onError?(e)
            } else {
                self?.readUpgradeResponse(conn: conn)
            }
        })
    }

    private func readUpgradeResponse(conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            if let e = err {
                self.onError?(e)
                return
            }
            if let d = data { self.receiveBuffer.append(d) }
            if let idx = self.receiveBuffer.range(of: Data("\r\n\r\n".utf8))?.upperBound {
                let headerData = self.receiveBuffer.prefix(upTo: idx)
                let head = String(data: headerData, encoding: .utf8) ?? ""
                if head.contains("101") {
                    self.isUpgradeDone = true
                    self.receiveBuffer = Data(self.receiveBuffer.suffix(from: idx))
                    if !self.receiveBuffer.isEmpty { self.tryParseFrames(conn: conn) }
                    DispatchQueue.main.async { self.onOpen?() }
                } else {
                    self.onError?(NSError(domain: "LiveWebSocketNW", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upgrade failed: \(head.prefix(200))"]))
                }
                self.startReceiveLoop(conn: conn)
            } else if isComplete {
                self.onError?(NSError(domain: "LiveWebSocketNW", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection closed before upgrade"]))
            } else {
                self.readUpgradeResponse(conn: conn)
            }
        }
    }

    private func startReceiveLoop(conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            if let e = err {
                self.onError?(e)
                return
            }
            if let d = data { self.receiveBuffer.append(d) }
            self.tryParseFrames(conn: conn)
            if !isComplete, self.connection != nil {
                self.startReceiveLoop(conn: conn)
            }
        }
    }

    private func tryParseFrames(conn: NWConnection) {
        while receiveBuffer.count >= 2 {
            let b0 = receiveBuffer[0], b1 = receiveBuffer[1]
            let opcode = Int(b0 & 0x0f)
            let masked = (b1 & 0x80) != 0
            var payloadLen = Int(b1 & 0x7f)
            var headerLen = 2
            if payloadLen == 126 {
                if receiveBuffer.count < 4 { break }
                payloadLen = Int(receiveBuffer[2]) << 8 | Int(receiveBuffer[3])
                headerLen = 4
            } else if payloadLen == 127 {
                if receiveBuffer.count < 10 { break }
                payloadLen = (0..<8).reduce(0) { Int(receiveBuffer[2 + $1]) << (56 - $1 * 8) | $0 }
                headerLen = 10
            }
            let maskLen = masked ? 4 : 0
            if receiveBuffer.count < headerLen + maskLen + payloadLen { break }
            var payload = receiveBuffer.subdata(in: (headerLen + maskLen)..<(headerLen + maskLen + payloadLen))
            if masked {
                let mask = receiveBuffer.subdata(in: headerLen..<(headerLen + 4))
                for i in 0..<payload.count { payload[i] ^= mask[i % 4] }
            }
            receiveBuffer.removeFirst(headerLen + maskLen + payloadLen)
            if opcode == 0x01 || opcode == 0x02 {
                DispatchQueue.main.async { self.onMessage?(payload) }
            } else if opcode == 0x08 {
                self.connection?.cancel()
                self.connection = nil
                DispatchQueue.main.async { self.onClose?() }
                return
            }
        }
    }

    private func encodeWebSocketFrame(opcode: UInt8, payload: Data) -> Data {
        var header = Data()
        header.append(0x80 | opcode)
        let len = payload.count
        if len < 126 {
            header.append(0x80 | UInt8(len))
        } else if len < 65536 {
            header.append(0x80 | 126)
            header.append(UInt8(len >> 8))
            header.append(UInt8(len & 0xff))
        } else {
            header.append(0x80 | 127)
            for i in (0..<8).reversed() { header.append(UInt8((len >> (i * 8)) & 0xff)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        header.append(contentsOf: mask)
        var body = payload
        for i in 0..<body.count { body[i] ^= mask[i % 4] }
        header.append(body)
        return header
    }
}
