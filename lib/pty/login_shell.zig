//! Running a command through the user's login shell, so it sees the
//! environment the user's rc files build. The command's arguments reach the
//! shell as positional parameters and are never read as shell code.

const std = @import("std");

/// Flags of a login shell that is also interactive, so it reads the rc
/// files that only interactive shells read (`.zshrc`, `.bashrc`), where
/// PATH additions often live.
pub const login_flags = [_][]const u8{ "-l", "-i" };
pub const interactive_flags = login_flags ++ [_][]const u8{"-c"};

/// Starts a known shell as an interactive login shell. Unknown shells keep
/// their direct launch because their login flags may differ.
/// Example: `const argv = login_shell.interactive(shell, &storage);`
pub fn interactive(shell: []const u8, storage: *[1 + login_flags.len][]const u8) []const []const u8 {
    storage[0] = shell;
    if (script(shell) == null) {
        return storage[0..1];
    }

    @memcpy(storage[1..], &login_flags);
    return storage;
}

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
