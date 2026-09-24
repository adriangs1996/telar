const relay = @import("relay.zig");
const RouteMatch = @import("../RouteMatch.zig");
const TranscodeConfiguration = @import("TranscodeConfiguration.zig");
const h2frames = @import("h2frames");
const Reader = h2frames.Reader;
const Tracker = h2frames.Tracker;
const std = @import("std");
const Headers = @import("../Headers.zig");
const rewrites = @import("../rewrites.zig");
const header_rules = @import("../header_rules.zig");
const framing_module = h2frames.framing;
const PeerSettings = h2frames.PeerSettings;
const Transcoder = @This();

inflater: ?*relay.c.nghttp2_hd_inflater = null,
deflater: ?*relay.c.nghttp2_hd_deflater = null,
failed: bool = false,
/// Request routes to report as watched.
watched_routes: []const RouteMatch,
configuration: TranscodeConfiguration,
applied_table_size: u32 = 4096,
applied_inflate_table_size: u32 = relay.max_header_block_bytes,

framing: Reader = .{},

continuation_stream: u32 = 0,
block_type: u8 = 0,
block_flags: u8 = 0,
block_stream: u32 = 0,
block_prefix: [5]u8 = undefined,
block_prefix_len: u8 = 0,
block_prefix_seen: u8 = 0,
frame_padding: usize = 0,
compressed: [relay.max_header_block_bytes]u8 = undefined,
compressed_len: usize = 0,
encoded: [2 * relay.max_header_block_bytes]u8 = undefined,
setting: [6]u8 = undefined,
setting_len: u8 = 0,
streams: Tracker = .{},

pub fn init(watched_routes: []const RouteMatch, configuration: TranscodeConfiguration) Transcoder {
    var transcoder: Transcoder = .{ .watched_routes = watched_routes, .configuration = configuration };
    if (relay.c.nghttp2_hd_inflate_new(&transcoder.inflater) != 0 or
        relay.c.nghttp2_hd_inflate_change_table_size(
            transcoder.inflater,
            relay.max_header_block_bytes,
        ) != 0)
    {
        transcoder.failed = true;
    }
    if (relay.c.nghttp2_hd_deflate_new(&transcoder.deflater, relay.max_header_block_bytes) != 0) {
        transcoder.failed = true;
    }
    return transcoder;
}

pub fn deinit(self: *Transcoder) void {
    if (self.inflater) |inflater| {
        relay.c.nghttp2_hd_inflate_del(inflater);
    }
    if (self.deflater) |deflater| {
        relay.c.nghttp2_hd_deflate_del(deflater);
    }
    self.inflater = null;
    self.deflater = null;
    std.crypto.secureZero(u8, &self.compressed);
    std.crypto.secureZero(u8, &self.encoded);
}

pub fn process(self: *Transcoder, input: []const u8, port: anytype) bool {
    const Receiver = struct {
        owner: *Transcoder,
        port: @TypeOf(port),

        pub fn beginFrame(receiver: *@This()) bool {
            return !receiver.owner.failed and receiver.owner.beginFrame(receiver.port);
        }

        pub fn payload(receiver: *@This(), bytes: []const u8) bool {
            return !receiver.owner.failed and receiver.owner.processPayload(bytes, receiver.port);
        }

        pub fn finishFrame(receiver: *@This()) bool {
            return receiver.owner.finishFrame(receiver.port);
        }
    };
    var receiver: Receiver = .{ .owner = self, .port = port };
    return self.framing.feed(input, &receiver) and !self.failed;
}

