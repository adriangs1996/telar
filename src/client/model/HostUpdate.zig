const HostUpdate = @This();
const HostCapabilities = @import("HostCapabilities.zig");
const source_namespace = @import("types.zig");
capabilities: HostCapabilities,
size: source_namespace.schema.TerminalSize,
