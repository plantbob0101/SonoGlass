import SwiftUI
import SonosKit
import PandoraKit

@main
struct SonoGlassVisionApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            VisionRootView()
                .environment(appState)
        }
        .defaultSize(width: 460, height: 620)
    }
}

struct VisionRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 0) {
            if appState.groups.isEmpty {
                emptyState
            } else {
                Picker("View", selection: $state.tab) {
                    ForEach(availableTabs, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

                switch appState.tab {
                case .nowPlaying:
                    VisionNowPlaying()
                case .favorites:
                    VisionBrowseList(items: .favorites)
                case .stations:
                    VisionBrowseList(items: .stations)
                }
                Spacer(minLength: 0)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = appState.toast {
                Text(toast)
                    .font(.caption)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 18)
            }
        }
        .onAppear { appState.popoverOpened() }
    }

    private var availableTabs: [PopoverTab] {
        appState.pandoraConfigured ? PopoverTab.allCases : [.nowPlaying, .favorites]
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            switch appState.discovery {
            case .searching, .idle:
                ProgressView()
                Text("Searching for Sonos…").foregroundStyle(.secondary)
            default:
                Image(systemName: "hifispeaker.slash").font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No speakers found").font(.headline)
                Text("Allow Local Network access in Settings → Privacy, or enter a speaker IP below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ManualIPField()
                Button("Retry") { appState.retryDiscovery() }
            }
            Spacer()
        }
        .padding(30)
    }
}

/// visionOS has no Settings scene wired up yet, so the manual-IP bootstrap
/// lives right in the empty state.
struct ManualIPField: View {
    @Environment(AppState.self) private var appState
    @AppStorage("manualIP") private var manualIP = ""

    var body: some View {
        HStack {
            TextField("Speaker IP (e.g. 192.168.1.10)", text: $manualIP)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            Button("Connect") { appState.retryDiscovery() }
                .disabled(manualIP.isEmpty)
        }
    }
}

