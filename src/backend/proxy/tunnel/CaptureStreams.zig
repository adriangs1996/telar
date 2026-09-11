const CaptureStreams = @This();
const capture = @import("../capture/root.zig");
const exchange_mod = @import("exchange_support.zig");
const CaptureSlot = @import("CaptureSlot.zig");
const h2 = @import("../h2/root.zig");
const std = @import("std");
const source_namespace = @import("h2.zig");
producer: *capture.Producer,
exchange: *exchange_mod.Exchange,
side: capture.Side,
slots: [128]?CaptureSlot = .{null} ** 128,

pub fn deinit(streams: *CaptureStreams) void {
    for (&streams.slots) |*slot| {
        const present = slot.* orelse continue;
        slot.* = null;
        streams.publish(present.half, .reset);
    }
}

pub fn feedHeaders(streams: *CaptureStreams, block: h2.HeaderBlock) void {
    const half = streams.ensure(block.stream_id) orelse return;
    const part: capture.Part = if (streams.side == .request) .request_head else .response_head;

    for (block.fields) |field| {
        _ = half.append(part, field.name);
        _ = half.append(part, ": ");
        _ = half.append(part, field.value);
        _ = half.append(part, "\r\n");

        if (streams.side == .request) {
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

pub fn feedBody(streams: *CaptureStreams, stream_id: u32, bytes: []const u8) void {
    const half = streams.ensure(stream_id) orelse return;
    const part: capture.Part = if (streams.side == .request) .request_body else .response_body;
    _ = half.append(part, bytes);
}

pub fn finish(streams: *CaptureStreams, stream_id: u32, outcome: capture.Outcome) void {
    const index = streams.find(stream_id) orelse return;
    const slot = streams.slots[index].?;
    streams.slots[index] = null;
    streams.publish(slot.half, outcome);
}

fn ensure(streams: *CaptureStreams, stream_id: u32) ?*capture.Half {
    if (streams.find(stream_id)) |index| {
        return streams.slots[index].?.half;
    }

    const index = streams.empty() orelse return null;
    const half = streams.producer.start(.{
        .credential = streams.exchange.credential,
        .dialect = streams.exchange.dialect,
        .protocol = streams.exchange.protocol,
        .key = .{ .connection_id = streams.exchange.connection_id, .stream_id = stream_id },
        .side = streams.side,
        .host = streams.exchange.host.bytes,
        .started_at_ms = source_namespace.Io.Timestamp.now(streams.exchange.io, .real).toMilliseconds(),
    }) orelse return null;
    streams.slots[index] = .{ .stream_id = stream_id, .half = half };

    return half;
}

fn find(streams: *const CaptureStreams, stream_id: u32) ?usize {
    for (streams.slots, 0..) |slot, index| {
        const present = slot orelse continue;
        if (present.stream_id == stream_id) {
            return index;
        }
    }

    return null;
}

fn empty(streams: *const CaptureStreams) ?usize {
    for (streams.slots, 0..) |slot, index| {
        if (slot == null) {
            return index;
        }
    }

    return null;
}

fn publish(streams: *CaptureStreams, half: *capture.Half, outcome: capture.Outcome) void {
    half.finish(outcome, source_namespace.Io.Timestamp.now(streams.exchange.io, .real).toMilliseconds());
    streams.producer.publish(streams.exchange.io, .{
        .credential = streams.exchange.credential,
        .half = half,
    });
}
