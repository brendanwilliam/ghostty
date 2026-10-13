import GhosttyKit
import XCTest
@testable import GhosttyiOS

final class ConfigFileTests: XCTestCase {
    func testRoundTripKeepsCommentsAndOrder() {
        let text = """
        # my config
        theme = Cutie Pro

        palette = 0=#000000
        palette = 1=#ff0000
        font-family = Fira Code
        """
        var file = ConfigFile(text: text)
        XCTAssertEqual(file.text, text + "\n")
        XCTAssertEqual(file.value("theme"), "Cutie Pro")
        XCTAssertEqual(file.values("palette"), ["0=#000000", "1=#ff0000"])

        // Replacing a repeated key keeps its position.
        file.set("palette", values: ["2=#00ff00"])
        XCTAssertEqual(file.text, """
        # my config
        theme = Cutie Pro

        palette = 2=#00ff00
        font-family = Fira Code

        """)

        file.set("font-size", "14")
        file.remove("theme")
        XCTAssertNil(file.value("theme"))
        XCTAssertEqual(file.entries.last?.key, "font-size")
    }

    func testValuesContainingEquals() {
        let file = ConfigFile(text: "keybind = ctrl+a=text:hi\n")
        XCTAssertEqual(file.value("keybind"), "ctrl+a=text:hi")
    }
}

final class RemoteConfigTests: XCTestCase {
    /// The user's real Mac config, which the sanitizer has to handle.
    private let macConfig = """
    theme = Cutie Pro
    font-family = Fira Code
    window-padding-x = 12
    window-padding-y = 12
    initial-command = /bin/zsh -ic "cd ~/GitHub && claude; exec zsh -l"
    working-directory = inherit
    keybind = super+alt+d=new_split:right
    macos-titlebar-style = tabs
    config-file = ?extra.ghostty
    """

