const relay = @import("relay.zig");
const types = @import("../../agent/types.zig");
const ReaderType = @import("Reader.zig");
const TrackerType = @import("Tracker.zig");
const std = @import("std");
const Decoded = @import("Decoded.zig");
const HeaderField = @import("HeaderField.zig");
const provider = @import("../provider/request_support.zig");
const middleware = @import("../middleware.zig");
const Observer = @This();

inflater: ?*relay.c.nghttp2_hd_inflater = null,
failed: bool = false,
dialect: types.ApiDialect,
direction: relay.Direction,

framing: ReaderType = .{},
padding: usize = 0,

continuation_stream: u32 = 0,
block_stream: u32 = 0,
block_kind: relay.HeaderKind = .none,
block_end_stream: bool = false,
block: [relay.max_header_block_bytes]u8 = undefined,
block_len: usize = 0,
streams: TrackerType = .{},

pub fn init(dialect: types.ApiDialect, direction: relay.Direction) Observer {
    var observer: Observer = .{ .dialect = dialect, .direction = direction };
    if (relay.c.nghttp2_hd_inflate_new(&observer.inflater) != 0 or
        relay.c.nghttp2_hd_inflate_change_table_size(
            observer.inflater,
            relay.max_header_block_bytes,
        ) != 0)
    {
        observer.failed = true;
    }
    return observer;
}

pub fn deinit(observer: *Observer) void {
    if (observer.inflater) |inflater| {
        relay.c.nghttp2_hd_inflate_del(inflater);
    }
    observer.inflater = null;
    std.crypto.secureZero(u8, &observer.block);
}

pub fn observe(observer: *Observer, input: []const u8, sink: anytype) void {
    const Receiver = struct {
        owner: *Observer,
        port: @TypeOf(sink),

        pub fn beginFrame(receiver: *@This()) bool {
            receiver.owner.beginFrame();
            return true;
        }

        pub fn payload(receiver: *@This(), bytes: []const u8) bool {
            receiver.owner.observePayload(bytes, receiver.port);
            return true;
        }

        pub fn finishFrame(receiver: *@This()) bool {
            receiver.owner.finishFrame(receiver.port);
            return true;
        }
    };
    var receiver: Receiver = .{ .owner = observer, .port = sink };
    _ = observer.framing.feed(input, &receiver);
}

fn beginFrame(observer: *Observer) void {
    observer.padding = 0;

    if (observer.framing.frame_type == relay.frame_headers or observer.framing.frame_type == relay.frame_push_promise) {
        observer.block_end_stream = observer.framing.flags & relay.flag_end_stream != 0;
    }

    if (observer.failed) {
        if (observer.framing.frame_type == relay.frame_headers and observer.continuation_stream == 0) {
            observer.block_stream = observer.framing.stream_id;
            observer.block_kind = .headers;
        }
        return;
    }
    switch (observer.framing.frame_type) {
        relay.frame_headers, relay.frame_push_promise => {
            if (observer.continuation_stream != 0 or observer.framing.stream_id == 0) {
                observer.fail();
                return;
            }
            observer.block_len = 0;
            observer.block_stream = observer.framing.stream_id;
            observer.block_kind = if (observer.framing.frame_type == relay.frame_headers)
                .headers
            else
                .push_promise;
        },
        relay.frame_continuation => {
            if (observer.continuation_stream == 0 or
                observer.continuation_stream != observer.framing.stream_id)
            {
                observer.fail();
            }
        },
        else => if (observer.continuation_stream != 0) observer.fail(),
    }
}

fn observePayload(observer: *Observer, payload: []const u8, sink: anytype) void {
    if (observer.framing.frame_type == relay.frame_data and payload.len != 0) {
        if (observer.direction == .response) {
            sink.emit(.{ .lifecycle = .{
                .phase = .response_activity,
                .stream_id = observer.framing.stream_id,
                .status_code = observer.streams.status(observer.framing.stream_id),
            } });
        }

        if (observer.dataBodyFragment(payload)) |fragment| {
            if (fragment.len != 0) {
                switch (observer.direction) {
                    .request => sink.emit(.{ .request_body = .{
                        .stream_id = observer.framing.stream_id,
                        .bytes = fragment,
                    } }),
                    .response => sink.emit(.{ .response_body = .{
                        .stream_id = observer.framing.stream_id,
                        .status_code = observer.streams.status(observer.framing.stream_id),
                        .sse_body = observer.hasObservableSseBody(observer.framing.stream_id),
                        .bytes = fragment,
                    } }),
                }
            }
        }
    }

    if (observer.failed or !relay.isHeaderFrame(observer.framing.frame_type)) {
        return;
    }

    if (observer.framing.flags & relay.flag_padded != 0 and observer.framing.payload_offset == 0) {
        if (payload.len == 0) {
            return;
        }
        observer.padding = payload[0];
    }
    const prefix = observer.headerPrefixLength() orelse {
        observer.fail();
        return;
    };
    if (observer.padding > observer.framing.payload_len - prefix) {
        observer.fail();
        return;
    }
    const fragment_end = observer.framing.payload_len - observer.padding;
    const input_start = observer.framing.payload_offset;
    const input_end = input_start + payload.len;
    const copy_start = @max(input_start, prefix);
    const copy_end = @min(input_end, fragment_end);
    if (copy_start >= copy_end) {
        return;
    }
    const source = payload[copy_start - input_start .. copy_end - input_start];
    if (source.len > observer.block.len - observer.block_len) {
        observer.fail();
        return;
    }
    @memcpy(observer.block[observer.block_len..][0..source.len], source);
    observer.block_len += source.len;
}

