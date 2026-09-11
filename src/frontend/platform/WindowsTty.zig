const std = @import("std");
const windows_ops = @import("windows.zig");
const Size = @import("Size.zig");
const Tty = @This();

input: std.os.windows.HANDLE,
output: std.os.windows.HANDLE,
original_input: std.os.windows.DWORD,
original_output: std.os.windows.DWORD,

/// Opens the console directly rather than using the standard handles.
///
/// The same reasoning as `/dev/tty` on Unix: stdin may be a pipe when the
/// program was started from a script, and `CONIN$`/`CONOUT$` name the
/// console itself whatever the standard handles were redirected to.
pub fn open() !Tty {
    const input = try windows_ops.openConsole("CONIN$", true);
    errdefer std.os.windows.CloseHandle(input);
    const output = try windows_ops.openConsole("CONOUT$", false);
    errdefer std.os.windows.CloseHandle(output);

    var original_input: std.os.windows.DWORD = 0;
    var original_output: std.os.windows.DWORD = 0;
    if (windows_ops.GetConsoleMode(input, &original_input) == 0) {
        return error.NotATerminal;
    }
    if (windows_ops.GetConsoleMode(output, &original_output) == 0) {
        return error.NotATerminal;
    }

    // Without VIRTUAL_TERMINAL_PROCESSING every escape sequence this
    // program emits is printed literally, which is what makes a Windows
    // TUI look like it vomited its own source code.
    const out_mode = original_output |
        windows_ops.ENABLE_PROCESSED_OUTPUT |
        windows_ops.ENABLE_VIRTUAL_TERMINAL_PROCESSING |
        // Stops the console wrapping and scrolling when a write lands in
        // the last column, which would shift the whole frame up by a row.
        windows_ops.DISABLE_NEWLINE_AUTO_RETURN;

    const in_mode = (original_input &
        ~(windows_ops.ENABLE_LINE_INPUT | windows_ops.ENABLE_ECHO_INPUT | windows_ops.ENABLE_PROCESSED_INPUT)) |
        windows_ops.ENABLE_WINDOW_INPUT |
        // Delivers keys and mouse as the same escape sequences a Unix
        // terminal sends, so the input parser is shared rather than
        // reimplemented against console records.
        windows_ops.ENABLE_VIRTUAL_TERMINAL_INPUT;

    if (windows_ops.SetConsoleMode(output, out_mode) == 0) {
        return error.NotATerminal;
    }
    if (windows_ops.SetConsoleMode(input, in_mode) == 0) {
        return error.NotATerminal;
    }

    return .{
        .input = input,
        .output = output,
        .original_input = original_input,
        .original_output = original_output,
    };
}

pub fn deinit(t: *Tty) void {
    _ = windows_ops.SetConsoleMode(t.input, t.original_input);
    _ = windows_ops.SetConsoleMode(t.output, t.original_output);
    std.os.windows.CloseHandle(t.input);
    std.os.windows.CloseHandle(t.output);
}

pub fn size(t: *const Tty) Size {
    var info: windows_ops.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (windows_ops.GetConsoleScreenBufferInfo(t.output, &info) == 0) {
        return .{ .cols = 80, .rows = 24 };
    }
    // `srWindow` and not `dwSize`: the buffer is usually taller than the
    // window, because that is where the scrollback lives. Drawing to the
    // buffer's height puts most of the frame where nobody can see it.
    return .{
        .cols = @intCast(@max(1, info.srWindow.Right - info.srWindow.Left + 1)),
        .rows = @intCast(@max(1, info.srWindow.Bottom - info.srWindow.Top + 1)),
    };
}

pub fn writeHandle(t: *const Tty) std.Io.File {
    return .{ .handle = t.output, .flags = .{ .nonblocking = false } };
}

pub fn readHandle(t: *const Tty) std.Io.File {
    return .{ .handle = t.input, .flags = .{ .nonblocking = false } };
}

/// Returns a reconnect-stable console identity when no emulator session
/// identifier is available in the environment.
///
/// ```zig
/// const identity = try tty.identity();
/// ```
pub fn identity(t: *const Tty) !u64 {
    const raw = if (windows_ops.GetConsoleWindow()) |window|
        @intFromPtr(window)
    else
        @intFromPtr(t.output);
    if (raw == 0) {
        return error.TerminalIdentityUnavailable;
    }

    return @intCast(raw);
}
