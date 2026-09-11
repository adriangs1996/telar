/// Opens the default pane in the workspace implied by `launch.cwd`, creating
/// it when none exists, or attaches to a specific existing pane. This makes
/// attach-or-create atomic.
const OpenPane = @This();
const source_namespace = @import("pane.zig");
request_id: source_namespace.RequestId,
target: source_namespace.PaneTarget = .default,
size: source_namespace.TerminalSize,
launch: ?source_namespace.Launch,
