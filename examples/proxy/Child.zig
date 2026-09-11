const std = @import("std");
const main = @import("main.zig");
/// The command to run in the pty. `pty_proxy claude --resume` runs Claude Code
/// under the taps; with no arguments it falls back to an interactive shell,
/// which is what the OSC 133 command log is written against.
const Child = @This();

file: [*:0]const u8,
argv: [main.max_argv:null]?[*:0]const u8,

pub fn fromArgs(init: std.process.Init) Child {
    var child: Child = .{ .file = main.default_shell, .argv = @splat(null) };
    var it = init.minimal.args.iterate();
    _ = it.next(); // argv[0], ours

    var n: usize = 0;
    while (it.next()) |arg| {
        if (n == main.max_argv - 1) {
            break;
        }
        if (n == 0) {
            child.file = arg.ptr;
        }
        child.argv[n] = arg.ptr;
        n += 1;
    }
    if (n == 0) {
        child.argv[0] = main.default_shell;
    }
    return child;
}
