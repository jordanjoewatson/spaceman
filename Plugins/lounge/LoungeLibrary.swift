import Foundation

/// How a library entry starts. A closed set on purpose.
///
/// **Hard rule: no free-text commands and no shell, ever.** Every case is a
/// fixed launch type whose fields are filled in through pickers and validated
/// fields. Future process-backed types (Steam, Docker) will run through
/// `Process` with a fixed executable and a fixed argument array built from
/// validated values — never `/bin/sh -c`, never a user-typed command line.
///
/// Planned cases, not implemented yet (adding one means a new case here, its
/// `type` tag, validation, and a launcher):
/// - `steam(appID: Int)` — `steam://rungameid/<appID>`.
/// - `dockerImage(image: String, port: Int)` — validated image reference.
public enum LoungeLaunch: Equatable, Sendable {
    /// A chosen `.app`, opened by bundle ID. `path` is where it was picked
    /// from, used only to find it again if LaunchServices forgets it.
    case app(bundleID: String, path: String?)
    /// A page opened in Lounge's own fullscreen web view, so the controller
    /// and home button keep working.
    case web(url: URL)
    /// A Docker Compose project: `docker compose -f <file> up -d`, wait for
    /// `port`, show `http://localhost:<port>` in Lounge's web view, and
    /// `docker compose -f <file> down` on quit — unless `keepRunning`, for a
    /// stack you also use outside Lounge, where quitting only closes the page.
    /// `file` is an absolute path chosen with a file picker.
    case dockerCompose(file: String, port: Int, keepRunning: Bool = false)

    /// The tag stored in JSON.
    public var type: String {
        switch self {
        case .app: return "app"
        case .web: return "web"
        case .dockerCompose: return "dockerCompose"
        }
    }
}

extension LoungeLaunch: Codable {
    private enum CodingKeys: String, CodingKey { case type, bundleID, path, url, file, port, keepRunning }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "app":
            self = .app(bundleID: try c.decode(String.self, forKey: .bundleID),
                        path: try c.decodeIfPresent(String.self, forKey: .path))
        case "web":
            self = .web(url: try c.decode(URL.self, forKey: .url))
        case "dockerCompose":
            self = .dockerCompose(file: try c.decode(String.self, forKey: .file),
                                  port: try c.decode(Int.self, forKey: .port),
                                  keepRunning: try c.decodeIfPresent(Bool.self, forKey: .keepRunning) ?? false)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "Unknown launch type '\(other)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case let .app(bundleID, path):
            try c.encode(bundleID, forKey: .bundleID)
            try c.encodeIfPresent(path, forKey: .path)
        case let .web(url):
            try c.encode(url, forKey: .url)
        case let .dockerCompose(file, port, keepRunning):
            try c.encode(file, forKey: .file)
            try c.encode(port, forKey: .port)
            try c.encode(keepRunning, forKey: .keepRunning)
        }
    }
}

public struct LoungeEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var launch: LoungeLaunch

    public init(id: UUID = UUID(), title: String, launch: LoungeLaunch) {
        self.id = id
        self.title = title
        self.launch = launch
    }

    /// The bundle ID for app entries, nil otherwise.
    public var bundleID: String? {
        if case let .app(bundleID, _) = launch { return bundleID }
        return nil
    }
}

public enum LoungeValidationError: Error, Equatable {
    case emptyTitle
    case titleTooLong
    case invalidBundleID
    case invalidURL
    case invalidComposeFile
    case invalidPort
}

public enum LoungeValidation {
    public static let maxTitleLength = 80

    public static func validate(_ entry: LoungeEntry) throws {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LoungeValidationError.emptyTitle }
        guard title.count <= maxTitleLength else { throw LoungeValidationError.titleTooLong }
        switch entry.launch {
        case let .app(bundleID, _):
            guard isValidBundleID(bundleID) else { throw LoungeValidationError.invalidBundleID }
        case let .web(url):
            guard isValidWebURL(url) else { throw LoungeValidationError.invalidURL }
        case let .dockerCompose(file, port, _):
            guard isValidComposePath(file) else { throw LoungeValidationError.invalidComposeFile }
            guard isValidPort(port) else { throw LoungeValidationError.invalidPort }
        }
    }

    /// An absolute path to a `.yml` / `.yaml` file, with no control
    /// characters. It is passed to `docker` as a single argument, never
    /// through a shell, so spaces and quotes are harmless.
    public static func isValidComposePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains(".."),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "yml" || ext == "yaml"
    }

    public static func isValidPort(_ port: Int) -> Bool { (1...65535).contains(port) }

    /// Reverse-DNS characters only: letters, digits, `-` and `.`, at least two
    /// components, no empty component.
    public static func isValidBundleID(_ id: String) -> Bool {
        guard id.count <= 255 else { return false }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// http or https with a host. Nothing else (no `file:`, `javascript:`,
    /// custom schemes) can reach the web view.
    public static func isValidWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// Parses what a user typed into the URL field, adding `https://` when no
    /// scheme was given. Returns nil unless the result is valid.
    public static func webURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), isValidWebURL(url) else { return nil }
        return url
    }
}

