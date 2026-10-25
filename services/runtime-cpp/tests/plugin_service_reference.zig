const std = @import("std");
const core = @import("telar-core");
const capture = @import("exchangecapture");
const Service = @import("plugins/Service.zig");
const ServiceSpec = @import("plugins/ServiceSpec.zig");
const ExchangeView = @import("plugins/Exchange.zig");
const HalfView = @import("plugins/Half.zig");
const protocol = @import("plugins/protocol.zig");
const owned = @import("proxy/capture/owned.zig");

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const executable = std.mem.trim(u8, @embedFile("worker-executable.txt"), "\r\n");
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "tap-worker")) {
        return std.process.replace(init.io, .{ .argv = &.{ executable, "tap-worker", arguments[2] } });
    }
    if (arguments.len != 3) {
        return error.InvalidArguments;
    }

    const gpa = init.gpa;
    var quota = capture.Quota.init(128 * 1024 * 1024);
    const capabilities = core.CapabilitySet.initMany(&.{ .proxy_tap, .notifications });
    const specification = try ServiceSpec.init(0, 8, .{
        .id = "service-probe",
        .entry = arguments[1],
        .digest = .{0} ** 32,
        .declared = capabilities,
        .granted = capabilities,
    });
    var service: Service = undefined;
    try service.init(.{ .gpa = gpa, .io = init.io, .specs = &.{specification} });
    defer service.deinit();
    var prefix: [4]u8 = undefined;
    var output: [64 * 1024]u8 = undefined;
    while (try readExact(init.io, &prefix)) {
        const length = std.mem.readInt(u32, &prefix, .little);
        if (length == 0 or length > 128 * 1024 * 1024) {
            return error.InvalidFrame;
        }
        const frame = try gpa.alloc(u8, length);
        defer {
            std.crypto.secureZero(u8, frame);
            gpa.free(frame);
        }
        if (!try readExact(init.io, frame)) {
            return error.IncompleteFrame;
        }
        const decoded = try protocol.decodeExchange(frame);
        var exchange: owned.Exchange = .{};
        defer exchange.deinit();
        if (decoded.request) |half| {
            exchange.request = try copyHalf(gpa, &quota, decoded, half, .request);
        }
        if (decoded.response) |half| {
            exchange.response = try copyHalf(gpa, &quota, decoded, half, .response);
        }
        service.submit(&exchange);
        const result = try service.receive(init.io);
        defer result.deinit();
        try service.authorize(result);
        const reply = try protocol.encodeEffects(&output, result.event_id, &result.batch);
        std.mem.writeInt(u32, &prefix, @intCast(reply.len), .little);
        try std.Io.File.stdout().writeStreamingAll(init.io, &prefix);
        try std.Io.File.stdout().writeStreamingAll(init.io, reply);
    }
}

fn copyHalf(gpa: std.mem.Allocator, quota: *capture.Quota, exchange: ExchangeView, view: HalfView, side: capture.buffer_support.Side) !*owned.Half {
    const half = owned.Half.create(.{
        .gpa = gpa,
        .quota = quota,
        .config = .{ .enabled = true },
        .meta = .{ .protocol = exchange.protocol },
        .key = .{ .connection_id = exchange.connection_id, .stream_id = exchange.stream_id },
        .side = side,
        .host = exchange.host,
        .started_at_ms = exchange.started_at_ms,
    }) orelse return error.OutOfMemory;
    half.setMethod(exchange.method);
    half.setTarget(exchange.target);
    half.setEncoding(view.encoding);
    _ = half.append(if (side == .request) .request_head else .response_head, view.head);
    _ = half.append(if (side == .request) .request_body else .response_body, view.body);
    half.body.truncated = view.body_truncated;
    half.body_decoded = view.decoded;
    half.status_code = view.status_code;
    half.outcome = view.outcome;
    half.finished_at_ms = view.finished_at_ms;
    return half;
}

fn readExact(io: std.Io, output: []u8) !bool {
    var offset: usize = 0;
    while (offset < output.len) {
        const count = std.Io.File.stdin().readStreaming(io, &.{output[offset..]}) catch |err| switch (err) {
            error.EndOfStream => return false,
            else => return err,
        };
        if (count == 0) {
            return false;
        }
        offset += count;
    }
    return true;
}
