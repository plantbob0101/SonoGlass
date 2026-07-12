import SwiftUI
import SonosKit
import PandoraKit

struct FavoritesSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if appState.favorites.isEmpty && appState.playlists.isEmpty {
                    Text("No Sonos Favorites yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ForEach(appState.favorites) { item in
                        BrowseRow(
                            title: item.title,
                            subtitle: item.description.isEmpty ? item.artist : item.description,
                            artURL: item.artURL(via: appState.coordinatorIP ?? "")
                        ) {
                            appState.play(favorite: item)
                        }
                    }

                    if !appState.playlists.isEmpty {
                        Text("Sonos Playlists")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                            .padding(.horizontal, 6)
                        ForEach(appState.playlists) { item in
                            BrowseRow(
                                title: item.title,
                                subtitle: "Sonos Playlist",
                                artURL: item.artURL(via: appState.coordinatorIP ?? ""),
                                fallbackSymbol: "music.note.list"
                            ) {
                                appState.play(favorite: item)
                            }
                        }
                    }

                    if !appState.services.isEmpty {
                        servicesRow
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .frame(height: 320)
    }

    private var servicesRow: some View {
        let names = Set(appState.favorites.compactMap { fav -> String? in
            guard let sid = SonosURI.queryParam("sid", in: fav.res), let id = Int(sid) else { return nil }
            return appState.services.first { $0.id == id }?.name
        })
        return VStack(alignment: .leading, spacing: 2) {
            Text("Your services")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(names.isEmpty ? "—" : names.sorted().joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.horizontal, 6)
        .padding(.top, 12)
    }
}

struct StationsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if appState.stations.isEmpty {
                    Text("Loading Pandora stations…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ForEach(appState.stations) { station in
                        BrowseRow(
                            title: station.stationName,
                            subtitle: "Pandora Station",
                            artURL: station.artUrl.flatMap(URL.init(string:)),
                            fallbackSymbol: "radio"
                        ) {
                            appState.play(station: station)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .frame(height: 320)
    }
}

struct BrowseRow: View {
    let title: String
    let subtitle: String
    let artURL: URL?
    var fallbackSymbol: String = "music.note"
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AsyncImage(url: artURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        ZStack {
                            Rectangle().fill(.quaternary)
                            Image(systemName: fallbackSymbol)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if hovering {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .accessibilityLabel("Play \(title)")
    }
}
