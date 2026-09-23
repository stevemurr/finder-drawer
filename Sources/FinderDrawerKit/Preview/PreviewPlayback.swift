import AppKit
import AVKit
import Observation
import SwiftUI

@MainActor @Observable
final class PreviewPlayback {
    let id = UUID()
    let player = AVPlayer()
    var position: Double = 0
    var isPlaying = false
    var rate: Float = 1
    var error: String?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var status: NSKeyValueObservation?

    func start(_ url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        status = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let message = item.status == .failed ? item.error?.localizedDescription ?? "This media format cannot be played." : nil
            Task { @MainActor [weak self] in self?.error = message }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if time.seconds.isFinite { position = max(0, time.seconds) }
                isPlaying = player.rate != 0
            }
        }
    }
    func toggle(duration: Double) {
        if isPlaying { player.pause(); isPlaying = false }
        else {
            if position >= duration - 0.1 { seek(0) }
            player.playImmediately(atRate: rate); isPlaying = true
        }
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        position = max(0, seconds)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil; status = nil
        player.replaceCurrentItem(with: nil)
        isPlaying = false; position = 0; error = nil
    }
}

struct MediaFilePreview: View {
    let document: FilePreviewDocument
    var browser: BrowserViewModel?
    @State private var playback = PreviewPlayback()
    var body: some View {
        VStack(spacing: 0) {
            if document.kind == .video {
                PreviewVideoSurface(player: playback.player)
                    .frame(minHeight: 180, idealHeight: 240, maxHeight: 300)
                    .background(.black)
            } else if !document.waveform.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sampled waveform").font(.system(size: 11)).foregroundStyle(.secondary)
                    WaveformCanvas(channels: document.waveform, progress: playback.position / max(1, document.duration)) { fraction in
                        playback.seek(fraction * document.duration)
                    }.frame(height: 155)
                    HStack { Text("0:00"); Spacer(); Text(FilePreviewDocument.time(document.duration)) }
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }.padding(16)
            } else {
                Image(systemName: "waveform").font(.system(size: 38, weight: .light))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 180)
            }
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.secondary).padding(12) }
            Slider(value: Binding(get: { min(playback.position, max(document.duration, 0.01)) },
                                  set: { playback.seek($0) }), in: 0...max(document.duration, 0.01))
                .accessibilityLabel("Playback position").padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            ViewThatFits(in: .horizontal) {
                transport(showsRate: true)
                transport(showsRate: false)
            }.padding(10).background(DrawerTheme.surface)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear {
            playback.start(document.url)
            browser?.previewPlayback = (playback.id, document.url, { [weak playback = playback] in playback?.toggle(duration: document.duration) })
        }
        .onDisappear {
            playback.stop()
            if browser?.previewPlayback?.id == playback.id { browser?.previewPlayback = nil }
        }
    }

    private func transport(showsRate: Bool) -> some View {
        HStack(spacing: 10) {
            Button { playback.seek(max(0, playback.position - 5)) } label: { Image(systemName: "gobackward.5") }
                .help("Back five seconds").accessibilityLabel("Back five seconds")
            Button { playback.toggle(duration: document.duration) } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 28, height: 28)
                    .background(Color.primary, in: Circle()).foregroundStyle(Color(nsColor: .controlBackgroundColor))
            }.accessibilityLabel(playback.isPlaying ? "Pause preview" : "Play preview")
            Button { playback.seek(min(document.duration, playback.position + 5)) } label: { Image(systemName: "goforward.5") }
                .help("Forward five seconds").accessibilityLabel("Forward five seconds")
            Text("\(FilePreviewDocument.time(playback.position)) / \(FilePreviewDocument.time(document.duration))")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 0)
            if showsRate {
                Menu {
                    ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { rate in
                        Button("\(rate.formatted())×") {
                            playback.rate = rate
                            if playback.isPlaying { playback.player.rate = rate }
                        }
                    }
                } label: { Text("\(playback.rate.formatted())×").font(.caption) }
                .menuStyle(.borderlessButton).fixedSize().help("Playback speed")
            }
        }.buttonStyle(.plain)
    }
}

private struct PreviewVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none; view.videoGravity = .resizeAspect; view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

struct WaveformCanvas: View {
    let channels: [[Float]]
    let progress: Double
    let seek: (Double) -> Void
    var body: some View {
        Canvas { context, size in
            let channelHeight = size.height / CGFloat(max(1, channels.count))
            for (channel, peaks) in channels.enumerated() {
                let step = size.width / CGFloat(max(1, peaks.count))
                for (index, peak) in peaks.enumerated() {
                    let height = max(2, CGFloat(peak) * (channelHeight - 12))
                    let rect = CGRect(x: CGFloat(index) * step, y: CGFloat(channel) * channelHeight + (channelHeight - height) / 2,
                                      width: max(1, step * 0.6), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Double(index) / Double(peaks.count) <= progress ? .accentColor : .secondary.opacity(0.4)))
                }
            }
            let x = size.width * min(max(progress, 0), 1)
            context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.accentColor))
        }
        .overlay {
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    seek(min(1, max(0, value.location.x / max(1, geometry.size.width))))
                })
            }
        }
        .accessibilityLabel("Audio waveform")
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityAdjustableAction { direction in seek(min(1, max(0, progress + (direction == .increment ? 0.02 : -0.02)))) }
    }
}
