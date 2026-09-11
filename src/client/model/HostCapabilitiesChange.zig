const HostCapabilities = @import("HostCapabilities.zig");
const HostCapabilitiesChange = @This();

previous: HostCapabilities,
current: HostCapabilities,
host_capabilities_revision: u64,
