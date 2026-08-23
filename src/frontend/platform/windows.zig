const std = @import("std");
const Io = std.Io;
const File = Io.File;
const windows = std.os.windows;

const platform = @import("../platform.zig");
const Size = platform.Size;

// Windows: console modes for the state, the screen buffer info for the size,
// and - the awkward one - polling for the change.
//
// Zig's standard library ships no console bindings, so the imports are here.
// That is the arrangement the project asks for anyway: OS APIs belong in the
// platform file and nowhere else.
//
// NOT YET VERIFIED ON A REAL WINDOWS MACHINE. It cross compiles, and the
// console mode flags and structures are the documented ones, but nobody has
// watched it run. Treat a bug report against this file as more likely to be
// right than the code is.

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const WORD = windows.WORD;
const SHORT = i16;

// Output modes.
const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
const DISABLE_NEWLINE_AUTO_RETURN: DWORD = 0x0008;

// Input modes. The three that are *cleared* are the ones that make a console
// behave like a line editor: buffering until Enter, echoing what is typed, and
// turning Ctrl+C into a signal. Exactly the trio termios calls ICANON, ECHO
// and ISIG, under different names.
const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
const ENABLE_LINE_INPUT: DWORD = 0x0002;
const ENABLE_ECHO_INPUT: DWORD = 0x0004;
const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
const ENABLE_MOUSE_INPUT: DWORD = 0x0010;
const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;

const COORD = extern struct { X: SHORT, Y: SHORT };
const SMALL_RECT = extern struct { Left: SHORT, Top: SHORT, Right: SHORT, Bottom: SHORT };
const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: HANDLE,
    lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
) callconv(.winapi) BOOL;

pub const Tty = struct {
    input: HANDLE,
    output: HANDLE,
    original_input: DWORD,
    original_output: DWORD,

    /// Opens the console directly rather than using the standard handles.
    ///
    /// The same reasoning as `/dev/tty` on Unix: stdin may be a pipe when the
    /// program was started from a script, and `CONIN$`/`CONOUT$` name the
    /// console itself whatever the standard handles were redirected to.
    pub fn open() !Tty {
        const input = try openConsole("CONIN$", true);
        errdefer windows.CloseHandle(input);
        const output = try openConsole("CONOUT$", false);
        errdefer windows.CloseHandle(output);

        var original_input: DWORD = 0;
        var original_output: DWORD = 0;
        if (GetConsoleMode(input, &original_input) == 0) return error.NotATerminal;
        if (GetConsoleMode(output, &original_output) == 0) return error.NotATerminal;

        // Without VIRTUAL_TERMINAL_PROCESSING every escape sequence this
        // program emits is printed literally, which is what makes a Windows
        // TUI look like it vomited its own source code.
        const out_mode = original_output |
            ENABLE_PROCESSED_OUTPUT |
            ENABLE_VIRTUAL_TERMINAL_PROCESSING |
            // Stops the console wrapping and scrolling when a write lands in
            // the last column, which would shift the whole frame up by a row.
            DISABLE_NEWLINE_AUTO_RETURN;

        const in_mode = (original_input &
            ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT)) |
            ENABLE_WINDOW_INPUT |
            // Delivers keys and mouse as the same escape sequences a Unix
            // terminal sends, so the input parser is shared rather than
            // reimplemented against console records.
            ENABLE_VIRTUAL_TERMINAL_INPUT;

        if (SetConsoleMode(output, out_mode) == 0) return error.NotATerminal;
        if (SetConsoleMode(input, in_mode) == 0) return error.NotATerminal;

        return .{
            .input = input,
            .output = output,
            .original_input = original_input,
            .original_output = original_output,
        };
    }

    pub fn deinit(t: *Tty) void {
        _ = SetConsoleMode(t.input, t.original_input);
        _ = SetConsoleMode(t.output, t.original_output);
        windows.CloseHandle(t.input);
        windows.CloseHandle(t.output);
    }

    pub fn size(t: *const Tty) Size {
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (GetConsoleScreenBufferInfo(t.output, &info) == 0) return .{ .cols = 80, .rows = 24 };
        // `srWindow` and not `dwSize`: the buffer is usually taller than the
        // window, because that is where the scrollback lives. Drawing to the
        // buffer's height puts most of the frame where nobody can see it.
        return .{
            .cols = @intCast(@max(1, info.srWindow.Right - info.srWindow.Left + 1)),
            .rows = @intCast(@max(1, info.srWindow.Bottom - info.srWindow.Top + 1)),
        };
    }

    pub fn writeHandle(t: *const Tty) File {
        return .{ .handle = t.output, .flags = .{ .nonblocking = false } };
    }

    pub fn readHandle(t: *const Tty) File {
        return .{ .handle = t.input, .flags = .{ .nonblocking = false } };
    }
};

fn openConsole(comptime name: []const u8, read: bool) !HANDLE {
    const path = std.unicode.utf8ToUtf16LeStringLiteral(name);
    const handle = windows.kernel32.CreateFileW(
        path,
        if (read) windows.GENERIC_READ | windows.GENERIC_WRITE else windows.GENERIC_READ | windows.GENERIC_WRITE,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
        null,
        windows.OPEN_EXISTING,
        0,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return error.NotATerminal;
    return handle;
}

/// Crash-time terminal restore is not implemented on Windows: the console
/// mode is per-handle state the next process resets, and there is no POSIX
/// fatal-signal path to hook. A crash leaves the console in VT mode, which
/// Windows Terminal recovers from on the next prompt.
pub fn installCrashRestore(_: *const Tty) void {}

pub fn emergencyRestore() void {}

/// Notices resizes by looking, because the alternative steals keystrokes.
///
/// Windows reports a resize as a `WINDOW_BUFFER_SIZE_EVENT` record on the
/// console input handle - but reading records *consumes* them, and the same
/// handle carries the keyboard. A watcher that drained records to find resizes
/// would eat the input the parser is waiting for, and the symptom is dropped
/// characters under an unrelated subsystem.
///
/// So this asks for the size on a timer instead. It costs one cheap call every
/// hundred milliseconds and a resize is noticed within that window, which is
/// well under the time a human takes to finish dragging a window edge. The
/// honest alternative is to move *all* input behind this file and translate
/// console records centrally; that is the right long-term answer and a much
/// larger change than a resize watcher.
///
/// Recorded exception to `docs/engineering-invariants.md` ("Idle panes and
/// clients schedule no polling or repaint proportional to their count"): this
/// is one constant-cost poll per client on Windows only, independent of pane
/// count. It disappears when console records are translated centrally.
pub const ResizeWatcher = struct {
    tty: *Tty,
    last: Size,

    const interval_ms = 100;

    pub fn init(tty: *Tty) !ResizeWatcher {
        return .{ .tty = tty, .last = tty.size() };
    }

    pub fn deinit(_: *ResizeWatcher) void {}

    pub fn wait(w: *ResizeWatcher, io: Io) Io.Cancelable!void {
        while (true) {
            try io.sleep(.fromMilliseconds(interval_ms), .awake);
            const now = w.tty.size();
            if (now.cols != w.last.cols or now.rows != w.last.rows) {
                w.last = now;
                return;
            }
        }
    }
};
