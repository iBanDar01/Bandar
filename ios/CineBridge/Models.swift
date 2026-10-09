import Foundation

struct CapturePreset: Identifiable, Hashable {
    let id: String
    let title: String
    let width: Int
    let height: Int
    let fps: Int
    let defaultBitrateMbps: Int

    static let presets: [CapturePreset] = [
        .init(id: "1080p60", title: "1080p 60 — أقل تأخير", width: 1920, height: 1080, fps: 60, defaultBitrateMbps: 18),
        .init(id: "1080p30", title: "1080p 30 — ثابت", width: 1920, height: 1080, fps: 30, defaultBitrateMbps: 14),
        .init(id: "4k30", title: "4K 30 — أعلى جودة", width: 3840, height: 2160, fps: 30, defaultBitrateMbps: 32)
    ]
}

enum TransportMode: String, CaseIterable, Identifiable {
    case wifiUDP = "Wi‑Fi UDP"
    case usbTCP = "USB TCP"

    var id: String { rawValue }
}

enum CinematicFocusStrength: String, CaseIterable, Identifiable {
    case weak = "تلقائي"
    case strong = "تثبيت قوي"

    var id: String { rawValue }
}

struct StreamConfiguration: Equatable {
    var transport: TransportMode = .wifiUDP
    var host: String = "192.168.1.10"
    var port: UInt16 = 5004
    var preset: CapturePreset = CapturePreset.presets[0]
    var bitrateMbps: Int = 18
    var cinematicRequested: Bool = true
    var simulatedAperture: Float = 2.8
    var focusStrength: CinematicFocusStrength = .weak
}
