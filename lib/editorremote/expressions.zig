//! Encode paths as string data, then use each editor's filename API.
const std = @import("std");
const Target = @import("Target.zig");

/// The longest path an expression carries.
pub const max_path_bytes = 4096;
/// Room for a path quoted in the worst case, plus identity checks.
pub const max_bytes = max_path_bytes * 2 + 1024;

/// Checks identity again in the same remote evaluation that opens the file.
/// Example: `const expression = try vim(&buffer, .{ .pid = pid, .path = path });`
pub fn vim(buffer: []u8, target: Target) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("getpid() == {d}", .{target.pid});
    if (target.hostname.len != 0) {
        try writer.writeAll(" && hostname() == ");
        try vimString(&writer, target.hostname);
    }

    try writer.writeAll(" ? [execute('drop ' . fnameescape(");
    try vimString(&writer, target.path);
    try writer.writeAll(")), 1][1] : 0");
    return writer.buffered();
}

fn vimString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('\'');
    for (text) |byte| {
        try writer.writeByte(byte);
        if (byte == '\'') {
            try writer.writeByte('\'');
        }
    }

    try writer.writeByte('\'');
}

/// Selects the frame attached to this pane's TTY, including daemon clients.
/// Example: `const expression = try emacs(&buffer, .{ .pid = pid, .path = path, .tty = tty });`
pub fn emacs(buffer: []u8, target: Target) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("(if (and (= (emacs-pid) {d})", .{target.pid});
    if (target.hostname.len != 0) {
        try writer.writeAll(" (equal (system-name) ");
        try lispString(&writer, target.hostname);
        try writer.writeByte(')');
    }

    try writer.writeAll(") (let ((f (catch 'found (dolist (f (frame-list)) (when (and (not (display-graphic-p f)) (equal (terminal-name (frame-terminal f)) ");
    try lispString(&writer, target.tty);
    try writer.writeAll(")) (throw 'found f)))))) (if f (with-selected-frame f (find-file (concat \"/:\" ");
    try lispString(&writer, target.path);
    try writer.writeAll(")) 1) 0)) 0)");
    return writer.buffered();
}

fn lispString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        if (byte == '"' or byte == '\\') {
            try writer.writeByte('\\');
        }

        try writer.writeByte(byte);
    }

    try writer.writeByte('"');
}

test "editor paths remain literal data across Vim and Lisp quoting" {
    var buffer: [max_bytes]u8 = undefined;
    const target: Target = .{ .pid = 42, .path = "/tmp/a'|quit!\"\\$().txt" };
    const vim_expression = try vim(&buffer, target);
    try std.testing.expect(std.mem.indexOf(u8, vim_expression, "fnameescape('/tmp/a''|quit!\"\\$().txt')") != null);
    try std.testing.expect(std.mem.startsWith(u8, vim_expression, "getpid() == 42 ?"));

    const emacs_expression = try emacs(&buffer, target);
    try std.testing.expect(std.mem.indexOf(u8, emacs_expression, "(find-file (concat \"/:\" \"/tmp/a'|quit!\\\"\\\\$().txt\"))") != null);
    try std.testing.expect(std.mem.startsWith(u8, emacs_expression, "(if (and (= (emacs-pid) 42)"));
}
