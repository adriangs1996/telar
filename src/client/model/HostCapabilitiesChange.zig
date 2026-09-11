const HostCapabilitiesChange = @This();
const HostCapabilities = @import("HostCapabilities.zig");
previous: HostCapabilities,
current: HostCapabilities,
host_capabilities_revision: u64,
