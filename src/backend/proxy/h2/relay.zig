//! HTTP/2 relay with bounded HPACK observation and optional head transforms.
//!
//! The observation path forwards every frame byte for byte. When a transformer
//! is installed, each direction transcodes only header blocks through an
//! independent inflater and deflater. DATA, flow control, and stream ownership
//! remain end to end in both modes.

const std = @import("std");
const stream_state = @import("streams.zig");
const middleware = @import("../middleware.zig");
const provider = @import("../provider/request.zig");
const tls = @import("../tls.zig");

const c = @cImport({
    @cInclude("nghttp2/nghttp2.h");
});

pub const frame_header_len = 9;
pub const client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
pub const max_header_block_bytes = 128 * 1024;
pub const max_tracked_streams = stream_state.max_tracked_streams;

const frame_data: u8 = 0x0;
const frame_headers: u8 = 0x1;
const frame_rst_stream: u8 = 0x3;
const frame_push_promise: u8 = 0x5;
const frame_goaway: u8 = 0x7;
const frame_continuation: u8 = 0x9;

const flag_end_stream: u8 = 0x1;
const flag_end_headers: u8 = 0x4;
const flag_padded: u8 = 0x8;
const flag_priority: u8 = 0x20;

pub const Direction = enum { request, response };

pub const Stats = struct {
    decode_failed: bool = false,
};

pub const Lifecycle = struct {
    phase: middleware.Phase,
    stream_id: u32,
    status_code: u16,
};

pub const ResponseBody = struct {
    stream_id: u32,
    status_code: u16,
    sse_body: bool,
    bytes: []const u8,
};

/// One borrowed observation produced while relaying HTTP/2 frames.
pub const Event = union(enum) {
    lifecycle: Lifecycle,
    response_body: ResponseBody,
};

pub const PeerSettings = struct {
    header_table_size: std.atomic.Value(u32) = .init(4096),
    max_frame_size: std.atomic.Value(u32) = .init(16 * 1024),
};

pub const Route = struct {
    from: tls.Session.Side,
    to: tls.Session.Side,
    direction: Direction,
    agent_provider: provider.AgentProvider,
};

pub const TransformedRoute = struct {
    route: Route,
    source_settings: *PeerSettings,
    target_settings: *PeerSettings,
    pipeline: *const middleware.TransformPipeline,
    io: std.Io,
    transform_context: middleware.TransformContext,
};

const HeaderKind = enum { none, headers, push_promise };

const Decoded = struct {
    status_code: u16 = 0,
    request: bool = false,
    inference_method: bool = false,
    inference_route: bool = false,
    content_type_seen: bool = false,
    event_stream: bool = false,
    identity_encoding: bool = true,
    metadata_valid: bool = true,

    fn isInference(decoded: Decoded) bool {
        return decoded.request and decoded.inference_method and decoded.inference_route;
    }

    fn hasObservableSseBody(decoded: Decoded) bool {
        return decoded.metadata_valid and decoded.content_type_seen and
            decoded.event_stream and decoded.identity_encoding;
    }
};

