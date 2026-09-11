const Completion = @This();
const source_namespace = @import("exit.zig");
const pty = @import("../../../../pty/root.zig");
pane: source_namespace.PaneKey,
result: anyerror!pty.Exit,
