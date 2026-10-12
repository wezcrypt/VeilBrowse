import AVFoundation
import AVKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Last playback position per backed-up video (item ids are random, so nothing
/// about the content is revealed). Bounded to the 300 most recent entries.
enum PlaybackPositions {
    private static let key = "viewer.playbackPositions.v1"
    private static let limit = 300

    static func position(for itemID: String, defaults: UserDefaults = .standard) -> TimeInterval? {
        guard let entry = (defaults.dictionary(forKey: key) as? [String: [Double]])?[itemID], entry.count == 2 else { return nil }
        return entry[0]
    }

    static func save(_ seconds: TimeInterval, duration: TimeInterval, for itemID: String, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: key) as? [String: [Double]]) ?? [:]
        // Finished (or barely started) videos start from the beginning next time.
        if seconds < 5 || (duration > 0 && seconds > duration * 0.95) {
            all.removeValue(forKey: itemID)
        } else {
            all[itemID] = [seconds, Date().timeIntervalSince1970]
        }
        if all.count > limit {
            let keep = all.sorted { $0.value[1] > $1.value[1] }.prefix(limit)
            all = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        defaults.set(all, forKey: key)
    }
}

/// AVPlayer state for the custom controls. Lives on the main actor.
@MainActor
@Observable
final class VideoPlaybackModel {
    static let rates: [Float] = [0.5, 1, 1.25, 1.5, 2]

    let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var duration: TimeInterval = 0
    private(set) var presentationSize: CGSize = .zero
    var currentTime: TimeInterval = 0
    var isScrubbing = false
    private(set) var rate: Float = 1
    private(set) var isMuted = false
    private(set) var volume: Float = 1
    private(set) var legibleOptions: [AVMediaSelectionOption] = []
    private(set) var selectedLegible: AVMediaSelectionOption?
    private(set) var legibleGroup: AVMediaSelectionGroup?
    private(set) var externalSubtitles: SubtitleTrack?
    private(set) var currentCue: SubtitleCue?
    private(set) var failure: String?
    private(set) var pipPossible = false

    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var pipController: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private var itemID: String?

    func load(url: URL, itemID: String) async {
        self.itemID = itemID
        failure = nil
        let asset = AVURLAsset(url: url)
        do {
            let (playable, assetDuration) = try await asset.load(.isPlayable, .duration)
            guard playable else {
                failure = String(localized: "iOS cannot play this video format.")
                return
            }
            duration = CMTimeGetSeconds(assetDuration).isFinite ? CMTimeGetSeconds(assetDuration) : 0
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                presentationSize = CGSize(width: abs(rect.width), height: abs(rect.height))
            }
            if let group = try await asset.loadMediaSelectionGroup(for: .legible) {
                legibleGroup = group
                legibleOptions = group.options
            }
        } catch {
            failure = error.localizedDescription
            return
        }
        let item = AVPlayerItem(asset: asset)
        // Let AVFoundation keep only a small forward buffer from the local file.
        item.preferredForwardBufferDuration = 10
        if let group = legibleGroup { item.select(nil, in: group) }
        player.replaceCurrentItem(with: item)
        player.automaticallyWaitsToMinimizeStalling = false
        observe(item)
        if let resume = PlaybackPositions.position(for: itemID), resume < duration - 3 {
            await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = resume
        }
        configureAudioSession()
        play()
    }

    private func observe(_ item: AVPlayerItem) {
        removeObservers()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite { self.currentTime = seconds }
                self.currentCue = self.externalSubtitles?.cue(at: self.currentTime)
            }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                self?.isPlaying = status != .paused
                self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
            }
        })
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let message = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                if failed { self?.failure = message ?? String(localized: "Playback failed.") }
            }
        })
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinish() }
        }
    }

    private func didFinish() {
        isPlaying = false
        if let itemID { PlaybackPositions.save(duration, duration: duration, for: itemID) }
    }

    private func removeObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    func play() {
        if duration > 0, currentTime >= duration - 0.25 { seek(to: 0) }
        player.playImmediately(atRate: rate)
    }

    func pause() {
        player.pause()
        savePosition()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: min(max(currentTime + seconds, 0), max(duration, 0)))
    }

    /// Coarse seeks while scrubbing keep the UI responsive; the final seek is exact.
    func seek(to seconds: TimeInterval, precise: Bool = true) {
        currentTime = seconds
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        currentCue = externalSubtitles?.cue(at: seconds)
    }

    func setRate(_ value: Float) {
        rate = value
        if isPlaying { player.rate = value }
    }

    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
        player.volume = volume
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    func selectLegible(_ option: AVMediaSelectionOption?) {
        guard let group = legibleGroup, let item = player.currentItem else { return }
        item.select(option, in: group)
        selectedLegible = option
        if option != nil { externalSubtitles = nil; currentCue = nil }
    }

    func useExternalSubtitles(_ track: SubtitleTrack?) {
        externalSubtitles = track
        if track != nil, let group = legibleGroup { player.currentItem?.select(nil, in: group); selectedLegible = nil }
        currentCue = track?.cue(at: currentTime)
    }

    // MARK: Picture in Picture

    func attach(layer: AVPlayerLayer) {
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        pipController = controller
        pipObservation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in self?.pipPossible = possible }
        }
    }

    func togglePictureInPicture() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    var isPictureInPictureActive: Bool { pipController?.isPictureInPictureActive ?? false }

    func savePosition() {
        guard let itemID, duration > 0 else { return }
        PlaybackPositions.save(currentTime, duration: duration, for: itemID)
    }

    func teardown() {
        savePosition()
        player.pause()
        removeObservers()
        pipObservation?.invalidate()
        pipObservation = nil
        pipController = nil
        player.replaceCurrentItem(with: nil)
    }
}

