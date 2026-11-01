import Testing
import Foundation
@testable import LoungePlugin

@Suite("Lounge library")
struct LoungeLibraryTests {

    private let app = LoungeEntry(title: "Celeste",
                                  launch: .app(bundleID: "com.example.celeste", path: "/Applications/Celeste.app"))
    private let web = LoungeEntry(title: "Arcade", launch: .web(url: URL(string: "https://arcade.example.com")!))

    @Test("round-trips entries, order and version")
    func roundTrip() throws {
        let library = LoungeLibrary(entries: [app, web])
        let decoded = LoungeLibrary.decode(try library.encoded())
        #expect(decoded == library)
        #expect(decoded?.version == LoungeLibrary.currentVersion)
    }

    @Test("encodes launch type as a tagged object")
    func schemaShape() throws {
        let data = try LoungeLibrary(entries: [app, web]).encoded()
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        let entries = try #require(json["entries"] as? [[String: Any]])
        let first = try #require(entries[0]["launch"] as? [String: Any])
        #expect(first["type"] as? String == "app")
        #expect(first["bundleID"] as? String == "com.example.celeste")
        let second = try #require(entries[1]["launch"] as? [String: Any])
        #expect(second["type"] as? String == "web")
        #expect(second["url"] as? String == "https://arcade.example.com")
    }

    @Test("decodes a hand-written v1 file")
    func decodesFixture() throws {
        let json = """
        {"version": 1, "entries": [
          {"id": "6F1C2C1E-0000-4000-8000-000000000001", "title": "Game",
           "launch": {"type": "app", "bundleID": "com.example.game"}}
        ]}
        """
        let library = try #require(LoungeLibrary.decode(Data(json.utf8)))
        #expect(library.entries.count == 1)
        #expect(library.entries[0].launch == .app(bundleID: "com.example.game", path: nil))
    }

    @Test("drops entries with unknown launch types or invalid fields, keeps the rest")
    func lossyEntries() throws {
        let json = """
        {"version": 1, "entries": [
          {"id": "6F1C2C1E-0000-4000-8000-000000000001", "title": "Shell",
           "launch": {"type": "command", "command": "rm -rf ~"}},
          {"id": "6F1C2C1E-0000-4000-8000-000000000002", "title": "Bad",
           "launch": {"type": "web", "url": "file:///etc/passwd"}},
          {"id": "6F1C2C1E-0000-4000-8000-000000000003", "title": "Good",
           "launch": {"type": "web", "url": "https://example.com"}}
        ]}
        """
        let library = try #require(LoungeLibrary.decode(Data(json.utf8)))
        #expect(library.entries.map(\.title) == ["Good"])
    }

    @Test("rejects a newer version and corrupt data")
    func rejectsUnreadable() {
        #expect(LoungeLibrary.decode(Data(#"{"version": 99, "entries": []}"#.utf8)) == nil)
        #expect(LoungeLibrary.decode(Data("not json".utf8)) == nil)
    }

