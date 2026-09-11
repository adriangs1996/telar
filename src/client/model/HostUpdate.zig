const HostCapabilities = @import("HostCapabilities.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const HostUpdate = @This();

capabilities: HostCapabilities,
size: TerminalSizeType,