const Observer = struct {
    inflater: ?*c.nghttp2_hd_inflater = null,
    failed: bool = false,
    agent_provider: provider.AgentProvider,
    direction: Direction,

    header: [frame_header_len]u8 = undefined,
    header_len: u8 = 0,
    payload_len: usize = 0,
    payload_left: usize = 0,
    payload_offset: usize = 0,
    frame_type: u8 = 0,
    flags: u8 = 0,
    stream_id: u32 = 0,
    padding: usize = 0,

    continuation_stream: u32 = 0,
    block_stream: u32 = 0,
    block_kind: HeaderKind = .none,
    block_end_stream: bool = false,
    block: [max_header_block_bytes]u8 = undefined,
    block_len: usize = 0,
    streams: stream_state.Tracker = .{},

    fn init(agent_provider: provider.AgentProvider, direction: Direction) Observer {
        var observer: Observer = .{ .agent_provider = agent_provider, .direction = direction };
        if (c.nghttp2_hd_inflate_new(&observer.inflater) != 0 or
            c.nghttp2_hd_inflate_change_table_size(
                observer.inflater,
                max_header_block_bytes,
            ) != 0)
            observer.failed = true;
        return observer;
    }

    fn deinit(observer: *Observer) void {
        if (observer.inflater) |inflater| c.nghttp2_hd_inflate_del(inflater);
        observer.inflater = null;
        std.crypto.secureZero(u8, &observer.block);
    }

    fn observe(observer: *Observer, input: []const u8, sink: anytype) void {
        var offset: usize = 0;
        while (offset < input.len) {
            if (observer.header_len < frame_header_len) {
                const take = @min(frame_header_len - observer.header_len, input.len - offset);
                @memcpy(observer.header[observer.header_len..][0..take], input[offset..][0..take]);
                observer.header_len += @intCast(take);
                offset += take;
                if (observer.header_len != frame_header_len) continue;
                observer.beginFrame();
                if (observer.payload_left == 0) {
                    observer.finishFrame(sink);
                }
                continue;
            }

            const take = @min(observer.payload_left, input.len - offset);
            const payload = input[offset..][0..take];
            observer.observePayload(payload, sink);
            observer.payload_offset += take;
            observer.payload_left -= take;
            offset += take;
            if (observer.payload_left == 0) {
                observer.finishFrame(sink);
            }
        }
    }

    fn beginFrame(observer: *Observer) void {
        observer.payload_len = (@as(usize, observer.header[0]) << 16) |
            (@as(usize, observer.header[1]) << 8) | observer.header[2];
        observer.payload_left = observer.payload_len;
        observer.payload_offset = 0;
        observer.frame_type = observer.header[3];
        observer.flags = observer.header[4];
        observer.stream_id = streamId(&observer.header);
        observer.padding = 0;

        if (observer.frame_type == frame_headers or observer.frame_type == frame_push_promise)
            observer.block_end_stream = observer.flags & flag_end_stream != 0;

        if (observer.failed) {
            if (observer.frame_type == frame_headers and observer.continuation_stream == 0) {
                observer.block_stream = observer.stream_id;
                observer.block_kind = .headers;
            }
            return;
        }
        switch (observer.frame_type) {
            frame_headers, frame_push_promise => {
                if (observer.continuation_stream != 0 or observer.stream_id == 0) {
                    observer.fail();
                    return;
                }
                observer.block_len = 0;
                observer.block_stream = observer.stream_id;
                observer.block_kind = if (observer.frame_type == frame_headers)
                    .headers
                else
                    .push_promise;
            },
            frame_continuation => {
                if (observer.continuation_stream == 0 or
                    observer.continuation_stream != observer.stream_id)
                    observer.fail();
            },
            else => if (observer.continuation_stream != 0) observer.fail(),
        }
    }

    fn observePayload(observer: *Observer, payload: []const u8, sink: anytype) void {
        if (observer.direction == .response and observer.frame_type == frame_data and payload.len != 0) {
            sink.emit(.{ .lifecycle = .{
                .phase = .response_activity,
                .stream_id = observer.stream_id,
                .status_code = observer.streams.status(observer.stream_id),
            } });

            if (observer.responseBodyFragment(payload)) |fragment| {
                if (fragment.len != 0) {
                    sink.emit(.{ .response_body = .{
                        .stream_id = observer.stream_id,
                        .status_code = observer.streams.status(observer.stream_id),
                        .sse_body = observer.hasObservableSseBody(observer.stream_id),
                        .bytes = fragment,
                    } });
                }
            }
        }

        if (observer.failed or !isHeaderFrame(observer.frame_type)) return;

        if (observer.flags & flag_padded != 0 and observer.payload_offset == 0) {
            if (payload.len == 0) return;
            observer.padding = payload[0];
        }
        const prefix = observer.headerPrefixLength() orelse {
            observer.fail();
            return;
        };
        if (observer.padding > observer.payload_len - prefix) {
            observer.fail();
            return;
        }
        const fragment_end = observer.payload_len - observer.padding;
        const input_start = observer.payload_offset;
        const input_end = input_start + payload.len;
        const copy_start = @max(input_start, prefix);
        const copy_end = @min(input_end, fragment_end);
        if (copy_start >= copy_end) return;
        const source = payload[copy_start - input_start .. copy_end - input_start];
        if (source.len > observer.block.len - observer.block_len) {
            observer.fail();
            return;
        }
        @memcpy(observer.block[observer.block_len..][0..source.len], source);
        observer.block_len += source.len;
    }

    fn finishFrame(observer: *Observer, sink: anytype) void {
        const completed_type = observer.frame_type;
        const completed_flags = observer.flags;
        const completed_stream = observer.stream_id;

        if (isHeaderFrame(completed_type)) {
            if (completed_flags & flag_end_headers != 0) {
                observer.continuation_stream = 0;
                const decoded = if (observer.failed) Decoded{} else observer.decodeBlock();
                if (observer.block_kind == .headers) {
                    switch (observer.direction) {
                        .request => {
                            if (decoded.request and observer.streams.startRequest(observer.block_stream)) {
                                sink.emit(.{ .lifecycle = .{
                                    .phase = if (decoded.isInference())
                                        .request_started
                                    else
                                        .auxiliary_request_started,
                                    .stream_id = observer.block_stream,
                                    .status_code = 0,
                                } });
                            }

                            if (observer.block_end_stream) {
                                observer.streams.finishRequest(observer.block_stream);
                            }
                        },
                        .response => {
                            if (decoded.status_code >= 200) {
                                _ = observer.streams.setResponse(.{
                                    .stream_id = observer.block_stream,
                                    .status_code = decoded.status_code,
                                    .sse_body = decoded.hasObservableSseBody(),
                                });
                            }

                            if (observer.block_end_stream) {
                                const status_code = observer.streams.status(observer.block_stream);
                                sink.emit(.{ .lifecycle = .{
                                    .phase = if (status_code >= 400) .request_failed else .response_finished,
                                    .stream_id = observer.block_stream,
                                    .status_code = status_code,
                                } });
                                observer.streams.finishResponse(observer.block_stream);
                            }
                        },
                    }
                }
                observer.block_kind = .none;
                observer.block_end_stream = false;
                observer.block_len = 0;
            } else if (completed_type != frame_continuation) {
                observer.continuation_stream = completed_stream;
            }
        }

        if (completed_type == frame_rst_stream and completed_stream != 0) {
            sink.emit(.{ .lifecycle = .{
                .phase = .request_failed,
                .stream_id = completed_stream,
                .status_code = observer.streams.status(completed_stream),
            } });
            observer.streams.finishResponse(completed_stream);
            if (observer.direction == .request) {
                observer.streams.finishRequest(completed_stream);
            }
        } else if (observer.direction == .response and completed_type == frame_goaway and
            observer.streams.hasActiveResponses())
        {
            sink.emit(.{ .lifecycle = .{
                .phase = .request_failed,
                .stream_id = 0,
                .status_code = 0,
            } });
        } else if (observer.direction == .response and completed_type == frame_data and
            completed_stream != 0 and
            completed_flags & flag_end_stream != 0)
        {
            const status_code = observer.streams.status(completed_stream);
            sink.emit(.{ .lifecycle = .{
                .phase = if (status_code >= 400) .request_failed else .response_finished,
                .stream_id = completed_stream,
                .status_code = status_code,
            } });
            observer.streams.finishResponse(completed_stream);
        }
        if (observer.direction == .request and completed_type == frame_data and
            completed_stream != 0 and
            completed_flags & flag_end_stream != 0)
        {
            observer.streams.finishRequest(completed_stream);
        }

        observer.header_len = 0;
        observer.payload_len = 0;
        observer.payload_left = 0;
        observer.payload_offset = 0;
    }

    fn responseBodyFragment(observer: *Observer, payload: []const u8) ?[]const u8 {
        const prefix: usize = @intFromBool(observer.flags & flag_padded != 0);

        if (prefix != 0 and observer.payload_offset == 0) {
            if (payload.len == 0) {
                return "";
            }

            observer.padding = payload[0];
        }

        if (observer.padding > observer.payload_len -| prefix) {
            return null;
        }

        const body_end = observer.payload_len - observer.padding;
        const input_start = observer.payload_offset;
        const input_end = input_start + payload.len;
        const fragment_start = @max(input_start, prefix);
        const fragment_end = @min(input_end, body_end);

        if (fragment_start >= fragment_end) {
            return "";
        }

        return payload[fragment_start - input_start .. fragment_end - input_start];
    }

    fn headerPrefixLength(observer: *const Observer) ?usize {
        var prefix: usize = if (observer.flags & flag_padded != 0) 1 else 0;
        prefix += switch (observer.frame_type) {
            frame_headers => if (observer.flags & flag_priority != 0) 5 else 0,
            frame_push_promise => 4,
            frame_continuation => 0,
            else => return null,
        };
        if (prefix > observer.payload_len) return null;
        return prefix;
    }

    fn decodeBlock(observer: *Observer) Decoded {
        const inflater = observer.inflater orelse {
            observer.fail();
            return .{};
        };
        var decoded: Decoded = .{};
        var input = observer.block[0..observer.block_len];
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
            if (consumed < 0 or @as(usize, @intCast(consumed)) > input.len) {
                observer.fail();
                return .{};
            }
            input = input[@intCast(consumed)..];
            if (flags & c.NGHTTP2_HD_INFLATE_EMIT != 0) {
                const name = field.name[0..field.namelen];
                const value = field.value[0..field.valuelen];
                if (std.mem.eql(u8, name, ":status"))
                    decoded.status_code = std.fmt.parseInt(u16, value, 10) catch 0;
                if (std.mem.eql(u8, name, ":method")) {
                    decoded.request = true;
                    decoded.inference_method = std.ascii.eqlIgnoreCase(value, "POST");
                }
                if (std.mem.eql(u8, name, ":path"))
                    decoded.inference_route = provider.classify(observer.agent_provider, .{
                        .method = "POST",
                        .target = value,
                    }) == .inference;
                if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                    if (decoded.content_type_seen) {
                        decoded.metadata_valid = false;
                    } else {
                        decoded.content_type_seen = true;
                        decoded.event_stream = middleware.isEventStreamContentType(value);
                    }
                }
                if (std.ascii.eqlIgnoreCase(name, "content-encoding") and
                    !middleware.isIdentityContentEncoding(value))
                {
                    decoded.identity_encoding = false;
                }
            }
            if (flags & c.NGHTTP2_HD_INFLATE_FINAL != 0) {
                if (c.nghttp2_hd_inflate_end_headers(inflater) != 0) observer.fail();
                return decoded;
            }
            if (consumed == 0 and flags & c.NGHTTP2_HD_INFLATE_EMIT == 0) {
                observer.fail();
                return .{};
            }
        }
    }

    fn hasObservableSseBody(observer: *const Observer, stream_id: u32) bool {
        return observer.streams.hasObservableSseBody(stream_id);
    }

    fn fail(observer: *Observer) void {
        observer.failed = true;
        observer.block_len = 0;
        observer.continuation_stream = 0;
        observer.block_kind = .none;
    }
};

/// Replaces one HPACK context with another while leaving stream IDs, DATA,
/// SETTINGS, and flow control end to end. A direction owns its inflater and
/// deflater; the reverse direction only publishes the peer SETTINGS that bound
/// its output encoding.
const TranscodeConfiguration = struct {
    direction: Direction,
    to: tls.Session.Side,
    source_settings: *PeerSettings,
    target_settings: *PeerSettings,
    pipeline: *const middleware.TransformPipeline,
    io: std.Io,
    transform_context: middleware.TransformContext,
};

const CompletedFrame = struct {
    frame_type: u8,
    flags: u8,
    stream_id: u32,
};

const FrameHeader = struct {
    length: usize,
    frame_type: u8,
    flags: u8,
    stream_id: u32,
};

fn TranscodePort(comptime Session: type, comptime Sink: type) type {
    return struct {
        session: Session,
        sink: Sink,

        fn writeAll(port: @This(), to: tls.Session.Side, bytes: []const u8) bool {
            return port.session.writeAll(to, bytes);
        }

        fn emit(port: @This(), event: Event) void {
            port.sink.emit(event);
        }
    };
}

fn transcodePort(session: anytype, sink: anytype) TranscodePort(@TypeOf(session), @TypeOf(sink)) {
    return .{ .session = session, .sink = sink };
}

