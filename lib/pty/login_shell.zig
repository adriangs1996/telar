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

/// The one-liner a shell runs to exec the command, by the shell's base name,
/// or null for a shell whose flags or syntax telar does not know (tcsh, nu).
/// POSIX shells take the command as `$0` and `$@`, fish as `$argv`; the
/// shell execs it, so the command's exit status is the pane's. bash, zsh and
/// ksh read a program named `-w` as an option of `exec` unless `--` ends
/// them; dash takes `--` for the program, so `sh`, which is dash on many
/// Linux systems, goes without. fish cannot exec a program whose name
/// starts with `-` either way.
///
/// ```zig
/// const line = login_shell.script("/bin/zsh").?; // exec -- "$0" "$@"
/// ```
pub fn script(shell: []const u8) ?[]const u8 {
    const name = std.fs.path.basename(shell);
    for ([_][]const u8{ "bash", "zsh", "ksh" }) |known| {
        if (std.mem.eql(u8, name, known)) {
            return "exec -- \"$0\" \"$@\"";
        }
    }

    for ([_][]const u8{ "sh", "dash" }) |known| {
        if (std.mem.eql(u8, name, known)) {
            return "exec \"$0\" \"$@\"";
        }
    }

    if (std.mem.eql(u8, name, "fish")) {
        return "exec $argv";
    }

    return null;
}

/// Writes `shell -l -i -c SCRIPT argv...` into `storage` and returns it; a
/// shell `script` does not know gets `argv` unchanged.
///
/// ```zig
/// var storage: [login_shell.wrapper_len + 4][]const u8 = undefined;
/// const argv = try login_shell.wrap("/bin/zsh", &.{ "claude", "fix it" }, &storage);
/// ```
pub fn wrap(shell: []const u8, argv: []const []const u8, storage: [][]const u8) ![]const []const u8 {
    if (argv.len == 0) {
        return error.EmptyCommand;
    }

    const line = script(shell) orelse return argv;
    if (wrapper_len + argv.len > storage.len) {
        return error.TooManyArguments;
    }

    storage[0] = shell;
    @memcpy(storage[1 .. 1 + interactive_flags.len], &interactive_flags);
    storage[interactive_flags.len + 1] = line;
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
    const line = script(first) orelse return first;
    for (interactive_flags ++ [_][]const u8{line}) |expected| {
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

test "each known shell family gets its own line and any other shell none" {
    try std.testing.expectEqualStrings("exec -- \"$0\" \"$@\"", script("/bin/zsh").?);
    try std.testing.expectEqualStrings("exec -- \"$0\" \"$@\"", script("/usr/bin/bash").?);
    try std.testing.expectEqualStrings("exec -- \"$0\" \"$@\"", script("/bin/ksh").?);
    try std.testing.expectEqualStrings("exec \"$0\" \"$@\"", script("/bin/sh").?);
    try std.testing.expectEqualStrings("exec \"$0\" \"$@\"", script("/usr/bin/dash").?);
    try std.testing.expectEqualStrings("exec $argv", script("/opt/homebrew/bin/fish").?);
    try std.testing.expect(script("/bin/tcsh") == null);
    try std.testing.expect(script("/bin/csh") == null);
    try std.testing.expect(script("/opt/homebrew/bin/nu") == null);
    try std.testing.expect(script("/bin/zsh5") == null);
}

test "a shell telar does not know runs the command as it is" {
    var storage: [wrapper_len + 2][]const u8 = undefined;
    const argv = [_][]const u8{ "claude", "fix it" };
    const launched = try wrap("/bin/tcsh", &argv, &storage);
    try std.testing.expectEqual(argv.len, launched.len);
    try std.testing.expectEqualStrings("claude", launched[0]);
    try std.testing.expectEqualStrings("fix it", launched[1]);

    var arguments: SliceArguments = .{ .items = launched };
    try std.testing.expectEqualStrings("claude", program(&arguments).?);
}

test "a wrapped command keeps every argument whole after the shell's own" {
    var storage: [wrapper_len + 3][]const u8 = undefined;
    const argv = try wrap("/bin/zsh", &.{ "claude", "$HOME; rm -rf *", "" }, &storage);

    const expected = [_][]const u8{ "/bin/zsh", "-l", "-i", "-c", "exec -- \"$0\" \"$@\"", "claude", "$HOME; rm -rf *", "" };
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
