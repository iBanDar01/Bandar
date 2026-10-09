import Foundation

final class RTPPacketizer {
    private var sequenceNumber: UInt16 = UInt16.random(in: 0...UInt16.max)
    private let ssrc: UInt32 = UInt32.random(in: 1...UInt32.max)
    private let payloadType: UInt8 = 96
    private let maxPayloadSize = 1200

    func packetizeAccessUnit(nalus: [Data], timestamp: UInt32) -> [Data] {
        guard !nalus.isEmpty else { return [] }
        var packets: [Data] = []
        for (index, nalu) in nalus.enumerated() {
            let isLastNAL = index == nalus.count - 1
            packets.append(contentsOf: packetizeNAL(nalu, timestamp: timestamp, markLastPacket: isLastNAL))
        }
        return packets
    }

    private func packetizeNAL(_ nalu: Data, timestamp: UInt32, markLastPacket: Bool) -> [Data] {
        guard !nalu.isEmpty else { return [] }

        if nalu.count <= maxPayloadSize {
            return [makePacket(payload: nalu, timestamp: timestamp, marker: markLastPacket)]
        }

        let bytes = [UInt8](nalu)
        let nalHeader = bytes[0]
        let nalType = nalHeader & 0x1F
        let nri = nalHeader & 0x60
        let fuIndicator = nri | 28

        let fragmentSize = maxPayloadSize - 2
        var offset = 1
        var result: [Data] = []
        var first = true

        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = min(fragmentSize, remaining)
            let last = offset + count >= bytes.count

            var fuHeader = nalType
            if first { fuHeader |= 0x80 }
            if last { fuHeader |= 0x40 }

            var payload = Data([fuIndicator, fuHeader])
            payload.append(contentsOf: bytes[offset..<(offset + count)])
            result.append(makePacket(payload: payload, timestamp: timestamp, marker: markLastPacket && last))

            offset += count
            first = false
        }
        return result
    }

    private func makePacket(payload: Data, timestamp: UInt32, marker: Bool) -> Data {
        var packet = Data(capacity: 12 + payload.count)
        packet.append(0x80)
        packet.append((marker ? 0x80 : 0x00) | payloadType)

        var seq = sequenceNumber.bigEndian
        var ts = timestamp.bigEndian
        var stream = ssrc.bigEndian
        withUnsafeBytes(of: &seq) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &stream) { packet.append(contentsOf: $0) }
        packet.append(payload)

        sequenceNumber &+= 1
        return packet
    }
}