/// The library file: `library.json` in the plugin's data directory.
public struct LoungeLibrary: Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var entries: [LoungeEntry]

    public init(entries: [LoungeEntry] = []) {
        self.version = Self.currentVersion
        self.entries = entries
    }
}

extension LoungeLibrary: Codable {
    private enum CodingKeys: String, CodingKey { case version, entries }

    /// Lossy per entry: an entry that fails to decode or validate (say, a
    /// launch type from a newer version) is dropped rather than losing the
    /// whole library.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        let raw = try c.decodeIfPresent([Lossy].self, forKey: .entries) ?? []
        entries = raw.compactMap(\.entry).filter { (try? LoungeValidation.validate($0)) != nil }
    }

    private struct Lossy: Decodable {
        let entry: LoungeEntry?
        init(from decoder: Decoder) throws { entry = try? LoungeEntry(from: decoder) }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// A missing, corrupt or too-new file reads as nil; the caller decides
    /// whether that means "empty" or "leave the file alone".
    public static func decode(_ data: Data) -> LoungeLibrary? {
        guard let library = try? JSONDecoder().decode(LoungeLibrary.self, from: data),
              library.version <= currentVersion else { return nil }
        return library
    }
}

/// Reads the published host ports out of a compose file, without a YAML
/// parser: good enough to suggest a port, which the user can then edit.
public enum LoungeCompose {

    /// Host ports from `ports:` entries, in file order. Handles the short
    /// syntax (`"8080:80"`, `127.0.0.1:8080:80`, `8080:80/tcp`, `"3000"`) and
    /// the long syntax's `published: 8080`.
    /// Ports dev servers usually serve a web UI on, best first.
    static let webPorts = [5173, 3000, 8080, 8000, 4200, 5000, 4173, 8888, 80]

    /// The published port most likely to be the web UI: a well-known dev
    /// server port if there is one (so Kafka's 9092 doesn't win just by being
    /// listed first), otherwise the first.
    public static func suggestedPort(in yaml: String) -> Int? {
        let ports = publishedPorts(in: yaml)
        return webPorts.first(where: ports.contains) ?? ports.first
    }

    public static func publishedPorts(in yaml: String) -> [Int] {
        servicePorts(in: yaml).map(\.port)
    }

    /// Published host ports with the service that publishes each, for
    /// labelling the choices ("5173 · web", "9092 · kafka").
    public static func servicePorts(in yaml: String) -> [(service: String, port: Int)] {
        var result: [(service: String, port: Int)] = []
        var service = ""
        var serviceIndent: Int?
        var inPorts = false
        var portsIndent = 0
        for raw in yaml.components(separatedBy: .newlines) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indent = line.prefix { $0 == " " }.count
            // A service is a key one level under `services:`.
            if trimmed == "services:" { serviceIndent = nil; inPorts = false; continue }
            if trimmed.hasSuffix(":"), !trimmed.hasPrefix("-"), !inPorts || indent <= portsIndent {
                if serviceIndent == nil, indent > 0 { serviceIndent = indent }
                if indent == serviceIndent { service = String(trimmed.dropLast()) }
            }
            if trimmed.hasPrefix("ports:") {
                inPorts = true
                portsIndent = indent
                continue
            }
            if inPorts && indent <= portsIndent { inPorts = false }
            guard inPorts else { continue }
            var value = trimmed
            if value.hasPrefix("- ") { value.removeFirst(2) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if value.hasPrefix("published:") {
                value = String(value.dropFirst("published:".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if let port = Int(value), LoungeValidation.isValidPort(port) { result.append((service, port)) }
                continue
            }
            guard !value.contains(" ") else { continue }
            let mapping = value.split(separator: "/").first.map(String.init) ?? value
            let parts = mapping.split(separator: ":").map(String.init)
            // host:container or ip:host:container → host is second to last;
            // a bare port publishes the same number.
            let host = parts.count >= 2 ? parts[parts.count - 2] : parts.first
            // A range ("8000-8005") suggests its first port.
            if let host, let port = Int(host.split(separator: "-").first ?? ""),
               LoungeValidation.isValidPort(port) {
                result.append((service, port))
            }
        }
        return result
    }
}
