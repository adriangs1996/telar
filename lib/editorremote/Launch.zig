//! The argv that starts an editor on a file, with the cursor on a line when
//! the editor's command line has a way to say so. The path stays one
//! argument, or the head of one for editors that read `path:line`; no shell
//! ever sees it.
const std = @import("std");
const editor = @import("editor.zig");
const expressions = @import("expressions.zig");
const Launch = @This();

pub const max_arguments = 3;

/// Room for the path plus `:line:column`, or for Vim's `+call cursor(l, c)`.
const position_bytes = 64;

arguments: [max_arguments][]const u8 = undefined,
text: [expressions.max_path_bytes + position_bytes]u8 = undefined,

/// How an editor's command line takes a position. Editors this list does
/// not know open the file without one.
const Convention = enum {
    /// `+line` or `+call cursor(line, column)`: Vim and Neovim.
    vim,
    /// `+line:column`: Emacs, Kakoune, micro.
    plus_line_column,
    /// `+line,column`: nano.
    nano,
    /// `path:line:column`: Helix.
    path_suffix,
    /// `-g path:line:column`: VS Code and its forks.
    goto_flag,
    none,
};

/// Builds the argv for `executable` on `path`. The slices borrow `self`, so
/// the launch outlives the argv's use. `line` zero opens without a position.
///
/// ```zig
/// var launch: Launch = .{};
/// const argv = try launch.argv("nvim", "/tmp/a.zig", 12, 0); // { "nvim", "+12", "/tmp/a.zig" }
/// ```
pub fn argv(self: *Launch, executable: []const u8, path: []const u8, line: u32, column: u32) ![]const []const u8 {
    const convention = conventionOf(executable);
    if (line == 0 or convention == .none) {
        self.arguments[0] = executable;
        self.arguments[1] = path;
        return self.arguments[0..2];
    }

    var writer: std.Io.Writer = .fixed(&self.text);
    switch (convention) {
        .vim => {
            if (column == 0) {
                try writer.print("+{d}", .{line});
            } else {
                try writer.print("+call cursor({d}, {d})", .{ line, column });
            }
        },
        .plus_line_column => try writePlus(&writer, line, column, ':'),
        .nano => try writePlus(&writer, line, column, ','),
        .path_suffix, .goto_flag => {
            try writer.writeAll(path);
            try writer.print(":{d}", .{line});
            if (column != 0) {
                try writer.print(":{d}", .{column});
            }
        },
        .none => unreachable,
    }

    self.arguments[0] = executable;
    switch (convention) {
        .path_suffix => {
            self.arguments[1] = writer.buffered();
            return self.arguments[0..2];
        },
        .goto_flag => {
            self.arguments[1] = "-g";
            self.arguments[2] = writer.buffered();
            return self.arguments[0..3];
        },
        else => {
            self.arguments[1] = writer.buffered();
            self.arguments[2] = path;
            return self.arguments[0..3];
        },
    }
}

fn writePlus(writer: *std.Io.Writer, line: u32, column: u32, separator: u8) !void {
    try writer.print("+{d}", .{line});
    if (column != 0) {
        try writer.print("{c}{d}", .{ separator, column });
    }
}

fn conventionOf(executable: []const u8) Convention {
    switch (editor.identify(executable)) {
        .neovim, .vim => return .vim,
        .emacs => return .plus_line_column,
        .unsupported => {},
    }

    const name = std.fs.path.basename(executable);
    const known = [_]struct { name: []const u8, convention: Convention }{
        .{ .name = "kak", .convention = .plus_line_column },
        .{ .name = "micro", .convention = .plus_line_column },
        .{ .name = "nano", .convention = .nano },
        .{ .name = "hx", .convention = .path_suffix },
        .{ .name = "helix", .convention = .path_suffix },
        .{ .name = "code", .convention = .goto_flag },
        .{ .name = "code-insiders", .convention = .goto_flag },
        .{ .name = "codium", .convention = .goto_flag },
        .{ .name = "cursor", .convention = .goto_flag },
    };
    for (known) |entry| {
        if (std.mem.eql(u8, name, entry.name)) {
            return entry.convention;
        }
    }

    return .none;
}

test "each editor family receives the position the way its command line reads it" {
    const cases = [_]struct { executable: []const u8, line: u32, column: u32, expected: []const []const u8 }{
        .{ .executable = "/opt/homebrew/bin/nvim", .line = 12, .column = 0, .expected = &.{ "/opt/homebrew/bin/nvim", "+12", "/tmp/a.zig" } },
        .{ .executable = "vim", .line = 12, .column = 3, .expected = &.{ "vim", "+call cursor(12, 3)", "/tmp/a.zig" } },
        .{ .executable = "emacsclient", .line = 12, .column = 3, .expected = &.{ "emacsclient", "+12:3", "/tmp/a.zig" } },
        .{ .executable = "nano", .line = 12, .column = 3, .expected = &.{ "nano", "+12,3", "/tmp/a.zig" } },
        .{ .executable = "hx", .line = 12, .column = 0, .expected = &.{ "hx", "/tmp/a.zig:12" } },
        .{ .executable = "code", .line = 12, .column = 3, .expected = &.{ "code", "-g", "/tmp/a.zig:12:3" } },
        .{ .executable = "ed", .line = 12, .column = 3, .expected = &.{ "ed", "/tmp/a.zig" } },
        .{ .executable = "nvim", .line = 0, .column = 0, .expected = &.{ "nvim", "/tmp/a.zig" } },
    };

    for (cases) |case| {
        var launch: Launch = .{};
        const arguments = try launch.argv(case.executable, "/tmp/a.zig", case.line, case.column);
        try std.testing.expectEqual(case.expected.len, arguments.len);
        for (case.expected, arguments) |expected, actual| {
            try std.testing.expectEqualStrings(expected, actual);
        }
    }
}

test "the longest path still fits with its position" {
    const path = "/" ++ "a" ** (expressions.max_path_bytes - 1);
    var launch: Launch = .{};
    const arguments = try launch.argv("hx", path, std.math.maxInt(u32), std.math.maxInt(u32));
    try std.testing.expect(std.mem.startsWith(u8, arguments[1], path));
}
