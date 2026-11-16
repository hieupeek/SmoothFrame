import SwiftUI
import UniformTypeIdentifiers

/// Main player UI: video area (MTKView), transport controls, and a sidebar
/// with FPS / engine / resolution / upscaling controls, profiles, and stats.
struct ContentView: View {
    @StateObject private var stats = PlaybackStats()
    @StateObject private var playback = PlaybackEngineWrapper()

    @AppStorage("targetFPS") private var targetFPS = 60
    @AppStorage("engine") private var engineRaw = EngineChoice.auto.rawValue
    @AppStorage("smoothness") private var smoothness = 0.7
    @AppStorage("sceneThreshold") private var sceneThreshold = 0.35
    @AppStorage("showStats") private var showStats = false
    @AppStorage("profile") private var profileRaw = PlaybackProfile.film.rawValue
    @AppStorage("outputResolution") private var outputResolutionRaw = OutputResolution.native.rawValue
    @AppStorage("upscaleQuality") private var upscaleQualityRaw = UpscaleQuality.balanced.rawValue

    @State private var errorMessage: String?
    @State private var showOpenPanel = false
    @State private var exportProgress: Double?
    @State private var displayInfo: DisplayInfo?

    private var profile: PlaybackProfile {
        PlaybackProfile(rawValue: profileRaw) ?? .film
    }
    private var outputResolution: OutputResolution {
        OutputResolution(rawValue: outputResolutionRaw) ?? .native
    }
    private var upscaleQuality: UpscaleQuality {
        UpscaleQuality(rawValue: upscaleQualityRaw) ?? .balanced
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                videoArea
                transportBar
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .smoothFrameOpenFile)) { _ in
            showOpenPanel = true
        }
        .fileImporter(isPresented: $showOpenPanel, allowedContentTypes: [.movie, .video, .mpeg4Movie]) { result in
            switch result {
            case .success(let url): open(url: url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            displayInfo = DisplayDetector.mainDisplay()
            playback.renderer.stats = stats
            applySettingsToRenderer()
        }
        .onChange(of: targetFPS) { applySettingsToRenderer() }
        .onChange(of: engineRaw) { applySettingsToRenderer() }
        .onChange(of: outputResolutionRaw) { applySettingsToRenderer() }
        .onChange(of: upscaleQualityRaw) { applySettingsToRenderer() }
    }

    // MARK: - Video area

    private var videoArea: some View {
        ZStack {
            MetalVideoView(renderer: playback.renderer)
            if playback.videoInfo == nil {
                VStack(spacing: 12) {
                    Image(systemName: "film.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Mở một file video để bắt đầu")
                    Button("Open Video…") { showOpenPanel = true }
                        .keyboardShortcut("o", modifiers: .command)
                }
            }
            if showStats { statsOverlay }
        }
        .background(Color.black)
    }

    private var statsOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Engine: \(stats.engineName)")
            Text("Source: \(String(format: "%.2f", stats.sourceFPS)) fps  •  Output: \(String(format: "%.0f", stats.outputFPS)) fps")
            Text("Frame time: \(String(format: "%.2f", stats.frameTimeMs)) ms  (budget \(String(format: "%.2f", stats.frameBudgetMs)) ms)")
            Text("Upscale: \(String(format: "%.2f", stats.upscaleTimeMs)) ms  •  Output: \(stats.outputWidth)×\(stats.outputHeight)")
            Text("Interpolated: \(stats.interpolatedFrames)  •  Dropped: \(stats.droppedFrames)")
            if stats.didDegradeFPS {
                Text("⚠️ \(stats.degradeReason)").foregroundStyle(.yellow)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(8)
        .background(Color.black.opacity(0.6))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    // MARK: - Transport

    private var transportBar: some View {
        HStack(spacing: 16) {
            Button(action: { playback.engine.togglePlayPause(); playback.isPlaying.toggle() }) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            if let info = playback.videoInfo {
                Text(info.displayName).lineLimit(1).truncationMode(.middle)
                Text(info.resolutionLabel).foregroundStyle(.secondary)
                Text("\(String(format: "%.0f", info.sourceFPS)) fps").foregroundStyle(.secondary)
            } else {
                Text("No video loaded").foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = exportProgress {
                ProgressView(value: progress).frame(width: 120)
            }
            Button("Export…") { startExport() }
                .disabled(playback.videoInfo == nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        Form {
            Section("Màn hình") {
                if let display = displayInfo {
                    Text(display.label).font(.callout)
                    if display.isQHD180 {
                        Button("🖥 Áp dụng preset: Màn 2K 180Hz") { applyQHD180Preset() }
                            .buttonStyle(.borderedProminent)
                        Text("1440p • 180 fps • engine tự động. Lưu ý: MacBook Air có thể tự hạ xuống 120 fps nếu không đủ 5.55 ms/khung.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let preset = DisplayDetector.suggestedPreset() {
                        Text("Gợi ý: \(preset.targetFPS) fps cho màn hình này.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Nội suy (Interpolation)") {
                Picker("Target FPS", selection: $targetFPS) {
                    ForEach(TargetFPS.allCases) { fps in
                        Text(fps.label).tag(fps.rawValue)
                    }
                }
                Text("24→180 cần 6.5 khung trung gian/khung gốc (7.5×); 30→180 cần 5 khung; 60→180 cần 2 khung. Ngân sách mỗi khung đích ở 180 fps chỉ 5.55 ms.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Engine", selection: $engineRaw) {
                    ForEach(EngineChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice.rawValue)
                    }
                }
                Picker("Profile", selection: $profileRaw) {
                    ForEach(PlaybackProfile.allCases) { p in
                        Text(p.rawValue).tag(p.rawValue)
                    }
                }
                .onChange(of: profileRaw) { _, newValue in
                    if let p = PlaybackProfile(rawValue: newValue) {
                        smoothness = p.smoothness
                        sceneThreshold = p.sceneThreshold
                        applySettingsToRenderer()
                    }
                }
                Slider(value: $smoothness, in: 0...1) { Text("Smoothness") }
                Text("Smoothness: \(String(format: "%.2f", smoothness))").font(.caption)
                Slider(value: $sceneThreshold, in: 0.1...0.8) { Text("Scene threshold") }
                Text("Scene threshold: \(String(format: "%.2f", sceneThreshold)) — cao hơn = ít nhận cắt cảnh hơn.").font(.caption)
            }

            Section("Upscale độ phân giải") {
                Picker("Output resolution", selection: $outputResolutionRaw) {
                    ForEach(OutputResolution.allCases) { res in
                        Text(res.rawValue).tag(res.rawValue)
                    }
                }
                Picker("Upscale quality", selection: $upscaleQualityRaw) {
                    ForEach(UpscaleQuality.allCases) { q in
                        Text(q.rawValue).tag(q.rawValue)
                    }
                }
                Text("Nội suy chạy ở độ phân giải gốc trước, upscale lên 1440p sau — tiết kiệm hiệu năng. Upscale là Lanczos/bilinear cổ điển, không phải AI super-resolution.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Hiển thị") {
                Toggle("Show stats (⌘I)", isOn: $showStats)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private func applySettingsToRenderer() {
        var s = AppSettings()
        s.targetFPS = targetFPS
        s.engine = EngineChoice(rawValue: engineRaw) ?? .auto
        s.smoothness = smoothness
        s.sceneThreshold = sceneThreshold
        s.showStats = showStats
        s.profile = profile
        s.outputResolution = outputResolution
        s.upscaleQuality = upscaleQuality
        playback.renderer.settings = s
        playback.renderer.sceneDetector.threshold = sceneThreshold
        playback.renderer.upscaler = (outputResolution == .native)
            ? nil : MetalUpscaler(quality: upscaleQuality)
    }

    private func applyQHD180Preset() {
        let preset = AppSettings.qhd180Preset
        targetFPS = preset.targetFPS
        engineRaw = preset.engine.rawValue
        smoothness = preset.smoothness
        sceneThreshold = preset.sceneThreshold
        showStats = preset.showStats
        profileRaw = preset.profile.rawValue
        outputResolutionRaw = preset.outputResolution.rawValue
        upscaleQualityRaw = preset.upscaleQuality.rawValue
        applySettingsToRenderer()
    }

    private func open(url: URL) {
        playback.engine.open(url: url) { result in
            switch result {
            case .success(let info):
                playback.videoInfo = info
                playback.engine.play()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startExport() {
        guard let info = playback.videoInfo else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = info.url.deletingPathExtension().lastPathComponent + "-smoothframe.mp4"
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            var options = OfflineExporter.Options()
            options.targetFPS = targetFPS
            options.outputResolution = outputResolution
            if let warning = OfflineExporter.heavyExportWarning(for: options, source: info) {
                errorMessage = warning // Shown once; export still proceeds after OK.
            }
            let exporter = OfflineExporter()
            exporter.export(sourceURL: info.url, destinationURL: dest, options: options) { progress in
                Task { @MainActor in self.exportProgress = progress }
            } completion: { result in
                Task { @MainActor in
                    self.exportProgress = nil
                    if case .failure(let error) = result { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }
}

// MARK: - Observable wrapper (PlaybackEngine itself is not ObservableObject)

@MainActor
final class PlaybackEngineWrapper: ObservableObject {
    let engine = PlaybackEngine()
    let renderer = DisplayLinkRenderer()
    @Published var videoInfo: VideoInfo?
    @Published var isPlaying = false

    init() {
        renderer.playbackEngine = engine
    }
}