fn finishFrame(observer: *Observer, sink: anytype) void {
    const completed_type = observer.framing.frame_type;
    const completed_flags = observer.framing.flags;
    const completed_stream = observer.framing.stream_id;

    if (relay.isHeaderFrame(completed_type)) {
        if (completed_flags & relay.flag_end_headers != 0) {
            observer.continuation_stream = 0;
            const decoded = if (observer.failed) Decoded{} else observer.decodeBlock(sink);
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
                            sink.emit(.{ .request_finished = .{ .stream_id = observer.block_stream } });
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
        } else if (completed_type != relay.frame_continuation) {
            observer.continuation_stream = completed_stream;
        }
    }

    if (completed_type == relay.frame_rst_stream and completed_stream != 0) {
        sink.emit(.{ .lifecycle = .{
            .phase = .request_failed,
            .stream_id = completed_stream,
            .status_code = observer.streams.status(completed_stream),
        } });
        observer.streams.finishResponse(completed_stream);
        if (observer.direction == .request) {
            observer.streams.finishRequest(completed_stream);
        }
    } else if (observer.direction == .response and completed_type == relay.frame_goaway and
        observer.streams.hasActiveResponses())
    {
        sink.emit(.{ .lifecycle = .{
            .phase = .request_failed,
            .stream_id = 0,
            .status_code = 0,
        } });
    } else if (observer.direction == .response and completed_type == relay.frame_data and
        completed_stream != 0 and
        completed_flags & relay.flag_end_stream != 0)
    {
        const status_code = observer.streams.status(completed_stream);
        sink.emit(.{ .lifecycle = .{
            .phase = if (status_code >= 400) .request_failed else .response_finished,
            .stream_id = completed_stream,
            .status_code = status_code,
        } });
        observer.streams.finishResponse(completed_stream);
    }
    if (observer.direction == .request and completed_type == relay.frame_data and
        completed_stream != 0 and
        completed_flags & relay.flag_end_stream != 0)
    {
        sink.emit(.{ .request_finished = .{ .stream_id = completed_stream } });
        observer.streams.finishRequest(completed_stream);
    }
}

fn dataBodyFragment(observer: *Observer, payload: []const u8) ?[]const u8 {
    const prefix: usize = @intFromBool(observer.framing.flags & relay.flag_padded != 0);

    if (prefix != 0 and observer.framing.payload_offset == 0) {
        if (payload.len == 0) {
            return "";
        }

        observer.padding = payload[0];
    }

    if (observer.padding > observer.framing.payload_len -| prefix) {
        return null;
    }

    const body_end = observer.framing.payload_len - observer.padding;
    const input_start = observer.framing.payload_offset;
    const input_end = input_start + payload.len;
    const fragment_start = @max(input_start, prefix);
    const fragment_end = @min(input_end, body_end);

    if (fragment_start >= fragment_end) {
        return "";
    }

    return payload[fragment_start - input_start .. fragment_end - input_start];
}

fn headerPrefixLength(observer: *const Observer) ?usize {
    var prefix: usize = if (observer.framing.flags & relay.flag_padded != 0) 1 else 0;
    prefix += switch (observer.framing.frame_type) {
        relay.frame_headers => if (observer.framing.flags & relay.flag_priority != 0) 5 else 0,
        relay.frame_push_promise => 4,
        relay.frame_continuation => 0,
        else => return null,
    };
    if (prefix > observer.framing.payload_len) {
        return null;
    }
    return prefix;
}

fn decodeBlock(observer: *Observer, sink: anytype) Decoded {
    const inflater = observer.inflater orelse {
        observer.fail();
        return .{};
    };
    var decoded: Decoded = .{};
    var input = observer.block[0..observer.block_len];
    while (true) {
        var field: relay.c.nghttp2_nv = undefined;
        var flags: c_int = 0;
        const consumed = relay.c.nghttp2_hd_inflate_hd2(
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
        if (flags & relay.c.NGHTTP2_HD_INFLATE_EMIT != 0) {
            const name = field.name[0..field.namelen];
            const value = field.value[0..field.valuelen];
            if (observer.block_kind == .headers) {
                const fields = [_]HeaderField{.{ .name = name, .value = value }};
                switch (observer.direction) {
                    .request => sink.emit(.{ .request_headers = .{
                        .stream_id = observer.block_stream,
                        .fields = &fields,
                    } }),
                    .response => sink.emit(.{ .response_headers = .{
                        .stream_id = observer.block_stream,
                        .fields = &fields,
                    } }),
                }
            }

            if (std.mem.eql(u8, name, ":status")) {
                decoded.status_code = std.fmt.parseInt(u16, value, 10) catch 0;
            }
            if (std.mem.eql(u8, name, ":method")) {
                decoded.request = true;
                decoded.inference_method = std.ascii.eqlIgnoreCase(value, "POST");
            }
            if (std.mem.eql(u8, name, ":path")) {
                decoded.inference_route = provider.classify(observer.dialect, .{
                    .method = "POST",
                    .target = value,
                }) == .inference;
            }
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
        if (flags & relay.c.NGHTTP2_HD_INFLATE_FINAL != 0) {
            if (relay.c.nghttp2_hd_inflate_end_headers(inflater) != 0) {
                observer.fail();
            }
            return decoded;
        }
        if (consumed == 0 and flags & relay.c.NGHTTP2_HD_INFLATE_EMIT == 0) {
            observer.fail();
            return .{};
        }
    }
}

fn hasObservableSseBody(observer: *const Observer, stream_id: u32) bool {
    return observer.streams.hasObservableSseBody(stream_id);
}

pub fn fail(observer: *Observer) void {
    observer.failed = true;
    observer.block_len = 0;
    observer.continuation_stream = 0;
    observer.block_kind = .none;
}
