//! HTTP/2 relay with bounded HPACK observation. Every frame is forwarded byte
//! for byte; header blocks are decoded from a copy through an independent
//! inflater per direction. DATA, flow control, and stream ownership remain end
//! to end.

const h2frames = @import("h2frames");
const framing = h2frames.framing;
const Observer = @import("Observer.zig");
const header_memory = @import("header_memory.zig");
const std = @import("std");
const BodyCollector = @import("BodyCollector.zig");
const RouteMatch = @import("../RouteMatch.zig");
const localca = @import("localca");
const Session = localca.Session;

pub const c = @cImport({
    @cInclude("nghttp2/nghttp2.h");
});

pub const client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
pub const max_header_block_bytes = 128 * 1024;

pub const frame_data: u8 = 0x0;
pub const frame_headers: u8 = 0x1;
pub const frame_rst_stream: u8 = 0x3;
pub const frame_push_promise: u8 = 0x5;
pub const frame_goaway: u8 = 0x7;
pub const frame_continuation: u8 = 0x9;

pub const flag_end_stream: u8 = 0x1;
pub const flag_end_headers: u8 = 0x4;
pub const flag_padded: u8 = 0x8;
pub const flag_priority: u8 = 0x20;

pub const Direction = enum { request, response };

pub const Stats = @import("Stats.zig");

pub const Lifecycle = @import("Lifecycle.zig");

pub const RequestBody = @import("RequestBody.zig");

pub const RequestFinished = @import("RequestFinished.zig");

pub const ResponseBody = @import("ResponseBody.zig");

const HeaderField = h2frames.HeaderField;

const HeaderBlock = h2frames.HeaderBlock;

/// One borrowed observation produced while relaying HTTP/2 frames.
pub const Event = union(enum) {
    lifecycle: Lifecycle,
    request_headers: HeaderBlock,
    request_body: RequestBody,
    request_finished: RequestFinished,
    response_headers: HeaderBlock,
    response_body: ResponseBody,
};

pub const Route = @import("RelayRoute.zig");

pub const HeaderKind = enum { none, headers, push_promise };

/// Relays one HTTP/2 direction byte for byte while publishing decoded events.
///
/// ```zig
/// const stats = relay(session, route, &sink);
/// ```
pub fn relay(session: anytype, route: Route, sink: anytype) Stats {
    var memory = header_memory.of(&route.gpa);
    var observer = Observer.init(&memory, route.watched_routes, route.direction);
    defer observer.deinit();
    var preface_offset: usize = 0;
    var buffer: [32 * 1024]u8 = undefined;
    while (true) {
        const len = session.read(route.from, &buffer) orelse break;
        var input = buffer[0..len];
        if (route.direction == .request and preface_offset < client_preface.len) {
            const take = @min(client_preface.len - preface_offset, input.len);
            if (!std.mem.eql(
                u8,
                client_preface[preface_offset..][0..take],
                input[0..take],
            )) {
                observer.fail();
            }
            preface_offset += take;
            input = input[take..];
        }

        if (route.direction == .request) {
            observer.observe(input, sink);
        }

        if (!session.writeAll(route.to, buffer[0..len])) {
            break;
        }

        if (route.direction == .response) {
            observer.observe(input, sink);
        }
    }
    if ((route.direction == .request and preface_offset != client_preface.len) or
        observer.framing.header_len != 0 or observer.framing.payload_left != 0 or
        observer.continuation_stream != 0)
    {
        observer.fail();
    }

    session.halfClose(route.to);
    return .{ .decode_failed = observer.failed };
}

pub fn isHeaderFrame(frame_type: u8) bool {
    return frame_type == frame_headers or
        frame_type == frame_push_promise or
        frame_type == frame_continuation;
}

pub fn writeFrameHeader(buffer: *[framing.header_bytes]u8, header: FrameHeader) void {
    buffer.* = .{
        @truncate(header.length >> 16),
        @truncate(header.length >> 8),
        @truncate(header.length),
        header.frame_type,
        header.flags,
        @truncate(header.stream_id >> 24),
        @truncate(header.stream_id >> 16),
        @truncate(header.stream_id >> 8),
        @truncate(header.stream_id),
    };
}

