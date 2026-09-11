const HostCapabilitiesType = @import("../../model/HostCapabilities.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const SidebarConfiguration = @This();

capabilities: HostCapabilitiesType,
size: TerminalSizeType,
