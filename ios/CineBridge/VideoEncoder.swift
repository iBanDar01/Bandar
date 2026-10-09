import Foundation
import AVFoundation
import VideoToolbox

final class VideoEncoder {
    typealias PacketHandler = (Data) -> Void

    private var compressionSession: VTCompressionSession?
    private let packetizer = RTPPacketizer()
    private var packetHandler: PacketHandler?
    private var timebaseOrigin: Double?
    private var nalLengthFieldBytes: Int = 4

    func configure(width: Int, height: Int, fps: Int, bitrateMbps: Int, packetHandler: @escaping PacketHandler) throws {
        invalidate()
        self.packetHandler = packetHandler

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.outputCallback,
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw NSError(domain: "CineBridge.VideoEncoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed: \(status)"])
        }

        compressionSession = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)

        let expectedFps = NSNumber(value: fps)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: expectedFps)

        let bitrate = NSNumber(value: bitrateMbps * 1_000_000)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate)

        let bytesPerSecond = max(1, bitrateMbps * 1_000_000 / 8)
        let limits = [NSNumber(value: bytesPerSecond), NSNumber(value: 1)] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)

        let gop = NSNumber(value: max(15, fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: gop)

        if #available(iOS 15.0, *) {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            invalidate()
            throw NSError(domain: "CineBridge.VideoEncoder", code: Int(prepareStatus), userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionPrepareToEncodeFrames failed: \(prepareStatus)"])
        }
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: duration.isValid ? duration : .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    func invalidate() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        compressionSession = nil
        packetHandler = nil
        timebaseOrigin = nil
        nalLengthFieldBytes = 4
    }

    deinit { invalidate() }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard status == noErr,
              let refcon,
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.handleEncodedSampleBuffer(sampleBuffer)
    }

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let isKeyframe: Bool = {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
                  let first = attachments.first else { return true }
            return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        }()

        var accessUnitNALs: [Data] = []

        if isKeyframe, let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            var headerLength: Int32 = 0
            var pointer: UnsafePointer<UInt8>?
            var size = 0

            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &headerLength
            ) == noErr, let pointer {
                accessUnitNALs.append(Data(bytes: pointer, count: size))
                nalLengthFieldBytes = Int(headerLength)
            }

            pointer = nil
            size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 1,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer {
                accessUnitNALs.append(Data(bytes: pointer, count: size))
            }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        var encoded = Data(count: totalLength)
        let copyStatus: OSStatus = encoded.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: totalLength, destination: baseAddress)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        var offset = 0
        let lengthBytes = max(1, min(4, nalLengthFieldBytes))
        while offset + lengthBytes <= encoded.count {
            var naluLength = 0
            for i in 0..<lengthBytes {
                naluLength = (naluLength << 8) | Int(encoded[offset + i])
            }
            offset += lengthBytes
            guard naluLength > 0, offset + naluLength <= encoded.count else { break }
            accessUnitNALs.append(encoded.subdata(in: offset..<(offset + naluLength)))
            offset += naluLength
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = pts.seconds.isFinite ? pts.seconds : 0
        if timebaseOrigin == nil { timebaseOrigin = seconds }
        let relativeSeconds = max(0, seconds - (timebaseOrigin ?? seconds))
        let timestamp = UInt32(truncatingIfNeeded: Int64(relativeSeconds * 90_000.0))

        for packet in packetizer.packetizeAccessUnit(nalus: accessUnitNALs, timestamp: timestamp) {
            packetHandler?(packet)
        }
    }
}
