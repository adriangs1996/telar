//! HTTP/2 relay with bounded HPACK observation and optional head transforms.
//!
//! The observation path forwards every frame byte for byte. When a transformer
//! is installed, each direction transcodes only header blocks through an
//! independent inflater and deflater. DATA, flow control, and stream ownership
//! remain end to end in both modes.

const framing = @import("framing.zig");
const stream_state = @import("streams.zig");
const StatsType = @import("Stats.zig");
const LifecycleType = @import("Lifecycle.zig");
const RequestBodyType = @import("RequestBody.zig");
const RequestFinishedType = @import("RequestFinished.zig");
const ResponseBodyType = @import("ResponseBody.zig");
const HeaderFieldType = @import("HeaderField.zig");
const HeaderBlockType = @import("HeaderBlock.zig");
const PeerSettingsType = @import("PeerSettings.zig");
const RelayRoute = @import("RelayRoute.zig");
const TransformedRouteType = @import("TransformedRoute.zig");
const GenericTranscodePort = @import("GenericTranscodePort.zig").Type;
const Observer = @import("Observer.zig");
const std = @import("std");
const TranscodeConfiguration = @import("TranscodeConfiguration.zig");
const Transcoder = @import("Transcoder.zig");
const HeadersType = @import("../Headers.zig");
const middleware = @import("../middleware.zig");
const FrameHeader = @import("FrameHeader.zig");
const HeaderEmission = @import("HeaderEmission.zig");
const BodyCollector = @import("BodyCollector.zig");
const TestTranscodeSetup = @import("TestTranscodeSetup.zig");
const TransformationType = @import("../Transformation.zig");
const TransformPipelineType = @import("../TransformPipeline.zig");
const FakeWriteSession = @import("FakeWriteSession.zig");

pub const c = @cImport({
    @cInclude("nghttp2/nghttp2.h");
});

pub const frame_header_len = framing.header_bytes;
pub const client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
pub const max_header_block_bytes = 128 * 1024;
pub const max_tracked_streams = stream_state.max_tracked_streams;

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

pub const HeaderField = @import("HeaderField.zig");

pub const HeaderBlock = @import("HeaderBlock.zig");

/// One borrowed observation produced while relaying HTTP/2 frames.
pub const Event = union(enum) {
    lifecycle: LifecycleType,
    request_headers: HeaderBlockType,
    request_body: RequestBodyType,
    request_finished: RequestFinishedType,
    response_headers: HeaderBlockType,
    response_body: ResponseBodyType,
};

pub const PeerSettings = @import("PeerSettings.zig");

pub const Route = @import("RelayRoute.zig");

pub const TransformedRoute = @import("TransformedRoute.zig");

pub const HeaderKind = enum { none, headers, push_promise };

fn transcodePort(session: anytype, sink: anytype) GenericTranscodePort(@TypeOf(session), @TypeOf(sink)) {
    return .{ .session = session, .sink = sink };
}

/// Relays one HTTP/2 direction byte for byte while publishing decoded events.
///
/// ```zig
/// const stats = relay(session, route, &sink);
/// ```
pub fn relay(session: anytype, route: RelayRoute, sink: anytype) StatsType {
    var observer = Observer.init(route.dialect, route.direction);
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

/// Relays one direction while transcoding only its bounded header blocks.
///
/// ```zig
/// const stats = relayTransformed(session, route, &sink);
/// ```
pub fn relayTransformed(session: anytype, transformed_route: TransformedRouteType, sink: anytype) StatsType {
    const route = transformed_route.route;
    const configuration: TranscodeConfiguration = .{
        .direction = route.direction,
        .to = route.to,
        .source_settings = transformed_route.source_settings,
        .target_settings = transformed_route.target_settings,
        .pipeline = transformed_route.pipeline,
        .io = transformed_route.io,
        .transform_context = transformed_route.transform_context,
    };
    var transcoder = Transcoder.init(route.dialect, configuration);
    defer transcoder.deinit();
    const port = transcodePort(session, sink);
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
            ) or !session.writeAll(route.to, input[0..take])) {
                transcoder.failed = true;
                break;
            }
            preface_offset += take;
            input = input[take..];
        }
        if (!transcoder.process(input, port)) {
            break;
        }
    }
    if ((route.direction == .request and preface_offset != client_preface.len) or
        transcoder.framing.header_len != 0 or transcoder.framing.payload_left != 0 or
        transcoder.continuation_stream != 0)
    {
        transcoder.failed = true;
    }

    session.halfClose(route.to);
    return .{ .decode_failed = transcoder.failed };
}

pub fn headerKind(block_type: u8, headers: *const HeadersType) middleware.HeaderKind {
    if (block_type == frame_push_promise) {
        return .push_promise;
    }
    if (headers.find(":method") != null) {
        return .request;
    }
    if (headers.find(":status") != null) {
        return .response;
    }
    return .trailers;
}

pub fn parseStatusHeader(headers: *const HeadersType) u16 {
    return std.fmt.parseInt(u16, headers.find(":status") orelse return 0, 10) catch 0;
}

pub fn validH2Headers(headers: *const HeadersType, kind: middleware.HeaderKind) bool {
    var regular_seen = false;
    var method_seen = false;
    var scheme_seen = false;
    var authority_seen = false;
    var path_seen = false;
    var protocol_seen = false;
    var status_seen = false;
    for (headers.fields[0..headers.len]) |field| {
        const name = headers.name(field);
        const value = headers.value(field);
        if (value.len != 0 and (value[0] == ' ' or value[0] == '\t' or
            value[value.len - 1] == ' ' or value[value.len - 1] == '\t'))
        {
            return false;
        }
        for (name) |byte| if (std.ascii.isUpper(byte)) return false;
        const pseudo = name.len != 0 and name[0] == ':';
        if (pseudo and regular_seen) {
            return false;
        }
        regular_seen = regular_seen or !pseudo;
        if (pseudo) {
            const seen = if (std.mem.eql(u8, name, ":method")) &method_seen else if (std.mem.eql(
                u8,
                name,
                ":scheme",
            )) &scheme_seen else if (std.mem.eql(u8, name, ":authority")) &authority_seen else if (std.mem.eql(
                u8,
                name,
                ":path",
            )) &path_seen else if (std.mem.eql(u8, name, ":protocol")) &protocol_seen else if (std.mem.eql(
                u8,
                name,
                ":status",
            )) &status_seen else return false;
            if (seen.* or !pseudoAllowed(kind, name)) {
                return false;
            }
            seen.* = true;
        }
        if (std.mem.eql(u8, name, "connection") or
            std.mem.eql(u8, name, "keep-alive") or
            std.mem.eql(u8, name, "proxy-connection") or
            std.mem.eql(u8, name, "transfer-encoding") or
            std.mem.eql(u8, name, "upgrade"))
        {
            return false;
        }
        if (std.mem.eql(u8, name, "te") and
            !std.ascii.eqlIgnoreCase(value, "trailers"))
        {
            return false;
        }
        if (kind == .trailers and pseudo) {
            return false;
        }
    }
    return switch (kind) {
        .request, .push_promise => requestPseudosValid(headers, kind),
        .response => status_seen and validStatus(headers.find(":status").?),
        .trailers => true,
    };
}

