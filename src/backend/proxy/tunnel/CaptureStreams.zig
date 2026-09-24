const Producer = @import("../capture/Producer.zig");
const Exchange = @import("Exchange.zig");
const buffer_support = @import("../capture/buffer_support.zig");
const h2frames = @import("h2frames");
const HeaderBlock = h2frames.HeaderBlock;
const std = @import("std");
const Half = @import("../capture/Half.zig");
const CaptureStreams = @This();

producer: *Producer,
exchange: *Exchange,
side: buffer_support.Side,
slots: [128]?CaptureSlot = .{null} ** 128,

pub fn deinit(self: *CaptureStreams) void {
    for (&self.slots) |*slot| {
        const present = slot.* orelse continue;
        slot.* = null;
        self.publish(present.half, .reset);
    }
}

pub fn feedHeaders(self: *CaptureStreams, block: HeaderBlock) void {
    const half = self.ensure(block.stream_id) orelse return;
    const part: buffer_support.Part = if (self.side == .request) .request_head else .response_head;

    for (block.fields) |field| {
        _ = half.append(part, field.name);
        _ = half.append(part, ": ");
        _ = half.append(part, field.value);
        _ = half.append(part, "\r\n");

        if (self.side == .request) {
            if (std.mem.eql(u8, field.name, ":method")) {
                half.setMethod(field.value);
            } else if (std.mem.eql(u8, field.name, ":path")) {
                half.setTarget(field.value);
            }
        } else if (std.mem.eql(u8, field.name, ":status")) {
            half.status_code = std.fmt.parseInt(u16, field.value, 10) catch 0;
            if (half.status_code >= 100 and half.status_code < 200) {
                half.head.reset();
                half.captured_bytes = half.body.len;
            }
        }

        if (std.ascii.eqlIgnoreCase(field.name, "content-encoding")) {
            half.setEncoding(field.value);
        }
    }
}

pub fn feedBody(self: *CaptureStreams, stream_id: u32, bytes: []const u8) void {
    const half = self.ensure(stream_id) orelse return;
    const part: buffer_support.Part = if (self.side == .request) .request_body else .response_body;
    _ = half.append(part, bytes);
}

pub fn finish(self: *CaptureStreams, stream_id: u32, outcome: buffer_support.Outcome) void {
    const index = self.find(stream_id) orelse return;
    const slot = self.slots[index].?;
    self.slots[index] = null;
    self.publish(slot.half, outcome);
}

fn ensure(self: *CaptureStreams, stream_id: u32) ?*Half {
    if (self.find(stream_id)) |index| {
        return self.slots[index].?.half;
    }

    const index = self.empty() orelse return null;
    const half = self.producer.start(.{
        .credential = self.exchange.credential,
        .dialect = self.exchange.dialect,
        .protocol = self.exchange.protocol,
        .key = .{ .connection_id = self.exchange.connection_id, .stream_id = stream_id },
        .side = self.side,
        .host = self.exchange.host.bytes,
        .started_at_ms = std.Io.Timestamp.now(self.exchange.io, .real).toMilliseconds(),
    }) orelse return null;
    self.slots[index] = .{ .stream_id = stream_id, .half = half };

    return half;
}

fn find(self: *const CaptureStreams, stream_id: u32) ?usize {
    for (self.slots, 0..) |slot, index| {
        const present = slot orelse continue;
        if (present.stream_id == stream_id) {
            return index;
        }
    }

    return null;
}

fn empty(self: *const CaptureStreams) ?usize {
    for (self.slots, 0..) |slot, index| {
        if (slot == null) {
            return index;
        }
    }

    return null;
}

fn publish(self: *CaptureStreams, half: *Half, outcome: buffer_support.Outcome) void {
    half.finish(outcome, std.Io.Timestamp.now(self.exchange.io, .real).toMilliseconds());
    self.producer.publish(self.exchange.io, .{
        .credential = self.exchange.credential,
        .half = half,
    });
}

const CaptureSlot = struct {
    stream_id: u32,
    half: *Half,
};