/// Bare AVPlayerLayer host (no system controls) so the player can be styled and
/// Picture in Picture can be driven from the custom controls.
struct PlayerLayerView: UIViewRepresentable {
    let model: VideoPlaybackModel

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        view.playerLayer.player = model.player
        view.playerLayer.videoGravity = .resizeAspect
        model.attach(layer: view.playerLayer)
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== model.player { view.playerLayer.player = model.player }
    }
}

/// One video page in the viewer: downloads the encrypted original (with progress),
/// decrypts it on the device into a protected temporary file and plays that file.
/// Encrypted data is never handed to AVPlayer, and there is no encrypted
/// streaming: playback starts after the whole video is decrypted locally.
struct VideoPage: View {
    let item: VaultItem
    let isCurrent: Bool
    @Binding var chromeVisible: Bool
    var hasPrevious: Bool
    var hasNext: Bool
    var onPrevious: () -> Void
    var onNext: () -> Void

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case decrypting
        case ready
        case failed(String)
    }

    @Environment(AppModel.self) private var model
    @State private var playback = VideoPlaybackModel()
    @State private var phase: Phase = .idle
    @State private var folder: URL?
    @State private var poster: UIImage?
    @State private var showSubtitleImporter = false
    @State private var subtitleError: String?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            switch phase {
            case .ready:
                PlayerLayerView(model: playback)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() } }
                if let cue = playback.currentCue {
                    VStack {
                        Spacer()
                        Text(cue.text)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                            .padding(.bottom, chromeVisible ? 150 : 40)
                    }
                    .allowsHitTesting(false)
                }
                if chromeVisible {
                    controls.transition(.opacity)
                }
                if let failure = playback.failure {
                    errorView(failure)
                }
            case .idle, .downloading, .decrypting:
                if let poster { Image(uiImage: poster).resizable().scaledToFit().opacity(0.5) }
                progressView
            case .failed(let message):
                errorView(message)
            }
        }
        .task(id: isCurrent) {
            if isCurrent {
                if phase == .idle { start() } else if phase == .ready { playback.play() }
            } else if phase == .ready, !playback.isPictureInPictureActive {
                playback.pause()
            }
        }
        .task { poster = await posterImage() }
        .onDisappear(perform: cleanup)
        .fileImporter(isPresented: $showSubtitleImporter, allowedContentTypes: Self.subtitleTypes) { result in
            do {
                playback.useExternalSubtitles(try SubtitleParser.load(try result.get()))
                subtitleError = nil
            } catch {
                subtitleError = error.localizedDescription
            }
        }
    }

    static var subtitleTypes: [UTType] {
        [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt"), .plainText].compactMap { $0 }
    }

    private var progressView: some View {
        VStack(spacing: 12) {
            switch phase {
            case .downloading(let value):
                ProgressView(value: value).frame(width: 220).tint(.white)
                Text(String(localized: "Downloading encrypted video… \(Int(value * 100))%"))
                Text(Formatters.bytes(item.manifest.payloadBytes)).font(.caption).foregroundStyle(.white.opacity(0.7))
            case .decrypting:
                ProgressView().tint(.white)
                Text(String(localized: "Decrypting on this iPhone…"))
            default:
                ProgressView().tint(.white)
            }
        }
        .foregroundStyle(.white)
        .font(.callout)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.white)
            Button(String(localized: "Try Again")) {
                cleanup()
                playback = VideoPlaybackModel()
                phase = .idle
                start()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 44) {
                Button { playback.skip(by: -10) } label: { Image(systemName: "gobackward.10") }
                    .accessibilityLabel(String(localized: "Back 10 seconds"))
                Button { playback.togglePlay() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44))
                }
                .accessibilityLabel(playback.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
                Button { playback.skip(by: 10) } label: { Image(systemName: "goforward.10") }
                    .accessibilityLabel(String(localized: "Forward 10 seconds"))
            }
            .font(.system(size: 30))
            .foregroundStyle(.white)
            .shadow(radius: 4)
            .overlay { if playback.isBuffering { ProgressView().tint(.white).offset(y: 50) } }
            Spacer()
            VStack(spacing: 10) {
                scrubber
                HStack(spacing: 18) {
                    Button(action: onPrevious) { Image(systemName: "backward.end.fill") }
                        .disabled(!hasPrevious).accessibilityLabel(String(localized: "Previous"))
                    Button(action: onNext) { Image(systemName: "forward.end.fill") }
                        .disabled(!hasNext).accessibilityLabel(String(localized: "Next"))
                    Spacer()
                    speedMenu
                    subtitleMenu
                    Button { playback.toggleMute() } label: {
                        Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .accessibilityLabel(playback.isMuted ? String(localized: "Unmute") : String(localized: "Mute"))
                    Slider(value: Binding(get: { Double(playback.volume) }, set: { playback.setVolume(Float($0)) }), in: 0...1)
                        .frame(width: 80)
                        .accessibilityLabel(String(localized: "Volume"))
                    if playback.pipPossible {
                        Button { playback.togglePictureInPicture() } label: { Image(systemName: "pip.enter") }
                            .accessibilityLabel(String(localized: "Picture in Picture"))
                    }
                }
                .font(.body)
                .foregroundStyle(.white)
                if let subtitleError { Text(subtitleError).font(.caption).foregroundStyle(.yellow) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 64)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        }
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(Formatters.duration(playback.currentTime)).monospacedDigit()
            Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0, precise: false) }),
                   in: 0...max(playback.duration, 0.1)) { editing in
                playback.isScrubbing = editing
                if !editing { playback.seek(to: playback.currentTime, precise: true) }
            }
            .tint(.white)
            .accessibilityLabel(String(localized: "Playback position"))
            Text(Formatters.duration(playback.duration)).monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.white)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(VideoPlaybackModel.rates, id: \.self) { rate in
                Button { playback.setRate(rate) } label: {
                    if rate == playback.rate { Label(Self.rateTitle(rate), systemImage: "checkmark") } else { Text(Self.rateTitle(rate)) }
                }
            }
        } label: {
            Text(Self.rateTitle(playback.rate)).font(.callout.weight(.semibold)).monospacedDigit()
        }
        .accessibilityLabel(String(localized: "Playback speed"))
    }

    private var subtitleMenu: some View {
        Menu {
            Button(String(localized: "Off")) {
                playback.selectLegible(nil)
                playback.useExternalSubtitles(nil)
            }
            ForEach(Array(playback.legibleOptions.enumerated()), id: \.offset) { _, option in
                Button(option.displayName) { playback.selectLegible(option) }
            }
            Button { showSubtitleImporter = true } label: { Label(String(localized: "Load from Files (.srt, .vtt)…"), systemImage: "doc.badge.plus") }
        } label: {
            Image(systemName: playback.selectedLegible != nil || playback.externalSubtitles != nil ? "captions.bubble.fill" : "captions.bubble")
        }
        .accessibilityLabel(String(localized: "Subtitles"))
    }

    static func rateTitle(_ rate: Float) -> String {
        rate == 1 ? "1×" : String(format: "%g×", rate)
    }

    // MARK: Loading

    private func start() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    private func load() async {
        guard let primary = item.manifest.primary else { phase = .failed(RestoreError.missingResource.localizedDescription); return }
        do {
            let service = try model.restoreService()
            phase = .downloading(0)
            let progress = LockedBox(0.0)
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    if case .downloading = phase { phase = .downloading(progress.value) }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            defer { ticker.cancel() }
            let url = try await service.viewerFile(primary) { value in
                progress.value = value
            }
            ticker.cancel()
            try Task.checkCancellation()
            folder = url.deletingLastPathComponent()
            phase = .decrypting
            await playback.load(url: url, itemID: item.id)
            if let failure = playback.failure { phase = .failed(failure); return }
            phase = .ready
            if !isCurrent { playback.pause() }
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func posterImage() async -> UIImage? {
        guard let service = try? model.restoreService() else { return nil }
        return try? await service.thumbnail(for: item, maxPixelSize: 800)
    }

    private func cleanup() {
        loadTask?.cancel()
        loadTask = nil
        if playback.isPictureInPictureActive { return }
        playback.teardown()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        if phase == .ready { phase = .idle }
    }
}
