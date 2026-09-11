const std = @import("std");
pub const Io = std.Io;
pub const File = Io.File;
pub const windows = std.os.windows;

const Size = @import("types.zig").Size;
const LocalTime = @import("types.zig").LocalTime;

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

pub const HANDLE = windows.HANDLE;
pub const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const WORD = windows.WORD;
const SHORT = i16;

// Output modes.
pub const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
pub const DISABLE_NEWLINE_AUTO_RETURN: DWORD = 0x0008;

// Input modes. The three that are *cleared* are the ones that make a console
// behave like a line editor: buffering until Enter, echoing what is typed, and
// turning Ctrl+C into a signal. Exactly the trio termios calls ICANON, ECHO
// and ISIG, under different names.
pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
pub const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
const ENABLE_MOUSE_INPUT: DWORD = 0x0010;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;

const COORD = extern struct { X: SHORT, Y: SHORT };
const SMALL_RECT = extern struct { Left: SHORT, Top: SHORT, Right: SHORT, Bottom: SHORT };
pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};
const SYSTEMTIME = extern struct {
    year: WORD,
    month: WORD,
    day_of_week: WORD,
    day: WORD,
    hour: WORD,
    minute: WORD,
    second: WORD,
    milliseconds: WORD,
};

pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
extern "kernel32" fn GetLocalTime(system_time: *SYSTEMTIME) callconv(.winapi) void;
pub extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?windows.HWND;

pub fn localTime() LocalTime {
    var value: SYSTEMTIME = undefined;
    GetLocalTime(&value);

    return .{
        .year = value.year,
        .month = @intCast(value.month),
        .day = @intCast(value.day),
        .hour = @intCast(value.hour),
        .minute = @intCast(value.minute),
        .second = @intCast(value.second),
        .weekday = @intCast(value.day_of_week),
    };
}

pub const FastWriter = @import("WindowsFastWriter.zig");

pub const Tty = @import("WindowsTty.zig");

pub fn openConsole(comptime name: []const u8, read: bool) !HANDLE {
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
    if (handle == windows.INVALID_HANDLE_VALUE) {
        return error.NotATerminal;
    }
    return handle;
}

/// Crash-time terminal restore is not implemented on Windows: the console
/// mode is per-handle state the next process resets, and there is no POSIX
/// fatal-signal path to hook. A crash leaves the console in VT mode, which
/// Windows Terminal recovers from on the next prompt.
pub fn installCrashRestore(_: *const Tty) void {}

pub fn emergencyRestore() void {}

pub const ResizeWatcher = @import("WindowsResizeWatcher.zig");