const Transcoder = struct {
    inflater: ?*c.nghttp2_hd_inflater = null,
    deflater: ?*c.nghttp2_hd_deflater = null,
    failed: bool = false,
    agent_provider: provider.AgentProvider,
    configuration: TranscodeConfiguration,
    applied_table_size: u32 = 4096,
    applied_inflate_table_size: u32 = max_header_block_bytes,

    header: [frame_header_len]u8 = undefined,
    header_len: u8 = 0,
    payload_len: usize = 0,
    payload_left: usize = 0,
    payload_offset: usize = 0,
    frame_type: u8 = 0,
    flags: u8 = 0,
    stream_id: u32 = 0,

    continuation_stream: u32 = 0,
    block_type: u8 = 0,
    block_flags: u8 = 0,
    block_stream: u32 = 0,
    block_prefix: [5]u8 = undefined,
    block_prefix_len: u8 = 0,
    block_prefix_seen: u8 = 0,
    frame_padding: usize = 0,
    compressed: [max_header_block_bytes]u8 = undefined,
    compressed_len: usize = 0,
    encoded: [2 * max_header_block_bytes]u8 = undefined,
    setting: [6]u8 = undefined,
    setting_len: u8 = 0,
    streams: stream_state.Tracker = .{},

    fn init(agent_provider: provider.AgentProvider, configuration: TranscodeConfiguration) Transcoder {
        var transcoder: Transcoder = .{ .agent_provider = agent_provider, .configuration = configuration };
        if (c.nghttp2_hd_inflate_new(&transcoder.inflater) != 0 or
            c.nghttp2_hd_inflate_change_table_size(
                transcoder.inflater,
                max_header_block_bytes,
            ) != 0)
            transcoder.failed = true;
        if (c.nghttp2_hd_deflate_new(&transcoder.deflater, max_header_block_bytes) != 0)
            transcoder.failed = true;
        return transcoder;
    }

    fn deinit(transcoder: *Transcoder) void {
        if (transcoder.inflater) |inflater| c.nghttp2_hd_inflate_del(inflater);
        if (transcoder.deflater) |deflater| c.nghttp2_hd_deflate_del(deflater);
        transcoder.inflater = null;
        transcoder.deflater = null;
        std.crypto.secureZero(u8, &transcoder.compressed);
        std.crypto.secureZero(u8, &transcoder.encoded);
    }

    fn process(transcoder: *Transcoder, input: []const u8, port: anytype) bool {
        var offset: usize = 0;
        while (offset < input.len and !transcoder.failed) {
            if (transcoder.header_len < frame_header_len) {
                const take = @min(frame_header_len - transcoder.header_len, input.len - offset);
                @memcpy(
                    transcoder.header[transcoder.header_len..][0..take],
                    input[offset..][0..take],
                );
                transcoder.header_len += @intCast(take);
                offset += take;
                if (transcoder.header_len != frame_header_len) {
                    continue;
                }

                if (!transcoder.beginFrame(port)) {
                    return false;
                }

                if (transcoder.payload_left == 0 and !transcoder.finishFrame(port)) {
                    return false;
                }

                continue;
            }

            const take = @min(transcoder.payload_left, input.len - offset);
            const payload = input[offset..][0..take];
            if (!transcoder.processPayload(payload, port)) {
                return false;
            }

            transcoder.payload_offset += take;
            transcoder.payload_left -= take;
            offset += take;

            if (transcoder.payload_left == 0 and !transcoder.finishFrame(port)) {
                return false;
            }
        }
        return !transcoder.failed;
    }

    fn beginFrame(transcoder: *Transcoder, port: anytype) bool {
        transcoder.payload_len = (@as(usize, transcoder.header[0]) << 16) |
            (@as(usize, transcoder.header[1]) << 8) | transcoder.header[2];
        transcoder.payload_left = transcoder.payload_len;
        transcoder.payload_offset = 0;
        transcoder.frame_type = transcoder.header[3];
        transcoder.flags = transcoder.header[4];
        transcoder.stream_id = streamId(&transcoder.header);
        transcoder.setting_len = 0;
        transcoder.frame_padding = 0;

        if (transcoder.continuation_stream != 0) {
            if (transcoder.frame_type != frame_continuation or
                transcoder.stream_id != transcoder.continuation_stream)
            {
                transcoder.failed = true;
                return false;
            }
            return true;
        }
        if (transcoder.frame_type == frame_continuation) {
            transcoder.failed = true;
            return false;
        }
        if (transcoder.frame_type == frame_headers or
            transcoder.frame_type == frame_push_promise)
        {
            if (transcoder.stream_id == 0) {
                transcoder.failed = true;
                return false;
            }
            transcoder.block_type = transcoder.frame_type;
            transcoder.block_flags = transcoder.flags;
            transcoder.block_stream = transcoder.stream_id;
            transcoder.block_prefix_len = switch (transcoder.frame_type) {
                frame_headers => if (transcoder.flags & flag_priority != 0) 5 else 0,
                frame_push_promise => 4,
                else => unreachable,
            };
            transcoder.block_prefix_seen = 0;
            transcoder.compressed_len = 0;
            return true;
        }
        if (!port.writeAll(transcoder.configuration.to, &transcoder.header)) {
            transcoder.failed = true;
            return false;
        }
        return true;
    }

    fn processPayload(transcoder: *Transcoder, payload: []const u8, port: anytype) bool {
        if (!isHeaderFrame(transcoder.frame_type)) {
            // Publish peer limits before the last SETTINGS byte reaches the
            // peer. Its next header block may use the newly advertised HPACK
            // table or frame size immediately.
            if (transcoder.frame_type == c.NGHTTP2_SETTINGS and
                transcoder.flags & c.NGHTTP2_FLAG_ACK == 0)
            {
                transcoder.observeSettings(payload, transcoder.configuration.source_settings);
            }
            if (!port.writeAll(transcoder.configuration.to, payload)) {
                transcoder.failed = true;
                return false;
            }
            if (transcoder.configuration.direction == .response and transcoder.frame_type == frame_data and payload.len != 0) {
                port.emit(.{ .lifecycle = .{
                    .phase = .response_activity,
                    .stream_id = transcoder.stream_id,
                    .status_code = transcoder.streams.status(transcoder.stream_id),
                } });

                if (transcoder.responseBodyFragment(payload)) |fragment| {
                    if (fragment.len != 0) {
                        port.emit(.{ .response_body = .{
                            .stream_id = transcoder.stream_id,
                            .status_code = transcoder.streams.status(transcoder.stream_id),
                            .sse_body = transcoder.hasObservableSseBody(transcoder.stream_id),
                            .bytes = fragment,
                        } });
                    }
                }
            }
            return true;
        }

        var input_start = transcoder.payload_offset;
        var slice = payload;
        if (transcoder.frame_type != frame_continuation and
            transcoder.flags & flag_padded != 0 and input_start == 0)
        {
            if (slice.len == 0) return true;
            transcoder.frame_padding = slice[0];
            slice = slice[1..];
            input_start += 1;
        }

        if (transcoder.frame_type != frame_continuation and
            transcoder.block_prefix_seen < transcoder.block_prefix_len)
        {
            const take = @min(
                transcoder.block_prefix_len - transcoder.block_prefix_seen,
                slice.len,
            );
            @memcpy(
                transcoder.block_prefix[transcoder.block_prefix_seen..][0..take],
                slice[0..take],
            );
            transcoder.block_prefix_seen += @intCast(take);
            slice = slice[take..];
            input_start += take;
        }

        const padding_start = transcoder.payload_len -| transcoder.frame_padding;
        if (transcoder.frame_padding > transcoder.payload_len or
            padding_start < transcoder.headerPayloadPrefixLength())
        {
            transcoder.failed = true;
            return false;
        }
        if (input_start >= padding_start) return true;
        const fragment_len = @min(slice.len, padding_start - input_start);
        if (fragment_len > transcoder.compressed.len - transcoder.compressed_len) {
            transcoder.failed = true;
            return false;
        }
        @memcpy(
            transcoder.compressed[transcoder.compressed_len..][0..fragment_len],
            slice[0..fragment_len],
        );
        transcoder.compressed_len += fragment_len;
        return true;
    }

    fn finishFrame(transcoder: *Transcoder, port: anytype) bool {
        const completed_type = transcoder.frame_type;
        const completed_flags = transcoder.flags;
        const completed_stream = transcoder.stream_id;

        if (isHeaderFrame(completed_type)) {
            if (completed_flags & flag_end_headers == 0) {
                transcoder.continuation_stream = completed_stream;
            } else {
                transcoder.continuation_stream = 0;
                if (transcoder.block_prefix_seen != transcoder.block_prefix_len or
                    !transcoder.finishHeaderBlock(port))
                {
                    transcoder.failed = true;
                    return false;
                }
            }
        } else {
            transcoder.observeCompletedFrame(.{
                .frame_type = completed_type,
                .flags = completed_flags,
                .stream_id = completed_stream,
            }, port);
        }

        transcoder.header_len = 0;
        transcoder.payload_len = 0;
        transcoder.payload_left = 0;
        transcoder.payload_offset = 0;
        return true;
    }

    fn finishHeaderBlock(transcoder: *Transcoder, port: anytype) bool {
        const configuration = transcoder.configuration;
        const direction = configuration.direction;
        const target_settings = configuration.target_settings;

        const inflate_table_size = @min(
            target_settings.header_table_size.load(.seq_cst),
            max_header_block_bytes,
        );
        if (inflate_table_size != transcoder.applied_inflate_table_size) {
            const inflater = transcoder.inflater orelse return false;
            if (c.nghttp2_hd_inflate_change_table_size(inflater, inflate_table_size) != 0)
                return false;
            transcoder.applied_inflate_table_size = inflate_table_size;
        }
        // The table-size limit must be installed before decoding a block that
        // can begin with an HPACK dynamic-table update.
        var original = transcoder.decodeHeaders() orelse return false;
        const kind = headerKind(transcoder.block_type, &original);
        if (!validH2Headers(&original, kind)) return false;
        if (transcoder.block_type == frame_push_promise and
            (direction != .response or promisedStreamId(transcoder) == 0 or
                promisedStreamId(transcoder) & 1 != 0)) return false;
        var transformed: middleware.Headers = undefined;
        transformed.copyFrom(&original);
        var context = configuration.transform_context;
        context.stream_id = if (transcoder.block_type == frame_push_promise)
            promisedStreamId(transcoder)
        else
            transcoder.block_stream;
        context.kind = kind;
        _ = configuration.pipeline.apply(.{ .io = configuration.io, .context = context, .headers = &transformed });
        if (!compatibleH2Headers(&original, &transformed, context.kind))
            transformed.copyFrom(&original);

        if (direction == .request and context.kind == .request and
            transcoder.streams.startRequest(transcoder.block_stream))
        {
            port.emit(.{ .lifecycle = .{
                .phase = if (provider.classify(transcoder.agent_provider, .{
                    .method = original.find(":method") orelse "",
                    .target = original.find(":path") orelse "",
                }) == .inference)
                    .request_started
                else
                    .auxiliary_request_started,
                .stream_id = transcoder.block_stream,
                .status_code = 0,
            } });
        }

        const table_size = @min(
            target_settings.header_table_size.load(.seq_cst),
            max_header_block_bytes,
        );
        if (table_size != transcoder.applied_table_size) {
            const deflater = transcoder.deflater orelse return false;
            if (c.nghttp2_hd_deflate_change_table_size(deflater, table_size) != 0)
                return false;
            transcoder.applied_table_size = table_size;
        }
        var nv: [middleware.max_header_fields]c.nghttp2_nv = undefined;
        for (transformed.fields[0..transformed.len], 0..) |field, index| nv[index] = .{
            .name = @constCast(transformed.name(field).ptr),
            .value = @constCast(transformed.value(field).ptr),
            .namelen = field.name_len,
            .valuelen = field.value_len,
            .flags = if (field.sensitive) c.NGHTTP2_NV_FLAG_NO_INDEX else 0,
        };
        const deflater = transcoder.deflater orelse return false;
        const bound = c.nghttp2_hd_deflate_bound(deflater, &nv, transformed.len);
        if (bound > transcoder.encoded.len) return false;
        const encoded_len = c.nghttp2_hd_deflate_hd2(
            deflater,
            &transcoder.encoded,
            transcoder.encoded.len,
            &nv,
            transformed.len,
        );
        if (encoded_len < 0) return false;
        if (!transcoder.writeHeaderBlock(port, @intCast(encoded_len))) {
            return false;
        }

        const status_code = parseStatusHeader(&transformed);
        if (direction == .response and status_code >= 200) {
            _ = transcoder.streams.setResponse(.{
                .stream_id = transcoder.block_stream,
                .status_code = status_code,
                .sse_body = middleware.hasObservableSseBody(&original),
            });
        }

        if (transcoder.block_flags & flag_end_stream != 0) switch (direction) {
            .request => transcoder.streams.finishRequest(transcoder.block_stream),
            .response => {
                const final_status = transcoder.streams.status(transcoder.block_stream);
                port.emit(.{ .lifecycle = .{
                    .phase = if (final_status >= 400) .request_failed else .response_finished,
                    .stream_id = transcoder.block_stream,
                    .status_code = final_status,
                } });
                transcoder.streams.finishResponse(transcoder.block_stream);
            },
        };
        return true;
    }

    fn decodeHeaders(transcoder: *Transcoder) ?middleware.Headers {
        const inflater = transcoder.inflater orelse return null;
        var headers: middleware.Headers = .{};
        var input = transcoder.compressed[0..transcoder.compressed_len];
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
            if (consumed < 0 or @as(usize, @intCast(consumed)) > input.len)
                return null;
            input = input[@intCast(consumed)..];
            if (flags & c.NGHTTP2_HD_INFLATE_EMIT != 0) {
                headers.append(.{
                    .name = field.name[0..field.namelen],
                    .value = field.value[0..field.valuelen],
                    .sensitive = field.flags & c.NGHTTP2_NV_FLAG_NO_INDEX != 0,
                }) catch return null;
            }
            if (flags & c.NGHTTP2_HD_INFLATE_FINAL != 0) {
                if (c.nghttp2_hd_inflate_end_headers(inflater) != 0) return null;
                return headers;
            }
            if (consumed == 0 and flags & c.NGHTTP2_HD_INFLATE_EMIT == 0)
                return null;
        }
    }

    fn writeHeaderBlock(transcoder: *Transcoder, port: anytype, encoded_len: usize) bool {
        const advertised_frame_size = transcoder.configuration.target_settings.max_frame_size.load(.seq_cst);
        const max_frame_size: usize = if (advertised_frame_size >= 16 * 1024 and
            advertised_frame_size <= 0x00ff_ffff)
            advertised_frame_size
        else
            16 * 1024;
        if (transcoder.block_prefix_len >= max_frame_size) return false;
        var offset: usize = 0;
        var first = true;
        while (first or offset < encoded_len) {
            const prefix_len: usize = if (first) transcoder.block_prefix_len else 0;
            const fragment_len = @min(encoded_len - offset, max_frame_size - prefix_len);
            const final = offset + fragment_len == encoded_len;
            var header: [frame_header_len]u8 = undefined;
            const kind: u8 = if (first) transcoder.block_type else frame_continuation;
            var flags: u8 = if (first)
                transcoder.block_flags & ~(flag_padded | flag_end_headers)
            else
                0;
            if (final) flags |= flag_end_headers;
            writeFrameHeader(
                &header,
                .{
                    .length = prefix_len + fragment_len,
                    .frame_type = kind,
                    .flags = flags,
                    .stream_id = transcoder.block_stream,
                },
            );
            if (!port.writeAll(transcoder.configuration.to, &header)) {
                return false;
            }

            if (prefix_len != 0 and !port.writeAll(
                transcoder.configuration.to,
                transcoder.block_prefix[0..prefix_len],
            )) {
                return false;
            }

            if (fragment_len != 0 and !port.writeAll(
                transcoder.configuration.to,
                transcoder.encoded[offset..][0..fragment_len],
            )) {
                return false;
            }

            offset += fragment_len;
            first = false;
        }
        return true;
    }

    fn observeSettings(transcoder: *Transcoder, payload: []const u8, settings: *PeerSettings) void {
        for (payload) |byte| {
            transcoder.setting[transcoder.setting_len] = byte;
            transcoder.setting_len += 1;
            if (transcoder.setting_len != transcoder.setting.len) continue;
            const identifier = std.mem.readInt(u16, transcoder.setting[0..2], .big);
            const value = std.mem.readInt(u32, transcoder.setting[2..6], .big);
            switch (identifier) {
                c.NGHTTP2_SETTINGS_HEADER_TABLE_SIZE => settings.header_table_size.store(value, .seq_cst),
                c.NGHTTP2_SETTINGS_MAX_FRAME_SIZE => if (value >= 16 * 1024 and
                    value <= 0x00ff_ffff)
                    settings.max_frame_size.store(value, .seq_cst),
                else => {},
            }
            transcoder.setting_len = 0;
        }
    }

    fn observeCompletedFrame(transcoder: *Transcoder, completed: CompletedFrame, port: anytype) void {
        const direction = transcoder.configuration.direction;
        const frame_type = completed.frame_type;
        const frame_flags = completed.flags;
        const frame_stream = completed.stream_id;

        if (frame_type == frame_rst_stream and frame_stream != 0) {
            port.emit(.{ .lifecycle = .{
                .phase = .request_failed,
                .stream_id = frame_stream,
                .status_code = transcoder.streams.status(frame_stream),
            } });
            transcoder.streams.finishResponse(frame_stream);
            if (direction == .request) transcoder.streams.finishRequest(frame_stream);
        } else if (direction == .response and frame_type == frame_goaway and
            transcoder.streams.hasActiveResponses())
        {
            port.emit(.{ .lifecycle = .{
                .phase = .request_failed,
                .stream_id = 0,
                .status_code = 0,
            } });
        } else if (direction == .response and frame_type == frame_data and
            frame_stream != 0 and frame_flags & flag_end_stream != 0)
        {
            const status_code = transcoder.streams.status(frame_stream);
            port.emit(.{ .lifecycle = .{
                .phase = if (status_code >= 400) .request_failed else .response_finished,
                .stream_id = frame_stream,
                .status_code = status_code,
            } });
            transcoder.streams.finishResponse(frame_stream);
        }
        if (direction == .request and frame_type == frame_data and
            frame_stream != 0 and frame_flags & flag_end_stream != 0)
            transcoder.streams.finishRequest(frame_stream);
    }

    fn responseBodyFragment(transcoder: *Transcoder, payload: []const u8) ?[]const u8 {
        const prefix: usize = @intFromBool(transcoder.flags & flag_padded != 0);

        if (prefix != 0 and transcoder.payload_offset == 0) {
            if (payload.len == 0) {
                return "";
            }

            transcoder.frame_padding = payload[0];
        }

        if (transcoder.frame_padding > transcoder.payload_len -| prefix) {
            return null;
        }

        const body_end = transcoder.payload_len - transcoder.frame_padding;
        const input_start = transcoder.payload_offset;
        const input_end = input_start + payload.len;
        const fragment_start = @max(input_start, prefix);
        const fragment_end = @min(input_end, body_end);

        if (fragment_start >= fragment_end) {
            return "";
        }

        return payload[fragment_start - input_start .. fragment_end - input_start];
    }

    fn headerPayloadPrefixLength(transcoder: *const Transcoder) usize {
        if (transcoder.frame_type == frame_continuation) return 0;
        return @as(usize, transcoder.block_prefix_len) +
            @intFromBool(transcoder.block_flags & flag_padded != 0);
    }

    fn hasObservableSseBody(transcoder: *const Transcoder, stream_id: u32) bool {
        return transcoder.streams.hasObservableSseBody(stream_id);
    }
};