fn beginFrame(self: *Transcoder, port: anytype) bool {
    self.setting_len = 0;
    self.frame_padding = 0;

    if (self.continuation_stream != 0) {
        if (self.framing.frame_type != relay.frame_continuation or
            self.framing.stream_id != self.continuation_stream)
        {
            self.failed = true;
            return false;
        }
        return true;
    }
    if (self.framing.frame_type == relay.frame_continuation) {
        self.failed = true;
        return false;
    }
    if (self.framing.frame_type == relay.frame_headers or
        self.framing.frame_type == relay.frame_push_promise)
    {
        if (self.framing.stream_id == 0) {
            self.failed = true;
            return false;
        }
        self.block_type = self.framing.frame_type;
        self.block_flags = self.framing.flags;
        self.block_stream = self.framing.stream_id;
        self.block_prefix_len = switch (self.framing.frame_type) {
            relay.frame_headers => if (self.framing.flags & relay.flag_priority != 0) 5 else 0,
            relay.frame_push_promise => 4,
            else => unreachable,
        };
        self.block_prefix_seen = 0;
        self.compressed_len = 0;
        return true;
    }
    if (!port.writeAll(self.configuration.to, &self.framing.header)) {
        self.failed = true;
        return false;
    }
    return true;
}

fn processPayload(self: *Transcoder, payload: []const u8, port: anytype) bool {
    if (!relay.isHeaderFrame(self.framing.frame_type)) {
        // Publish peer limits before the last SETTINGS byte reaches the
        // peer. Its next header block may use the newly advertised HPACK
        // table or frame size immediately.
        if (self.framing.frame_type == relay.c.NGHTTP2_SETTINGS and
            self.framing.flags & relay.c.NGHTTP2_FLAG_ACK == 0)
        {
            self.observeSettings(payload, self.configuration.source_settings);
        }
        if (!port.writeAll(self.configuration.to, payload)) {
            self.failed = true;
            return false;
        }
        if (self.framing.frame_type == relay.frame_data and payload.len != 0) {
            if (self.configuration.direction == .response) {
                port.emit(.{ .lifecycle = .{
                    .stage = .response_activity,
                    .stream_id = self.framing.stream_id,
                    .status_code = self.streams.status(self.framing.stream_id),
                } });
            }

            if (self.dataBodyFragment(payload)) |fragment| {
                if (fragment.len != 0) {
                    switch (self.configuration.direction) {
                        .request => port.emit(.{ .request_body = .{
                            .stream_id = self.framing.stream_id,
                            .bytes = fragment,
                        } }),
                        .response => port.emit(.{ .response_body = .{
                            .stream_id = self.framing.stream_id,
                            .status_code = self.streams.status(self.framing.stream_id),
                            .sse_body = self.hasObservableSseBody(self.framing.stream_id),
                            .bytes = fragment,
                        } }),
                    }
                }
            }
        }
        return true;
    }

    var input_start = self.framing.payload_offset;
    var slice = payload;
    if (self.framing.frame_type != relay.frame_continuation and
        self.framing.flags & relay.flag_padded != 0 and input_start == 0)
    {
        if (slice.len == 0) {
            return true;
        }
        self.frame_padding = slice[0];
        slice = slice[1..];
        input_start += 1;
    }

    if (self.framing.frame_type != relay.frame_continuation and
        self.block_prefix_seen < self.block_prefix_len)
    {
        const take = @min(
            self.block_prefix_len - self.block_prefix_seen,
            slice.len,
        );
        @memcpy(
            self.block_prefix[self.block_prefix_seen..][0..take],
            slice[0..take],
        );
        self.block_prefix_seen += @intCast(take);
        slice = slice[take..];
        input_start += take;
    }

    const padding_start = self.framing.payload_len -| self.frame_padding;
    if (self.frame_padding > self.framing.payload_len or
        padding_start < self.headerPayloadPrefixLength())
    {
        self.failed = true;
        return false;
    }
    if (input_start >= padding_start) {
        return true;
    }
    const fragment_len = @min(slice.len, padding_start - input_start);
    if (fragment_len > self.compressed.len - self.compressed_len) {
        self.failed = true;
        return false;
    }
    @memcpy(
        self.compressed[self.compressed_len..][0..fragment_len],
        slice[0..fragment_len],
    );
    self.compressed_len += fragment_len;
    return true;
}

