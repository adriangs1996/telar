//! The result the adapter delivers for one pick-list command.
const data = @import("model");
const Output = @import("Output.zig");
const PickCommandJob = @import("PickCommandJob.zig");
const PickCommandCompletion = @This();

execution_id: data.command_execution.Id,
purpose: PickCommandJob.Purpose,
result: anyerror!Output,
