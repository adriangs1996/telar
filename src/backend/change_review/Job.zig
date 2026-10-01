const operation_module = @import("operation.zig");
const std = @import("std");
const core = @import("telar-core");
const Service = @import("Service.zig");
const Context = @import("Context.zig");
const Result = @import("Result.zig");
const ClientKey = @import("../history/ClientKey.zig");
const Job = @This();

service: *Service,
context: Context,
client: ?ClientKey,
request_id: core.RequestId,
/// The admitted request, re-encoded; a sample is the largest one.
wire: [core.change_review.max_sample_message_bytes]u8 = undefined,
wire_len: u32,
result: ?*Result = null,
failure: ?anyerror = null,
latest_edition_id: u64 = 0,

pub fn run(self: *Job, io: std.Io) *Job {
    const budget = core.enter(.observation);
    defer budget.restore();
    self.work(io) catch |err| {
        self.failure = err;
        if (self.client == null) {
            _ = self.service.dropped.fetchAdd(1, .monotonic);
        }
    };
    return self;
}

fn work(self: *Job, io: std.Io) !void {
    if (self.client == null) {
        self.latest_edition_id = try self.service.latestEdition(io, self.context);
        return;
    }

    const decoded = try core.decodeClient(self.wire[0..self.wire_len]);
    const operation: operation_module.Operation = switch (decoded) {
        .query_change_review => |value| .{ .query = value },
        .change_review_command => |value| .{ .command = value },
        .report_change_review_sample => |value| .{ .sample = value },
        else => return error.InvalidReviewAction,
    };
    self.result = try self.service.execute(io, .{ .context = self.context, .operation = operation });
    self.latest_edition_id = switch (operation) {
        .sample => self.result.?.changed_edition,
        .query, .command => (try self.result.?.snapshot()).latest_edition_id,
    };
}

pub fn deinit(self: *Job) void {
    if (self.result) |result| {
        result.deinit();
        self.result = null;
    }
}