    @Test("validates titles")
    func titles() {
        #expect(throws: LoungeValidationError.emptyTitle) {
            try LoungeValidation.validate(LoungeEntry(title: "  ", launch: web.launch))
        }
        #expect(throws: LoungeValidationError.titleTooLong) {
            try LoungeValidation.validate(LoungeEntry(title: String(repeating: "x", count: 81), launch: web.launch))
        }
        #expect(throws: Never.self) { try LoungeValidation.validate(app) }
    }

    @Test("validates bundle IDs", arguments: [
        ("com.example.game", true), ("com.example-co.Game2", true),
        ("game", false), ("com..game", false), ("com.example.game; rm", false),
        ("com.example/game", false), ("", false),
    ])
    func bundleIDs(id: String, valid: Bool) {
        #expect(LoungeValidation.isValidBundleID(id) == valid)
    }

    @Test("accepts only http(s) URLs with a host")
    func urls() {
        #expect(LoungeValidation.webURL(from: "example.com")?.absoluteString == "https://example.com")
        #expect(LoungeValidation.webURL(from: " http://localhost:8080 ") != nil)
        #expect(LoungeValidation.webURL(from: "javascript:alert(1)") == nil)
        #expect(LoungeValidation.webURL(from: "file:///etc/passwd") == nil)
        #expect(LoungeValidation.webURL(from: "steam://run/1") == nil)
        #expect(LoungeValidation.webURL(from: "two words") == nil)
        #expect(LoungeValidation.webURL(from: "") == nil)
    }

    @Test("game category detection")
    func gameCategories() {
        #expect(LoungeApps.isGameCategory("public.app-category.games"))
        #expect(LoungeApps.isGameCategory("public.app-category.action-games"))
        #expect(!LoungeApps.isGameCategory("public.app-category.productivity"))
        #expect(!LoungeApps.isGameCategory(nil))
    }

    @MainActor
    @Test("store persists, rejects duplicates and invalid entries, and reorders")
    func store() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = LoungeStore(directory: dir)
        #expect(first.entries.isEmpty)
        #expect(first.add(app))
        #expect(!first.add(LoungeEntry(title: "Again", launch: app.launch)))
        #expect(!first.add(LoungeEntry(title: "", launch: web.launch)))
        #expect(first.add(web))
        first.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        let second = LoungeStore(directory: dir)
        #expect(second.entries == [web, app])
        second.remove(web.id)
        #expect(LoungeStore(directory: dir).entries == [app])
    }

    @MainActor
    @Test("an unreadable file is never overwritten")
    func keepsUnreadableFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("library.json")
        let future = Data(#"{"version": 2, "entries": []}"#.utf8)
        try future.write(to: file)

        let store = LoungeStore(directory: dir)
        store.add(app)
        #expect(try Data(contentsOf: file) == future)
    }
}

@Suite("Lounge HID home button")
struct LoungeHIDHomeTests {
    @Test("PS bit position per Sony controller and report layout")
    func psByte() {
        #expect(LoungeHIDHome.psByteIndex(product: 0x0CE6, reportID: 0x01) == 10)
        #expect(LoungeHIDHome.psByteIndex(product: 0x0CE6, reportID: 0x31) == 11)
        #expect(LoungeHIDHome.psByteIndex(product: 0x09CC, reportID: 0x11) == 9)
        #expect(LoungeHIDHome.psByteIndex(product: 0x0CE6, reportID: 0x02) == nil)
        #expect(LoungeHIDHome.psByteIndex(product: 0x1234, reportID: 0x01) == nil)
    }
}

@Suite("Lounge Docker Compose")
struct LoungeComposeTests {

    private let entry = LoungeEntry(title: "Game jam",
                                    launch: .dockerCompose(file: "/Users/me/My Project/compose.yaml", port: 8080))

    @Test("round-trips with its own type tag")
    func roundTrip() throws {
        let library = LoungeLibrary(entries: [entry])
        let data = try library.encoded()
        #expect(LoungeLibrary.decode(data) == library)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let launch = try #require((json["entries"] as? [[String: Any]])?.first?["launch"] as? [String: Any])
        #expect(launch["type"] as? String == "dockerCompose")
        #expect(launch["file"] as? String == "/Users/me/My Project/compose.yaml")
        #expect(launch["port"] as? Int == 8080)
    }

