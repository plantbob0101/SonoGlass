import SwiftUI
import SonosKit

struct NowPlayingSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            nowPlayingCard
            if appState.isPandoraNow {
                ThumbsRow()
            }
            TransportRow()
            VolumeRow()
            GroupPickerRow()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var nowPlayingCard: some View {
        HStack(spacing: 12) {
            ArtworkView(url: appState.nowPlaying.artURL, size: 84, cornerRadius: 12)
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.option) {
                        appState.copyDebugURIs()
                    }
                }
                .accessibilityLabel("Album artwork. Option-click to copy raw URIs.")

            VStack(alignment: .leading, spacing: 3) {
                if appState.nowPlaying.title.isEmpty {
                    Text("Nothing playing")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text(appState.nowPlaying.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    if !appState.nowPlaying.artist.isEmpty {
                        Text(appState.nowPlaying.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if !appState.nowPlaying.relTime.isEmpty,
                       appState.nowPlaying.duration != "0:00:00",
                       !appState.nowPlaying.duration.isEmpty {
                        Text("\(trim(appState.nowPlaying.relTime)) / \(trim(appState.nowPlaying.duration))")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var subtitle: String {
        let station = appState.nowPlaying.stationName
        let album = appState.nowPlaying.album
        if !station.isEmpty { return station }
        return album
    }

    private func trim(_ time: String) -> String {
        time.hasPrefix("0:") ? String(time.dropFirst(2)) : time
    }
}

struct ThumbsRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let thumb = appState.currentThumb
        let enabled = appState.thumbsAvailable
        let hint = "Thumbs need a playing Pandora track"
        HStack(spacing: 44) {
            Button {
                appState.thumbsDown()
            } label: {
                Image(systemName: thumb == false ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 32)
            }
            .buttonStyle(.glass)
            .disabled(!enabled)
            .help(enabled ? "Thumbs down (skips track)" : hint)
            .accessibilityLabel("Thumbs down")

            Button {
                appState.thumbsUp()
            } label: {
                Image(systemName: thumb == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 32)
            }
            .buttonStyle(.glass)
            .disabled(!enabled)
            .help(enabled ? "Thumbs up" : hint)
            .accessibilityLabel("Thumbs up")
        }
        .opacity(enabled ? 1 : 0.5)
    }
}

struct TransportRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 28) {
            // Pandora radio can't rewind — hide Previous while it plays.
            if !appState.isPandoraNow {
                Button {
                    appState.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 16))
                        .frame(width: 36, height: 30)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Previous track")
            }

            Button {
                appState.togglePlayPause()
            } label: {
                Image(systemName: appState.nowPlaying.transport.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .frame(width: 54, height: 40)
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel(appState.nowPlaying.transport.isPlaying ? "Pause" : "Play")

            Button {
                appState.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16))
                    .frame(width: 36, height: 30)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Skip")
        }
    }
}

struct VolumeRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        HStack(spacing: 10) {
            Button {
                appState.toggleMute()
            } label: {
                Image(systemName: appState.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 22)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(appState.muted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { state.volume },
                    set: { appState.volumeChanged($0) }
                ),
                in: 0...100,
                onEditingChanged: { editing in
                    if !editing { appState.volumeCommitted() }
                }
            )
            .accessibilityLabel("Volume")

            Text("\(Int(appState.volume))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

struct GroupPickerRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Menu {
            ForEach(appState.groups) { group in
                Button {
                    appState.selectGroup(group.id)
                } label: {
                    if group.id == appState.selectedGroupID {
                        Label(group.displayName, systemImage: "checkmark")
                    } else {
                        Text(group.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: (appState.selectedGroup?.members.count ?? 1) > 1
                      ? "hifispeaker.2.fill" : "hifispeaker.fill")
                    .font(.caption)
                Text(appState.selectedGroup?.displayName ?? "No room")
                    .font(.callout)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Speaker group")
    }
}

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.34))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
