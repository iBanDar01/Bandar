import Foundation
import SwiftUI
import AVFoundation
import CoreMedia

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var isStreaming = false
    @Published private(set) var statusText = "جاهز"
    @Published private(set) var cinematicActive = false
    @Published private(set) var actualFormatText = "—"
    @Published private(set) var lastError: String?

    private let sessionQueue = DispatchQueue(label: "cinebridge.capture", qos: .userInteractive)
    private let sampleQueue = DispatchQueue(label: "cinebridge.samples", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let encoder = VideoEncoder()
    private let udp = UDPStreamer()
    private let tcp = TCPPacketServer()

    private var activeDevice: AVCaptureDevice?
    private var activeInput: AVCaptureDeviceInput?
    private var activeConfiguration = StreamConfiguration()
    private var effectiveFPS = 30
    private var effectiveWidth = 1920
    private var effectiveHeight = 1080

    override init() {
        super.init()
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        tcp.onClientState = { [weak self] message in
            DispatchQueue.main.async {
                if self?.isStreaming == true { self?.statusText = message }
            }
        }
    }

    func start(_ configuration: StreamConfiguration) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.lastError = "تم رفض صلاحية الكاميرا"
                    self.statusText = "صلاحية الكاميرا مطلوبة"
                }
                return
            }
            self.sessionQueue.async {
                self.configureAndRun(configuration)
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.stopInternal()
        }
    }

    func focus(at devicePoint: CGPoint, strength: CinematicFocusStrength) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }

            if #available(iOS 26.0, *), self.cinematicActive {
                let mode: AVCaptureDevice.CinematicVideoFocusMode = (strength == .strong) ? .strong : .weak
                device.setCinematicVideoTrackingFocus(at: devicePoint, focusMode: mode)
                DispatchQueue.main.async { self.statusText = "Cinematic focus tracking updated" }
                return
            }

            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.statusText = "Focus updated" }
            } catch {
                DispatchQueue.main.async { self.lastError = error.localizedDescription }
            }
        }
    }

    private func configureAndRun(_ configuration: StreamConfiguration) {
        stopInternal(updateUI: false)
        activeConfiguration = configuration
        var configurationOpen = false

        do {
            session.beginConfiguration()
            configurationOpen = true
            session.sessionPreset = .inputPriority
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }

            guard let device = selectDevice(cinematicRequested: configuration.cinematicRequested) else {
                throw makeError("Compatible rear camera not found")
            }

            let selection = try selectFormat(device: device, configuration: configuration)
            try device.lockForConfiguration()
            device.activeFormat = selection.format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(selection.fps))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(selection.fps))
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            device.unlockForConfiguration()

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw makeError("Cannot add camera input") }
            session.addInput(input)

            var cinematicEnabled = false
            if configuration.cinematicRequested {
                if #available(iOS 26.0, *) {
                    if input.isCinematicVideoCaptureSupported {
                        input.isCinematicVideoCaptureEnabled = true
                        let minA = device.activeFormat.minSimulatedAperture
                        let maxA = device.activeFormat.maxSimulatedAperture
                        if minA > 0, maxA > 0 {
                            input.simulatedAperture = min(max(configuration.simulatedAperture, minA), maxA)
                        }
                        cinematicEnabled = true
                    }
                }
            }

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            guard session.canAddOutput(videoOutput) else { throw makeError("Cannot add video output") }
            session.addOutput(videoOutput)

            if #available(iOS 26.0, *), cinematicEnabled, session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                metadataOutput.metadataObjectTypes = metadataOutput.requiredMetadataObjectTypesForCinematicVideoCapture
            }

            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
            }

            let dimensions = CMVideoFormatDescriptionGetDimensions(selection.format.formatDescription)
            effectiveWidth = Int(dimensions.width)
            effectiveHeight = Int(dimensions.height)
            effectiveFPS = selection.fps

            session.commitConfiguration()
            configurationOpen = false

            switch configuration.transport {
            case .wifiUDP:
                udp.start(host: configuration.host, port: configuration.port)
            case .usbTCP:
                try tcp.start(port: configuration.port)
            }

            try encoder.configure(
                width: effectiveWidth,
                height: effectiveHeight,
                fps: effectiveFPS,
                bitrateMbps: configuration.bitrateMbps
            ) { [weak self] packet in
                guard let self else { return }
                switch configuration.transport {
                case .wifiUDP: self.udp.send(packet)
                case .usbTCP: self.tcp.send(packet)
                }
            }

            activeDevice = device
            activeInput = input
            session.startRunning()

            DispatchQueue.main.async {
                self.cinematicActive = cinematicEnabled
                self.isStreaming = true
                self.actualFormatText = "\(self.effectiveWidth)×\(self.effectiveHeight) @ \(self.effectiveFPS)fps"
                if configuration.cinematicRequested && !cinematicEnabled {
                    self.statusText = "Streaming — Cinematic غير مدعوم على هذا النظام/التنسيق، تم استخدام الوضع العادي"
                } else if configuration.transport == .usbTCP {
                    self.statusText = "Streaming — بانتظار اتصال USB من الكمبيوتر"
                } else {
                    self.statusText = cinematicEnabled ? "Streaming — Apple Cinematic فعال" : "Streaming — Standard"
                }
                self.lastError = nil
            }
        } catch {
            if configurationOpen {
                session.commitConfiguration()
            }
            encoder.invalidate()
            udp.stop()
            tcp.stop()
            DispatchQueue.main.async {
                self.isStreaming = false
                self.cinematicActive = false
                self.lastError = error.localizedDescription
                self.statusText = "تعذر بدء البث"
            }
        }
    }

    private func stopInternal(updateUI: Bool = true) {
        if session.isRunning { session.stopRunning() }
        encoder.invalidate()
        udp.stop()
        tcp.stop()
        activeDevice = nil
        activeInput = nil
        if updateUI {
            DispatchQueue.main.async {
                self.isStreaming = false
                self.cinematicActive = false
                self.statusText = "متوقف"
            }
        }
    }

    private func selectDevice(cinematicRequested: Bool) -> AVCaptureDevice? {
        if #available(iOS 26.0, *), cinematicRequested {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInDualWideCamera, .builtInTripleCamera, .builtInDualCamera, .builtInWideAngleCamera],
                mediaType: .video,
                position: .back
            )
            if let capable = discovery.devices.first(where: { device in
                device.formats.contains(where: { $0.isCinematicVideoCaptureSupported })
            }) {
                return capable
            }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private struct FormatSelection {
        let format: AVCaptureDevice.Format
        let fps: Int
    }

    private func selectFormat(device: AVCaptureDevice, configuration: StreamConfiguration) throws -> FormatSelection {
        let target = configuration.preset
        var candidates: [(AVCaptureDevice.Format, Int, Int)] = []

        for format in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let width = Int(d.width)
            let height = Int(d.height)
            guard width >= 1280, height >= 720 else { continue }

            if #available(iOS 26.0, *), configuration.cinematicRequested {
                guard format.isCinematicVideoCaptureSupported else { continue }
            }

            let maxFPS: Double
            if #available(iOS 26.0, *), configuration.cinematicRequested {
                maxFPS = format.videoFrameRateRangeForCinematicVideo?.maxFrameRate ?? 0
            } else {
                maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            }
            guard maxFPS >= 24 else { continue }

            let chosenFPS = Int(min(Double(target.fps), floor(maxFPS)))
            let resolutionPenalty = abs(width - target.width) + abs(height - target.height)
            let fpsPenalty = abs(chosenFPS - target.fps) * 500
            candidates.append((format, chosenFPS, resolutionPenalty + fpsPenalty))
        }

        if let best = candidates.min(by: { $0.2 < $1.2 }) {
            return FormatSelection(format: best.0, fps: best.1)
        }

        // iOS 18–25 or an unsupported device: keep the app useful by falling back to normal capture.
        if configuration.cinematicRequested {
            var fallback = configuration
            fallback.cinematicRequested = false
            return try selectFormat(device: device, configuration: fallback)
        }

        throw makeError("No compatible camera format found")
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "CineBridge.Camera", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        encoder.encode(sampleBuffer)
    }
}