fn finishFrame(self: *Transcoder, port: anytype) bool {
    const completed_type = self.framing.frame_type;
    const completed_flags = self.framing.flags;
    const completed_stream = self.framing.stream_id;

    if (relay.isHeaderFrame(completed_type)) {
        if (completed_flags & relay.flag_end_headers == 0) {
            self.continuation_stream = completed_stream;
        } else {
            self.continuation_stream = 0;
            if (self.block_prefix_seen != self.block_prefix_len or
                !self.finishHeaderBlock(port))
            {
                self.failed = true;
                return false;
            }
        }
    } else {
        self.observeCompletedFrame(.{
            .frame_type = completed_type,
            .flags = completed_flags,
            .stream_id = completed_stream,
        }, port);
    }

    return true;
}

fn finishHeaderBlock(self: *Transcoder, port: anytype) bool {
    const configuration = self.configuration;
    const direction = configuration.direction;
    const target_settings = configuration.target_settings;

    const inflate_table_size = @min(
        target_settings.header_table_size.load(.seq_cst),
        relay.max_header_block_bytes,
    );
    if (inflate_table_size != self.applied_inflate_table_size) {
        const inflater = self.inflater orelse return false;
        if (relay.c.nghttp2_hd_inflate_change_table_size(inflater, inflate_table_size) != 0) {
            return false;
        }
        self.applied_inflate_table_size = inflate_table_size;
    }
    // The table-size limit must be installed before decoding a block that
    // can begin with an HPACK dynamic-table update.
    var original = self.decodeHeaders() orelse return false;
    const kind = relay.headerKind(self.block_type, &original);
    if (!relay.validH2Headers(&original, kind)) {
        return false;
    }
    if (self.block_type == relay.frame_push_promise and
        (direction != .response or relay.promisedStreamId(self) == 0 or
            relay.promisedStreamId(self) & 1 != 0))
    {
        return false;
    }
    if (kind == .request or kind == .response) {
        relay.emitHeaders(port, .{
            .direction = direction,
            .stream_id = self.block_stream,
            .headers = &original,
        });
    }
    var transformed: Headers = undefined;
    transformed.copyFrom(&original);
    _ = rewrites.apply(configuration.rewrites, .{
        .direction = switch (direction) {
            .request => .request,
            .response => .response,
        },
        .kind = kind,
    }, &transformed);
    if (!relay.compatibleH2Headers(&original, &transformed, kind)) {
        transformed.copyFrom(&original);
    }

    if (direction == .request and kind == .request and
        self.streams.startRequest(self.block_stream))
    {
        port.emit(.{ .lifecycle = .{
            .stage = .request_started,
            .watched = RouteMatch.matchesAny(
                original.find(":method") orelse "",
                original.find(":path") orelse "",
                self.watched_routes,
            ),
            .stream_id = self.block_stream,
            .status_code = 0,
        } });
    }

    const table_size = @min(
        target_settings.header_table_size.load(.seq_cst),
        relay.max_header_block_bytes,
    );
    if (table_size != self.applied_table_size) {
        const deflater = self.deflater orelse return false;
        if (relay.c.nghttp2_hd_deflate_change_table_size(deflater, table_size) != 0) {
            return false;
        }
        self.applied_table_size = table_size;
    }
    var nv: [header_rules.max_header_fields]relay.c.nghttp2_nv = undefined;
    for (transformed.fields[0..transformed.len], 0..) |field, index| nv[index] = .{
        .name = @constCast(transformed.name(field).ptr),
        .value = @constCast(transformed.value(field).ptr),
        .namelen = field.name_len,
        .valuelen = field.value_len,
        .flags = if (field.sensitive) relay.c.NGHTTP2_NV_FLAG_NO_INDEX else 0,
    };
    const deflater = self.deflater orelse return false;
    const bound = relay.c.nghttp2_hd_deflate_bound(deflater, &nv, transformed.len);
    if (bound > self.encoded.len) {
        return false;
    }
    const encoded_len = relay.c.nghttp2_hd_deflate_hd2(
        deflater,
        &self.encoded,
        self.encoded.len,
        &nv,
        transformed.len,
    );
    if (encoded_len < 0) {
        return false;
    }
    if (!self.writeHeaderBlock(port, @intCast(encoded_len))) {
        return false;
    }

    const status_code = relay.parseStatusHeader(&transformed);
    if (direction == .response and status_code >= 200) {
        _ = self.streams.setResponse(.{
            .stream_id = self.block_stream,
            .status_code = status_code,
            .sse_body = header_rules.hasObservableSseBody(&original),
        });
    }

    if (self.block_flags & relay.flag_end_stream != 0) {
        switch (direction) {
            .request => {
                port.emit(.{ .request_finished = .{ .stream_id = self.block_stream } });
                self.streams.finishRequest(self.block_stream);
            },
            .response => {
                const final_status = self.streams.status(self.block_stream);
                port.emit(.{ .lifecycle = .{
                    .stage = .response_ended,
                    .stream_id = self.block_stream,
                    .status_code = final_status,
                } });
                self.streams.finishResponse(self.block_stream);
            },
        }
    }
    return true;
}

