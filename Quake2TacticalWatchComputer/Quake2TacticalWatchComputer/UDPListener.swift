//
//  UDPListener.swift
//  Quake2TacticalWatchComputer
//
//  Holds the LAN UDP socket that receives the engine's newline-delimited JSON
//  feed (default port 27999). Each datagram is split on '\n' and decoded into a
//  WireMessage; complete messages are handed to `onMessage` on the main actor.
//

import Foundation
import Combine
import Network

@MainActor
final class UDPListener: ObservableObject {

    enum Status: Equatable {
        case idle
        case waiting(String)
        case listening(port: UInt16)
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "OFFLINE"
            case .waiting: return "WAITING…"
            case .listening(let p): return "LISTENING :\(p)"
            case .failed(let m): return "ERROR — \(m)"
            }
        }
    }

    /// Bonjour service type advertised on the LAN (see iOSApp-Info.plist).
    static let bonjourType = "_q2watch._udp"

    @Published private(set) var status: Status = .idle

    /// Invoked for every fully decoded message, on the main actor.
    var onMessage: ((WireMessage) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "watchlink.udp", qos: .userInitiated)
    /// Per-connection carry-over for the rare datagram that doesn't end on a
    /// newline boundary (engine sends one line per datagram, but be safe).
    private var buffers: [ObjectIdentifier: Data] = [:]

    func start(port: UInt16) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            status = .failed("bad port")
            return
        }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        do {
            let l = try NWListener(using: params, on: nwPort)
            listener = l

            // Advertise over Bonjour so the engine (and any listener) can find
            // this phone on the LAN without a hand-typed IP. Type must match the
            // NSBonjourServices entry in iOSApp-Info.plist.
            l.service = NWListener.Service(type: Self.bonjourType)

            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state, port: port) }
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.start(queue: queue)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        buffers.removeAll()
        restartScheduled = false       // don't let a pending retry fire for a stale port
        retryDelay = 1.5
        status = .idle
    }

    // MARK: - Internals

    private var restartScheduled = false
    private var retryDelay: Double = 1.5

    private func handleListenerState(_ state: NWListener.State, port: UInt16) {
        switch state {
        case .ready:
            status = .listening(port: port)
            retryDelay = 1.5                       // reset backoff on success
        case .waiting(let err):
            // NORMAL transient state — usually the Local Network permission
            // prompt is still pending or Wi-Fi is momentarily unavailable. The
            // framework advances this listener to .ready on its own once access
            // is granted, so we must NOT restart here (doing so cancels the very
            // listener that's about to succeed). Just reflect it and wait.
            status = .waiting(err.localizedDescription)
        case .failed(let err):
            status = .failed(err.localizedDescription)
            scheduleRestart(port: port)
        case .cancelled:
            status = .idle
        default:
            break
        }
    }

    /// Retry start() after a backoff, unless we've since gone live. Recovers
    /// from a hard failure without spinning.
    private func scheduleRestart(port: UInt16) {
        guard !restartScheduled else { return }
        restartScheduled = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)       // exponential backoff, cap 30s
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            self.restartScheduled = false
            switch self.status {
            case .listening, .waiting: return       // recovered on its own
            default: self.start(port: port)
            }
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty {
                Task { @MainActor in self?.ingest(data, from: conn) }
            }
            if error == nil {
                // UDP message-mode delivers whole datagrams; keep listening.
                Task { @MainActor in self?.receive(on: conn) }
            } else {
                conn.cancel()
                // Free this peer's carry-over buffer so it can't leak over a long
                // session of changing source ports.
                Task { @MainActor in self?.buffers[ObjectIdentifier(conn)] = nil }
            }
        }
    }

    private func ingest(_ data: Data, from conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        var buf = buffers[key] ?? Data()
        buf.append(data)

        let newline = UInt8(ascii: "\n")
        while let idx = buf.firstIndex(of: newline) {
            let line = buf[buf.startIndex..<idx]
            buf.removeSubrange(buf.startIndex...idx)
            if !line.isEmpty, let msg = WireMessage(jsonLine: Data(line)) {
                onMessage?(msg)
            }
        }
        // Keep any trailing partial line; cap to avoid unbounded growth.
        buffers[key] = buf.count < 8192 ? buf : Data()
    }
}
