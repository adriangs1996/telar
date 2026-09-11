const Job = @This();
const source_namespace = @import("git_probe.zig");
const workspace = @import("../../workspace/root.zig");
io: source_namespace.Io,
request: workspace.GitProbe,
