const Tty = @This();
const source_namespace = @import("windows.zig");
const Size = @import("types.zig").Size;
input: source_namespace.HANDLE,
output: source_namespace.HANDLE,
original_input: source_namespace.DWORD,
original_output: source_namespace.DWORD,

/// Opens the console directly rather than using the standard handles.
///
/// The same reasoning as `/dev/tty` on Unix: stdin may be a pipe when the
/// program was started from a script, and `CONIN$`/`CONOUT$` name the
/// console itself whatever the standard handles were redirected to.
pub fn open() !Tty {
    const input = try source_namespace.openConsole("CONIN$", true);
    errdefer source_namespace.windows.CloseHandle(input);
    const output = try source_namespace.openConsole("CONOUT$", false);
    errdefer source_namespace.windows.CloseHandle(output);

    var original_input: source_namespace.DWORD = 0;
    var original_output: source_namespace.DWORD = 0;
    if (source_namespace.GetConsoleMode(input, &original_input) == 0) {
        return error.NotATerminal;
    }
    if (source_namespace.GetConsoleMode(output, &original_output) == 0) {
        return error.NotATerminal;
    }

    // Without VIRTUAL_TERMINAL_PROCESSING every escape sequence this
    // program emits is printed literally, which is what makes a Windows
    // TUI look like it vomited its own source code.
    const out_mode = original_output |
        source_namespace.ENABLE_PROCESSED_OUTPUT |
        source_namespace.ENABLE_VIRTUAL_TERMINAL_PROCESSING |
        // Stops the console wrapping and scrolling when a write lands in
        // the last column, which would shift the whole frame up by a row.
        source_namespace.DISABLE_NEWLINE_AUTO_RETURN;

    const in_mode = (original_input &
        ~(source_namespace.ENABLE_LINE_INPUT | source_namespace.ENABLE_ECHO_INPUT | source_namespace.ENABLE_PROCESSED_INPUT)) |
        source_namespace.ENABLE_WINDOW_INPUT |
        // Delivers keys and mouse as the same escape sequences a Unix
        // terminal sends, so the input parser is shared rather than
        // reimplemented against console records.
        source_namespace.ENABLE_VIRTUAL_TERMINAL_INPUT;

    if (source_namespace.SetConsoleMode(output, out_mode) == 0) {
        return error.NotATerminal;
    }
    if (source_namespace.SetConsoleMode(input, in_mode) == 0) {
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
    _ = source_namespace.SetConsoleMode(t.input, t.original_input);
    _ = source_namespace.SetConsoleMode(t.output, t.original_output);
    source_namespace.windows.CloseHandle(t.input);
    source_namespace.windows.CloseHandle(t.output);
}

pub fn size(t: *const Tty) Size {
    var info: source_namespace.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (source_namespace.GetConsoleScreenBufferInfo(t.output, &info) == 0) {
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

pub fn writeHandle(t: *const Tty) source_namespace.File {
    return .{ .handle = t.output, .flags = .{ .nonblocking = false } };
}

pub fn readHandle(t: *const Tty) source_namespace.File {
    return .{ .handle = t.input, .flags = .{ .nonblocking = false } };
}

/// Returns a reconnect-stable console identity when no emulator session
/// identifier is available in the environment.
///
/// ```zig
/// const identity = try tty.identity();
/// ```
pub fn identity(t: *const Tty) !u64 {
    const raw = if (source_namespace.GetConsoleWindow()) |window|
        @intFromPtr(window)
    else
        @intFromPtr(t.output);
    if (raw == 0) {
        return error.TerminalIdentityUnavailable;
    }

    return @intCast(raw);
}