/// Relays one HTTP/2 direction byte for byte while publishing decoded events.
///
/// ```zig
/// const stats = relay(session, route, &sink);
/// ```
pub fn relay(session: anytype, route: Route, sink: anytype) Stats {
    var observer = Observer.init(route.agent_provider, route.direction);
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
            )) observer.fail();
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
        observer.header_len != 0 or observer.payload_left != 0 or
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
pub fn relayTransformed(session: anytype, transformed_route: TransformedRoute, sink: anytype) Stats {
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
    var transcoder = Transcoder.init(route.agent_provider, configuration);
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
        transcoder.header_len != 0 or transcoder.payload_left != 0 or
        transcoder.continuation_stream != 0)
    {
        transcoder.failed = true;
    }

    session.halfClose(route.to);
    return .{ .decode_failed = transcoder.failed };
}

fn headerKind(block_type: u8, headers: *const middleware.Headers) middleware.HeaderKind {
    if (block_type == frame_push_promise) return .push_promise;
    if (headers.find(":method") != null) return .request;
    if (headers.find(":status") != null) return .response;
    return .trailers;
}

fn parseStatusHeader(headers: *const middleware.Headers) u16 {
    return std.fmt.parseInt(u16, headers.find(":status") orelse return 0, 10) catch 0;
}

