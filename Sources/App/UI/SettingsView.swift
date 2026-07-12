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
                Text("Credentials are stored in your Keychain and used only for Pandora thumbs and your station list. No Sonos account is required — favorites live on your speakers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