fn pseudoAllowed(kind: middleware.HeaderKind, name: []const u8) bool {
    return switch (kind) {
        .request, .push_promise => std.mem.eql(u8, name, ":method") or
            std.mem.eql(u8, name, ":scheme") or
            std.mem.eql(u8, name, ":authority") or
            std.mem.eql(u8, name, ":path") or
            std.mem.eql(u8, name, ":protocol"),
        .response => std.mem.eql(u8, name, ":status"),
        .trailers => false,
    };
}

fn requestPseudosValid(headers: *const HeadersType, kind: middleware.HeaderKind) bool {
    const method = headers.find(":method") orelse return false;
    if (!validToken(method)) {
        return false;
    }
    const scheme = headers.find(":scheme");
    const authority = headers.find(":authority");
    const path = headers.find(":path");
    const protocol = headers.find(":protocol");
    if (authority) |value| {
        if (containsSpace(value)) {
            return false;
        }
    }
    if (scheme) |value| {
        if (!validScheme(value)) {
            return false;
        }
    }
    if (path) |value| {
        if (containsSpace(value)) {
            return false;
        }
    }
    if (protocol) |value| {
        if (!validToken(value)) {
            return false;
        }
    }
    if (kind == .push_promise and std.mem.eql(u8, method, "CONNECT")) {
        return false;
    }
    if (std.mem.eql(u8, method, "CONNECT")) {
        if (authority == null or authority.?.len == 0) {
            return false;
        }
        if (protocol == null) {
            return scheme == null and path == null;
        }
        return protocol.?.len != 0 and scheme != null and scheme.?.len != 0 and
            path != null and path.?.len != 0;
    }
    return protocol == null and scheme != null and scheme.?.len != 0 and
        path != null and path.?.len != 0;
}

fn validScheme(value: []const u8) bool {
    if (value.len == 0 or !std.ascii.isAlphabetic(value[0])) {
        return false;
    }
    for (value[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and
        byte != '+' and byte != '-' and byte != '.') return false;
    return true;
}

fn containsSpace(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, " \t") != null;
}

fn validToken(value: []const u8) bool {
    if (value.len == 0) {
        return false;
    }
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and
        byte != '!' and byte != '#' and byte != '$' and byte != '%' and
        byte != '&' and byte != '\'' and byte != '*' and byte != '+' and
        byte != '-' and byte != '.' and byte != '^' and byte != '_' and
        byte != '`' and byte != '|' and byte != '~') return false;
    return true;
}

fn validStatus(value: []const u8) bool {
    if (value.len != 3) {
        return false;
    }
    const status = std.fmt.parseInt(u16, value, 10) catch return false;
    return status >= 100 and status <= 599 and status != 101;
}

pub fn compatibleH2Headers(original: *const HeadersType, transformed: *const HeadersType, kind: middleware.HeaderKind) bool {
    if (!validH2Headers(transformed, kind) or
        !sameHeaderValues(original, transformed, "content-length"))
    {
        return false;
    }
    if (kind != .response) {
        return true;
    }
    return statusSemantics(parseStatusHeader(original)) ==
        statusSemantics(parseStatusHeader(transformed));
}

const StatusSemantics = enum { informational, bodyless, regular, invalid };

fn statusSemantics(status: u16) StatusSemantics {
    if (status >= 100 and status < 200 and status != 101) {
        return .informational;
    }
    if (status == 204 or status == 205 or status == 304) {
        return .bodyless;
    }
    if (status >= 200) {
        return .regular;
    }
    return .invalid;
}

fn sameHeaderValues(left: *const HeadersType, right: *const HeadersType, wanted: []const u8) bool {
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (true) {
        const left_value = nextHeaderValue(left, wanted, &left_index);
        const right_value = nextHeaderValue(right, wanted, &right_index);
        if (left_value == null or right_value == null) {
            return left_value == null and right_value == null;
        }
        if (!std.mem.eql(u8, left_value.?, right_value.?)) {
            return false;
        }
    }
}

fn nextHeaderValue(headers: *const HeadersType, wanted: []const u8, index: *usize) ?[]const u8 {
    while (index.* < headers.len) {
        const field = headers.fields[index.*];
        index.* += 1;
        if (std.mem.eql(u8, headers.name(field), wanted)) {
            return headers.value(field);
        }
    }
    return null;
}

pub fn promisedStreamId(transcoder: *const Transcoder) u32 {
    return (@as(u32, transcoder.block_prefix[0] & 0x7f) << 24) |
        (@as(u32, transcoder.block_prefix[1]) << 16) |
        (@as(u32, transcoder.block_prefix[2]) << 8) |
        transcoder.block_prefix[3];
}

pub fn isHeaderFrame(frame_type: u8) bool {
    return frame_type == frame_headers or
        frame_type == frame_push_promise or
        frame_type == frame_continuation;
}

