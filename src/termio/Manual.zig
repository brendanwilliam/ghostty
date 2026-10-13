//! Manual is a termio backend with no subprocess or pty. The host
//! application owns the "other end" of the terminal: it feeds program
//! output into the terminal with `Termio.processOutput` and receives
//! terminal input (keystrokes, query responses, etc.) via a callback.
//!
//! This is used on platforms that can't spawn subprocesses (iOS) and
//! for hosts that connect the terminal to something other than a local
//! process, such as an SSH channel or an in-process emulator.
const Manual = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const log = std.log.scoped(.io_manual);

/// Called with bytes the terminal wants to send to the program, e.g.
/// encoded key input or responses to terminal queries. This is called
/// on the termio thread, so implementations must be thread-safe. The
/// data is only valid for the duration of the call.
pub const WriteFn = *const fn (
    userdata: ?*anyopaque,
    data: [*]const u8,
    len: usize,
) callconv(.c) void;

/// Called when the terminal grid size changes so the host can inform
/// the program (e.g. an SSH "window-change" request). This may be called
/// from the main thread (during initialization) or the termio thread.
pub const ResizeFn = *const fn (
    userdata: ?*anyopaque,
    columns: u16,
    rows: u16,
    width_px: u32,
    height_px: u32,
) callconv(.c) void;

pub const Config = struct {
    userdata: ?*anyopaque = null,
    write: ?WriteFn = null,
    resize: ?ResizeFn = null,
};

config: Config,

pub fn init(cfg: Config) Manual {
    return .{ .config = cfg };
}

pub fn deinit(self: *Manual) void {
    _ = self;
}

pub fn initTerminal(self: *Manual, term: *terminal.Terminal) void {
    self.resize(.{
        .columns = term.cols,
        .rows = term.rows,
    }, .{
        .width = term.width_px,
        .height = term.height_px,
    }) catch unreachable;
}

pub fn threadEnter(
    self: *Manual,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;
    td.backend = .{ .manual = .{} };
}

pub fn threadExit(self: *Manual, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

pub fn focusGained(
    self: *Manual,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *Manual,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    const cb = self.config.resize orelse return;
    cb(
        self.config.userdata,
        grid_size.columns,
        grid_size.rows,
        screen_size.width,
        screen_size.height,
    );
}

pub fn queueWrite(
    self: *Manual,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    if (td.backend.manual.exited) return;
    const cb = self.config.write orelse return;

    if (!linefeed) {
        cb(self.config.userdata, data.ptr, data.len);
        return;
    }

    // Replace \r with \r\n, flushing through a small stack buffer.
    var buf: [256]u8 = undefined;
    var buf_i: usize = 0;
    for (data) |ch| {
        if (buf_i >= buf.len - 1) {
            cb(self.config.userdata, &buf, buf_i);
            buf_i = 0;
        }

        buf[buf_i] = ch;
        buf_i += 1;
        if (ch == '\r') {
            buf[buf_i] = '\n';
            buf_i += 1;
        }
    }
    if (buf_i > 0) cb(self.config.userdata, &buf, buf_i);
}

pub fn childExitedAbnormally(
    self: *Manual,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    log.debug("manual session exited code={} runtime={}ms", .{ exit_code, runtime_ms });
}

/// There is no local process, so no process information is available.
pub fn getProcessInfo(self: *Manual, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

/// The thread local data for the manual implementation.
pub const ThreadData = struct {
    /// Set once the host reports that the session has ended. Writes
    /// after this point are dropped.
    exited: bool = false,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

test "queueWrite linefeed conversion" {
    const testing = std.testing;

    const Capture = struct {
        var out: std.ArrayList(u8) = .empty;

        fn write(_: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) void {
            out.appendSlice(testing.allocator, data[0..len]) catch unreachable;
        }
    };
    defer Capture.out.deinit(testing.allocator);

    var m: Manual = .init(.{ .write = Capture.write });
    var td: termio.Termio.ThreadData = undefined;
    td.backend = .{ .manual = .{} };

    try m.queueWrite(testing.allocator, &td, "a\rb", false);
    try testing.expectEqualStrings("a\rb", Capture.out.items);

    Capture.out.clearRetainingCapacity();
    const long = "x\r" ** 200;
    try m.queueWrite(testing.allocator, &td, long, true);
    try testing.expectEqualStrings("x\r\n" ** 200, Capture.out.items);

    // Writes after exit are dropped.
    Capture.out.clearRetainingCapacity();
    td.backend.manual.exited = true;
    try m.queueWrite(testing.allocator, &td, "ignored", false);
    try testing.expectEqual(@as(usize, 0), Capture.out.items.len);
}
