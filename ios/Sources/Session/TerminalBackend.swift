import Foundation

/// The size of a terminal grid, reported by libghostty whenever the
/// surface is resized.
struct TerminalSize: Equatable, Sendable {
    var columns: Int
    var rows: Int
    var widthPixels: Int
    var heightPixels: Int

    static let `default` = TerminalSize(columns: 80, rows: 24, widthPixels: 0, heightPixels: 0)
}

/// Events a backend reports back to the terminal.
enum TerminalBackendEvent: Sendable {
    /// Program output to feed into the terminal.
    case output(Data)

    /// The session ended. A nil exit code means it ended without one
    /// (e.g. the connection dropped).
    case exited(code: Int32?, message: String?)
}

/// The program side of a terminal. libghostty owns the emulator and
/// renderer; a backend owns whatever produces output and consumes input.
///
/// `SSHBackend` is the only implementation today. A future on-device
/// backend (e.g. an in-process Linux userland) implements the same
/// protocol and plugs into `TerminalSurfaceView` unchanged.
///
/// `write` and `resize` may be called from any thread (libghostty calls
/// them from its IO thread), so implementations must be thread-safe.
protocol TerminalBackend: AnyObject, Sendable {
    /// Events from the backend. Consumed once by the terminal view.
    var events: AsyncStream<TerminalBackendEvent> { get }

    /// Start the session with the current terminal size.
    func start(size: TerminalSize) async throws

    /// Bytes from the terminal (encoded key input, query responses).
    func write(_ data: Data)

    /// The terminal grid changed size.
    func resize(_ size: TerminalSize)

    /// Tear down the session.
    func close()
}
