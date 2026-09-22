const HostCapabilitiesChange = @import("HostCapabilitiesChange.zig");
const HostResizeCommit = @import("HostResizeCommit.zig");
const HostCommit = @This();

capabilities: ?HostCapabilitiesChange,
resize: ?HostResizeCommit,
