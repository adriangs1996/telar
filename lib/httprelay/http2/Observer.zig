const relay = @import("relay.zig");
const RouteMatch = @import("../RouteMatch.zig");
const h2frames = @import("h2frames");
const Reader = h2frames.Reader;
const Tracker = h2frames.Tracker;
const std = @import("std");
const Decoded = @import("Decoded.zig");
const HeaderField = h2frames.HeaderField;
const header_rules = @import("../header_rules.zig");
const Observer = @This();

inflater: ?*relay.c.nghttp2_hd_inflater = null,
failed: bool = false,
/// A header block passed `max_header_block_bytes`.
block_too_large: bool = false,
/// Streams not followed because the tracker was full.
untracked_streams: u32 = 0,
/// Request routes to report as watched; at most 64.
watched_routes: []const RouteMatch,
direction: relay.Direction,

framing: Reader = .{},
padding: usize = 0,

continuation_stream: u32 = 0,
block_stream: u32 = 0,
block_kind: relay.HeaderKind = .none,
block_end_stream: bool = false,
block: [relay.max_header_block_bytes]u8 = undefined,
block_len: usize = 0,
streams: Tracker = .{},

/// Starts observing one direction. The inflater allocates through `memory`
/// (see `header_memory.of`), which must outlive the observer.
///
/// ```zig
/// var memory = header_memory.of(&gpa);
/// var observer = Observer.init(&memory, routes, .request);
/// defer observer.deinit();
/// ```
pub fn init(memory: *relay.c.nghttp2_mem, watched_routes: []const RouteMatch, direction: relay.Direction) Observer {
    std.debug.assert(watched_routes.len <= 64);
    var observer: Observer = .{
        .watched_routes = watched_routes,
        .direction = direction,
    };
    if (relay.c.nghttp2_hd_inflate_new2(&observer.inflater, memory) != 0 or
        relay.c.nghttp2_hd_inflate_change_table_size(
            observer.inflater,
            relay.max_header_block_bytes,
        ) != 0)
    {
        observer.failed = true;
    }
    return observer;
}

pub fn deinit(self: *Observer) void {
    if (self.inflater) |inflater| {
        relay.c.nghttp2_hd_inflate_del(inflater);
    }
    self.inflater = null;
    std.crypto.secureZero(u8, &self.block);
}

pub fn observe(self: *Observer, input: []const u8, sink: anytype) void {
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
    var receiver: Receiver = .{ .owner = self, .port = sink };
    _ = self.framing.feed(input, &receiver);
}

fn beginFrame(self: *Observer) void {
    self.padding = 0;

    if (self.framing.frame_type == relay.frame_headers or self.framing.frame_type == relay.frame_push_promise) {
        self.block_end_stream = self.framing.flags & relay.flag_end_stream != 0;
    }

    if (self.failed) {
        if (self.framing.frame_type == relay.frame_headers and self.continuation_stream == 0) {
            self.block_stream = self.framing.stream_id;
            self.block_kind = .headers;
        }
        return;
    }
    switch (self.framing.frame_type) {
        relay.frame_headers, relay.frame_push_promise => {
            if (self.continuation_stream != 0 or self.framing.stream_id == 0) {
                self.fail();
                return;
            }
            self.block_len = 0;
            self.block_stream = self.framing.stream_id;
            self.block_kind = if (self.framing.frame_type == relay.frame_headers)
                .headers
            else
                .push_promise;
        },
        relay.frame_continuation => {
            if (self.continuation_stream == 0 or
                self.continuation_stream != self.framing.stream_id)
            {
                self.fail();
            }
        },
        else => if (self.continuation_stream != 0) self.fail(),
    }
}

