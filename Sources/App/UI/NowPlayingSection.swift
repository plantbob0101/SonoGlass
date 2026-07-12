import SwiftUI
import SonosKit

struct NowPlayingSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            nowPlayingCard
            if appState.isPandoraNow {
                ThumbsRow()
            } else if appState.isAppleMusicNow {
                FavoriteRow()
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
                    MarqueeText(text: appState.nowPlaying.title,
                                font: .system(size: 14, weight: .semibold))
                    if !appState.nowPlaying.artist.isEmpty {
                        MarqueeText(text: appState.nowPlaying.artist,
                                    font: .system(size: 12))
                            .foregroundStyle(.secondary)
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
        HStack(spacing: 30) {
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
            .opacity(enabled ? 1 : 0.5)

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
            .opacity(enabled ? 1 : 0.5)

            // The "I *really* like this" escape hatches.
            VStack(spacing: 6) {
                Button {
                    appState.findCurrentInAppleMusic()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 13))
                        .frame(width: 26, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Find this song in Apple Music")
                .accessibilityLabel("Find in Apple Music")

                Button {
                    appState.openPandoraSongPage()
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 13))
                        .frame(width: 26, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Open this song on pandora.com")
                .accessibilityLabel("Open on pandora.com")
            }
        }
    }
}

struct FavoriteRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let favorite = appState.currentFavorite == true
        HStack(spacing: 24) {
            Button {
                appState.toggleFavorite()
            } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 20))
                    .foregroundStyle(favorite ? .yellow : .primary)
                    .frame(width: 44, height: 32)
            }
            .buttonStyle(.glass)
            .help(favorite ? "Remove Favorite from Apple Music" : "Favorite on Apple Music")
            .accessibilityLabel("Favorite on Apple Music")

            Button {
                appState.openInAppleMusic()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 32)
            }
            .buttonStyle(.glass)
            .help("Open this song in Apple Music")
            .accessibilityLabel("Open in Apple Music")
        }
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
        VStack(spacing: 6) {
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

            // Per-room trim when more than one room is grouped.
            if let group = appState.selectedGroup, group.members.count > 1 {
                ForEach(group.members.sorted {
                    $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
                }) { member in
                    HStack(spacing: 10) {
                        Text(member.roomName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 92, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { Double(appState.memberVolumes[member.udn] ?? 0) },
                                set: { appState.memberVolumeChanged(member, to: $0) }
                            ),
                            in: 0...100,
                            onEditingChanged: { editing in
                                if !editing { appState.memberVolumeCommitted(member) }
                            }
                        )
                        .controlSize(.mini)
                        .accessibilityLabel("\(member.roomName) volume")
                        Text("\(appState.memberVolumes[member.udn] ?? 0)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 26, alignment: .trailing)
                    }
                }
            }
        }
    }
}

struct GroupPickerRow: View {
    @Environment(AppState.self) private var appState
    @State private var editingGroup = false

    var body: some View {
        HStack(spacing: 10) {
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

            Button {
                editingGroup.toggle()
            } label: {
                Image(systemName: "plus.square.on.square")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Add or remove rooms from this group")
            .accessibilityLabel("Edit group rooms")
            .popover(isPresented: $editingGroup, arrowEdge: .bottom) {
                GroupEditor()
                    .environment(appState)
            }
        }
    }
}

/// Checkbox-per-room editor: check to pull a room into the current group,
/// uncheck to split it out as its own room.
struct GroupEditor: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let members = appState.selectedGroupMemberUDNs
        VStack(alignment: .leading, spacing: 8) {
            Text("Rooms in “\(appState.selectedGroup?.displayName ?? "group")”")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(appState.allRooms) { room in
                let isMember = members.contains(room.udn)
                let isLastMember = isMember && members.count == 1
                Toggle(isOn: Binding(
                    get: { isMember },
                    set: { appState.setRoom(room, grouped: $0) }
                )) {
                    Text(room.roomName)
                        .font(.callout)
                }
                .toggleStyle(.checkbox)
                .disabled(isLastMember)
                .help(isLastMember ? "A group needs at least one room" : "")
            }
        }
        .padding(14)
        .frame(minWidth: 200)
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
