import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()

    @State private var transport: TransportMode = .wifiUDP
    @State private var host = "192.168.1.10"
    @State private var portText = "5004"
    @State private var selectedPreset = CapturePreset.presets[0]
    @State private var bitrateMbps = 18.0
    @State private var cinematic = true
    @State private var aperture = 2.8
    @State private var focusStrength: CinematicFocusStrength = .weak

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 12) {
                CameraPreview(session: camera.session) { point in
                    camera.focus(at: point, strength: focusStrength)
                }
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(camera.cinematicActive ? "CINEMATIC" : "CAMERA")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.65), in: Capsule())
                        Text(camera.actualFormatText)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(10)
                }
                .overlay(alignment: .bottom) {
                    Text("اضغط على الشخص داخل الصورة لتغيير التتبع/الفوكس")
                        .font(.caption)
                        .padding(8)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .frame(maxHeight: .infinity)

                controls
            }
            .padding()
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("النقل", selection: $transport) {
                    ForEach(TransportMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("الجودة", selection: $selectedPreset) {
                    ForEach(CapturePreset.presets) { Text($0.title).tag($0) }
                }
                .onChange(of: selectedPreset) { _, newValue in
                    bitrateMbps = Double(newValue.defaultBitrateMbps)
                }
            }

            HStack(spacing: 10) {
                if transport == .wifiUDP {
                    TextField("IP الكمبيوتر", text: $host)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text("USB: وصّل الكيبل وشغّل Port Forward من برنامج الكمبيوتر")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Port", text: $portText)
                    .keyboardType(.numberPad)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Toggle("Apple Cinematic", isOn: $cinematic)
                    .disabled(camera.isStreaming)

                Picker("الفوكس", selection: $focusStrength) {
                    ForEach(CinematicFocusStrength.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Text("f/\(aperture, specifier: "%.1f")")
                    .font(.caption.monospacedDigit())
                    .frame(width: 55, alignment: .leading)
                Slider(value: $aperture, in: 2.0...16.0, step: 0.1)
                    .disabled(camera.isStreaming || !cinematic)

                Text("\(Int(bitrateMbps)) Mbps")
                    .font(.caption.monospacedDigit())
                    .frame(width: 72, alignment: .trailing)
                Slider(value: $bitrateMbps, in: 6...45, step: 1)
                    .disabled(camera.isStreaming)
                    .frame(maxWidth: 180)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(camera.statusText)
                        .font(.footnote)
                    if let error = camera.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Button(camera.isStreaming ? "إيقاف" : "بدء البث") {
                    if camera.isStreaming {
                        camera.stop()
                    } else {
                        camera.start(makeConfiguration())
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func makeConfiguration() -> StreamConfiguration {
        StreamConfiguration(
            transport: transport,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: UInt16(portText) ?? 5004,
            preset: selectedPreset,
            bitrateMbps: Int(bitrateMbps),
            cinematicRequested: cinematic,
            simulatedAperture: Float(aperture),
            focusStrength: focusStrength
        )
    }
}
