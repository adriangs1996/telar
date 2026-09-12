const WindowsTty = @import("WindowsTty.zig");

const std = @import("std");
const LocalTime = @import("telar-client").LocalTime;

// Windows: console modes for the state, the screen buffer info for the size,
// and - the awkward one - polling for the change.
//
// Zig's standard library ships no console bindings, so the imports are here.
// That is the arrangement the project asks for anyway: OS APIs belong in the
// platform file and nowhere else.
//
// Not verified on a real Windows machine. The console ABI has a layout test;
// TTY method checks still expose pre-existing Zig 0.16 Windows API mismatches.
// A passing layout check does not establish working console I/O.

// Output modes.
pub const ENABLE_PROCESSED_OUTPUT: std.os.windows.DWORD = 0x0001;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: std.os.windows.DWORD = 0x0004;
pub const DISABLE_NEWLINE_AUTO_RETURN: std.os.windows.DWORD = 0x0008;

// Input modes. The three that are *cleared* are the ones that make a console
// behave like a line editor: buffering until Enter, echoing what is typed, and
// turning Ctrl+C into a signal. Exactly the trio termios calls ICANON, ECHO
// and ISIG, under different names.
pub const ENABLE_PROCESSED_INPUT: std.os.windows.DWORD = 0x0001;
pub const ENABLE_LINE_INPUT: std.os.windows.DWORD = 0x0002;
pub const ENABLE_ECHO_INPUT: std.os.windows.DWORD = 0x0004;
pub const ENABLE_WINDOW_INPUT: std.os.windows.DWORD = 0x0008;
const ENABLE_MOUSE_INPUT: std.os.windows.DWORD = 0x0010;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT: std.os.windows.DWORD = 0x0200;

const COORD = @import("Coord.zig").COORD;
const SMALL_RECT = @import("SmallRect.zig").SMALL_RECT;
pub const CONSOLE_SCREEN_BUFFER_INFO = @import("ConsoleScreenBufferInfo.zig").CONSOLE_SCREEN_BUFFER_INFO;
const SYSTEMTIME = @import("SystemTime.zig").SYSTEMTIME;

pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, lpMode: *std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, dwMode: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
pub extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: std.os.windows.HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetLocalTime(system_time: *SYSTEMTIME) callconv(.winapi) void;
pub extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?std.os.windows.HWND;

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

pub fn openConsole(comptime name: []const u8, read: bool) !std.os.windows.HANDLE {
    const path = std.unicode.utf8ToUtf16LeStringLiteral(name);
    const handle = std.os.windows.kernel32.CreateFileW(
        path,
        if (read) std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE else std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE,
        std.os.windows.FILE_SHARE_READ | std.os.windows.FILE_SHARE_WRITE,
        null,
        std.os.windows.OPEN_EXISTING,
        0,
        null,
    );
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
        return error.NotATerminal;
    }
    return handle;
}

/// Crash-time terminal restore is not implemented on Windows: the console
/// mode is per-handle state the next process resets, and there is no POSIX
/// fatal-signal path to hook. A crash leaves the console in VT mode, which
/// Windows Terminal recovers from on the next prompt.
pub fn installCrashRestore(_: *const WindowsTty) void {}

pub fn emergencyRestore() void {}

pub const ResizeWatcher = @import("WindowsResizeWatcher.zig");

test "Windows console layouts preserve their pre-extraction ABI" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(COORD));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SMALL_RECT));
    try std.testing.expectEqual(@as(usize, 22), @sizeOf(CONSOLE_SCREEN_BUFFER_INFO));
    try std.testing.expectEqual(@as(usize, 2), @alignOf(CONSOLE_SCREEN_BUFFER_INFO));
    try std.testing.expectEqual(@as(usize, 10), @offsetOf(CONSOLE_SCREEN_BUFFER_INFO, "srWindow"));
    try std.testing.expectEqual(@as(usize, 18), @offsetOf(CONSOLE_SCREEN_BUFFER_INFO, "dwMaximumWindowSize"));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(SYSTEMTIME));
    try std.testing.expectEqual(@as(usize, 14), @offsetOf(SYSTEMTIME, "milliseconds"));
}
