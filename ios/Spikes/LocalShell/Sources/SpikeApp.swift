import SwiftTerm
import SwiftUI
import UIKit

@main
struct SpikeApp: App {
    init() {
        if ProcessInfo.processInfo.arguments.contains("-selftest") {
            SelfTest.run()
        }
    }

    var body: some Scene {
        WindowGroup {
            TerminalHost()
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

/// SwiftTerm stands in for libghostty here: the spike tests the backend,
/// and libghostty needs a Zig build this machine doesn't have.
struct TerminalHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> TerminalController { TerminalController() }
    func updateUIViewController(_ controller: TerminalController, context: Context) {}
}

final class TerminalController: UIViewController, TerminalViewDelegate {
    private let backend = LocalBackend()
    private var terminal: TerminalView!

    override func viewDidLoad() {
        super.viewDidLoad()
        terminal = TerminalView(frame: view.bounds)
        terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        terminal.terminalDelegate = self
        view.addSubview(terminal)

        let backend = backend
        Task { @MainActor [weak self] in
            for await event in backend.events {
                switch event {
                case .output(let data):
                    self?.terminal.feed(byteArray: ArraySlice(data))
                case .exited:
                    self?.terminal.feed(text: "\r\n[session ended]\r\n")
                }
            }
        }
        Task {
            let size = terminal.getTerminal()
            try await backend.start(size: TerminalSize(
                columns: size.cols, rows: size.rows, widthPixels: 0, heightPixels: 0))
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        _ = terminal.becomeFirstResponder()
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        backend.write(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        backend.resize(TerminalSize(columns: newCols, rows: newRows, widthPixels: 0, heightPixels: 0))
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