fn validH2Headers(headers: *const middleware.Headers, kind: middleware.HeaderKind) bool {
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
            value[value.len - 1] == ' ' or value[value.len - 1] == '\t')) return false;
        for (name) |byte| if (std.ascii.isUpper(byte)) return false;
        const pseudo = name.len != 0 and name[0] == ':';
        if (pseudo and regular_seen) return false;
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
            if (seen.* or !pseudoAllowed(kind, name)) return false;
            seen.* = true;
        }
        if (std.mem.eql(u8, name, "connection") or
            std.mem.eql(u8, name, "keep-alive") or
            std.mem.eql(u8, name, "proxy-connection") or
            std.mem.eql(u8, name, "transfer-encoding") or
            std.mem.eql(u8, name, "upgrade")) return false;
        if (std.mem.eql(u8, name, "te") and
            !std.ascii.eqlIgnoreCase(value, "trailers")) return false;
        if (kind == .trailers and pseudo) return false;
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

fn requestPseudosValid(headers: *const middleware.Headers, kind: middleware.HeaderKind) bool {
    const method = headers.find(":method") orelse return false;
    if (!validToken(method)) return false;
    const scheme = headers.find(":scheme");
    const authority = headers.find(":authority");
    const path = headers.find(":path");
    const protocol = headers.find(":protocol");
    if (authority) |value| if (containsSpace(value)) return false;
    if (scheme) |value| if (!validScheme(value)) return false;
    if (path) |value| if (containsSpace(value)) return false;
    if (protocol) |value| if (!validToken(value)) return false;
    if (kind == .push_promise and std.mem.eql(u8, method, "CONNECT")) return false;
    if (std.mem.eql(u8, method, "CONNECT")) {
        if (authority == null or authority.?.len == 0) return false;
        if (protocol == null) return scheme == null and path == null;
        return protocol.?.len != 0 and scheme != null and scheme.?.len != 0 and
            path != null and path.?.len != 0;
    }
    return protocol == null and scheme != null and scheme.?.len != 0 and
        path != null and path.?.len != 0;
}

fn validScheme(value: []const u8) bool {
    if (value.len == 0 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and
        byte != '+' and byte != '-' and byte != '.') return false;
    return true;
}

fn containsSpace(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, " \t") != null;
}

fn validToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and
        byte != '!' and byte != '#' and byte != '$' and byte != '%' and
        byte != '&' and byte != '\'' and byte != '*' and byte != '+' and
        byte != '-' and byte != '.' and byte != '^' and byte != '_' and
        byte != '`' and byte != '|' and byte != '~') return false;
    return true;
}

fn validStatus(value: []const u8) bool {
    if (value.len != 3) return false;
    const status = std.fmt.parseInt(u16, value, 10) catch return false;
    return status >= 100 and status <= 599 and status != 101;
}

fn compatibleH2Headers(original: *const middleware.Headers, transformed: *const middleware.Headers, kind: middleware.HeaderKind) bool {
    if (!validH2Headers(transformed, kind) or
        !sameHeaderValues(original, transformed, "content-length")) return false;
    if (kind != .response) return true;
    return statusSemantics(parseStatusHeader(original)) ==
        statusSemantics(parseStatusHeader(transformed));
}

const StatusSemantics = enum { informational, bodyless, regular, invalid };

fn statusSemantics(status: u16) StatusSemantics {
    if (status >= 100 and status < 200 and status != 101) return .informational;
    if (status == 204 or status == 205 or status == 304) return .bodyless;
    if (status >= 200) return .regular;
    return .invalid;
}

