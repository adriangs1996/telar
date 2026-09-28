//! One connection attempt, run off the event loop. The worker writes the
//! connection or its report into the client's slots before it posts the
//! completion; the client reads them only after.
const std = @import("std");
const MachineTarget = @import("../machines/MachineTarget.zig").MachineTarget;
const RuntimeConnection = @import("../machines/RuntimeConnection.zig");
const ConnectReport = @import("ConnectReport.zig");
const RuntimeConnectJob = @This();

target: MachineTarget,
environ: std.process.Environ,
connection: *RuntimeConnection,
report: *ConnectReport,