    /// A fake host: interprets the fetch script's `f="..."` paths against
    /// an in-memory file system and prints the same framing the real
    /// script does.
    private func fakeHost(home: String, files: [String: String]) -> RemoteConfigFetcher.Runner {
        { command in
            let regex = try NSRegularExpression(pattern: #"f="((?:[^"\\]|\\.)*)""#)
            // The script is single-quoted for sh; undo that quoting.
            let script = command.replacingOccurrences(of: #"'\''"#, with: "'")
            let range = NSRange(script.startIndex..., in: script)
            var out = ""
            for (index, match) in regex.matches(in: script, range: range).enumerated() {
                var path = String(script[Range(match.range(at: 1), in: script)!])
                path = path.replacingOccurrences(of: "${XDG_CONFIG_HOME:-$HOME/.config}", with: "\(home)/.config")
                path = path.replacingOccurrences(of: "$HOME", with: home)
                path = path.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
                if let text = files[path] {
                    out += "\n@@GHOSTTY-IOS-FILE@@ \(index) \(path)\n\(text)"
                }
            }
            if script.contains("home %s") {
                out += "\n@@GHOSTTY-IOS-FILE@@ home \(home)\n"
            }
            return Data(out.utf8)
        }
    }

    func testFetchSanitizesAndFollowsIncludes() async throws {
        let support = "/Users/me/Library/Application Support/com.mitchellh.ghostty"
        let fetcher = RemoteConfigFetcher(
            run: fakeHost(home: "/Users/me", files: [
                "/Users/me/.config/ghostty/config": "font-size = 15\n",
                "\(support)/config.ghostty": macConfig + "\n",
                "\(support)/extra.ghostty": "cursor-style = bar\ntheme = My Theme\n",
                "/Users/me/.config/ghostty/themes/My Theme": "background = #101010\n",
            ]),
            isBundledTheme: { $0 == "Cutie Pro" })

        let result = try await fetcher.fetch()
        let config = result.config

        XCTAssertEqual(result.sources, [
            "/Users/me/.config/ghostty/config",
            "\(support)/config.ghostty",
            "\(support)/extra.ghostty",
        ])
        XCTAssertEqual(config.value("font-size"), "15")
        XCTAssertEqual(config.value("window-padding-x"), "12")
        XCTAssertEqual(config.value("font-family"), "Fira Code")
        XCTAssertEqual(config.value("cursor-style"), "bar")
        // The include comes after the file that names it, so it wins.
        XCTAssertEqual(config.value("theme"), "My Theme")

        for key in ["initial-command", "working-directory", "keybind", "macos-titlebar-style", "config-file"] {
            XCTAssertNil(config.value(key), "\(key) should be dropped")
        }
        XCTAssertTrue(result.dropped.contains { $0.hasPrefix("initial-command") })

        // Only the custom theme is fetched; Cutie Pro ships with the app.
        XCTAssertEqual(Array(result.themes.keys), ["My Theme"])
        XCTAssertEqual(result.themes["My Theme"].map { String(decoding: $0, as: UTF8.self) }, "background = #101010\n")
    }

    func testFetchWithNoConfig() async throws {
        let fetcher = RemoteConfigFetcher(run: fakeHost(home: "/home/me", files: [:]), isBundledTheme: { _ in true })
        let result = try await fetcher.fetch()
        XCTAssertTrue(result.sources.isEmpty)
        XCTAssertTrue(result.config.entries.isEmpty)
    }

    func testThemeNamesAndPaths() {
        XCTAssertEqual(RemoteConfigFetcher.themeNames("Cutie Pro"), ["Cutie Pro"])
        XCTAssertEqual(RemoteConfigFetcher.themeNames("light:Day,dark:Night"), ["Day", "Night"])
        XCTAssertEqual(RemoteConfigFetcher.themeNames("/abs/path"), ["/abs/path"])
        XCTAssertFalse(RemoteConfigFetcher.isSafeThemeName("../evil"))
        XCTAssertFalse(RemoteConfigFetcher.isSafeThemeName(".."))
        XCTAssertTrue(RemoteConfigFetcher.isSafeThemeName("Cutie Pro"))

        XCTAssertEqual(RemoteConfigFetcher.resolve("~/x", relativeTo: "/a/b/config", home: "/h"), "/h/x")
        XCTAssertEqual(RemoteConfigFetcher.resolve("x", relativeTo: "/a/b/config", home: "/h"), "/a/b/x")
        XCTAssertEqual(RemoteConfigFetcher.resolve("/y", relativeTo: "/a/b/config", home: "/h"), "/y")
    }

    func testShellQuotingOnlyExpandsHome() {
        XCTAssertEqual(RemoteConfigFetcher.shellDoubleQuoted("$HOME/a b"), #""$HOME/a b""#)
        XCTAssertEqual(RemoteConfigFetcher.shellDoubleQuoted("/x/$(rm -rf ~)`id`\"q"), #""/x/\$(rm -rf ~)\`id\`\"q""#)
        XCTAssertEqual(RemoteConfigFetcher.shellSingleQuoted("it's"), #"'it'\''s'"#)
    }

    func testCacheRewritesCustomThemesToCachedPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = RemoteConfigCache(directory: dir)
        let result = RemoteConfigFetcher.Result(
            config: ConfigFile(text: "theme = light:Cutie Pro,dark:Mine\n"),
            themes: ["Mine": Data("background = #000000\n".utf8)],
            sources: ["/x"],
            dropped: [])

        XCTAssertTrue(try cache.store(result))
        let stored = ConfigFile(contentsOf: cache.configURL)
        let minePath = dir.appendingPathComponent("themes/Mine").path
        XCTAssertEqual(stored.value("theme"), "light:Cutie Pro,dark:\(minePath)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: minePath))
        XCTAssertEqual(cache.metadata?.sources, ["/x"])

        // Storing the same result again reports no change.
        XCTAssertFalse(try cache.store(result))
    }
}

final class ConfigBuilderTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        _ = GhosttyRuntime.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, _ text: String) -> URL {
        let url = dir.appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testLaterLayersWin() throws {
        let remote = file("remote.ghostty", "font-size = 15\ncursor-style-blink = false\n")
        let overrides = file("overrides.ghostty", "font-size = 17\n")

        let withOverrides = try XCTUnwrap(ConfigBuilder.build(remote: remote, overridesURL: overrides))
        XCTAssertEqual(withOverrides.float("font-size"), 17)

        let remoteOnly = try XCTUnwrap(ConfigBuilder.build(remote: remote, overridesURL: file("empty.ghostty", "")))
        XCTAssertEqual(remoteOnly.float("font-size"), 15)

        // Bundled defaults apply when nothing else sets the key.
        let defaultsOnly = try XCTUnwrap(ConfigBuilder.build(remote: nil, overridesURL: file("empty2.ghostty", "")))
        XCTAssertEqual(defaultsOnly.float("font-size"), 12)
    }

    /// On a device only Library/, Documents/, and tmp/ are writable; the
    /// simulator also allows the container root, so it can't catch this.
    func testOverridesLiveInADeviceWritableDirectory() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let overrides = ConfigPaths.overrides.standardizedFileURL.path
        XCTAssertTrue(overrides.hasPrefix(home + "/Library/"), overrides)
        XCTAssertEqual(
            ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            ConfigPaths.configHome.standardizedFileURL.path)
    }

    func testBundledThemeResolves() {
        XCTAssertTrue(ThemeCatalog.isBundled("Cutie Pro"))
        XCTAssertGreaterThan(ThemeCatalog.names.count, 400)
        XCTAssertEqual(ConfigBuilder.validate("theme = Cutie Pro\n"), [])
        XCTAssertFalse(ConfigBuilder.validate("theme = No Such Theme Anywhere\n").isEmpty)
    }

    func testInvalidValueIsReported() {
        XCTAssertFalse(ConfigBuilder.validate("font-size = huge\n").isEmpty)
        XCTAssertFalse(ConfigBuilder.validate("not-a-real-option = 1\n").isEmpty)
        XCTAssertEqual(ConfigBuilder.validate("font-size = 14\n"), [])
    }

    @MainActor
    func testSettingsModelRejectsInvalidEdits() {
        let url = dir.appendingPathComponent("config.ghostty")
        let model = SettingsModel(overridesURL: url)
        XCTAssertFalse(model.set("font-size", "huge").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        XCTAssertEqual(model.set("font-size", "14"), [])
        XCTAssertEqual(ConfigFile(contentsOf: url).value("font-size"), "14")
        XCTAssertEqual(model.effective("font-size").source, .settings)

        model.reset("font-size")
        XCTAssertEqual(model.effective("font-size").source, .app)
        XCTAssertEqual(model.effective("cursor-style").source, .ghostty)
    }
}

final class ConfigCatalogTests: XCTestCase {
    func testCatalogHasCommonOptions() throws {
        let catalog = ConfigCatalog.shared
        XCTAssertGreaterThan(catalog.options.count, 150)
        XCTAssertEqual(catalog.option("font-size")?.kind, .number)
        XCTAssertEqual(catalog.option("copy-on-select")?.kind, .bool)
        XCTAssertEqual(catalog.option("background")?.kind, .color)
        let cursor = try XCTUnwrap(catalog.option("cursor-style"))
        XCTAssertEqual(cursor.kind, .enumeration)
        XCTAssertTrue(cursor.values?.contains("bar") ?? false)
        XCTAssertTrue(catalog.option("font-family")?.repeatable ?? false)
        XCTAssertNotNil(catalog.option("theme"))
        XCTAssertEqual(catalog.option("macos-titlebar-style")?.platform, "macos")
    }
}

final class ShiftMappingTests: XCTestCase {
    func testShiftedCharacters() {
        XCTAssertEqual(KeyInput.shifted("a"), "A")
        XCTAssertEqual(KeyInput.shifted("-"), "_")
        XCTAssertEqual(KeyInput.shifted("/"), "?")
        XCTAssertEqual(KeyInput.shifted("1"), "!")
        XCTAssertEqual(KeyInput.shifted("|"), "|")
        XCTAssertEqual(KeyInput.shifted("~"), "~")
    }
}

@MainActor
final class KeyAccessoryBarTests: XCTestCase {
    func testKeyWidths() throws {
        let app = try XCTUnwrap(GhosttyRuntime.shared.app)
        final class NoBackend: TerminalBackend, @unchecked Sendable {
            let events = AsyncStream<TerminalBackendEvent> { $0.finish() }
            func start(size: TerminalSize) async throws {}
            func write(_ data: Data) {}
            func resize(_ size: TerminalSize) {}
            func close() {}
        }
        let view = TerminalSurfaceView(app: app, backend: NoBackend())
        let bar = try XCTUnwrap(view.inputAccessoryView)
        bar.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        bar.layoutIfNeeded()

        let buttons = allButtons(in: bar)
        // Symbol keys are named by their accessibility label.
        let names = buttons.map {
            $0.accessibilityLabel ?? $0.configuration?.attributedTitle.map { String($0.characters) } ?? ""
        }
        XCTAssertEqual(Array(names.prefix(6)), ["Escape", "Control", "Option", "Command", "Shift", "Tab"])
        XCTAssertFalse(names.contains { $0.localizedCaseInsensitiveContains("paste") }, "names: \(names)")

        // Every key is the same width and never squeezed.
        let minWidth = KeyAccessoryBar.minKeyWidth
        XCTAssertGreaterThan(minWidth, 30)
        for (name, button) in zip(names, buttons) {
            XCTAssertEqual(button.frame.width, minWidth, accuracy: 0.5, "\(name) should be the key width")
        }

        // Hide Keyboard is pinned at the right edge, outside the scrolling keys.
        let hide = try XCTUnwrap(zip(names, buttons).first { $0.0 == "Hide Keyboard" }?.1)
        XCTAssertTrue(hide.superview === bar)
        XCTAssertEqual(hide.frame.maxX, bar.bounds.width - 8, accuracy: 0.5)
        let scroll = try XCTUnwrap(bar.subviews.first { $0 is UIScrollView } as? UIScrollView)
        XCTAssertLessThanOrEqual(scroll.frame.maxX, hide.frame.minX)
        XCTAssertGreaterThan(scroll.contentSize.width, scroll.frame.width, "the other keys scroll on a phone")
    }

    private func allButtons(in view: UIView) -> [UIButton] {
        view.subviews.flatMap { sub -> [UIButton] in
            if let button = sub as? UIButton { return [button] }
            return allButtons(in: sub)
        }
    }
}