fn decodeHeaders(self: *Transcoder) ?Headers {
    const inflater = self.inflater orelse return null;
    var headers: Headers = .{};
    var input = self.compressed[0..self.compressed_len];
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
            return null;
        }
        input = input[@intCast(consumed)..];
        if (flags & relay.c.NGHTTP2_HD_INFLATE_EMIT != 0) {
            headers.append(.{
                .name = field.name[0..field.namelen],
                .value = field.value[0..field.valuelen],
                .sensitive = field.flags & relay.c.NGHTTP2_NV_FLAG_NO_INDEX != 0,
            }) catch return null;
        }
        if (flags & relay.c.NGHTTP2_HD_INFLATE_FINAL != 0) {
            if (relay.c.nghttp2_hd_inflate_end_headers(inflater) != 0) {
                return null;
            }
            return headers;
        }
        if (consumed == 0 and flags & relay.c.NGHTTP2_HD_INFLATE_EMIT == 0) {
            return null;
        }
    }
}

fn writeHeaderBlock(self: *Transcoder, port: anytype, encoded_len: usize) bool {
    const advertised_frame_size = self.configuration.target_settings.max_frame_size.load(.seq_cst);
    const max_frame_size: usize = if (advertised_frame_size >= 16 * 1024 and
        advertised_frame_size <= 0x00ff_ffff)
        advertised_frame_size
    else
        16 * 1024;
    if (self.block_prefix_len >= max_frame_size) {
        return false;
    }
    var offset: usize = 0;
    var first = true;
    while (first or offset < encoded_len) {
        const prefix_len: usize = if (first) self.block_prefix_len else 0;
        const fragment_len = @min(encoded_len - offset, max_frame_size - prefix_len);
        const final = offset + fragment_len == encoded_len;
        var header: [framing_module.header_bytes]u8 = undefined;
        const kind: u8 = if (first) self.block_type else relay.frame_continuation;
        var flags: u8 = if (first)
            self.block_flags & ~(relay.flag_padded | relay.flag_end_headers)
        else
            0;
        if (final) {
            flags |= relay.flag_end_headers;
        }
        relay.writeFrameHeader(
            &header,
            .{
                .length = prefix_len + fragment_len,
                .frame_type = kind,
                .flags = flags,
                .stream_id = self.block_stream,
            },
        );
        if (!port.writeAll(self.configuration.to, &header)) {
            return false;
        }

        if (prefix_len != 0 and !port.writeAll(
            self.configuration.to,
            self.block_prefix[0..prefix_len],
        )) {
            return false;
        }

        if (fragment_len != 0 and !port.writeAll(
            self.configuration.to,
            self.encoded[offset..][0..fragment_len],
        )) {
            return false;
        }

        offset += fragment_len;
        first = false;
    }
    return true;
}

