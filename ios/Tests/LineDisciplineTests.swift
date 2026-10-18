import XCTest
@testable import GhosttyiOS

/// The cooked-mode input a TTY would give: echo, editing, history.
final class LineDisciplineTests: XCTestCase {
    private func feed(_ discipline: inout LineDiscipline, _ text: String) -> [LineDiscipline.Action] {
        discipline.feed(Data(text.utf8))
    }

    private func echoed(_ actions: [LineDiscipline.Action]) -> String {
        var bytes: [UInt8] = []
        for case .echo(let echo) in actions { bytes += echo }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func lines(_ actions: [LineDiscipline.Action]) -> [String] {
        actions.compactMap { if case .line(let text) = $0 { text } else { nil } }
    }

    func testTypingIsEchoedAndEnterFinishesTheLine() {
        var discipline = LineDiscipline()
        let actions = feed(&discipline, "ls -l\r")
        XCTAssertEqual(echoed(actions), "ls -l\r\n")
        XCTAssertEqual(lines(actions), ["ls -l"])
    }

    func testBackspaceErasesAWholeCharacter() {
        var discipline = LineDiscipline()
        let actions = feed(&discipline, "caf\u{E9}\u{7F}e\r")
        XCTAssertEqual(lines(actions), ["cafe"])
        XCTAssertTrue(echoed(actions).contains("\u{8} \u{8}"))
    }

    func testBackspaceOnAnEmptyLineDoesNothing() {
        var discipline = LineDiscipline()
        XCTAssertEqual(echoed(feed(&discipline, "\u{7F}")), "")
    }

    func testControlUClearsTheLine() {
        var discipline = LineDiscipline()
        _ = feed(&discipline, "abc")
        let actions = feed(&discipline, "\u{15}d\r")
        XCTAssertEqual(lines(actions), ["d"])
    }

    func testControlCDropsTheLineAndInterrupts() {
        var discipline = LineDiscipline()
        _ = feed(&discipline, "abc")
        let actions = feed(&discipline, "\u{3}")
        XCTAssertTrue(actions.contains(.interrupt))
        XCTAssertEqual(feed(&discipline, "x\r").compactMap { if case .line(let text) = $0 { text } else { nil } }, ["x"])
    }

    func testControlDEndsInputOnlyOnAnEmptyLine() {
        var discipline = LineDiscipline()
        _ = feed(&discipline, "ab")
        XCTAssertFalse(feed(&discipline, "\u{4}").contains(.endOfFile))
        _ = feed(&discipline, "\u{15}")
        XCTAssertTrue(feed(&discipline, "\u{4}").contains(.endOfFile))
    }

    func testArrowsAndOtherEscapeSequencesAreNotTyped() {
        var discipline = LineDiscipline()
        let actions = feed(&discipline, "a\u{1B}[Cb\u{1B}[1;5Dc\r")
        XCTAssertEqual(lines(actions), ["abc"])
    }

    func testUpArrowRecallsHistoryWhenEnabled() {
        var discipline = LineDiscipline()
        discipline.usesHistory = true
        _ = feed(&discipline, "one\rtwo\r")
        var actions = feed(&discipline, "\u{1B}[A")
        XCTAssertTrue(echoed(actions).hasSuffix("two"))
        actions = feed(&discipline, "\u{1B}[A")
        XCTAssertTrue(echoed(actions).hasSuffix("one"))
        // Down returns toward the newest, then to an empty line.
        _ = feed(&discipline, "\u{1B}[B")
        _ = feed(&discipline, "\u{1B}[B")
        XCTAssertEqual(lines(feed(&discipline, "\r")), [""])
    }

    func testRecalledLineCanBeEditedAndRun() {
        var discipline = LineDiscipline()
        discipline.usesHistory = true
        _ = feed(&discipline, "echo abc\r")
        _ = feed(&discipline, "\u{1B}[A")
        XCTAssertEqual(lines(feed(&discipline, "\u{7F}d\r")), ["echo abd"])
    }

    func testHistoryIsIgnoredWhenDisabled() {
        var discipline = LineDiscipline()
        _ = feed(&discipline, "one\r")
        XCTAssertEqual(echoed(feed(&discipline, "\u{1B}[A")), "")
    }

    func testRepeatedLinesAreKeptOnceInHistory() {
        var discipline = LineDiscipline()
        discipline.usesHistory = true
        _ = feed(&discipline, "ls\rls\r")
        XCTAssertEqual(discipline.history, ["ls"])
    }

    func testAnEscapeSequenceSplitAcrossWritesStillWorks() {
        var discipline = LineDiscipline()
        discipline.usesHistory = true
        _ = feed(&discipline, "ls\r")
        _ = feed(&discipline, "\u{1B}")
        let actions = feed(&discipline, "[A")
        XCTAssertTrue(echoed(actions).hasSuffix("ls"))
    }
}
