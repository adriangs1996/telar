//! Host observations own geometry validation and their presentation revisions.
const std = @import("std");
const schema = @import("telar-core").schema;
const types = @import("types.zig");
pub const HostCapabilities = types.HostCapabilities;
pub const HostUpdate = types.HostUpdate;
pub const HostCommit = types.HostCommit;
pub const HostCapabilityObservation = types.HostCapabilityObservation;
pub const HostResizeCommit = types.HostResizeCommit;
pub const HostCapabilitiesChange = types.HostCapabilitiesChange;

pub const State = @import("HostState.zig");