fn lifecycle(event: Event) ?Lifecycle {
    return switch (event) {
        .lifecycle => |value| value,
        .request_headers => null,
        .request_body => null,
        .request_finished => null,
        .response_headers => null,
        .response_body => null,
    };
}


/// Watched routes for the tests, shaped like Anthropic and OpenAI inference.
const claude_routes = [_]RouteMatch{.{ .method = "POST", .paths = &.{"/v1/messages"} }};
const openai_routes = [_]RouteMatch{.{ .method = "POST", .paths = &.{"/v1/responses"} }};

test "HTTP2 observer exposes request DATA across every two-chunk split" {
    const payload = "{\"stream\":true}";
    var wire: [framing.header_bytes + payload.len]u8 = undefined;
    writeFrameHeader(wire[0..framing.header_bytes], .{ .length = payload.len, .frame_type = frame_data, .flags = flag_end_stream, .stream_id = 5 });
    @memcpy(wire[framing.header_bytes..], payload);

    for (0..wire.len + 1) |split| {
        var collector: BodyCollector = .{};
        var memory = header_memory.of(&std.testing.allocator);
        var observer = Observer.init(&memory, &claude_routes, .request);
        defer observer.deinit();

        observer.observe(wire[0..split], &collector);
        observer.observe(wire[split..], &collector);

        try std.testing.expect(!observer.failed);
        try std.testing.expectEqualStrings(payload, collector.payloadSlice());
        try std.testing.expectEqual(@as(u32, 5), collector.stream_id);
        try std.testing.expect(collector.request_body);
        try std.testing.expectEqual(@as(usize, 1), collector.request_finished);
        try std.testing.expectEqual(@as(usize, 0), collector.activity);
        try std.testing.expectEqual(@as(usize, 0), collector.finished);
    }
}

test "HTTP2 observer finishes a bodyless request across every two-chunk split" {
    const block = "\x83\x04\x0c/v1/messages";
    var wire: [framing.header_bytes + block.len]u8 = undefined;
    writeFrameHeader(wire[0..framing.header_bytes], .{ .length = block.len, .frame_type = frame_headers, .flags = flag_end_headers | flag_end_stream, .stream_id = 5 });
    @memcpy(wire[framing.header_bytes..], block);

    for (0..wire.len + 1) |split| {
        var collector: BodyCollector = .{};
        var memory = header_memory.of(&std.testing.allocator);
        var observer = Observer.init(&memory, &claude_routes, .request);
        defer observer.deinit();

        observer.observe(wire[0..split], &collector);
        observer.observe(wire[split..], &collector);

        try std.testing.expect(!observer.failed);
        try std.testing.expectEqualStrings("", collector.payloadSlice());
        try std.testing.expect(!collector.request_body);
        try std.testing.expectEqual(@as(usize, 1), collector.request_finished);
    }
}

test "HTTP2 observer exposes DATA payload across every two-chunk split" {
    const payload = "event: message_delta\ndata: payload\n\n";
    var wire: [framing.header_bytes + payload.len]u8 = undefined;
    writeFrameHeader(wire[0..framing.header_bytes], .{ .length = payload.len, .frame_type = frame_data, .flags = flag_end_stream, .stream_id = 7 });
    @memcpy(wire[framing.header_bytes..], payload);

    for (0..wire.len + 1) |split| {
        var collector: BodyCollector = .{};
        var memory = header_memory.of(&std.testing.allocator);
        var observer = Observer.init(&memory, &claude_routes, .response);
        defer observer.deinit();

        observer.observe(wire[0..split], &collector);
        observer.observe(wire[split..], &collector);

        try std.testing.expect(!observer.failed);
        try std.testing.expectEqualStrings(payload, collector.payloadSlice());
        try std.testing.expectEqual(@as(u32, 7), collector.stream_id);
        try std.testing.expectEqual(@as(u16, 0), collector.status_code);
        try std.testing.expect(!collector.sse_body);
        try std.testing.expect(collector.activity != 0);
        try std.testing.expectEqual(@as(usize, 1), collector.finished);
        try std.testing.expect(!collector.finished_before_body);
    }
}