struct VisionNowPlaying: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 16) {
            // Art + track info
            VStack(spacing: 12) {
                AsyncImage(url: appState.nowPlaying.artURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        ZStack {
                            Rectangle().fill(.quaternary)
                            Image(systemName: "music.note")
                                .font(.system(size: 50))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(spacing: 3) {
                    MarqueeText(
                        text: appState.nowPlaying.title.isEmpty ? "Nothing playing" : appState.nowPlaying.title,
                        font: .title3.weight(.semibold)
                    )
                    MarqueeText(text: appState.nowPlaying.artist, font: .body)
                        .foregroundStyle(.secondary)
                    if !appState.nowPlaying.stationName.isEmpty {
                        Text(appState.nowPlaying.stationName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: 320)
            }

            // Ratings / funnel row
            if appState.isPandoraNow {
                HStack(spacing: 18) {
                    ratingButton(appState.currentThumb == false ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                                 "Thumbs down") { appState.thumbsDown() }
                    ratingButton(appState.currentThumb == true ? "hand.thumbsup.fill" : "hand.thumbsup",
                                 "Thumbs up") { appState.thumbsUp() }
                    ratingButton("arrow.up.forward.app", "Find in Apple Music") {
                        appState.findCurrentInAppleMusic()
                    }
                    ratingButton("globe", "Open on pandora.com") { appState.openPandoraSongPage() }
                }
            } else if appState.isAppleMusicNow {
                HStack(spacing: 18) {
                    ratingButton(appState.currentFavorite == true ? "star.fill" : "star",
                                 "Favorite on Apple Music") { appState.toggleFavorite() }
                    ratingButton("arrow.up.forward.app", "Open in Apple Music") {
                        appState.openInAppleMusic()
                    }
                }
            }

            // Transport
            HStack(spacing: 26) {
                if !appState.isPandoraNow {
                    Button { appState.previous() } label: {
                        Image(systemName: "backward.fill")
                    }
                    .buttonStyle(.borderless)
                }
                Button { appState.togglePlayPause() } label: {
                    Image(systemName: appState.nowPlaying.transport.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                Button { appState.next() } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.borderless)
            }

            VisionVolume()
            VisionGroupPicker()
        }
        .padding(.horizontal, 24)
    }

    private func ratingButton(_ symbol: String, _ label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.bordered)
        .clipShape(Circle())
        .help(label)
        .accessibilityLabel(label)
    }
}

struct VisionVolume: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { appState.toggleMute() } label: {
                    Image(systemName: appState.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)
                Slider(
                    value: Binding(get: { state.volume }, set: { appState.volumeChanged($0) }),
                    in: 0...100,
                    onEditingChanged: { if !$0 { appState.volumeCommitted() } }
                )
                Text("\(Int(appState.volume))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
            if let group = appState.selectedGroup, group.members.count > 1 {
                ForEach(group.members.sorted {
                    $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
                }) { member in
                    HStack(spacing: 12) {
                        Text(member.roomName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                            .lineLimit(1)
                        Slider(
                            value: Binding(
                                get: { Double(appState.memberVolumes[member.udn] ?? 0) },
                                set: { appState.memberVolumeChanged(member, to: $0) }
                            ),
                            in: 0...100,
                            onEditingChanged: { if !$0 { appState.memberVolumeCommitted(member) } }
                        )
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

struct VisionGroupPicker: View {
    @Environment(AppState.self) private var appState
    @State private var editingGroup = false

    var body: some View {
        HStack(spacing: 12) {
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
                Label(appState.selectedGroup?.displayName ?? "No room",
                      systemImage: (appState.selectedGroup?.members.count ?? 1) > 1
                          ? "hifispeaker.2.fill" : "hifispeaker.fill")
            }

            Button {
                editingGroup.toggle()
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $editingGroup) {
                VisionGroupEditor()
                    .environment(appState)
            }
        }
    }
}

struct VisionGroupEditor: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let members = appState.selectedGroupMemberUDNs
        VStack(alignment: .leading, spacing: 10) {
            Text("Rooms in “\(appState.selectedGroup?.displayName ?? "group")”")
                .font(.headline)
            ForEach(appState.allRooms) { room in
                let isMember = members.contains(room.udn)
                Toggle(room.roomName, isOn: Binding(
                    get: { isMember },
                    set: { appState.setRoom(room, grouped: $0) }
                ))
                .disabled(isMember && members.count == 1)
            }
        }
        .padding(20)
        .frame(minWidth: 260)
    }
}

enum VisionBrowseKind { case favorites, stations }

struct VisionBrowseList: View {
    @Environment(AppState.self) private var appState
    let items: VisionBrowseKind

    var body: some View {
        List {
            switch items {
            case .favorites:
                ForEach(appState.favorites) { item in
                    row(title: item.title,
                        subtitle: item.description.isEmpty ? item.artist : item.description,
                        artURL: item.artURL(via: appState.coordinatorIP ?? "")) {
                        appState.play(favorite: item)
                    }
                }
                if !appState.playlists.isEmpty {
                    Section("Sonos Playlists") {
                        ForEach(appState.playlists) { item in
                            row(title: item.title, subtitle: "Sonos Playlist",
                                artURL: item.artURL(via: appState.coordinatorIP ?? "")) {
                                appState.play(favorite: item)
                            }
                        }
                    }
                }
            case .stations:
                ForEach(appState.stations) { station in
                    row(title: station.stationName, subtitle: "Pandora Station",
                        artURL: station.artUrl.flatMap(URL.init(string:))) {
                        appState.play(station: station)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(title: String, subtitle: String, artURL: URL?,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AsyncImage(url: artURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        ZStack {
                            Rectangle().fill(.quaternary)
                            Image(systemName: "music.note").font(.caption)
                        }
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}
