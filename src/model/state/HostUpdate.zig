const core = @import("telar-core");
const HostCapabilities = @import("HostCapabilities.zig");
const HostUpdate = @This();

capabilities: HostCapabilities,
size: core.TerminalSize,
