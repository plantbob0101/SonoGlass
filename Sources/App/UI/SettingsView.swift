import SwiftUI
import ServiceManagement
import SonosKit
import PandoraKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            PandoraSettings()
                .tabItem { Label("Pandora", systemImage: "radio") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 420)
    }
}

struct GeneralSettings: View {
    @Environment(AppState.self) private var appState
    @AppStorage("showTitleInMenuBar") private var showTitleInMenuBar = false
    @AppStorage("showMiniAtLaunch") private var showMiniAtLaunch = false
    @AppStorage("defaultRoom") private var defaultRoom = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }

            Toggle("Show track title in menu bar", isOn: $showTitleInMenuBar)
            Toggle("Show mini player at launch", isOn: $showMiniAtLaunch)

            Picker("Default room", selection: $defaultRoom) {
                Text("Last used").tag("")
                ForEach(appState.groups) { group in
                    if let room = group.coordinator?.roomName {
                        Text(room).tag(room)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

struct PandoraSettings: View {
    @Environment(AppState.self) private var appState
    @State private var email = PandoraKeychainMirror.username
    @State private var password = ""
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .textContentType(.username)
                SecureField("Password", text: $password)

                HStack {
                    Button {
                        verify()
                    } label: {
                        if busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Verify & Save")
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty || busy)

                    Spacer()

                    if appState.pandoraConfigured {
                        Button("Remove account", role: .destructive) {
                            appState.removePandoraAccount()
                            email = ""
                            password = ""
                            status = "Account removed"
                        }
                    }
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.contains("✓") ? .green : .secondary)
                }
            } footer: {
                Text("Credentials are stored in your Keychain and used for your Pandora station list. No Sonos account is required — favorites live on your speakers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ThumbsLinkSection()
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func verify() {
        busy = true
        status = "Signing in…"
        let user = email
        let pass = password
        Task {
            status = await appState.savePandoraCredentials(username: user, password: pass)
            busy = false
        }
    }
}

/// Small shim so the settings pane can prefill the stored e-mail without
/// keeping the password in memory.
enum PandoraKeychainMirror {
    static var username: String {
        PandoraKit.PandoraKeychain.load()?.username ?? ""
    }
}

/// Thumbs work through Sonos's own music-service link (SMAPI), which modern
/// Pandora-on-Sonos firmware requires — the track no longer exposes a token
/// the direct Pandora API can use. This is a one-time browser authorization.
struct ThumbsLinkSection: View {
    @Environment(AppState.self) private var appState
    @State private var status = ""
    @State private var authURL: String?

    var body: some View {
        Section {
            if appState.smapiLinked {
                HStack {
                    Label("Thumbs are linked", systemImage: "hand.thumbsup.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Unlink", role: .destructive) {
                        appState.unlinkPandoraThumbs()
                        status = ""
                        authURL = nil
                    }
                }
            } else if appState.linkInProgress, let link = appState.linkPrompt {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Open this page and sign in to Pandora to authorize SonoGlass:")
                        .font(.caption)
                    if let url = URL(string: link.regUrl) {
                        Link(destination: url) {
                            Text(link.regUrl).font(.caption)
                        }
                    }
                    if link.showLinkCode {
                        Text("Activation code: \(link.linkCode)").font(.caption.monospaced())
                    }
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to authorize…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Button {
                    startLink()
                } label: {
                    Label("Link Pandora for thumbs", systemImage: "link")
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.contains("linked") ? .green : .secondary)
                }
            }
        } header: {
            Text("Thumbs (Pandora feedback)")
        } footer: {
            Text("Thumbs up/down are sent the same way the Sonos app sends them (via the Sonos music-service link). A one-time browser sign-in authorizes SonoGlass to rate tracks on your speakers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func startLink() {
        status = "Starting…"
        Task {
            let result = await appState.beginPandoraLink()
            status = result == "linked" ? "Thumbs linked ✓" : result
        }
    }
}

struct AdvancedSettings: View {
    @Environment(AppState.self) private var appState
    @AppStorage("manualIP") private var manualIP = ""

    var body: some View {
        Form {
            Section("Discovery") {
                HStack {
                    TextField("Speaker IP (manual fallback)", text: $manualIP, prompt: Text("192.168.1.42"))
                    Button("Connect") { appState.retryDiscovery() }
                        .disabled(manualIP.isEmpty)
                }
            }
            Section("Status") {
                LabeledContent("Speakers") {
                    Text("\(appState.groups.reduce(0) { $0 + $1.members.count }) in \(appState.groups.count) group(s)")
                }
                LabeledContent("Live updates") {
                    Text(appState.eventsHealthy ? "UPnP events" : "Polling (1 s)")
                        .foregroundStyle(appState.eventsHealthy ? .green : .orange)
                }
                LabeledContent("Connection") {
                    Text(appState.reachable ? "OK" : "Reconnecting…")
                        .foregroundStyle(appState.reachable ? .green : .orange)
                }
                Button("Copy diagnostics") { appState.copyDiagnostics() }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("SonoGlass").font(.title2.weight(.semibold))
            Text("Version 1.0")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Local control via UPnP; Pandora feedback via Pandora's JSON API.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}
