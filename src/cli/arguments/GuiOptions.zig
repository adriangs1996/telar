//! `telar gui` takes the client's run options plus one flag of its own.
const std = @import("std");
const RunOptions = @import("RunOptions.zig");
const GuiOptions = @This();

pub const login_shell_flag = "--login-shell";

run: RunOptions,
/// Re-run through the user's login shell first, so a launch from Finder or
/// a desktop menu sees the same PATH, EDITOR and SHELL as a terminal.
login_shell: bool = false,

/// Example: `const options = try GuiOptions.parse(args, environ);`.
pub fn parse(args: []const [*:0]const u8, environ: std.process.Environ) !GuiOptions {
    var storage: [64][*:0]const u8 = undefined;
    if (args.len > storage.len) {
        return error.TooManyArguments;
    }

    var login_shell = false;
    var count: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, std.mem.span(arg), login_shell_flag)) {
            login_shell = true;
            continue;
        }

        storage[count] = arg;
        count += 1;
    }

    return .{ .run = try RunOptions.parse(storage[0..count], environ), .login_shell = login_shell };
}

test "the login shell flag is stripped before the run options see it" {
    const args = [_][*:0]const u8{ "--login-shell", "--no-config" };
    const options = try GuiOptions.parse(&args, .empty);

    try std.testing.expect(options.login_shell);
    try std.testing.expect(options.run.no_config);
}

test "without the flag gui options are plain run options" {
    const args = [_][*:0]const u8{"--no-config"};
    const options = try GuiOptions.parse(&args, .empty);

    try std.testing.expect(!options.login_shell);
}