fn streamId(header: *const [framing.header_bytes]u8) u32 {
    return (@as(u32, header[5] & 0x7f) << 24) |
        (@as(u32, header[6]) << 16) |
        (@as(u32, header[7]) << 8) |
        header[8];
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

pub fn emitHeaders(port: anytype, emission: HeaderEmission) void {
    for (emission.headers.fields[0..emission.headers.len]) |field| {
        const fields = [_]HeaderFieldType{.{
            .name = emission.headers.name(field),
            .value = emission.headers.value(field),
        }};
        switch (emission.direction) {
            .request => port.emit(.{ .request_headers = .{ .stream_id = emission.stream_id, .fields = &fields } }),
            .response => port.emit(.{ .response_headers = .{ .stream_id = emission.stream_id, .fields = &fields } }),
        }
    }
}

fn lifecycle(event: Event) ?LifecycleType {
    return switch (event) {
        .lifecycle => |value| value,
        .request_headers => null,
        .request_body => null,
        .request_finished => null,
        .response_headers => null,
        .response_body => null,
    };
}

test "HTTP2 observer exposes request DATA across every two-chunk split" {
    const payload = "{\"stream\":true}";
    var wire: [framing.header_bytes + payload.len]u8 = undefined;
    writeFrameHeader(wire[0..framing.header_bytes], .{ .length = payload.len, .frame_type = frame_data, .flags = flag_end_stream, .stream_id = 5 });
    @memcpy(wire[framing.header_bytes..], payload);

    for (0..wire.len + 1) |split| {
        var collector: BodyCollector = .{};
        var observer = Observer.init(.anthropic_messages, .request);
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
        var observer = Observer.init(.anthropic_messages, .request);
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
        var observer = Observer.init(.anthropic_messages, .response);
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
    var observer = Observer.init(.anthropic_messages, .response);
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
        var observer = Observer.init(.anthropic_messages, .response);
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
    var observer = Observer.init(.anthropic_messages, .response);
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
        phase: middleware.Phase = .request_started,
        stream_id: u32 = 0,
        status_code: u16 = 0,
        pub fn emit(self: *@This(), event: Event) void {
            const observed = lifecycle(event) orelse return;
            self.phase = observed.phase;
            self.stream_id = observed.stream_id;
            self.status_code = observed.status_code;
        }
    };
    var collector: Collector = .{};
    var observer = Observer.init(.anthropic_messages, .response);
    defer observer.deinit();
    for (frames[0 .. 2 * framing.header_bytes + encoded_len]) |byte|
        observer.observe(&.{byte}, &collector);
    try std.testing.expect(!observer.failed);
    try std.testing.expectEqual(middleware.Phase.request_failed, collector.phase);
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

            if (observed.phase == .request_started) {
                self.starts += 1;
            }
        }
    };
    var collector: Collector = .{};
    var observer = Observer.init(.anthropic_messages, .request);
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

test "cross-dialect HTTP2 requests are classified as auxiliary" {
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

            if (observed.phase == .request_started) {
                self.starts += 1;
            }
            if (observed.phase == .auxiliary_request_started) {
                self.auxiliary_starts += 1;
            }
        }
    };
    var collector: Collector = .{};
    var observer = Observer.init(.openai_responses, .request);
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

            if (observed.phase == .response_finished and observed.status_code == 200) {
                self.completed += 1;
            }
        }
    };
    var collector: Collector = .{};
    var observer = Observer.init(.anthropic_messages, .response);
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

fn decodeTestHeaderBlock(inflater: *c.nghttp2_hd_inflater, block: []const u8) !HeadersType {
    var headers: HeadersType = .{};
    var input = block;
    while (true) {
        var field: c.nghttp2_nv = undefined;
        var flags: c_int = 0;
        const consumed = c.nghttp2_hd_inflate_hd2(
            inflater,
            &field,
            &flags,
            input.ptr,
            input.len,
            1,
        );
        try std.testing.expect(consumed >= 0);
        input = input[@intCast(consumed)..];
        if (flags & c.NGHTTP2_HD_INFLATE_EMIT != 0) {
            try headers.append(.{
                .name = field.name[0..field.namelen],
                .value = field.value[0..field.valuelen],
                .sensitive = field.flags & c.NGHTTP2_NV_FLAG_NO_INDEX != 0,
            });
        }
        if (flags & c.NGHTTP2_HD_INFLATE_FINAL != 0) {
            try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_inflate_end_headers(inflater));
            return headers;
        }
        try std.testing.expect(consumed != 0 or flags & c.NGHTTP2_HD_INFLATE_EMIT != 0);
    }
}

fn initTestTranscoder(setup: TestTranscodeSetup) Transcoder {
    return Transcoder.init(setup.dialect, .{
        .direction = setup.direction,
        .to = setup.to,
        .source_settings = setup.source_settings,
        .target_settings = setup.target_settings,
        .pipeline = setup.pipeline,
        .io = std.testing.io,
        .transform_context = undefined,
    });
}

