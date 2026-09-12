//! Launches from Finder or a desktop menu carry the session's environment,
//! not the user's: no PATH additions, no EDITOR, often no SHELL. Running the
//! login shell once and letting it exec telar gives the native client the
//! same world a terminal would.

const std = @import("std");
const max_args_module = @import("telar-backend").max_args;
const login_shell_flag = @import("arguments/GuiOptions.zig").login_shell_flag;

/// Set in the relaunched process so it never relaunches again.
pub const marker = "TELAR_LOGIN_SHELL";

/// Replaces this process with `shell -l -c 'exec telar gui ARGS'`, dropping the
/// flag that asked for it. Returns only when the replacement fails, or at once
/// when this process already came through a login shell.
///
/// ```zig
/// try login_shell.relaunch(init, args[2..]);
/// ```
pub fn relaunch(init: std.process.Init, args: []const [*:0]const u8) !void {
    const environ = init.minimal.environ;
    if (environ.getPosix(marker) != null) {
        return;
    }

    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = executable_buffer[0..try std.process.executablePath(init.io, &executable_buffer)];
    const shell = loginShell(environ);

    var argv: [max_args_module + 6][]const u8 = undefined;
    var argc: usize = 0;
    for ([_][]const u8{ shell, "-l", "-c", command(shell), executable, "gui" }) |arg| {
        argv[argc] = arg;
        argc += 1;
    }
    for (args) |arg| {
        const value = std.mem.span(arg);
        if (std.mem.eql(u8, value, login_shell_flag)) {
            continue;
        }

        if (argc == argv.len) {
            return error.TooManyArguments;
        }

        argv[argc] = value;
        argc += 1;
    }

    var map = try environ.createMap(init.gpa);
    defer map.deinit();
    try map.put(marker, "1");
    return std.process.replace(init.io, .{ .argv = argv[0..argc], .environ_map = &map });
}

/// The login shell: `SHELL` when the session names one, else the account's
/// shell from the passwd database, else `/bin/sh`.
pub fn loginShell(environ: std.process.Environ) []const u8 {
    if (environ.getPosix("SHELL")) |shell| {
        if (shell.len > 0) {
            return shell;
        }
    }

    if (std.c.getpwuid(std.c.getuid())) |entry| {
        if (entry.shell) |shell| {
            return std.mem.span(shell);
        }
    }

    return "/bin/sh";
}

/// The one-liner each shell family runs: fish has no `$0`, POSIX has no `$argv`.
pub fn command(shell: []const u8) []const u8 {
    if (std.mem.eql(u8, std.fs.path.basename(shell), "fish")) {
        return "exec $argv";
    }

    return "exec \"$0\" \"$@\"";
}

test "posix shells exec through positional parameters and fish through argv" {
    try std.testing.expectEqualStrings("exec \"$0\" \"$@\"", command("/bin/zsh"));
    try std.testing.expectEqualStrings("exec \"$0\" \"$@\"", command("/usr/bin/bash"));
    try std.testing.expectEqualStrings("exec $argv", command("/opt/homebrew/bin/fish"));
}

test "an empty SHELL falls back instead of executing nothing" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("SHELL", "");
    const block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);

    try std.testing.expect(loginShell(.{ .block = block }).len > 0);
}
