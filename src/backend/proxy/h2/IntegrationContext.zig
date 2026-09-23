const Session = @import("../Session.zig");
const std = @import("std");
const middleware = @import("../middleware.zig");
const Settings = @import("Settings.zig");
const Stats = @import("Stats.zig");
const h2 = @import("h2.zig");
const relay_module = @import("relay.zig");
const IntegrationContext = @This();

session: FakeSession,
request_done: *std.Io.Queue(u8),
event_count: std.atomic.Value(u32) = .init(0),
request_phase: ?middleware.Phase = null,
decode_failures: u8 = 0,
settlements: u8 = 0,

pub fn io(_: *IntegrationContext) std.Io {
    return std.testing.io;
}

pub fn relayRequest(self: *IntegrationContext, settings: *Settings) Stats {
    const stats = h2.relay(&self.session, h2.relayOptions(.request, settings, .{ .dialect = .anthropic_messages }), self);
    self.request_done.putOneUncancelable(std.testing.io, 0) catch unreachable;
    return stats;
}

pub fn relayResponse(self: *IntegrationContext, settings: *Settings) Stats {
    _ = self.request_done.getOne(std.testing.io) catch return .{ .decode_failed = true };
    return h2.relay(&self.session, h2.relayOptions(.response, settings, .{ .dialect = .anthropic_messages }), self);
}

pub fn recordDecodeFailure(self: *IntegrationContext, _: relay_module.Direction) void {
    self.decode_failures += 1;
}

pub fn settle(self: *IntegrationContext) void {
    self.settlements += 1;
}

pub fn emit(self: *IntegrationContext, event: relay_module.Event) void {
    _ = self.event_count.fetchAdd(1, .monotonic);

    switch (event) {
        .lifecycle => |observed| if (observed.stream_id == 1) {
            self.request_phase = observed.phase;
        },
        .request_headers, .request_body, .request_finished, .response_headers, .response_body => {},
    }
}

const FakeSession = struct {
    child_input: []const u8,
    origin_input: []const u8,
    child_offset: usize = 0,
    origin_offset: usize = 0,
    child_output: [128]u8 = undefined,
    child_output_len: usize = 0,
    origin_output: [128]u8 = undefined,
    origin_output_len: usize = 0,
    child_half_closed: bool = false,
    origin_half_closed: bool = false,

    pub fn read(self: *FakeSession, side: Session.Side, output: []u8) ?usize {
        const input, const offset = switch (side) {
            .child => .{ self.child_input, &self.child_offset },
            .origin => .{ self.origin_input, &self.origin_offset },
        };

        if (offset.* == input.len) {
            return null;
        }

        const len = @min(output.len, input.len - offset.*);
        @memcpy(output[0..len], input[offset.*..][0..len]);
        offset.* += len;
        return len;
    }

    pub fn writeAll(self: *FakeSession, side: Session.Side, input: []const u8) bool {
        const output, const len = switch (side) {
            .child => .{ &self.child_output, &self.child_output_len },
            .origin => .{ &self.origin_output, &self.origin_output_len },
        };

        if (input.len > output.len - len.*) {
            return false;
        }

        @memcpy(output[len.*..][0..input.len], input);
        len.* += input.len;
        return true;
    }

    pub fn halfClose(self: *FakeSession, side: Session.Side) void {
        switch (side) {
            .child => self.child_half_closed = true,
            .origin => self.origin_half_closed = true,
        }
    }

    pub fn childOutput(self: *const FakeSession) []const u8 {
        return self.child_output[0..self.child_output_len];
    }

    pub fn originOutput(self: *const FakeSession) []const u8 {
        return self.origin_output[0..self.origin_output_len];
    }
};