test "HTTP2 transcoder applies a header transform across arbitrary input splits" {
    var input_deflater: ?*c.nghttp2_hd_deflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_deflate_new(&input_deflater, 8192));
    defer c.nghttp2_hd_deflate_del(input_deflater);
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.nghttp2_hd_deflate_change_table_size(input_deflater, 8192),
    );
    var fields = [_]c.nghttp2_nv{
        .{ .name = @constCast(":method"), .value = @constCast("POST"), .namelen = 7, .valuelen = 4, .flags = 0 },
        .{ .name = @constCast(":scheme"), .value = @constCast("https"), .namelen = 7, .valuelen = 5, .flags = 0 },
        .{ .name = @constCast(":path"), .value = @constCast("/v1/responses"), .namelen = 5, .valuelen = 13, .flags = 0 },
        .{ .name = @constCast(":authority"), .value = @constCast("api.example"), .namelen = 10, .valuelen = 11, .flags = 0 },
    };
    var compressed: [512]u8 = undefined;
    const compressed_len = c.nghttp2_hd_deflate_hd2(
        input_deflater,
        &compressed,
        compressed.len,
        &fields,
        fields.len,
    );
    try std.testing.expect(compressed_len > 0);
    var frame: [framing.header_bytes + compressed.len]u8 = undefined;
    writeFrameHeader(
        frame[0..framing.header_bytes],
        .{ .length = @intCast(compressed_len), .frame_type = frame_headers, .flags = flag_end_headers | flag_end_stream, .stream_id = 1 },
    );
    @memcpy(
        frame[framing.header_bytes..][0..@intCast(compressed_len)],
        compressed[0..@intCast(compressed_len)],
    );

    const AddHeader = struct {
        fn transform(_: *anyopaque, transformation: TransformationType) middleware.TransformStatus {
            transformation.effects.set(.{ .name = "x-telar", .value = "enabled" }) catch return .preserve;
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: TransformPipelineType = .{};
    try pipeline.add(.{ .context = &ignored, .transform = AddHeader.transform });
    var session: FakeWriteSession = .{};
    const Collector = struct {
        session: *const FakeWriteSession,
        starts: usize = 0,
        auxiliary_starts: usize = 0,
        output_bytes_at_start: usize = 0,

        pub fn emit(self: *@This(), event: Event) void {
            const observed = lifecycle(event) orelse return;

            if (observed.phase == .request_started) {
                self.starts += 1;
                self.output_bytes_at_start = self.session.len;
            }

            if (observed.phase == .auxiliary_request_started) {
                self.auxiliary_starts += 1;
            }
        }
    };
    var collector: Collector = .{ .session = &session };
    var source_settings: PeerSettingsType = .{};
    var target_settings: PeerSettingsType = .{};
    target_settings.header_table_size.store(8192, .seq_cst);
    var transcoder = initTestTranscoder(.{ .dialect = .openai_responses, .direction = .request, .to = .origin, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
    defer transcoder.deinit();
    for (frame[0 .. framing.header_bytes + @as(usize, @intCast(compressed_len))]) |byte|
        try std.testing.expect(transcoder.process(
            &.{byte},
            transcodePort(&session, &collector),
        ));

    try std.testing.expectEqual(@as(usize, 1), collector.starts);
    try std.testing.expectEqual(@as(usize, 0), collector.output_bytes_at_start);
    try std.testing.expectEqual(frame_headers, session.output[3]);
    try std.testing.expect(session.output[4] & flag_end_headers != 0);
    const output_len = (@as(usize, session.output[0]) << 16) |
        (@as(usize, session.output[1]) << 8) | session.output[2];
    try std.testing.expectEqual(framing.header_bytes + output_len, session.len);
    var output_inflater: ?*c.nghttp2_hd_inflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_inflate_new(&output_inflater));
    defer c.nghttp2_hd_inflate_del(output_inflater);
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.nghttp2_hd_inflate_change_table_size(output_inflater, 8192),
    );
    const decoded = try decodeTestHeaderBlock(
        output_inflater.?,
        session.output[framing.header_bytes..][0..output_len],
    );
    try std.testing.expectEqualStrings("enabled", decoded.find("x-telar").?);
    try std.testing.expectEqualStrings("POST", decoded.find(":method").?);
    try std.testing.expectEqual(
        @as(usize, 8192),
        c.nghttp2_hd_inflate_get_max_dynamic_table_size(transcoder.inflater.?),
    );

    var auxiliary_fields = [_]c.nghttp2_nv{
        .{ .name = @constCast(":method"), .value = @constCast("POST"), .namelen = 7, .valuelen = 4, .flags = 0 },
        .{ .name = @constCast(":scheme"), .value = @constCast("https"), .namelen = 7, .valuelen = 5, .flags = 0 },
        .{ .name = @constCast(":path"), .value = @constCast("/api/event_logging/v2/batch"), .namelen = 5, .valuelen = 27, .flags = 0 },
        .{ .name = @constCast(":authority"), .value = @constCast("api.example"), .namelen = 10, .valuelen = 11, .flags = 0 },
    };
    var auxiliary_compressed: [512]u8 = undefined;
    const auxiliary_len = c.nghttp2_hd_deflate_hd2(
        input_deflater,
        &auxiliary_compressed,
        auxiliary_compressed.len,
        &auxiliary_fields,
        auxiliary_fields.len,
    );
    try std.testing.expect(auxiliary_len > 0);
    var auxiliary_frame: [framing.header_bytes + auxiliary_compressed.len]u8 = undefined;
    writeFrameHeader(
        auxiliary_frame[0..framing.header_bytes],
        .{ .length = @intCast(auxiliary_len), .frame_type = frame_headers, .flags = flag_end_headers | flag_end_stream, .stream_id = 3 },
    );
    @memcpy(
        auxiliary_frame[framing.header_bytes..][0..@intCast(auxiliary_len)],
        auxiliary_compressed[0..@intCast(auxiliary_len)],
    );
    for (auxiliary_frame[0 .. framing.header_bytes + @as(usize, @intCast(auxiliary_len))]) |byte|
        try std.testing.expect(transcoder.process(
            &.{byte},
            transcodePort(&session, &collector),
        ));
    try std.testing.expectEqual(@as(usize, 1), collector.starts);
    try std.testing.expectEqual(@as(usize, 1), collector.auxiliary_starts);
}

test "HTTP2 transcoder preserves continuation padding priority and HPACK state" {
    var input_deflater: ?*c.nghttp2_hd_deflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_deflate_new(&input_deflater, 4096));
    defer c.nghttp2_hd_deflate_del(input_deflater);
    var output_inflater: ?*c.nghttp2_hd_inflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_inflate_new(&output_inflater));
    defer c.nghttp2_hd_inflate_del(output_inflater);

    const Identity = struct {
        fn transform(_: *anyopaque, _: TransformationType) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: TransformPipelineType = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });
    const Collector = struct {
        completed: usize = 0,
        pub fn emit(self: *@This(), event: Event) void {
            const observed = lifecycle(event) orelse return;

            if (observed.phase == .response_finished and observed.status_code == 200) {
                self.completed += 1;
            }
        }
    };
    var collector: Collector = .{};
    var session: FakeWriteSession = .{};
    var source_settings: PeerSettingsType = .{};
    var target_settings: PeerSettingsType = .{};
    var transcoder = initTestTranscoder(.{ .dialect = .anthropic_messages, .direction = .response, .to = .child, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
    defer transcoder.deinit();

    for (1..3) |stream_id| {
        var fields = [_]c.nghttp2_nv{
            .{ .name = @constCast(":status"), .value = @constCast("200"), .namelen = 7, .valuelen = 3, .flags = 0 },
            .{ .name = @constCast("x-repeat"), .value = @constCast("same-value"), .namelen = 8, .valuelen = 10, .flags = 0 },
        };
        var compressed: [512]u8 = undefined;
        const encoded = c.nghttp2_hd_deflate_hd2(
            input_deflater,
            &compressed,
            compressed.len,
            &fields,
            fields.len,
        );
        try std.testing.expect(encoded > 1);
        const encoded_len: usize = @intCast(encoded);
        const first_len = encoded_len / 2;
        const second_len = encoded_len - first_len;
        var wire: [2 * framing.header_bytes + 1 + 5 + 512 + 2]u8 = undefined;
        const first_payload_len = 1 + 5 + first_len + 2;
        writeFrameHeader(
            wire[0..framing.header_bytes],
            .{ .length = first_payload_len, .frame_type = frame_headers, .flags = flag_padded | flag_priority | flag_end_stream, .stream_id = @intCast(stream_id) },
        );
        var cursor: usize = framing.header_bytes;
        wire[cursor] = 2;
        cursor += 1;
        const priority = [_]u8{ 0, 0, 0, 0, 16 };
        @memcpy(wire[cursor..][0..priority.len], &priority);
        cursor += priority.len;
        @memcpy(wire[cursor..][0..first_len], compressed[0..first_len]);
        cursor += first_len;
        @memset(wire[cursor..][0..2], 0);
        cursor += 2;
        writeFrameHeader(
            wire[cursor..][0..framing.header_bytes],
            .{ .length = second_len, .frame_type = frame_continuation, .flags = flag_end_headers, .stream_id = @intCast(stream_id) },
        );
        cursor += framing.header_bytes;
        @memcpy(wire[cursor..][0..second_len], compressed[first_len..encoded_len]);
        cursor += second_len;

        const output_start = session.len;
        for (wire[0..cursor]) |byte| try std.testing.expect(transcoder.process(
            &.{byte},
            transcodePort(&session, &collector),
        ));
        const output = session.output[output_start..session.len];
        try std.testing.expectEqual(frame_headers, output[3]);
        try std.testing.expect(output[4] & flag_padded == 0);
        try std.testing.expect(output[4] & flag_priority != 0);
        try std.testing.expect(output[4] & flag_end_headers != 0);
        try std.testing.expectEqualSlices(u8, &priority, output[framing.header_bytes..][0..5]);
        const output_payload_len = (@as(usize, output[0]) << 16) |
            (@as(usize, output[1]) << 8) | output[2];
        const decoded = try decodeTestHeaderBlock(
            output_inflater.?,
            output[framing.header_bytes + priority.len ..][0 .. output_payload_len - priority.len],
        );
        try std.testing.expectEqualStrings("200", decoded.find(":status").?);
        try std.testing.expectEqualStrings("same-value", decoded.find("x-repeat").?);
    }
    try std.testing.expectEqual(@as(usize, 2), collector.completed);
}

test "HTTP2 transcoder fragments encoded heads to the peer frame limit" {
    const test_stream_id: u32 = 513;
    var input_deflater: ?*c.nghttp2_hd_deflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_deflate_new(&input_deflater, 4096));
    defer c.nghttp2_hd_deflate_del(input_deflater);
    var large_value: [20 * 1024]u8 = @splat(0xff);
    var fields = [_]c.nghttp2_nv{
        .{ .name = @constCast(":method"), .value = @constCast("GET"), .namelen = 7, .valuelen = 3, .flags = 0 },
        .{ .name = @constCast(":scheme"), .value = @constCast("https"), .namelen = 7, .valuelen = 5, .flags = 0 },
        .{ .name = @constCast(":path"), .value = @constCast("/large"), .namelen = 5, .valuelen = 6, .flags = 0 },
        .{ .name = @constCast("x-large"), .value = &large_value, .namelen = 7, .valuelen = large_value.len, .flags = c.NGHTTP2_NV_FLAG_NO_INDEX },
    };
    var compressed: [64 * 1024]u8 = undefined;
    const compressed_len_raw = c.nghttp2_hd_deflate_hd2(
        input_deflater,
        &compressed,
        compressed.len,
        &fields,
        fields.len,
    );
    try std.testing.expect(compressed_len_raw > 16 * 1024);
    const compressed_len: usize = @intCast(compressed_len_raw);

    var input_wire: [96 * 1024]u8 = undefined;
    var input_len: usize = 0;
    var encoded_offset: usize = 0;
    var first = true;
    while (encoded_offset < compressed_len) {
        const fragment_len = @min(@as(usize, 16 * 1024), compressed_len - encoded_offset);
        const final = encoded_offset + fragment_len == compressed_len;
        writeFrameHeader(
            input_wire[input_len..][0..framing.header_bytes],
            .{ .length = fragment_len, .frame_type = if (first) frame_headers else frame_continuation, .flags = if (final) flag_end_headers else 0, .stream_id = test_stream_id },
        );
        input_len += framing.header_bytes;
        @memcpy(
            input_wire[input_len..][0..fragment_len],
            compressed[encoded_offset..][0..fragment_len],
        );
        input_len += fragment_len;
        encoded_offset += fragment_len;
        first = false;
    }

    const Identity = struct {
        fn transform(_: *anyopaque, _: TransformationType) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: TransformPipelineType = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });
    const Collector = struct {
        pub fn emit(_: *@This(), _: Event) void {}
    };
    var collector: Collector = .{};
    var session: FakeWriteSession = .{};
    var source_settings: PeerSettingsType = .{};
    var target_settings: PeerSettingsType = .{};
    var transcoder = initTestTranscoder(.{ .dialect = .anthropic_messages, .direction = .request, .to = .origin, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
    defer transcoder.deinit();
    var input_offset: usize = 0;
    while (input_offset < input_len) {
        const take = @min(@as(usize, 137), input_len - input_offset);
        try std.testing.expect(transcoder.process(
            input_wire[input_offset..][0..take],
            transcodePort(&session, &collector),
        ));
        input_offset += take;
    }

    var output_block: [64 * 1024]u8 = undefined;
    var output_block_len: usize = 0;
    var output_offset: usize = 0;
    var frame_count: usize = 0;
    var final_seen = false;
    while (output_offset < session.len) {
        const header = session.output[output_offset..][0..framing.header_bytes];
        const payload_len = (@as(usize, header[0]) << 16) |
            (@as(usize, header[1]) << 8) | header[2];
        try std.testing.expect(payload_len <= 16 * 1024);
        try std.testing.expectEqual(
            if (frame_count == 0) frame_headers else frame_continuation,
            header[3],
        );
        try std.testing.expectEqual(test_stream_id, streamId(header));
        try std.testing.expect(output_offset + framing.header_bytes + payload_len <= session.len);
        @memcpy(
            output_block[output_block_len..][0..payload_len],
            session.output[output_offset + framing.header_bytes ..][0..payload_len],
        );
        output_block_len += payload_len;
        final_seen = header[4] & flag_end_headers != 0;
        if (final_seen) {
            try std.testing.expectEqual(session.len, output_offset + framing.header_bytes + payload_len);
        }
        output_offset += framing.header_bytes + payload_len;
        frame_count += 1;
    }
    try std.testing.expect(frame_count > 1);
    try std.testing.expect(final_seen);

    var output_inflater: ?*c.nghttp2_hd_inflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_inflate_new(&output_inflater));
    defer c.nghttp2_hd_inflate_del(output_inflater);
    const decoded = try decodeTestHeaderBlock(
        output_inflater.?,
        output_block[0..output_block_len],
    );
    try std.testing.expectEqualSlices(u8, &large_value, decoded.find("x-large").?);
}