fn observePayload(self: *Observer, payload: []const u8, sink: anytype) void {
    if (self.framing.frame_type == relay.frame_data and payload.len != 0) {
        if (self.direction == .response) {
            sink.emit(.{ .lifecycle = .{
                .stage = .response_activity,
                .stream_id = self.framing.stream_id,
                .status_code = self.streams.status(self.framing.stream_id),
            } });
        }

        if (self.dataBodyFragment(payload)) |fragment| {
            if (fragment.len != 0) {
                switch (self.direction) {
                    .request => sink.emit(.{ .request_body = .{
                        .stream_id = self.framing.stream_id,
                        .bytes = fragment,
                    } }),
                    .response => sink.emit(.{ .response_body = .{
                        .stream_id = self.framing.stream_id,
                        .status_code = self.streams.status(self.framing.stream_id),
                        .sse_body = self.hasObservableSseBody(self.framing.stream_id),
                        .bytes = fragment,
                    } }),
                }
            }
        }
    }

    if (self.failed or !relay.isHeaderFrame(self.framing.frame_type)) {
        return;
    }

    if (self.framing.flags & relay.flag_padded != 0 and self.framing.payload_offset == 0) {
        if (payload.len == 0) {
            return;
        }
        self.padding = payload[0];
    }
    const prefix = self.headerPrefixLength() orelse {
        self.fail();
        return;
    };
    if (self.padding > self.framing.payload_len - prefix) {
        self.fail();
        return;
    }
    const fragment_end = self.framing.payload_len - self.padding;
    const input_start = self.framing.payload_offset;
    const input_end = input_start + payload.len;
    const copy_start = @max(input_start, prefix);
    const copy_end = @min(input_end, fragment_end);
    if (copy_start >= copy_end) {
        return;
    }
    const source = payload[copy_start - input_start .. copy_end - input_start];
    if (source.len > self.block.len - self.block_len) {
        self.block_too_large = true;
        self.fail();
        return;
    }
    @memcpy(self.block[self.block_len..][0..source.len], source);
    self.block_len += source.len;
}

fn finishFrame(self: *Observer, sink: anytype) void {
    const completed_type = self.framing.frame_type;
    const completed_flags = self.framing.flags;
    const completed_stream = self.framing.stream_id;

    if (relay.isHeaderFrame(completed_type)) {
        if (completed_flags & relay.flag_end_headers != 0) {
            self.continuation_stream = 0;
            const decoded = if (self.failed) Decoded{} else self.decodeBlock(sink);
            if (self.block_kind == .headers) {
                switch (self.direction) {
                    .request => {
                        if (decoded.request and self.streams.startRequest(self.block_stream)) {
                            sink.emit(.{ .lifecycle = .{
                                .stage = .request_started,
                                .watched = decoded.isWatched(),
                                .stream_id = self.block_stream,
                                .status_code = 0,
                            } });
                        } else if (decoded.request and self.streams.requestsFull()) {
                            self.untracked_streams +|= 1;
                        }

                        if (self.block_end_stream) {
                            sink.emit(.{ .request_finished = .{ .stream_id = self.block_stream } });
                            self.streams.finishRequest(self.block_stream);
                        }
                    },
                    .response => {
                        if (decoded.status_code >= 200 and !self.streams.setResponse(.{
                            .stream_id = self.block_stream,
                            .status_code = decoded.status_code,
                            .sse_body = decoded.hasObservableSseBody(),
                        })) {
                            self.untracked_streams +|= 1;
                        }

                        if (self.block_end_stream) {
                            const status_code = self.streams.status(self.block_stream);
                            sink.emit(.{ .lifecycle = .{
                                .stage = .response_ended,
                                .stream_id = self.block_stream,
                                .status_code = status_code,
                            } });
                            self.streams.finishResponse(self.block_stream);
                        }
                    },
                }
            }
            self.block_kind = .none;
            self.block_end_stream = false;
            self.block_len = 0;
        } else if (completed_type != relay.frame_continuation) {
            self.continuation_stream = completed_stream;
        }
    }

    if (completed_type == relay.frame_rst_stream and completed_stream != 0) {
        sink.emit(.{ .lifecycle = .{
            .stage = .stream_reset,
            .stream_id = completed_stream,
            .status_code = self.streams.status(completed_stream),
        } });
        self.streams.finishResponse(completed_stream);
        if (self.direction == .request) {
            self.streams.finishRequest(completed_stream);
        }
    } else if (self.direction == .response and completed_type == relay.frame_goaway and
        self.streams.hasActiveResponses())
    {
        sink.emit(.{ .lifecycle = .{
            .stage = .connection_lost,
            .stream_id = 0,
            .status_code = 0,
        } });
    } else if (self.direction == .response and completed_type == relay.frame_data and
        completed_stream != 0 and
        completed_flags & relay.flag_end_stream != 0)
    {
        const status_code = self.streams.status(completed_stream);
        sink.emit(.{ .lifecycle = .{
            .stage = .response_ended,
            .stream_id = completed_stream,
            .status_code = status_code,
        } });
        self.streams.finishResponse(completed_stream);
    }
    if (self.direction == .request and completed_type == relay.frame_data and
        completed_stream != 0 and
        completed_flags & relay.flag_end_stream != 0)
    {
        sink.emit(.{ .request_finished = .{ .stream_id = completed_stream } });
        self.streams.finishRequest(completed_stream);
    }
}

