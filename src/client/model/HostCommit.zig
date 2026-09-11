const HostCommit = @This();
const HostCapabilitiesChange = @import("HostCapabilitiesChange.zig");
const HostResizeCommit = @import("HostResizeCommit.zig");
capabilities: ?HostCapabilitiesChange,
resize: ?HostResizeCommit,
