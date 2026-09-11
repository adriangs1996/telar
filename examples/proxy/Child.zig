/// The command to run in the pty. `pty_proxy claude --resume` runs Claude Code
/// under the taps; with no arguments it falls back to an interactive shell,
/// which is what the OSC 133 command log is written against.
const Child = @This();
const std = @import("std");
const source_namespace = @import("main.zig");
file: [*:0]const u8,
argv: [max_argv:null]?[*:0]const u8,

fn fromArgs(init: std.process.Init) Child {
    var child: Child = .{ .file = source_namespace.default_shell, .argv = @splat(null) };
    var it = init.minimal.args.iterate();
    _ = it.next(); // argv[0], ours

    var n: usize = 0;
    while (it.next()) |arg| {
        if (n == source_namespace.max_argv - 1) {
            break;
        }
        if (n == 0) {
            child.file = arg.ptr;
        }
        child.argv[n] = arg.ptr;
        n += 1;
    }
    if (n == 0) {
        child.argv[0] = source_namespace.default_shell;
    }
    return child;
}
