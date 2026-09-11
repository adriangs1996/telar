const SidebarConfiguration = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("host_resource_delivery.zig");
capabilities: client_model.HostCapabilities,
size: source_namespace.schema.TerminalSize,
