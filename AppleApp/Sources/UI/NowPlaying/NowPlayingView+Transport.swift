import SwiftUI
import BitChordShared
import UniformTypeIdentifiers
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(iOS)
import UIKit
import AVFAudio
#else
import AppKit
#endif

// Position, volume and transport controls, the More menu, and nerd stats.
extension NowPlayingView {
    var positionControls: some View {
        VStack(spacing: 6) {
            ThinSlider(
                value: controller.position,
                maximum: controller.duration,
                mixing: controller.smartMixInProgress,
                transitionWindow: controller.smartTransitionWindow.flatMap { w in
                    w.end > w.start ? w.start...w.end : nil
                },
                onEditingChanged: { controller.seek(to: $0) },
                onDraggingChanged: { dragging in
                    lyricsScrubbing = dragging
                    if !dragging { lyricsControlActivity += 1 }
                }
            )
            .tint(.white)

            HStack {
                Text(Self.timestamp(controller.position))
                Spacer()
                Text(remainingLabel)
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.7))
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
        }
    }

    private var remainingLabel: String {
        guard controller.duration > 0 else { return "-0:00" }
        return "-\(Self.timestamp(max(0, controller.duration - controller.position)))"
    }

    /// White: iOS system volume. Orange: BitChord-only gain.
    /// Drag normally to adjust system output, or press for 0.42 s until
    /// haptic feedback, then drag to adjust music gain without touching iOS.
    #if os(iOS)
    var deckVolumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 16, height: 16)
                .playerGlyph()

            DualVolumeControl(appVolume: Binding(
                get: { controller.volume },
                set: { controller.volume = $0 }
            ))
            .frame(height: 28)

            Image(systemName: "speaker.wave.3.fill")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 16, height: 16)
                .playerGlyph()
        }
    }
    #endif

    /// Music's order: shuffle · previous · play-in-circle · next · repeat.
    /// Play sits on a white disc so it never disappears into a bright wash.
    /// The transport row.
    ///
    /// Every control carries an explicit `accessibilityLabel` as well as a
    /// `.help()`. The help text is macOS-only, so on iOS these were unlabelled
    /// template images and VoiceOver announced the asset name — "bch shuffle,
    /// button" — rather than what the button does. The labels are the same
    /// strings, so the two platforms say the same thing.
    /// Transport: skip, play, skip — and nothing else.
    ///
    /// Shuffle and repeat are not here. They live in the queue-modes pill
    /// (`queueModesPill`), which is their single home on every platform and
    /// pane; repeating them beside the playback keys put the same two switches
    /// on screen twice with nothing saying they are the same switch.
    var playerTransport: some View {
        HStack(spacing: 14) {
            Button {
                Haptics.play(.skipPrevious)
                controller.previous()
            } label: {
                Image(.bchPrevious)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 53, height: 53)
                    .scaleEffect(y: 0.85)
                    .playerGlyph()
            }
            .buttonStyle(.plain)
            .disabled(!controller.canPlayPrevious)
            .help("Previous")
            .accessibilityLabel("Previous track")

            Button {
                Haptics.play(controller.isPlaying ? .pause : .resume)
                controller.togglePlayPause()
            } label: {
                ZStack {
                    if controller.isBuffering {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white)
                            .frame(width: 38, height: 38)
                    } else {
                        Image(controller.isPlaying ? .bchTransportPause : .bchTransportPlay)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 74, height: 74)
                            .playerGlyph()
                    }
                }
                .frame(width: 92, height: 92)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.current == nil && !controller.isBuffering)
            .help(controller.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(controller.isBuffering ? "Buffering" : (controller.isPlaying ? "Pause" : "Play"))

            Button {
                Haptics.play(.skipNext)
                controller.next()
            } label: {
                Image(.bchNext)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 53, height: 53)
                    .scaleEffect(y: 0.85)
                    .playerGlyph()
            }
            .buttonStyle(.plain)
            .disabled(!controller.canPlayNext)
            .help("Next")
            .accessibilityLabel("Next track")
        }
        .foregroundStyle(.white)
    }

    var repeatLabel: String {
        switch controller.repeatMode {
        case .one: "Repeat one"
        case .all: "Repeat all"
        case .off: "Repeat off"
        }
    }

    var moreMenu: some View {
        Menu {
            if let current = controller.current {
                SongActionButtons(entry: current, showSleepTimer: true, showDebugLog: true)
            }
            // The output route and live pipeline have their own player control;
            // this menu follows the upstream track-action list.
            if !controller.displayedLyrics.isEmpty {
                Divider()
                Button("Lyrics Offset…") { showLyricsOffset = true }
            }
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .help("More")
    }

    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        let hours = mins / 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, mins % 60, secs)
            : String(format: "%d:%02d", mins, secs)
    }

    func nerdLine(_ nerd: NerdStatsRec) -> String {
        var parts = [nerd.codec]
        if nerd.kbps > 0 { parts.append("\(nerd.kbps) kbps") }
        if nerd.bitDepth > 0 { parts.append("\(nerd.bitDepth)-bit") }
        if nerd.sampleRate > 0 { parts.append("\(nerd.sampleRate) Hz") }
        if nerd.channels > 0 { parts.append("\(nerd.channels) ch") }
        if let current = controller.current {
            if current.isLocal {
                parts.append("Local")
            } else if current.source.hasPrefix("yt:") {
                parts.append("YouTube")
            } else if !current.source.isEmpty {
                parts.append(current.source)
            }
        }
        if controller.racingLossless { parts.append("Upgrading Quality") }
        if let gain = nerd.loudnessGainDb, gain != 0 {
            parts.append(String(format: "%+.1f dB", gain))
        }
        if let tier = controller.analysisTier, !tier.isEmpty { parts.append(tier) }
        if let sources = controller.analysisSources, !sources.isEmpty { parts.append(sources) }
        if let conf = controller.analysisConfidence { parts.append(String(format: "%.0f%% mix", conf * 100)) }
        if controller.smartMixInProgress { parts.append("Automix") }
        // Only when the transition actually cued the track somewhere other than
        // the top — which is now the minority of transitions, so a non-nil value
        // is the interesting one.
        if let cue = controller.automixCueSeconds, cue > 0.05 {
            parts.append(String(format: "in at %@", QueueEntry.formatDuration(cue)))
        }
        return parts.joined(separator: " · ")
    }
}