fn sameHeaderValues(left: *const middleware.Headers, right: *const middleware.Headers, wanted: []const u8) bool {
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (true) {
        const left_value = nextHeaderValue(left, wanted, &left_index);
        const right_value = nextHeaderValue(right, wanted, &right_index);
        if (left_value == null or right_value == null)
            return left_value == null and right_value == null;
        if (!std.mem.eql(u8, left_value.?, right_value.?)) return false;
    }
}

fn nextHeaderValue(headers: *const middleware.Headers, wanted: []const u8, index: *usize) ?[]const u8 {
    while (index.* < headers.len) {
        const field = headers.fields[index.*];
        index.* += 1;
        if (std.mem.eql(u8, headers.name(field), wanted)) return headers.value(field);
    }
    return null;
}

fn promisedStreamId(transcoder: *const Transcoder) u32 {
    return (@as(u32, transcoder.block_prefix[0] & 0x7f) << 24) |
        (@as(u32, transcoder.block_prefix[1]) << 16) |
        (@as(u32, transcoder.block_prefix[2]) << 8) |
        transcoder.block_prefix[3];
}

fn isHeaderFrame(frame_type: u8) bool {
    return frame_type == frame_headers or
        frame_type == frame_push_promise or
        frame_type == frame_continuation;
}

fn streamId(header: *const [frame_header_len]u8) u32 {
    return (@as(u32, header[5] & 0x7f) << 24) |
        (@as(u32, header[6]) << 16) |
        (@as(u32, header[7]) << 8) |
        header[8];
}

fn writeFrameHeader(buffer: *[frame_header_len]u8, header: FrameHeader) void {
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
        .response_body => null,
    };
}

const BodyCollector = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    stream_id: u32 = 0,
    status_code: u16 = 0,
    sse_body: bool = false,
    activity: usize = 0,
    finished: usize = 0,
    finished_before_body: bool = false,

    fn emit(collector: *BodyCollector, event: Event) void {
        switch (event) {
            .lifecycle => |observed| switch (observed.phase) {
                .response_activity => collector.activity += 1,
                .response_finished => {
                    collector.finished_before_body = collector.len == 0;
                    collector.finished += 1;
                },
                else => {},
            },
            .response_body => |body| {
                std.debug.assert(body.bytes.len <= collector.bytes.len - collector.len);
                @memcpy(collector.bytes[collector.len..][0..body.bytes.len], body.bytes);
                collector.len += body.bytes.len;
                collector.stream_id = body.stream_id;
                collector.status_code = body.status_code;
                collector.sse_body = body.sse_body;
            },
        }
    }

    fn payloadSlice(collector: *const BodyCollector) []const u8 {
        return collector.bytes[0..collector.len];
    }
};

test "HTTP2 observer exposes DATA payload across every two-chunk split" {
    const payload = "event: message_delta\ndata: payload\n\n";
    var wire: [frame_header_len + payload.len]u8 = undefined;
    writeFrameHeader(wire[0..frame_header_len], .{ .length = payload.len, .frame_type = frame_data, .flags = flag_end_stream, .stream_id = 7 });
    @memcpy(wire[frame_header_len..], payload);

    for (0..wire.len + 1) |split| {
        var collector: BodyCollector = .{};
        var observer = Observer.init(.claude, .response);
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

    var header: [frame_header_len]u8 = undefined;
    writeFrameHeader(&header, .{ .length = @intCast(encoded), .frame_type = frame_headers, .flags = flag_end_headers, .stream_id = 17 });
    const payload = "payload";
    var data: [frame_header_len + payload.len]u8 = undefined;
    writeFrameHeader(data[0..frame_header_len], .{ .length = payload.len, .frame_type = frame_data, .flags = flag_end_stream, .stream_id = 17 });
    @memcpy(data[frame_header_len..], payload);
    var collector: BodyCollector = .{};
    var observer = Observer.init(.claude, .response);
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
    var wire: [frame_header_len + 1 + payload.len + padding_len]u8 = @splat(0);
    writeFrameHeader(
        wire[0..frame_header_len],
        .{ .length = wire.len - frame_header_len, .frame_type = frame_data, .flags = flag_padded | flag_end_stream, .stream_id = 9 },
    );
    wire[frame_header_len] = padding_len;
    @memcpy(wire[frame_header_len + 1 ..][0..payload.len], payload);

    for (0..wire.len + 1) |split| {
        var collector: BodyCollector = .{};
        var observer = Observer.init(.claude, .response);
        defer observer.deinit();

        observer.observe(wire[0..split], &collector);
        observer.observe(wire[split..], &collector);

        try std.testing.expect(!observer.failed);
        try std.testing.expectEqualStrings(payload, collector.payloadSlice());
        try std.testing.expectEqual(@as(usize, 1), collector.finished);
    }
}

test "HTTP2 observer drops invalid DATA padding from observation only" {
    var wire: [frame_header_len + 2]u8 = @splat(0);
    writeFrameHeader(wire[0..frame_header_len], .{ .length = 2, .frame_type = frame_data, .flags = flag_padded | flag_end_stream, .stream_id = 11 });
    wire[frame_header_len] = 2;
    var collector: BodyCollector = .{};
    var observer = Observer.init(.claude, .response);
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
    var frames: [2 * frame_header_len + block.len]u8 = undefined;
    writeFrameHeader(frames[0..frame_header_len], .{ .length = first_len, .frame_type = frame_headers, .flags = flag_end_stream, .stream_id = 1 });
    @memcpy(frames[frame_header_len..][0..first_len], block[0..first_len]);
    const second_header = frame_header_len + first_len;
    writeFrameHeader(
        frames[second_header..][0..frame_header_len],
        .{ .length = second_len, .frame_type = frame_continuation, .flags = flag_end_headers, .stream_id = 1 },
    );
    @memcpy(
        frames[second_header + frame_header_len ..][0..second_len],
        block[first_len..encoded_len],
    );

    const Collector = struct {
        phase: middleware.Phase = .request_started,
        stream_id: u32 = 0,
        status_code: u16 = 0,
        fn emit(self: *@This(), event: Event) void {
            const observed = lifecycle(event) orelse return;
            self.phase = observed.phase;
            self.stream_id = observed.stream_id;
            self.status_code = observed.status_code;
        }
    };
    var collector: Collector = .{};
    var observer = Observer.init(.claude, .response);
    defer observer.deinit();
    for (frames[0 .. 2 * frame_header_len + encoded_len]) |byte|
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
        fn emit(self: *@This(), event: Event) void {
            const observed = lifecycle(event) orelse return;

            if (observed.phase == .request_started) self.starts += 1;
        }
    };
    var collector: Collector = .{};
    var observer = Observer.init(.claude, .request);
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
    var request_header: [frame_header_len]u8 = undefined;
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
    var trailer_header: [frame_header_len]u8 = undefined;
    writeFrameHeader(&trailer_header, .{ .length = @intCast(trailer_len), .frame_type = frame_headers, .flags = flag_end_headers, .stream_id = 1 });
    observer.observe(&trailer_header, &collector);
    observer.observe(trailer_block[0..@intCast(trailer_len)], &collector);

    try std.testing.expect(!observer.failed);
    try std.testing.expectEqual(@as(usize, 1), collector.starts);
}

test "cross-provider HTTP2 requests are classified as auxiliary" {
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
    var header: [frame_header_len]u8 = undefined;
    writeFrameHeader(&header, .{ .length = @intCast(block_len), .frame_type = frame_headers, .flags = flag_end_headers, .stream_id = 1 });

    const Collector = struct {
        starts: usize = 0,
        auxiliary_starts: usize = 0,
        fn emit(self: *@This(), event: Event) void {
            const observed = lifecycle(event) orelse return;

            if (observed.phase == .request_started) self.starts += 1;
            if (observed.phase == .auxiliary_request_started) self.auxiliary_starts += 1;
        }
    };
    var collector: Collector = .{};
    var observer = Observer.init(.codex, .request);
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
        fn emit(self: *@This(), event: Event) void {
            const observed = lifecycle(event) orelse return;

            if (observed.phase == .response_finished and observed.status_code == 200) self.completed += 1;
        }
    };
    var collector: Collector = .{};
    var observer = Observer.init(.claude, .response);
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
        var header: [frame_header_len]u8 = undefined;
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