test "HTTP2 SETTINGS update the opposite encoder bounds without changing wire bytes" {
    const Identity = struct {
        fn transform(_: *anyopaque, _: TransformationType) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: TransformPipelineType = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });
    const Collector = struct {
        pub fn emit(_: *@This(), _: Event) void {}
    };
    var collector: Collector = .{};
    var session: FakeWriteSession = .{};
    var child_settings: PeerSettingsType = .{};
    var origin_settings: PeerSettingsType = .{};
    var transcoder = initTestTranscoder(.{ .dialect = .anthropic_messages, .direction = .request, .to = .origin, .source_settings = &child_settings, .target_settings = &origin_settings, .pipeline = &pipeline });
    defer transcoder.deinit();

    var settings_frame: [framing.header_bytes + 12]u8 = undefined;
    writeFrameHeader(settings_frame[0..framing.header_bytes], .{ .length = 12, .frame_type = c.NGHTTP2_SETTINGS, .flags = 0, .stream_id = 0 });
    std.mem.writeInt(u16, settings_frame[9..11], c.NGHTTP2_SETTINGS_HEADER_TABLE_SIZE, .big);
    std.mem.writeInt(u32, settings_frame[11..15], 0, .big);
    std.mem.writeInt(u16, settings_frame[15..17], c.NGHTTP2_SETTINGS_MAX_FRAME_SIZE, .big);
    std.mem.writeInt(u32, settings_frame[17..21], 32 * 1024, .big);
    try std.testing.expect(transcoder.process(
        &settings_frame,
        transcodePort(&session, &collector),
    ));
    try std.testing.expectEqualSlices(u8, &settings_frame, session.output[0..session.len]);
    try std.testing.expectEqual(@as(u32, 0), child_settings.header_table_size.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 32 * 1024), child_settings.max_frame_size.load(.monotonic));
}