fn observeSettings(self: *Transcoder, payload: []const u8, settings: *PeerSettings) void {
    for (payload) |byte| {
        self.setting[self.setting_len] = byte;
        self.setting_len += 1;
        if (self.setting_len != self.setting.len) {
            continue;
        }
        const identifier = std.mem.readInt(u16, self.setting[0..2], .big);
        const value = std.mem.readInt(u32, self.setting[2..6], .big);
        switch (identifier) {
            relay.c.NGHTTP2_SETTINGS_HEADER_TABLE_SIZE => settings.header_table_size.store(value, .seq_cst),
            relay.c.NGHTTP2_SETTINGS_MAX_FRAME_SIZE => if (value >= 16 * 1024 and
                value <= 0x00ff_ffff)
                settings.max_frame_size.store(value, .seq_cst),
            else => {},
        }
        self.setting_len = 0;
    }
}

fn observeCompletedFrame(self: *Transcoder, completed: CompletedFrame, port: anytype) void {
    const direction = self.configuration.direction;
    const frame_type = completed.frame_type;
    const frame_flags = completed.flags;
    const frame_stream = completed.stream_id;

    if (frame_type == relay.frame_rst_stream and frame_stream != 0) {
        port.emit(.{ .lifecycle = .{
            .stage = .stream_reset,
            .stream_id = frame_stream,
            .status_code = self.streams.status(frame_stream),
        } });
        self.streams.finishResponse(frame_stream);
        if (direction == .request) {
            self.streams.finishRequest(frame_stream);
        }
    } else if (direction == .response and frame_type == relay.frame_goaway and
        self.streams.hasActiveResponses())
    {
        port.emit(.{ .lifecycle = .{
            .stage = .connection_lost,
            .stream_id = 0,
            .status_code = 0,
        } });
    } else if (direction == .response and frame_type == relay.frame_data and
        frame_stream != 0 and frame_flags & relay.flag_end_stream != 0)
    {
        const status_code = self.streams.status(frame_stream);
        port.emit(.{ .lifecycle = .{
            .stage = .response_ended,
            .stream_id = frame_stream,
            .status_code = status_code,
        } });
        self.streams.finishResponse(frame_stream);
    }
    if (direction == .request and frame_type == relay.frame_data and
        frame_stream != 0 and frame_flags & relay.flag_end_stream != 0)
    {
        port.emit(.{ .request_finished = .{ .stream_id = frame_stream } });
        self.streams.finishRequest(frame_stream);
    }
}

fn dataBodyFragment(self: *Transcoder, payload: []const u8) ?[]const u8 {
    const prefix: usize = @intFromBool(self.framing.flags & relay.flag_padded != 0);

    if (prefix != 0 and self.framing.payload_offset == 0) {
        if (payload.len == 0) {
            return "";
        }

        self.frame_padding = payload[0];
    }

    if (self.frame_padding > self.framing.payload_len -| prefix) {
        return null;
    }

    const body_end = self.framing.payload_len - self.frame_padding;
    const input_start = self.framing.payload_offset;
    const input_end = input_start + payload.len;
    const fragment_start = @max(input_start, prefix);
    const fragment_end = @min(input_end, body_end);

    if (fragment_start >= fragment_end) {
        return "";
    }

    return payload[fragment_start - input_start .. fragment_end - input_start];
}

fn headerPayloadPrefixLength(self: *const Transcoder) usize {
    if (self.framing.frame_type == relay.frame_continuation) {
        return 0;
    }
    return @as(usize, self.block_prefix_len) +
        @intFromBool(self.block_flags & relay.flag_padded != 0);
}

fn hasObservableSseBody(self: *const Transcoder, stream_id: u32) bool {
    return self.streams.hasObservableSseBody(stream_id);
}

const CompletedFrame = struct {
    frame_type: u8,
    flags: u8,
    stream_id: u32,
};