test "HTTP2 observer attaches the decoded final status to response DATA" {
    var deflater: ?*c.nghttp2_hd_deflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_deflate_new(&deflater, 4096));
    defer c.nghttp2_hd_deflate_del(deflater);

    var fields = [_]c.nghttp2_nv{
        .{
            .name = @constCast(":status"),
            .value = @constCast("200"),
            .namelen = 7,
            .valuelen = 3,
            .flags = 0,
        },
        .{
            .name = @constCast("content-type"),
            .value = @constCast("text/event-stream"),
            .namelen = 12,
            .valuelen = 17,
            .flags = 0,
        },
    };
    var block: [64]u8 = undefined;
    const encoded = c.nghttp2_hd_deflate_hd(deflater, &block, block.len, &fields, fields.len);
    try std.testing.expect(encoded > 0);

    var header: [framing.header_bytes]u8 = undefined;
    writeFrameHeader(&header, .{ .length = @intCast(encoded), .frame_type = frame_headers, .flags = flag_end_headers, .stream_id = 17 });
    const payload = "payload";
    var data: [framing.header_bytes + payload.len]u8 = undefined;
    writeFrameHeader(data[0..framing.header_bytes], .{ .length = payload.len, .frame_type = frame_data, .flags = flag_end_stream, .stream_id = 17 });
    @memcpy(data[framing.header_bytes..], payload);
    var collector: BodyCollector = .{};
    var memory = header_memory.of(&std.testing.allocator);
    var observer = Observer.init(&memory, &claude_routes, .response);
    defer observer.deinit();

    observer.observe(&header, &collector);
    observer.observe(block[0..@intCast(encoded)], &collector);
    observer.observe(&data, &collector);

    try std.testing.expect(!observer.failed);
    try std.testing.expectEqualStrings(payload, collector.payloadSlice());
    try std.testing.expectEqual(@as(u16, 200), collector.status_code);
    try std.testing.expect(collector.sse_body);
    try std.testing.expectEqual(@as(usize, 1), collector.finished);
    try std.testing.expect(!collector.finished_before_body);
}

test "HTTP2 observer excludes the pad length and padding from DATA payload" {
    const payload = "hello";
    const padding_len = 2;
    var wire: [framing.header_bytes + 1 + payload.len + padding_len]u8 = @splat(0);
    writeFrameHeader(
        wire[0..framing.header_bytes],
        .{ .length = wire.len - framing.header_bytes, .frame_type = frame_data, .flags = flag_padded | flag_end_stream, .stream_id = 9 },
    );
    wire[framing.header_bytes] = padding_len;
    @memcpy(wire[framing.header_bytes + 1 ..][0..payload.len], payload);

    for (0..wire.len + 1) |split| {
        var collector: BodyCollector = .{};
        var memory = header_memory.of(&std.testing.allocator);
        var observer = Observer.init(&memory, &claude_routes, .response);
        defer observer.deinit();

        observer.observe(wire[0..split], &collector);
        observer.observe(wire[split..], &collector);

        try std.testing.expect(!observer.failed);
        try std.testing.expectEqualStrings(payload, collector.payloadSlice());
        try std.testing.expectEqual(@as(usize, 1), collector.finished);
    }
}

test "HTTP2 observer drops invalid DATA padding from observation only" {
    var wire: [framing.header_bytes + 2]u8 = @splat(0);
    writeFrameHeader(wire[0..framing.header_bytes], .{ .length = 2, .frame_type = frame_data, .flags = flag_padded | flag_end_stream, .stream_id = 11 });
    wire[framing.header_bytes] = 2;
    var collector: BodyCollector = .{};
    var memory = header_memory.of(&std.testing.allocator);
    var observer = Observer.init(&memory, &claude_routes, .response);
    defer observer.deinit();

    observer.observe(&wire, &collector);

    try std.testing.expect(!observer.failed);
    try std.testing.expectEqualStrings("", collector.payloadSlice());
    try std.testing.expectEqual(@as(usize, 1), collector.finished);
}