test "HTTP2 transform mode carries SSE response metadata into DATA events" {
    var input_deflater: ?*c.nghttp2_hd_deflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_deflate_new(&input_deflater, 4096));
    defer c.nghttp2_hd_deflate_del(input_deflater);
    var fields = [_]c.nghttp2_nv{
        .{ .name = @constCast(":status"), .value = @constCast("200"), .namelen = 7, .valuelen = 3, .flags = 0 },
        .{ .name = @constCast("content-type"), .value = @constCast("text/event-stream"), .namelen = 12, .valuelen = 17, .flags = 0 },
    };
    var compressed: [128]u8 = undefined;
    const compressed_len = c.nghttp2_hd_deflate_hd(
        input_deflater,
        &compressed,
        compressed.len,
        &fields,
        fields.len,
    );
    try std.testing.expect(compressed_len > 0);
    var header: [framing.header_bytes]u8 = undefined;
    writeFrameHeader(&header, .{ .length = @intCast(compressed_len), .frame_type = frame_headers, .flags = flag_end_headers, .stream_id = 19 });

    const payload = "payload";
    var data: [framing.header_bytes + payload.len]u8 = undefined;
    writeFrameHeader(data[0..framing.header_bytes], .{ .length = payload.len, .frame_type = frame_data, .flags = flag_end_stream, .stream_id = 19 });
    @memcpy(data[framing.header_bytes..], payload);

    const Identity = struct {
        fn transform(_: *anyopaque, _: TransformationType) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: TransformPipelineType = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });
    var collector: BodyCollector = .{};
    var session: FakeWriteSession = .{};
    var source_settings: PeerSettingsType = .{};
    var target_settings: PeerSettingsType = .{};
    var transcoder = initTestTranscoder(.{ .dialect = .anthropic_messages, .direction = .response, .to = .child, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
    defer transcoder.deinit();

    try std.testing.expect(transcoder.process(
        &header,
        transcodePort(&session, &collector),
    ));
    try std.testing.expect(transcoder.process(
        compressed[0..@intCast(compressed_len)],
        transcodePort(&session, &collector),
    ));
    try std.testing.expect(transcoder.process(
        &data,
        transcodePort(&session, &collector),
    ));

    try std.testing.expectEqualStrings(payload, collector.payloadSlice());
    try std.testing.expectEqual(@as(u16, 200), collector.status_code);
    try std.testing.expect(collector.sse_body);
    try std.testing.expect(!collector.finished_before_body);
    try std.testing.expectEqualSlices(u8, &data, session.output[session.len - data.len .. session.len]);
}

test "HTTP2 transform mode exposes unpadded response DATA without changing wire bytes" {
    const Identity = struct {
        fn transform(_: *anyopaque, _: TransformationType) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: TransformPipelineType = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });

    const payload = "event: message_delta\ndata: transformed\n\n";
    var wire: [framing.header_bytes + payload.len]u8 = undefined;
    writeFrameHeader(wire[0..framing.header_bytes], .{ .length = payload.len, .frame_type = frame_data, .flags = flag_end_stream, .stream_id = 13 });
    @memcpy(wire[framing.header_bytes..], payload);

    for (0..wire.len + 1) |split| {
        var collector: BodyCollector = .{};
        var session: FakeWriteSession = .{};
        var source_settings: PeerSettingsType = .{};
        var target_settings: PeerSettingsType = .{};
        var transcoder = initTestTranscoder(.{ .dialect = .anthropic_messages, .direction = .response, .to = .child, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
        defer transcoder.deinit();

        try std.testing.expect(transcoder.process(
            wire[0..split],
            transcodePort(&session, &collector),
        ));
        try std.testing.expect(transcoder.process(
            wire[split..],
            transcodePort(&session, &collector),
        ));

        try std.testing.expectEqualSlices(u8, &wire, session.output[0..session.len]);
        try std.testing.expectEqualStrings(payload, collector.payloadSlice());
        try std.testing.expectEqual(@as(u32, 13), collector.stream_id);
        try std.testing.expectEqual(@as(usize, 1), collector.finished);
    }
}

test "HTTP2 transform mode exposes request DATA without changing wire bytes" {
    const Identity = struct {
        fn transform(_: *anyopaque, _: TransformationType) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: TransformPipelineType = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });

    const payload = "{\"stream\":true}";
    var wire: [framing.header_bytes + payload.len]u8 = undefined;
    writeFrameHeader(wire[0..framing.header_bytes], .{ .length = payload.len, .frame_type = frame_data, .flags = flag_end_stream, .stream_id = 21 });
    @memcpy(wire[framing.header_bytes..], payload);

    for (0..wire.len + 1) |split| {
        var collector: BodyCollector = .{};
        var session: FakeWriteSession = .{};
        var source_settings: PeerSettingsType = .{};
        var target_settings: PeerSettingsType = .{};
        var transcoder = initTestTranscoder(.{ .dialect = .anthropic_messages, .direction = .request, .to = .origin, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
        defer transcoder.deinit();

        try std.testing.expect(transcoder.process(
            wire[0..split],
            transcodePort(&session, &collector),
        ));
        try std.testing.expect(transcoder.process(
            wire[split..],
            transcodePort(&session, &collector),
        ));

        try std.testing.expectEqualSlices(u8, &wire, session.output[0..session.len]);
        try std.testing.expectEqualStrings(payload, collector.payloadSlice());
        try std.testing.expectEqual(@as(u32, 21), collector.stream_id);
        try std.testing.expect(collector.request_body);
        try std.testing.expectEqual(@as(usize, 1), collector.request_finished);
        try std.testing.expectEqual(@as(usize, 0), collector.activity);
        try std.testing.expectEqual(@as(usize, 0), collector.finished);
    }
}

test "HTTP2 transform mode excludes DATA padding under single-byte reads" {
    const Identity = struct {
        fn transform(_: *anyopaque, _: TransformationType) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: TransformPipelineType = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });

    const payload = "payload";
    const padding_len = 3;
    var wire: [framing.header_bytes + 1 + payload.len + padding_len]u8 = @splat(0);
    writeFrameHeader(
        wire[0..framing.header_bytes],
        .{ .length = wire.len - framing.header_bytes, .frame_type = frame_data, .flags = flag_padded | flag_end_stream, .stream_id = 15 },
    );
    wire[framing.header_bytes] = padding_len;
    @memcpy(wire[framing.header_bytes + 1 ..][0..payload.len], payload);

    var collector: BodyCollector = .{};
    var session: FakeWriteSession = .{};
    var source_settings: PeerSettingsType = .{};
    var target_settings: PeerSettingsType = .{};
    var transcoder = initTestTranscoder(.{ .dialect = .anthropic_messages, .direction = .response, .to = .child, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
    defer transcoder.deinit();

    for (wire) |byte| {
        try std.testing.expect(transcoder.process(
            &.{byte},
            transcodePort(&session, &collector),
        ));
    }

    try std.testing.expectEqualSlices(u8, &wire, session.output[0..session.len]);
    try std.testing.expectEqualStrings(payload, collector.payloadSlice());
    try std.testing.expectEqual(@as(usize, 1), collector.finished);
}

test "HTTP2 transform mode relays DATA and control frames byte for byte" {
    const Identity = struct {
        fn transform(_: *anyopaque, _: TransformationType) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: TransformPipelineType = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });
    const Collector = struct {
        pub fn emit(_: *@This(), _: Event) void {}
    };
    var collector: Collector = .{};
    var session: FakeWriteSession = .{};
    var source_settings: PeerSettingsType = .{};
    var target_settings: PeerSettingsType = .{};
    var transcoder = initTestTranscoder(.{ .dialect = .anthropic_messages, .direction = .request, .to = .origin, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
    defer transcoder.deinit();

    var wire: [3 * framing.header_bytes + 17]u8 = undefined;
    var cursor: usize = 0;
    writeFrameHeader(wire[cursor..][0..framing.header_bytes], .{ .length = 5, .frame_type = frame_data, .flags = 0, .stream_id = 1 });
    cursor += framing.header_bytes;
    @memcpy(wire[cursor..][0..5], "hello");
    cursor += 5;
    writeFrameHeader(wire[cursor..][0..framing.header_bytes], .{ .length = 4, .frame_type = 0x8, .flags = 0, .stream_id = 1 });
    cursor += framing.header_bytes;
    std.mem.writeInt(u32, wire[cursor..][0..4], 1024, .big);
    cursor += 4;
    writeFrameHeader(wire[cursor..][0..framing.header_bytes], .{ .length = 8, .frame_type = 0x6, .flags = 0, .stream_id = 0 });
    cursor += framing.header_bytes;
    @memcpy(wire[cursor..][0..8], "12345678");
    cursor += 8;

    for (wire[0..cursor]) |byte| try std.testing.expect(transcoder.process(
        &.{byte},
        transcodePort(&session, &collector),
    ));
    try std.testing.expectEqualSlices(u8, wire[0..cursor], session.output[0..session.len]);
}

test "HTTP2 invalid transform effects preserve the original semantic head" {
    var input_deflater: ?*c.nghttp2_hd_deflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_deflate_new(&input_deflater, 4096));
    defer c.nghttp2_hd_deflate_del(input_deflater);
    var fields = [_]c.nghttp2_nv{
        .{ .name = @constCast(":method"), .value = @constCast("POST"), .namelen = 7, .valuelen = 4, .flags = 0 },
        .{ .name = @constCast(":scheme"), .value = @constCast("https"), .namelen = 7, .valuelen = 5, .flags = 0 },
        .{ .name = @constCast(":path"), .value = @constCast("/v1/messages"), .namelen = 5, .valuelen = 12, .flags = 0 },
        .{ .name = @constCast(":authority"), .value = @constCast("api.example"), .namelen = 10, .valuelen = 11, .flags = 0 },
        .{ .name = @constCast("content-length"), .value = @constCast("4"), .namelen = 14, .valuelen = 1, .flags = 0 },
    };
    var compressed: [512]u8 = undefined;
    const compressed_len = c.nghttp2_hd_deflate_hd2(
        input_deflater,
        &compressed,
        compressed.len,
        &fields,
        fields.len,
    );
    try std.testing.expect(compressed_len > 0);
    var frame: [framing.header_bytes + compressed.len]u8 = undefined;
    writeFrameHeader(
        frame[0..framing.header_bytes],
        .{ .length = @intCast(compressed_len), .frame_type = frame_headers, .flags = flag_end_headers, .stream_id = 1 },
    );
    @memcpy(
        frame[framing.header_bytes..][0..@intCast(compressed_len)],
        compressed[0..@intCast(compressed_len)],
    );

    const Invalid = struct {
        fn transform(_: *anyopaque, transformation: TransformationType) middleware.TransformStatus {
            transformation.effects.remove(":scheme") catch return .preserve;
            transformation.effects.set(.{ .name = "content-length", .value = "9" }) catch return .preserve;
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: TransformPipelineType = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Invalid.transform });
    const Collector = struct {
        pub fn emit(_: *@This(), _: Event) void {}
    };
    var collector: Collector = .{};
    var session: FakeWriteSession = .{};
    var source_settings: PeerSettingsType = .{};
    var target_settings: PeerSettingsType = .{};
    var transcoder = initTestTranscoder(.{ .dialect = .anthropic_messages, .direction = .request, .to = .origin, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
    defer transcoder.deinit();
    try std.testing.expect(transcoder.process(
        frame[0 .. framing.header_bytes + @as(usize, @intCast(compressed_len))],
        transcodePort(&session, &collector),
    ));

    const output_len = (@as(usize, session.output[0]) << 16) |
        (@as(usize, session.output[1]) << 8) | session.output[2];
    var output_inflater: ?*c.nghttp2_hd_inflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_inflate_new(&output_inflater));
    defer c.nghttp2_hd_inflate_del(output_inflater);
    const decoded = try decodeTestHeaderBlock(
        output_inflater.?,
        session.output[framing.header_bytes..][0..output_len],
    );
    try std.testing.expectEqualStrings("https", decoded.find(":scheme").?);
    try std.testing.expectEqualStrings("4", decoded.find("content-length").?);
}

test "HTTP2 PUSH_PROMISE exposes the promised stream to transformers" {
    var input_deflater: ?*c.nghttp2_hd_deflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_deflate_new(&input_deflater, 4096));
    defer c.nghttp2_hd_deflate_del(input_deflater);
    var fields = [_]c.nghttp2_nv{
        .{ .name = @constCast(":method"), .value = @constCast("GET"), .namelen = 7, .valuelen = 3, .flags = 0 },
        .{ .name = @constCast(":scheme"), .value = @constCast("https"), .namelen = 7, .valuelen = 5, .flags = 0 },
        .{ .name = @constCast(":path"), .value = @constCast("/asset"), .namelen = 5, .valuelen = 6, .flags = 0 },
        .{ .name = @constCast(":authority"), .value = @constCast("api.example"), .namelen = 10, .valuelen = 11, .flags = 0 },
    };
    var compressed: [512]u8 = undefined;
    const compressed_len = c.nghttp2_hd_deflate_hd2(
        input_deflater,
        &compressed,
        compressed.len,
        &fields,
        fields.len,
    );
    try std.testing.expect(compressed_len > 0);
    var frame: [framing.header_bytes + 4 + compressed.len]u8 = undefined;
    writeFrameHeader(
        frame[0..framing.header_bytes],
        .{ .length = 4 + @as(usize, @intCast(compressed_len)), .frame_type = frame_push_promise, .flags = flag_end_headers, .stream_id = 1 },
    );
    std.mem.writeInt(u32, frame[framing.header_bytes..][0..4], 2, .big);
    @memcpy(
        frame[framing.header_bytes + 4 ..][0..@intCast(compressed_len)],
        compressed[0..@intCast(compressed_len)],
    );

    const Capture = struct {
        stream_id: u32 = 0,
        kind: middleware.HeaderKind = .trailers,
        fn transform(raw: *anyopaque, transformation: TransformationType) middleware.TransformStatus {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.stream_id = transformation.snapshot.context.stream_id;
            self.kind = transformation.snapshot.context.kind;
            return .preserve;
        }
    };
    var capture: Capture = .{};
    var pipeline: TransformPipelineType = .{};
    try pipeline.add(.{ .context = &capture, .transform = Capture.transform });
    const Collector = struct {
        pub fn emit(_: *@This(), _: Event) void {}
    };
    var collector: Collector = .{};
    var session: FakeWriteSession = .{};
    var source_settings: PeerSettingsType = .{};
    var target_settings: PeerSettingsType = .{};
    var transcoder = initTestTranscoder(.{ .dialect = .anthropic_messages, .direction = .response, .to = .child, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
    defer transcoder.deinit();
    try std.testing.expect(transcoder.process(
        frame[0 .. framing.header_bytes + 4 + @as(usize, @intCast(compressed_len))],
        transcodePort(&session, &collector),
    ));
    try std.testing.expectEqual(@as(u32, 2), capture.stream_id);
    try std.testing.expectEqual(middleware.HeaderKind.push_promise, capture.kind);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(
        u32,
        session.output[framing.header_bytes..][0..4],
        .big,
    ));
}
