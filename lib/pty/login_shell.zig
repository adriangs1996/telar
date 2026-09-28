//! Running a command through the user's login shell, so it sees the
//! environment the user's rc files build. The command's arguments reach the
//! shell as positional parameters and are never read as shell code.

const std = @import("std");

/// Flags of a login shell that is also interactive, so it reads the rc
/// files that only interactive shells read (`.zshrc`, `.bashrc`), where
/// PATH additions often live.
pub const interactive_flags = [_][]const u8{ "-l", "-i", "-c" };

/// Arguments `wrap` puts before the command.
pub const wrapper_len = interactive_flags.len + 2;

/// The one-liner each shell family runs: POSIX shells take the command as
/// `$0` and `$@`, fish as `$argv`. Either way the shell execs it, so the
/// command's exit status is the pane's.
///
/// ```zig
/// const line = login_shell.script("/bin/zsh"); // exec "$0" "$@"
/// ```
pub fn script(shell: []const u8) []const u8 {
    if (std.mem.eql(u8, std.fs.path.basename(shell), "fish")) {
        return "exec $argv";
    }

    return "exec \"$0\" \"$@\"";
}

/// Writes `shell -l -i -c SCRIPT argv...` into `storage` and returns it.
///
/// ```zig
/// var storage: [login_shell.wrapper_len + 4][]const u8 = undefined;
/// const argv = try login_shell.wrap("/bin/zsh", &.{ "claude", "fix it" }, &storage);
/// ```
pub fn wrap(shell: []const u8, argv: []const []const u8, storage: [][]const u8) ![]const []const u8 {
    if (argv.len == 0) {
        return error.EmptyCommand;
    }

    if (wrapper_len + argv.len > storage.len) {
        return error.TooManyArguments;
    }

    storage[0] = shell;
    @memcpy(storage[1 .. 1 + interactive_flags.len], &interactive_flags);
    storage[interactive_flags.len + 1] = script(shell);
    @memcpy(storage[wrapper_len .. wrapper_len + argv.len], argv);
    return storage[0 .. wrapper_len + argv.len];
}

/// The program an argv runs: the command `wrap` handed to a login shell,
/// else its first argument. `arguments` is a pointer to an iterator whose
/// `next` returns `!?[]const u8`.
///
/// ```zig
/// var arguments = launch.arguments();
/// const name = login_shell.program(&arguments) orelse "";
/// ```
pub fn program(arguments: anytype) ?[]const u8 {
    const first = (arguments.next() catch return null) orelse return null;
    for (interactive_flags ++ [_][]const u8{script(first)}) |expected| {
        const argument = (arguments.next() catch return first) orelse return first;
        if (!std.mem.eql(u8, argument, expected)) {
            return first;
        }
    }

    return (arguments.next() catch return first) orelse first;
}

const SliceArguments = struct {
    items: []const []const u8,
    index: usize = 0,

    fn next(self: *SliceArguments) !?[]const u8 {
        if (self.index == self.items.len) {
            return null;
        }

        self.index += 1;
        return self.items[self.index - 1];
    }
};

test "posix shells exec through positional parameters and fish through argv" {
    try std.testing.expectEqualStrings("exec \"$0\" \"$@\"", script("/bin/zsh"));
    try std.testing.expectEqualStrings("exec \"$0\" \"$@\"", script("/usr/bin/bash"));
    try std.testing.expectEqualStrings("exec $argv", script("/opt/homebrew/bin/fish"));
}

test "a wrapped command keeps every argument whole after the shell's own" {
    var storage: [wrapper_len + 3][]const u8 = undefined;
    const argv = try wrap("/bin/zsh", &.{ "claude", "$HOME; rm -rf *", "" }, &storage);

    const expected = [_][]const u8{ "/bin/zsh", "-l", "-i", "-c", "exec \"$0\" \"$@\"", "claude", "$HOME; rm -rf *", "" };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }

    try std.testing.expectError(error.TooManyArguments, wrap("/bin/zsh", &.{ "a", "b", "c", "d" }, &storage));
    try std.testing.expectError(error.EmptyCommand, wrap("/bin/zsh", &.{}, &storage));
}

test "the program of a wrapped command is the command, of any other argv its first word" {
    var storage: [wrapper_len + 2][]const u8 = undefined;
    var wrapped: SliceArguments = .{ .items = try wrap("/opt/homebrew/bin/fish", &.{ "/usr/local/bin/claude", "go" }, &storage) };
    try std.testing.expectEqualStrings("/usr/local/bin/claude", program(&wrapped).?);

    var plain: SliceArguments = .{ .items = &.{ "/bin/zsh", "-l" } };
    try std.testing.expectEqualStrings("/bin/zsh", program(&plain).?);

    var shell_only: SliceArguments = .{ .items = &.{"/bin/zsh"} };
    try std.testing.expectEqualStrings("/bin/zsh", program(&shell_only).?);

    var empty: SliceArguments = .{ .items = &.{} };
    try std.testing.expect(program(&empty) == null);
}