test "HPACK status turns a completed HTTP2 error stream into failure" {
    var deflater: ?*c.nghttp2_hd_deflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_deflate_new(&deflater, 8192));
    defer c.nghttp2_hd_deflate_del(deflater);
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.nghttp2_hd_deflate_change_table_size(deflater, 8192),
    );
    var fields = [_]c.nghttp2_nv{.{
        .name = @constCast(":status"),
        .value = @constCast("429"),
        .namelen = 7,
        .valuelen = 3,
        .flags = 0,
    }};
    var block: [256]u8 = undefined;
    const block_len = c.nghttp2_hd_deflate_hd(deflater, &block, block.len, &fields, fields.len);
    try std.testing.expect(block_len > 0);

    const encoded_len: usize = @intCast(block_len);
    const first_len = encoded_len / 2;
    const second_len = encoded_len - first_len;
    var frames: [2 * framing.header_bytes + block.len]u8 = undefined;
    writeFrameHeader(frames[0..framing.header_bytes], .{ .length = first_len, .frame_type = frame_headers, .flags = flag_end_stream, .stream_id = 1 });
    @memcpy(frames[framing.header_bytes..][0..first_len], block[0..first_len]);
    const second_header = framing.header_bytes + first_len;
    writeFrameHeader(
        frames[second_header..][0..framing.header_bytes],
        .{ .length = second_len, .frame_type = frame_continuation, .flags = flag_end_headers, .stream_id = 1 },
    );
    @memcpy(
        frames[second_header + framing.header_bytes ..][0..second_len],
        block[first_len..encoded_len],
    );

    const Collector = struct {
        stage: Lifecycle.Stage = .request_started,
        stream_id: u32 = 0,
        status_code: u16 = 0,
        pub fn emit(self: *@This(), event: Event) void {
            const observed = lifecycle(event) orelse return;
            self.stage = observed.stage;
            self.stream_id = observed.stream_id;
            self.status_code = observed.status_code;
        }
    };
    var collector: Collector = .{};
    var memory = header_memory.of(&std.testing.allocator);
    var observer = Observer.init(&memory, &claude_routes, .response);
    defer observer.deinit();
    for (frames[0 .. 2 * framing.header_bytes + encoded_len]) |byte|
        observer.observe(&.{byte}, &collector);
    try std.testing.expect(!observer.failed);
    try std.testing.expectEqual(Lifecycle.Stage.response_ended, collector.stage);
    try std.testing.expectEqual(@as(u32, 1), collector.stream_id);
    try std.testing.expectEqual(@as(u16, 429), collector.status_code);
}

test "request trailers do not emit a second request start" {
    var deflater: ?*c.nghttp2_hd_deflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_deflate_new(&deflater, 4096));
    defer c.nghttp2_hd_deflate_del(deflater);

    const Collector = struct {
        starts: usize = 0,
        pub fn emit(self: *@This(), event: Event) void {
            const observed = lifecycle(event) orelse return;

            if ((observed.stage == .request_started and observed.watched)) {
                self.starts += 1;
            }
        }
    };
    var collector: Collector = .{};
    var memory = header_memory.of(&std.testing.allocator);
    var observer = Observer.init(&memory, &claude_routes, .request);
    defer observer.deinit();
    var request_fields = [_]c.nghttp2_nv{
        .{ .name = @constCast(":method"), .value = @constCast("POST"), .namelen = 7, .valuelen = 4, .flags = 0 },
        .{ .name = @constCast(":path"), .value = @constCast("/v1/messages?beta=true"), .namelen = 5, .valuelen = 22, .flags = 0 },
    };
    var request_block: [256]u8 = undefined;
    const request_len = c.nghttp2_hd_deflate_hd(
        deflater,
        &request_block,
        request_block.len,
        &request_fields,
        request_fields.len,
    );
    try std.testing.expect(request_len > 0);
    var request_header: [framing.header_bytes]u8 = undefined;
    writeFrameHeader(&request_header, .{ .length = @intCast(request_len), .frame_type = frame_headers, .flags = flag_end_headers, .stream_id = 1 });
    observer.observe(&request_header, &collector);
    observer.observe(request_block[0..@intCast(request_len)], &collector);

    var trailer_fields = [_]c.nghttp2_nv{.{
        .name = @constCast("grpc-status"),
        .value = @constCast("0"),
        .namelen = 11,
        .valuelen = 1,
        .flags = 0,
    }};
    var trailer_block: [256]u8 = undefined;
    const trailer_len = c.nghttp2_hd_deflate_hd(
        deflater,
        &trailer_block,
        trailer_block.len,
        &trailer_fields,
        trailer_fields.len,
    );
    try std.testing.expect(trailer_len > 0);
    var trailer_header: [framing.header_bytes]u8 = undefined;
    writeFrameHeader(&trailer_header, .{ .length = @intCast(trailer_len), .frame_type = frame_headers, .flags = flag_end_headers, .stream_id = 1 });
    observer.observe(&trailer_header, &collector);
    observer.observe(trailer_block[0..@intCast(trailer_len)], &collector);

    try std.testing.expect(!observer.failed);
    try std.testing.expectEqual(@as(usize, 1), collector.starts);
}

