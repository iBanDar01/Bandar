import Foundation
import Network

final class UDPStreamer {
    private let queue = DispatchQueue(label: "cinebridge.udp", qos: .userInteractive)
    private var connection: NWConnection?

    func start(host: String, port: UInt16) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        connection.start(queue: queue)
        self.connection = connection
    }

    func send(_ packet: Data) {
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    func stop() {
        connection?.cancel()
        connection = nil
    }
}
