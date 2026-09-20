const std = @import("std");
const core = @import("telar-core");
const Service = @import("Service.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const Operation = @import("operation.zig").Operation;
const ClientKey = @import("../history/ClientKey.zig");
const Job = @This();

service: *Service,
context: Context,
client: ClientKey,
request_id: core.RequestId,
wire: [32 * 1024]u8 = undefined,
wire_len: u32,
result: ?*Result = null,
failure: ?anyerror = null,

pub fn run(self: *Job, io: std.Io) *Job {
    const budget = core.enter(.observation);
    defer budget.restore();
    self.work(io) catch |err| {
        self.failure = err;
    };
    return self;
}

fn work(self: *Job, io: std.Io) !void {
    const decoded = try core.decodeClient(self.wire[0..self.wire_len]);
    const operation: Operation = switch (decoded) {
        .query_change_review => |value| .{ .query = value },
        .change_review_command => |value| .{ .command = value },
        .report_change_review_sample => |value| .{ .sample = value },
        else => return error.InvalidReviewAction,
    };
    self.result = try self.service.execute(io, .{ .context = self.context, .operation = operation });
}

pub fn deinit(self: *Job) void {
    if (self.result) |result| {
        result.deinit();
        self.result = null;
    }
}