    @Test("validates the file path and port")
    func validation() {
        #expect(LoungeValidation.isValidComposePath("/a/compose.yaml"))
        #expect(LoungeValidation.isValidComposePath("/a b/docker-compose.YML"))
        #expect(!LoungeValidation.isValidComposePath("compose.yaml"))
        #expect(!LoungeValidation.isValidComposePath("/a/../etc/compose.yaml"))
        #expect(!LoungeValidation.isValidComposePath("/a/Dockerfile"))
        #expect(!LoungeValidation.isValidComposePath("/a/x\n.yaml"))
        #expect(throws: LoungeValidationError.invalidPort) {
            try LoungeValidation.validate(LoungeEntry(title: "x", launch: .dockerCompose(file: "/a/c.yml", port: 0)))
        }
        #expect(throws: LoungeValidationError.invalidPort) {
            try LoungeValidation.validate(LoungeEntry(title: "x", launch: .dockerCompose(file: "/a/c.yml", port: 70000)))
        }
    }

    @Test("detects published ports")
    func ports() {
        let yaml = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"   # site
              - 127.0.0.1:3001:3000
              - 9000-9005:9000-9005/tcp
              - "5173"
            environment:
              - "PORT=1234"
          api:
            ports:
              - target: 80
                published: 4000
        """
        #expect(LoungeCompose.publishedPorts(in: yaml) == [8080, 3001, 9000, 5173, 4000])
        #expect(LoungeCompose.publishedPorts(in: "services:\n  a:\n    image: x\n").isEmpty)
    }

    @Test("passes the file as a single argument, no shell")
    func arguments() {
        let file = "/Users/me/My Project/compose.yaml"
        #expect(LoungeDocker.arguments(file: file, .up) == ["compose", "-f", file, "up", "-d"])
        #expect(LoungeDocker.arguments(file: file, .down) == ["compose", "-f", file, "down"])
        #expect(LoungeDocker.commandLine(file: file, .up)
                == #"docker compose -f "/Users/me/My Project/compose.yaml" up -d"#)
    }

    @Test("approval is per entry and per command")
    func approval() throws {
        let suite = "com.spaceman.tests.lounge.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!LoungeLaunchApproval.isApproved(entry, defaults: defaults))
        LoungeLaunchApproval.approve(entry, defaults: defaults)
        #expect(LoungeLaunchApproval.isApproved(entry, defaults: defaults))

        var moved = entry
        moved.launch = .dockerCompose(file: "/other/compose.yaml", port: 8080)
        #expect(!LoungeLaunchApproval.isApproved(moved, defaults: defaults))

        let web = LoungeEntry(title: "w", launch: .web(url: URL(string: "https://a.example")!))
        #expect(LoungeLaunchApproval.isApproved(web, defaults: defaults))
    }
}

@Suite("Lounge compose port suggestion")
struct LoungeComposePortTests {
    @Test("prefers a web dev port over whatever is listed first")
    func prefersWeb() {
        let yaml = """
        services:
          kafka:
            ports:
              - "9092:9092"
          postgres:
            ports:
              - "5433:5432"
          web:
            ports:
              - "5173:5173"
        """
        #expect(LoungeCompose.suggestedPort(in: yaml) == 5173)
        #expect(LoungeCompose.suggestedPort(in: "services:\n  a:\n    ports:\n      - \"9999:1\"\n") == 9999)
        #expect(LoungeCompose.suggestedPort(in: "services: {}\n") == nil)
    }
}

@Suite("Lounge compose keep-running")
struct LoungeComposeKeepRunningTests {
    @Test("round-trips, and defaults to off for entries saved before it existed")
    func keepRunning() throws {
        let entry = LoungeEntry(title: "Globit",
                                launch: .dockerCompose(file: "/g/compose.yml", port: 5173, keepRunning: true))
        let library = LoungeLibrary(entries: [entry])
        #expect(LoungeLibrary.decode(try library.encoded()) == library)

        let old = """
        {"version": 1, "entries": [{"id": "6F1C2C1E-0000-4000-8000-000000000009", "title": "Old",
          "launch": {"type": "dockerCompose", "file": "/g/compose.yml", "port": 5173}}]}
        """
        let decoded = try #require(LoungeLibrary.decode(Data(old.utf8)))
        #expect(decoded.entries[0].launch == .dockerCompose(file: "/g/compose.yml", port: 5173, keepRunning: false))
    }
}

@Suite("Lounge compose service ports")
struct LoungeServicePortTests {
    @Test("labels each port with its service")
    func labels() {
        let yaml = """
        services:
          kafka:
            image: apache/kafka
            ports:
              - "9092:9092"
            environment:
              KAFKA_X: "y"
          web:
            ports:
              - "5173:5173"
        volumes:
          data:
        """
        let ports = LoungeCompose.servicePorts(in: yaml)
        #expect(ports.map(\.service) == ["kafka", "web"])
        #expect(ports.map(\.port) == [9092, 5173])
    }
}