fn dataBodyFragment(self: *Observer, payload: []const u8) ?[]const u8 {
    const prefix: usize = @intFromBool(self.framing.flags & relay.flag_padded != 0);

    if (prefix != 0 and self.framing.payload_offset == 0) {
        if (payload.len == 0) {
            return "";
        }

        self.padding = payload[0];
    }

    if (self.padding > self.framing.payload_len -| prefix) {
        return null;
    }

    const body_end = self.framing.payload_len - self.padding;
    const input_start = self.framing.payload_offset;
    const input_end = input_start + payload.len;
    const fragment_start = @max(input_start, prefix);
    const fragment_end = @min(input_end, body_end);

    if (fragment_start >= fragment_end) {
        return "";
    }

    return payload[fragment_start - input_start .. fragment_end - input_start];
}

fn headerPrefixLength(self: *const Observer) ?usize {
    var prefix: usize = if (self.framing.flags & relay.flag_padded != 0) 1 else 0;
    prefix += switch (self.framing.frame_type) {
        relay.frame_headers => if (self.framing.flags & relay.flag_priority != 0) 5 else 0,
        relay.frame_push_promise => 4,
        relay.frame_continuation => 0,
        else => return null,
    };
    if (prefix > self.framing.payload_len) {
        return null;
    }
    return prefix;
}

fn decodeBlock(self: *Observer, sink: anytype) Decoded {
    const inflater = self.inflater orelse {
        self.fail();
        return .{};
    };
    var decoded: Decoded = .{};
    var input = self.block[0..self.block_len];
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
            self.fail();
            return .{};
        }
        input = input[@intCast(consumed)..];
        if (flags & relay.c.NGHTTP2_HD_INFLATE_EMIT != 0) {
            const name = field.name[0..field.namelen];
            const value = field.value[0..field.valuelen];
            if (self.block_kind == .headers) {
                const fields = [_]HeaderField{.{ .name = name, .value = value }};
                switch (self.direction) {
                    .request => sink.emit(.{ .request_headers = .{
                        .stream_id = self.block_stream,
                        .fields = &fields,
                    } }),
                    .response => sink.emit(.{ .response_headers = .{
                        .stream_id = self.block_stream,
                        .fields = &fields,
                    } }),
                }
            }

            if (std.mem.eql(u8, name, ":status")) {
                decoded.status_code = std.fmt.parseInt(u16, value, 10) catch 0;
            }
            if (std.mem.eql(u8, name, ":method")) {
                decoded.request = true;
                for (self.watched_routes, 0..) |route, index| {
                    if (route.matchesMethod(value)) {
                        decoded.method_routes |= @as(u64, 1) << @intCast(index);
                    }
                }
            }
            if (std.mem.eql(u8, name, ":path")) {
                for (self.watched_routes, 0..) |route, index| {
                    if (route.matchesPath(value)) {
                        decoded.path_routes |= @as(u64, 1) << @intCast(index);
                    }
                }
            }
            if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                if (decoded.content_type_seen) {
                    decoded.metadata_valid = false;
                } else {
                    decoded.content_type_seen = true;
                    decoded.event_stream = header_rules.isEventStreamContentType(value);
                }
            }
            if (std.ascii.eqlIgnoreCase(name, "content-encoding") and
                !header_rules.isIdentityContentEncoding(value))
            {
                decoded.identity_encoding = false;
            }
        }
        if (flags & relay.c.NGHTTP2_HD_INFLATE_FINAL != 0) {
            if (relay.c.nghttp2_hd_inflate_end_headers(inflater) != 0) {
                self.fail();
            }
            return decoded;
        }
        if (consumed == 0 and flags & relay.c.NGHTTP2_HD_INFLATE_EMIT == 0) {
            self.fail();
            return .{};
        }
    }
}

fn hasObservableSseBody(self: *const Observer, stream_id: u32) bool {
    return self.streams.hasObservableSseBody(stream_id);
}

pub fn fail(self: *Observer) void {
    self.failed = true;
    self.block_len = 0;
    self.continuation_stream = 0;
    self.block_kind = .none;
}