const FakeWriteSession = struct {
    output: [512 * 1024]u8 = undefined,
    len: usize = 0,

    fn writeAll(fake: *FakeWriteSession, _: tls.Session.Side, bytes: []const u8) bool {
        if (bytes.len > fake.output.len - fake.len) return false;
        @memcpy(fake.output[fake.len..][0..bytes.len], bytes);
        fake.len += bytes.len;
        return true;
    }
};

fn decodeTestHeaderBlock(inflater: *c.nghttp2_hd_inflater, block: []const u8) !middleware.Headers {
    var headers: middleware.Headers = .{};
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

const TestTranscodeSetup = struct {
    provider: provider.AgentProvider,
    direction: Direction,
    to: tls.Session.Side,
    source_settings: *PeerSettings,
    target_settings: *PeerSettings,
    pipeline: *const middleware.TransformPipeline,
};

fn initTestTranscoder(setup: TestTranscodeSetup) Transcoder {
    return Transcoder.init(setup.provider, .{
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
    var frame: [frame_header_len + compressed.len]u8 = undefined;
    writeFrameHeader(
        frame[0..frame_header_len],
        .{ .length = @intCast(compressed_len), .frame_type = frame_headers, .flags = flag_end_headers | flag_end_stream, .stream_id = 1 },
    );
    @memcpy(
        frame[frame_header_len..][0..@intCast(compressed_len)],
        compressed[0..@intCast(compressed_len)],
    );

    const AddHeader = struct {
        fn transform(_: *anyopaque, transformation: middleware.Transformation) middleware.TransformStatus {
            transformation.effects.set(.{ .name = "x-telar", .value = "enabled" }) catch return .preserve;
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: middleware.TransformPipeline = .{};
    try pipeline.add(.{ .context = &ignored, .transform = AddHeader.transform });
    var session: FakeWriteSession = .{};
    const Collector = struct {
        session: *const FakeWriteSession,
        starts: usize = 0,
        auxiliary_starts: usize = 0,
        output_bytes_at_start: usize = 0,

        fn emit(self: *@This(), event: Event) void {
            const observed = lifecycle(event) orelse return;

            if (observed.phase == .request_started) {
                self.starts += 1;
                self.output_bytes_at_start = self.session.len;
            }

            if (observed.phase == .auxiliary_request_started) self.auxiliary_starts += 1;
        }
    };
    var collector: Collector = .{ .session = &session };
    var source_settings: PeerSettings = .{};
    var target_settings: PeerSettings = .{};
    target_settings.header_table_size.store(8192, .seq_cst);
    var transcoder = initTestTranscoder(.{ .provider = .codex, .direction = .request, .to = .origin, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
    defer transcoder.deinit();
    for (frame[0 .. frame_header_len + @as(usize, @intCast(compressed_len))]) |byte|
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
    try std.testing.expectEqual(frame_header_len + output_len, session.len);
    var output_inflater: ?*c.nghttp2_hd_inflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_inflate_new(&output_inflater));
    defer c.nghttp2_hd_inflate_del(output_inflater);
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.nghttp2_hd_inflate_change_table_size(output_inflater, 8192),
    );
    const decoded = try decodeTestHeaderBlock(
        output_inflater.?,
        session.output[frame_header_len..][0..output_len],
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
    var auxiliary_frame: [frame_header_len + auxiliary_compressed.len]u8 = undefined;
    writeFrameHeader(
        auxiliary_frame[0..frame_header_len],
        .{ .length = @intCast(auxiliary_len), .frame_type = frame_headers, .flags = flag_end_headers | flag_end_stream, .stream_id = 3 },
    );
    @memcpy(
        auxiliary_frame[frame_header_len..][0..@intCast(auxiliary_len)],
        auxiliary_compressed[0..@intCast(auxiliary_len)],
    );
    for (auxiliary_frame[0 .. frame_header_len + @as(usize, @intCast(auxiliary_len))]) |byte|
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
        fn transform(_: *anyopaque, _: middleware.Transformation) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: middleware.TransformPipeline = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });
    const Collector = struct {
        completed: usize = 0,
        fn emit(self: *@This(), event: Event) void {
            const observed = lifecycle(event) orelse return;

            if (observed.phase == .response_finished and observed.status_code == 200) self.completed += 1;
        }
    };
    var collector: Collector = .{};
    var session: FakeWriteSession = .{};
    var source_settings: PeerSettings = .{};
    var target_settings: PeerSettings = .{};
    var transcoder = initTestTranscoder(.{ .provider = .claude, .direction = .response, .to = .child, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
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
        var wire: [2 * frame_header_len + 1 + 5 + 512 + 2]u8 = undefined;
        const first_payload_len = 1 + 5 + first_len + 2;
        writeFrameHeader(
            wire[0..frame_header_len],
            .{ .length = first_payload_len, .frame_type = frame_headers, .flags = flag_padded | flag_priority | flag_end_stream, .stream_id = @intCast(stream_id) },
        );
        var cursor: usize = frame_header_len;
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
            wire[cursor..][0..frame_header_len],
            .{ .length = second_len, .frame_type = frame_continuation, .flags = flag_end_headers, .stream_id = @intCast(stream_id) },
        );
        cursor += frame_header_len;
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
        try std.testing.expectEqualSlices(u8, &priority, output[frame_header_len..][0..5]);
        const output_payload_len = (@as(usize, output[0]) << 16) |
            (@as(usize, output[1]) << 8) | output[2];
        const decoded = try decodeTestHeaderBlock(
            output_inflater.?,
            output[frame_header_len + priority.len ..][0 .. output_payload_len - priority.len],
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
            input_wire[input_len..][0..frame_header_len],
            .{ .length = fragment_len, .frame_type = if (first) frame_headers else frame_continuation, .flags = if (final) flag_end_headers else 0, .stream_id = test_stream_id },
        );
        input_len += frame_header_len;
        @memcpy(
            input_wire[input_len..][0..fragment_len],
            compressed[encoded_offset..][0..fragment_len],
        );
        input_len += fragment_len;
        encoded_offset += fragment_len;
        first = false;
    }

    const Identity = struct {
        fn transform(_: *anyopaque, _: middleware.Transformation) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: middleware.TransformPipeline = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });
    const Collector = struct {
        fn emit(_: *@This(), _: Event) void {}
    };
    var collector: Collector = .{};
    var session: FakeWriteSession = .{};
    var source_settings: PeerSettings = .{};
    var target_settings: PeerSettings = .{};
    var transcoder = initTestTranscoder(.{ .provider = .claude, .direction = .request, .to = .origin, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
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
        const header = session.output[output_offset..][0..frame_header_len];
        const payload_len = (@as(usize, header[0]) << 16) |
            (@as(usize, header[1]) << 8) | header[2];
        try std.testing.expect(payload_len <= 16 * 1024);
        try std.testing.expectEqual(
            if (frame_count == 0) frame_headers else frame_continuation,
            header[3],
        );
        try std.testing.expectEqual(test_stream_id, streamId(header));
        try std.testing.expect(output_offset + frame_header_len + payload_len <= session.len);
        @memcpy(
            output_block[output_block_len..][0..payload_len],
            session.output[output_offset + frame_header_len ..][0..payload_len],
        );
        output_block_len += payload_len;
        final_seen = header[4] & flag_end_headers != 0;
        if (final_seen)
            try std.testing.expectEqual(session.len, output_offset + frame_header_len + payload_len);
        output_offset += frame_header_len + payload_len;
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
        fn transform(_: *anyopaque, _: middleware.Transformation) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: middleware.TransformPipeline = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });
    const Collector = struct {
        fn emit(_: *@This(), _: Event) void {}
    };
    var collector: Collector = .{};
    var session: FakeWriteSession = .{};
    var child_settings: PeerSettings = .{};
    var origin_settings: PeerSettings = .{};
    var transcoder = initTestTranscoder(.{ .provider = .claude, .direction = .request, .to = .origin, .source_settings = &child_settings, .target_settings = &origin_settings, .pipeline = &pipeline });
    defer transcoder.deinit();

    var settings_frame: [frame_header_len + 12]u8 = undefined;
    writeFrameHeader(settings_frame[0..frame_header_len], .{ .length = 12, .frame_type = c.NGHTTP2_SETTINGS, .flags = 0, .stream_id = 0 });
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
    var header: [frame_header_len]u8 = undefined;
    writeFrameHeader(&header, .{ .length = @intCast(compressed_len), .frame_type = frame_headers, .flags = flag_end_headers, .stream_id = 19 });

    const payload = "payload";
    var data: [frame_header_len + payload.len]u8 = undefined;
    writeFrameHeader(data[0..frame_header_len], .{ .length = payload.len, .frame_type = frame_data, .flags = flag_end_stream, .stream_id = 19 });
    @memcpy(data[frame_header_len..], payload);

    const Identity = struct {
        fn transform(_: *anyopaque, _: middleware.Transformation) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: middleware.TransformPipeline = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });
    var collector: BodyCollector = .{};
    var session: FakeWriteSession = .{};
    var source_settings: PeerSettings = .{};
    var target_settings: PeerSettings = .{};
    var transcoder = initTestTranscoder(.{ .provider = .claude, .direction = .response, .to = .child, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
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
        fn transform(_: *anyopaque, _: middleware.Transformation) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: middleware.TransformPipeline = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });

    const payload = "event: message_delta\ndata: transformed\n\n";
    var wire: [frame_header_len + payload.len]u8 = undefined;
    writeFrameHeader(wire[0..frame_header_len], .{ .length = payload.len, .frame_type = frame_data, .flags = flag_end_stream, .stream_id = 13 });
    @memcpy(wire[frame_header_len..], payload);

    for (0..wire.len + 1) |split| {
        var collector: BodyCollector = .{};
        var session: FakeWriteSession = .{};
        var source_settings: PeerSettings = .{};
        var target_settings: PeerSettings = .{};
        var transcoder = initTestTranscoder(.{ .provider = .claude, .direction = .response, .to = .child, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
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

test "HTTP2 transform mode excludes DATA padding under single-byte reads" {
    const Identity = struct {
        fn transform(_: *anyopaque, _: middleware.Transformation) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: middleware.TransformPipeline = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });

    const payload = "payload";
    const padding_len = 3;
    var wire: [frame_header_len + 1 + payload.len + padding_len]u8 = @splat(0);
    writeFrameHeader(
        wire[0..frame_header_len],
        .{ .length = wire.len - frame_header_len, .frame_type = frame_data, .flags = flag_padded | flag_end_stream, .stream_id = 15 },
    );
    wire[frame_header_len] = padding_len;
    @memcpy(wire[frame_header_len + 1 ..][0..payload.len], payload);

    var collector: BodyCollector = .{};
    var session: FakeWriteSession = .{};
    var source_settings: PeerSettings = .{};
    var target_settings: PeerSettings = .{};
    var transcoder = initTestTranscoder(.{ .provider = .claude, .direction = .response, .to = .child, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
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
        fn transform(_: *anyopaque, _: middleware.Transformation) middleware.TransformStatus {
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: middleware.TransformPipeline = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Identity.transform });
    const Collector = struct {
        fn emit(_: *@This(), _: Event) void {}
    };
    var collector: Collector = .{};
    var session: FakeWriteSession = .{};
    var source_settings: PeerSettings = .{};
    var target_settings: PeerSettings = .{};
    var transcoder = initTestTranscoder(.{ .provider = .claude, .direction = .request, .to = .origin, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
    defer transcoder.deinit();

    var wire: [3 * frame_header_len + 17]u8 = undefined;
    var cursor: usize = 0;
    writeFrameHeader(wire[cursor..][0..frame_header_len], .{ .length = 5, .frame_type = frame_data, .flags = 0, .stream_id = 1 });
    cursor += frame_header_len;
    @memcpy(wire[cursor..][0..5], "hello");
    cursor += 5;
    writeFrameHeader(wire[cursor..][0..frame_header_len], .{ .length = 4, .frame_type = 0x8, .flags = 0, .stream_id = 1 });
    cursor += frame_header_len;
    std.mem.writeInt(u32, wire[cursor..][0..4], 1024, .big);
    cursor += 4;
    writeFrameHeader(wire[cursor..][0..frame_header_len], .{ .length = 8, .frame_type = 0x6, .flags = 0, .stream_id = 0 });
    cursor += frame_header_len;
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
    var frame: [frame_header_len + compressed.len]u8 = undefined;
    writeFrameHeader(
        frame[0..frame_header_len],
        .{ .length = @intCast(compressed_len), .frame_type = frame_headers, .flags = flag_end_headers, .stream_id = 1 },
    );
    @memcpy(
        frame[frame_header_len..][0..@intCast(compressed_len)],
        compressed[0..@intCast(compressed_len)],
    );

    const Invalid = struct {
        fn transform(_: *anyopaque, transformation: middleware.Transformation) middleware.TransformStatus {
            transformation.effects.remove(":scheme") catch return .preserve;
            transformation.effects.set(.{ .name = "content-length", .value = "9" }) catch return .preserve;
            return .apply;
        }
    };
    var ignored: u8 = 0;
    var pipeline: middleware.TransformPipeline = .{};
    try pipeline.add(.{ .context = &ignored, .transform = Invalid.transform });
    const Collector = struct {
        fn emit(_: *@This(), _: Event) void {}
    };
    var collector: Collector = .{};
    var session: FakeWriteSession = .{};
    var source_settings: PeerSettings = .{};
    var target_settings: PeerSettings = .{};
    var transcoder = initTestTranscoder(.{ .provider = .claude, .direction = .request, .to = .origin, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
    defer transcoder.deinit();
    try std.testing.expect(transcoder.process(
        frame[0 .. frame_header_len + @as(usize, @intCast(compressed_len))],
        transcodePort(&session, &collector),
    ));

    const output_len = (@as(usize, session.output[0]) << 16) |
        (@as(usize, session.output[1]) << 8) | session.output[2];
    var output_inflater: ?*c.nghttp2_hd_inflater = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_hd_inflate_new(&output_inflater));
    defer c.nghttp2_hd_inflate_del(output_inflater);
    const decoded = try decodeTestHeaderBlock(
        output_inflater.?,
        session.output[frame_header_len..][0..output_len],
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
    var frame: [frame_header_len + 4 + compressed.len]u8 = undefined;
    writeFrameHeader(
        frame[0..frame_header_len],
        .{ .length = 4 + @as(usize, @intCast(compressed_len)), .frame_type = frame_push_promise, .flags = flag_end_headers, .stream_id = 1 },
    );
    std.mem.writeInt(u32, frame[frame_header_len..][0..4], 2, .big);
    @memcpy(
        frame[frame_header_len + 4 ..][0..@intCast(compressed_len)],
        compressed[0..@intCast(compressed_len)],
    );

    const Capture = struct {
        stream_id: u32 = 0,
        kind: middleware.HeaderKind = .trailers,
        fn transform(raw: *anyopaque, transformation: middleware.Transformation) middleware.TransformStatus {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.stream_id = transformation.snapshot.context.stream_id;
            self.kind = transformation.snapshot.context.kind;
            return .preserve;
        }
    };
    var capture: Capture = .{};
    var pipeline: middleware.TransformPipeline = .{};
    try pipeline.add(.{ .context = &capture, .transform = Capture.transform });
    const Collector = struct {
        fn emit(_: *@This(), _: Event) void {}
    };
    var collector: Collector = .{};
    var session: FakeWriteSession = .{};
    var source_settings: PeerSettings = .{};
    var target_settings: PeerSettings = .{};
    var transcoder = initTestTranscoder(.{ .provider = .claude, .direction = .response, .to = .child, .source_settings = &source_settings, .target_settings = &target_settings, .pipeline = &pipeline });
    defer transcoder.deinit();
    try std.testing.expect(transcoder.process(
        frame[0 .. frame_header_len + 4 + @as(usize, @intCast(compressed_len))],
        transcodePort(&session, &collector),
    ));
    try std.testing.expectEqual(@as(u32, 2), capture.stream_id);
    try std.testing.expectEqual(middleware.HeaderKind.push_promise, capture.kind);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(
        u32,
        session.output[frame_header_len..][0..4],
        .big,
    ));
}
