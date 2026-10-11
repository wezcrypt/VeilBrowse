import AVFoundation
import Observation
import SwiftUI
import UIKit

/// Player state for vault videos (streamed via HTTP Range through
/// `AuthenticatedResourceLoader`) and for on-device videos.
@MainActor
@Observable
final class VideoPlayerModel {
    let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isBuffering = true
    private(set) var failure: String?
    var isScrubbing = false

    private var loader: AuthenticatedResourceLoader?
    private var timeObserver: Any?
    private var endTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
    }

    func loadRemote(_ item: MediaItem, api: APIClient, autoplay: Bool) {
        loadTask?.cancel()
        let loader = AuthenticatedResourceLoader(api: api, mediaID: item.id, mimeType: item.mimeType)
        let asset = AVURLAsset(url: AuthenticatedResourceLoader.assetURL(for: item.id))
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        self.loader = loader
        let assetBox = UncheckedSendable(asset)
        loadTask = Task { [weak self] in
            do {
                let playable = try await assetBox.value.load(.isPlayable)
                guard !Task.isCancelled else { return }
                guard playable else {
                    self?.failure = String(localized: "This video format can’t be played on iPhone. Supported: H.264 and HEVC in MOV or MP4.")
                    self?.isBuffering = false
                    return
                }
                self?.prepare(AVPlayerItem(asset: assetBox.value), autoplay: autoplay)
            } catch is CancellationError {
                return
            } catch {
                self?.failure = String(localized: "The video could not be loaded: \(error.localizedDescription)")
                self?.isBuffering = false
            }
        }
    }

    func load(playerItem: AVPlayerItem, autoplay: Bool) {
        prepare(playerItem, autoplay: autoplay)
    }

    private func prepare(_ item: AVPlayerItem, autoplay: Bool) {
        item.preferredForwardBufferDuration = 8
        player.replaceCurrentItem(with: item)
        if timeObserver == nil {
            let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    self?.tick(time)
                }
            }
        }
        endTask?.cancel()
        endTask = Task { [weak self, weak item] in
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
                self?.didReachEnd()
            }
        }
        if autoplay { play() }
    }

    private func tick(_ time: CMTime) {
        guard let item = player.currentItem else { return }
        if item.status == .failed {
            failure = item.error?.localizedDescription ?? String(localized: "Playback failed.")
            isBuffering = false
            isPlaying = false
            return
        }
        let itemDuration = CMTimeGetSeconds(item.duration)
        if itemDuration.isFinite, itemDuration > 0 { duration = itemDuration }
        if !isScrubbing {
            let seconds = CMTimeGetSeconds(time)
            if seconds.isFinite { currentTime = seconds }
        }
        isPlaying = player.timeControlStatus == .playing
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    private func didReachEnd() {
        isPlaying = false
        player.seek(to: .zero)
        currentTime = 0
    }

    func play() {
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func teardown() {
        loadTask?.cancel()
        endTask?.cancel()
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        loader?.cancelAll()
        loader = nil
    }
}

private final class PlayerLayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> UIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? PlayerLayerUIView)?.playerLayer.player = player
    }
}

/// Full-screen player with custom controls: play/pause, ±10 s, scrubber, durations.
struct VideoPlayerView: View {
    @Bindable var model: VideoPlayerModel
    @Binding var controlsVisible: Bool
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            PlayerLayerView(player: model.player)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
                    scheduleHide()
                }
                .accessibilityLabel(String(localized: "Video"))

            if let failure = model.failure {
                ContentUnavailableView(String(localized: "Can’t Play Video"), systemImage: "exclamationmark.triangle", description: Text(failure))
                    .foregroundStyle(.white)
            } else if model.isBuffering {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if controlsVisible && model.failure == nil {
                controls
                    .transition(.opacity)
            }
        }
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
    }

    private var controls: some View {
        VStack {
            Spacer()
            HStack(spacing: 48) {
                Button { model.skip(by: -10); scheduleHide() } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 30, weight: .medium))
                }
                .accessibilityLabel(String(localized: "Back 10 seconds"))
                Button { model.togglePlay(); scheduleHide() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .frame(width: 64, height: 64)
                }
                .accessibilityLabel(model.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
                Button { model.skip(by: 10); scheduleHide() } label: {
                    Image(systemName: "goforward.10").font(.system(size: 30, weight: .medium))
                }
                .accessibilityLabel(String(localized: "Forward 10 seconds"))
            }
            .foregroundStyle(.white)
            .shadow(radius: 6)
            Spacer()
            VStack(spacing: 6) {
                Slider(
                    value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }),
                    in: 0...max(model.duration, 0.1)
                ) { editing in
                    model.isScrubbing = editing
                    scheduleHide()
                }
                .tint(.white)
                .accessibilityLabel(String(localized: "Playback position"))
                .accessibilityValue(Formatters.duration(model.currentTime))
                HStack {
                    Text(Formatters.duration(model.currentTime))
                    Spacer()
                    Text("-" + Formatters.duration(max(model.duration - model.currentTime, 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 84)
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, model.isPlaying, !model.isScrubbing else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
    }
}