test "HTTP2 requests outside the watched routes start as auxiliary" {
    var deflater: ?*c.nghttp2_hd_deflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_deflate_new(&deflater, 4096));
    defer c.nghttp2_hd_deflate_del(deflater);

    var fields = [_]c.nghttp2_nv{
        .{ .name = @constCast(":method"), .value = @constCast("POST"), .namelen = 7, .valuelen = 4, .flags = 0 },
        .{ .name = @constCast(":path"), .value = @constCast("/v1/messages"), .namelen = 5, .valuelen = 12, .flags = 0 },
    };
    var block: [256]u8 = undefined;
    const block_len = c.nghttp2_hd_deflate_hd(deflater, &block, block.len, &fields, fields.len);
    try std.testing.expect(block_len > 0);
    var header: [framing.header_bytes]u8 = undefined;
    writeFrameHeader(&header, .{ .length = @intCast(block_len), .frame_type = frame_headers, .flags = flag_end_headers, .stream_id = 1 });

    const Collector = struct {
        starts: usize = 0,
        auxiliary_starts: usize = 0,
        pub fn emit(self: *@This(), event: Event) void {
            const observed = lifecycle(event) orelse return;

            if ((observed.stage == .request_started and observed.watched)) {
                self.starts += 1;
            }
            if ((observed.stage == .request_started and !observed.watched)) {
                self.auxiliary_starts += 1;
            }
        }
    };
    var collector: Collector = .{};
    var memory = header_memory.of(&std.testing.allocator);
    var observer = Observer.init(&memory, &openai_routes, .request);
    defer observer.deinit();
    observer.observe(&header, &collector);
    observer.observe(block[0..@intCast(block_len)], &collector);

    try std.testing.expect(!observer.failed);
    try std.testing.expectEqual(@as(usize, 0), collector.starts);
    try std.testing.expectEqual(@as(usize, 1), collector.auxiliary_starts);
}

test "HPACK dynamic table survives padded response blocks" {
    var deflater: ?*c.nghttp2_hd_deflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_deflate_new(&deflater, 4096));
    defer c.nghttp2_hd_deflate_del(deflater);

    const Collector = struct {
        completed: usize = 0,
        pub fn emit(self: *@This(), event: Event) void {
            const observed = lifecycle(event) orelse return;

            if (observed.stage == .response_ended and observed.status_code == 200) {
                self.completed += 1;
            }
        }
    };
    var collector: Collector = .{};
    var memory = header_memory.of(&std.testing.allocator);
    var observer = Observer.init(&memory, &claude_routes, .response);
    defer observer.deinit();
    for (1..3) |stream_id| {
        var fields = [_]c.nghttp2_nv{
            .{ .name = @constCast(":status"), .value = @constCast("200"), .namelen = 7, .valuelen = 3, .flags = 0 },
            .{ .name = @constCast("x-telar-repeat"), .value = @constCast("same-value"), .namelen = 14, .valuelen = 10, .flags = 0 },
        };
        var block: [256]u8 = undefined;
        const encoded = c.nghttp2_hd_deflate_hd(deflater, &block, block.len, &fields, fields.len);
        try std.testing.expect(encoded > 0);
        const encoded_len: usize = @intCast(encoded);
        var header: [framing.header_bytes]u8 = undefined;
        writeFrameHeader(
            &header,
            .{ .length = 1 + encoded_len + 2, .frame_type = frame_headers, .flags = flag_padded | flag_end_headers | flag_end_stream, .stream_id = @intCast(stream_id) },
        );
        observer.observe(&header, &collector);
        observer.observe(&.{2}, &collector);
        observer.observe(block[0..encoded_len], &collector);
        observer.observe(&.{ 0, 0 }, &collector);
    }
    try std.testing.expect(!observer.failed);
    try std.testing.expectEqual(@as(usize, 2), collector.completed);
}

const FrameHeader = struct {
    length: usize,
    frame_type: u8,
    flags: u8,
    stream_id: u32,
};
