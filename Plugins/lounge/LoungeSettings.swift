import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Lounge: the library, edited by hand. Apps come from a file
/// picker and websites from a validated URL field — there is no free-text
/// command field and there never will be.
struct LoungeSettingsPane: View {
    @ObservedObject var store: LoungeStore
    let removed: (LoungeEntry) -> Void
    let added: (LoungeEntry) -> Void
    @AppStorage(LoungePlugin.Key.chord) private var chordEnabled = true

    @State private var webTitle = ""
    @State private var webURL = ""
    @State private var error: String?
    /// A compose file picked but not yet added, while the user checks the
    /// title and port.
    @State private var composeFile: String?
    @State private var composeTitle = ""
    @State private var composePort = ""
    @State private var composePorts: [(service: String, port: Int)] = []
    @State private var composeKeepRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Library").font(.headline)
            List {
                ForEach(store.entries) { entry in
                    HStack {
                        if let icon = LoungeApps.icon(for: entry) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        } else if case .dockerCompose = entry.launch {
                            Image(systemName: "shippingbox").frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "globe").frame(width: 20, height: 20)
                        }
                        Text(entry.title)
                        Spacer()
                        Text(detail(entry)).foregroundStyle(.secondary).lineLimit(1)
                        if case let .dockerCompose(file, port, keepRunning) = entry.launch {
                            Toggle("Keep running", isOn: Binding(
                                get: { keepRunning },
                                set: { value in
                                    var changed = entry
                                    changed.launch = .dockerCompose(file: file, port: port, keepRunning: value)
                                    store.update(changed)
                                }))
                            .toggleStyle(.checkbox)
                            .help("Quitting in Lounge only closes the page; containers stay up.")
                        }
                        Button(role: .destructive) {
                            store.remove(entry.id)
                            removed(entry)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                .onMove { store.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 160)
            .overlay {
                if store.entries.isEmpty {
                    Text("Nothing added yet").foregroundStyle(.secondary)
                }
            }

            Button("Add App…", action: pickApp)

            HStack {
                TextField("Title", text: $webTitle).frame(width: 160)
                TextField("https://example.com", text: $webURL)
                Button("Add Website", action: addWeb)
                    .disabled(webTitle.isEmpty || webURL.isEmpty)
            }
            HStack {
                Button("Add Docker Compose Project…", action: pickCompose)
                if let composeFile {
                    TextField("Title", text: $composeTitle).frame(width: 160)
                    TextField("Port", text: $composePort).frame(width: 70)
                    if composePorts.count > 1 {
                        Menu("Ports") {
                            ForEach(composePorts, id: \.port) { item in
                                Button(item.service.isEmpty ? String(item.port) : "\(item.port) · \(item.service)") {
                                    composePort = String(item.port)
                                }
                            }
                        }
                        .fixedSize()
                    }
                    Toggle("Keep running on quit", isOn: $composeKeepRunning)
                    Button("Add", action: addCompose)
                    Button("Cancel") { self.composeFile = nil }
                    Text((composeFile as NSString).lastPathComponent).foregroundStyle(.secondary)
                }
            }
            Text("Lounge runs `docker compose -f <file> up -d`, opens localhost:<port> in its web view, "
                 + "and runs `down` when you quit it. You'll see the exact command before the first launch.")
                .font(.caption).foregroundStyle(.secondary)

            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            Divider()
            Toggle("Also open Lounge with Options + Share / Menu + View", isOn: $chordEnabled)
            Text("The controller's home button (PS / Xbox / Guide) always toggles Lounge. "
                 + "The chord is a fallback for controllers where macOS keeps the home button.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detail(_ entry: LoungeEntry) -> String {
        switch entry.launch {
        case let .app(bundleID, _): return bundleID
        case let .web(url): return url.absoluteString
        case let .dockerCompose(file, port, keepRunning):
            return "\((file as NSString).abbreviatingWithTildeInPath) · localhost:\(port)"
                + (keepRunning ? " · keeps running" : "")
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        error = nil
        for url in panel.urls {
            if store.addApp(at: url), let entry = store.entries.last {
                added(entry)
            } else {
                error = "\(LoungeApps.displayName(of: url)) couldn't be added (already in the library, or not an app)."
            }
        }
    }

    private func pickCompose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "yml"), UTType(filenameExtension: "yaml")]
            .compactMap { $0 }
        panel.message = "Choose a compose file (compose.yaml or docker-compose.yml)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard LoungeValidation.isValidComposePath(url.path) else {
            error = "That isn't a .yml or .yaml file."
            return
        }
        error = LoungeDocker.canReadProject(file: url.path) ? nil : LoungeDocker.accessHelp
        composeFile = url.path
        composeTitle = url.deletingLastPathComponent().lastPathComponent
        let yaml = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        composePorts = LoungeCompose.servicePorts(in: yaml)
        composePort = LoungeCompose.suggestedPort(in: yaml).map(String.init) ?? ""
        if composePort.isEmpty { error = "No published port found in the file. Enter the port the app serves on." }
    }

    private func addCompose() {
        guard let file = composeFile else { return }
        guard let port = Int(composePort), LoungeValidation.isValidPort(port) else {
            error = "Enter a port between 1 and 65535."
            return
        }
        let entry = LoungeEntry(title: composeTitle.trimmingCharacters(in: .whitespaces),
                                launch: .dockerCompose(file: file, port: port, keepRunning: composeKeepRunning))
        do {
            try LoungeValidation.validate(entry)
        } catch {
            self.error = "Enter a title of up to \(LoungeValidation.maxTitleLength) characters."
            return
        }
        store.add(entry)
        added(entry)
        error = nil
        composeFile = nil
    }

    private func addWeb() {
        guard let url = LoungeValidation.webURL(from: webURL) else {
            error = "Enter an http or https address."
            return
        }
        let entry = LoungeEntry(title: webTitle.trimmingCharacters(in: .whitespaces), launch: .web(url: url))
        do {
            try LoungeValidation.validate(entry)
        } catch {
            self.error = "Enter a title of up to \(LoungeValidation.maxTitleLength) characters."
            return
        }
        store.add(entry)
        added(entry)
        error = nil
        webTitle = ""
        webURL = ""
    }
}
