import Foundation
import Network

/// USB mode uses a TCP listener on the iPhone. On Windows, pymobiledevice3 forwards
/// localhost:<port> to the same port on the iPhone through usbmuxd.
/// RTP packets are length-prefixed and micro-batched for ~1 ms to avoid thousands
/// of tiny TCP send calls per second at high 4K bitrates.
final class TCPPacketServer {
    private let queue = DispatchQueue(label: "cinebridge.usb.tcp", qos: .userInteractive)
    private var listener: NWListener?
    private var client: NWConnection?
    private var pending = Data()
    private var flushScheduled = false
    private let flushThreshold = 48 * 1024

    var onClientState: ((String) -> Void)?

    func start(port: UInt16) throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "CineBridge", code: 20, userInfo: [NSLocalizedDescriptionKey: "Invalid TCP port"])
        }

        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.queue.async {
                self.client?.cancel()
                self.client = connection
                self.pending.removeAll(keepingCapacity: true)
                self.flushScheduled = false

                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.onClientState?("USB client connected")
                    case .failed(let error): self?.onClientState?("USB client failed: \(error.localizedDescription)")
                    case .cancelled: self?.onClientState?("USB client disconnected")
                    default: break
                    }
                }
                connection.start(queue: self.queue)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onClientState?("USB listener ready on \(port)")
            case .failed(let error): self?.onClientState?("USB listener failed: \(error.localizedDescription)")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func send(_ packet: Data) {
        var framed = Data(capacity: packet.count + 4)
        var length = UInt32(packet.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(packet)

        queue.async { [weak self] in
            guard let self, self.client != nil else { return }
            self.pending.append(framed)
            if self.pending.count >= self.flushThreshold {
                self.flushNow()
            } else if !self.flushScheduled {
                self.flushScheduled = true
                self.queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
                    self?.flushNow()
                }
            }
        }
    }

    private func flushNow() {
        flushScheduled = false
        guard let client, !pending.isEmpty else { return }
        let chunk = pending
        pending.removeAll(keepingCapacity: true)
        client.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.onClientState?("USB send failed: \(error.localizedDescription)")
            }
        })
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            self?.client?.cancel()
            self?.client = nil
            self?.pending.removeAll(keepingCapacity: false)
            self?.flushScheduled = false
        }
    }
}
