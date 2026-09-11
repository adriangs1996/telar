const Transcoder = @This();
const source_namespace = @import("relay.zig");
const provider = @import("../provider/request_support.zig");
const TranscodeConfiguration = @import("TranscodeConfiguration.zig");
const framing_module = @import("framing.zig");
const stream_state = @import("streams.zig");
const std = @import("std");
const middleware = @import("../middleware.zig");
const PeerSettings = @import("PeerSettings.zig");
const CompletedFrame = @import("CompletedFrame.zig");
inflater: ?*source_namespace.c.nghttp2_hd_inflater = null,
deflater: ?*source_namespace.c.nghttp2_hd_deflater = null,
failed: bool = false,
dialect: provider.ApiDialect,
configuration: TranscodeConfiguration,
applied_table_size: u32 = 4096,
applied_inflate_table_size: u32 = source_namespace.max_header_block_bytes,

framing: framing_module.Reader = .{},

continuation_stream: u32 = 0,
block_type: u8 = 0,
block_flags: u8 = 0,
block_stream: u32 = 0,
block_prefix: [5]u8 = undefined,
block_prefix_len: u8 = 0,
block_prefix_seen: u8 = 0,
frame_padding: usize = 0,
compressed: [source_namespace.max_header_block_bytes]u8 = undefined,
compressed_len: usize = 0,
encoded: [2 * source_namespace.max_header_block_bytes]u8 = undefined,
setting: [6]u8 = undefined,
setting_len: u8 = 0,
streams: stream_state.Tracker = .{},

pub fn init(dialect: provider.ApiDialect, configuration: TranscodeConfiguration) Transcoder {
    var transcoder: Transcoder = .{ .dialect = dialect, .configuration = configuration };
    if (source_namespace.c.nghttp2_hd_inflate_new(&transcoder.inflater) != 0 or
        source_namespace.c.nghttp2_hd_inflate_change_table_size(
            transcoder.inflater,
            source_namespace.max_header_block_bytes,
        ) != 0)
    {
        transcoder.failed = true;
    }
    if (source_namespace.c.nghttp2_hd_deflate_new(&transcoder.deflater, source_namespace.max_header_block_bytes) != 0) {
        transcoder.failed = true;
    }
    return transcoder;
}

pub fn deinit(transcoder: *Transcoder) void {
    if (transcoder.inflater) |inflater| {
        source_namespace.c.nghttp2_hd_inflate_del(inflater);
    }
    if (transcoder.deflater) |deflater| {
        source_namespace.c.nghttp2_hd_deflate_del(deflater);
    }
    transcoder.inflater = null;
    transcoder.deflater = null;
    std.crypto.secureZero(u8, &transcoder.compressed);
    std.crypto.secureZero(u8, &transcoder.encoded);
}

pub fn process(transcoder: *Transcoder, input: []const u8, port: anytype) bool {
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
    var receiver: Receiver = .{ .owner = transcoder, .port = port };
    return transcoder.framing.feed(input, &receiver) and !transcoder.failed;
}

fn beginFrame(transcoder: *Transcoder, port: anytype) bool {
    transcoder.setting_len = 0;
    transcoder.frame_padding = 0;

    if (transcoder.continuation_stream != 0) {
        if (transcoder.framing.frame_type != source_namespace.frame_continuation or
            transcoder.framing.stream_id != transcoder.continuation_stream)
        {
            transcoder.failed = true;
            return false;
        }
        return true;
    }
    if (transcoder.framing.frame_type == source_namespace.frame_continuation) {
        transcoder.failed = true;
        return false;
    }
    if (transcoder.framing.frame_type == source_namespace.frame_headers or
        transcoder.framing.frame_type == source_namespace.frame_push_promise)
    {
        if (transcoder.framing.stream_id == 0) {
            transcoder.failed = true;
            return false;
        }
        transcoder.block_type = transcoder.framing.frame_type;
        transcoder.block_flags = transcoder.framing.flags;
        transcoder.block_stream = transcoder.framing.stream_id;
        transcoder.block_prefix_len = switch (transcoder.framing.frame_type) {
            source_namespace.frame_headers => if (transcoder.framing.flags & source_namespace.flag_priority != 0) 5 else 0,
            source_namespace.frame_push_promise => 4,
            else => unreachable,
        };
        transcoder.block_prefix_seen = 0;
        transcoder.compressed_len = 0;
        return true;
    }
    if (!port.writeAll(transcoder.configuration.to, &transcoder.framing.header)) {
        transcoder.failed = true;
        return false;
    }
    return true;
}

fn processPayload(transcoder: *Transcoder, payload: []const u8, port: anytype) bool {
    if (!source_namespace.isHeaderFrame(transcoder.framing.frame_type)) {
        // Publish peer limits before the last SETTINGS byte reaches the
        // peer. Its next header block may use the newly advertised HPACK
        // table or frame size immediately.
        if (transcoder.framing.frame_type == source_namespace.c.NGHTTP2_SETTINGS and
            transcoder.framing.flags & source_namespace.c.NGHTTP2_FLAG_ACK == 0)
        {
            transcoder.observeSettings(payload, transcoder.configuration.source_settings);
        }
        if (!port.writeAll(transcoder.configuration.to, payload)) {
            transcoder.failed = true;
            return false;
        }
        if (transcoder.framing.frame_type == source_namespace.frame_data and payload.len != 0) {
            if (transcoder.configuration.direction == .response) {
                port.emit(.{ .lifecycle = .{
                    .phase = .response_activity,
                    .stream_id = transcoder.framing.stream_id,
                    .status_code = transcoder.streams.status(transcoder.framing.stream_id),
                } });
            }

            if (transcoder.dataBodyFragment(payload)) |fragment| {
                if (fragment.len != 0) {
                    switch (transcoder.configuration.direction) {
                        .request => port.emit(.{ .request_body = .{
                            .stream_id = transcoder.framing.stream_id,
                            .bytes = fragment,
                        } }),
                        .response => port.emit(.{ .response_body = .{
                            .stream_id = transcoder.framing.stream_id,
                            .status_code = transcoder.streams.status(transcoder.framing.stream_id),
                            .sse_body = transcoder.hasObservableSseBody(transcoder.framing.stream_id),
                            .bytes = fragment,
                        } }),
                    }
                }
            }
        }
        return true;
    }

    var input_start = transcoder.framing.payload_offset;
    var slice = payload;
    if (transcoder.framing.frame_type != source_namespace.frame_continuation and
        transcoder.framing.flags & source_namespace.flag_padded != 0 and input_start == 0)
    {
        if (slice.len == 0) {
            return true;
        }
        transcoder.frame_padding = slice[0];
        slice = slice[1..];
        input_start += 1;
    }

    if (transcoder.framing.frame_type != source_namespace.frame_continuation and
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

    const padding_start = transcoder.framing.payload_len -| transcoder.frame_padding;
    if (transcoder.frame_padding > transcoder.framing.payload_len or
        padding_start < transcoder.headerPayloadPrefixLength())
    {
        transcoder.failed = true;
        return false;
    }
    if (input_start >= padding_start) {
        return true;
    }
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
    const completed_type = transcoder.framing.frame_type;
    const completed_flags = transcoder.framing.flags;
    const completed_stream = transcoder.framing.stream_id;

    if (source_namespace.isHeaderFrame(completed_type)) {
        if (completed_flags & source_namespace.flag_end_headers == 0) {
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

    return true;
}

fn finishHeaderBlock(transcoder: *Transcoder, port: anytype) bool {
    const configuration = transcoder.configuration;
    const direction = configuration.direction;
    const target_settings = configuration.target_settings;

    const inflate_table_size = @min(
        target_settings.header_table_size.load(.seq_cst),
        source_namespace.max_header_block_bytes,
    );
    if (inflate_table_size != transcoder.applied_inflate_table_size) {
        const inflater = transcoder.inflater orelse return false;
        if (source_namespace.c.nghttp2_hd_inflate_change_table_size(inflater, inflate_table_size) != 0) {
            return false;
        }
        transcoder.applied_inflate_table_size = inflate_table_size;
    }
    // The table-size limit must be installed before decoding a block that
    // can begin with an HPACK dynamic-table update.
    var original = transcoder.decodeHeaders() orelse return false;
    const kind = source_namespace.headerKind(transcoder.block_type, &original);
    if (!source_namespace.validH2Headers(&original, kind)) {
        return false;
    }
    if (transcoder.block_type == source_namespace.frame_push_promise and
        (direction != .response or source_namespace.promisedStreamId(transcoder) == 0 or
            source_namespace.promisedStreamId(transcoder) & 1 != 0))
    {
        return false;
    }
    if (kind == .request or kind == .response) {
        source_namespace.emitHeaders(port, .{
            .direction = direction,
            .stream_id = transcoder.block_stream,
            .headers = &original,
        });
    }
    var transformed: middleware.Headers = undefined;
    transformed.copyFrom(&original);
    var context = configuration.transform_context;
    context.stream_id = if (transcoder.block_type == source_namespace.frame_push_promise)
        source_namespace.promisedStreamId(transcoder)
    else
        transcoder.block_stream;
    context.kind = kind;
    _ = configuration.pipeline.apply(.{ .io = configuration.io, .context = context, .headers = &transformed });
    if (!source_namespace.compatibleH2Headers(&original, &transformed, context.kind)) {
        transformed.copyFrom(&original);
    }

    if (direction == .request and context.kind == .request and
        transcoder.streams.startRequest(transcoder.block_stream))
    {
        port.emit(.{ .lifecycle = .{
            .phase = if (provider.classify(transcoder.dialect, .{
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
        source_namespace.max_header_block_bytes,
    );
    if (table_size != transcoder.applied_table_size) {
        const deflater = transcoder.deflater orelse return false;
        if (source_namespace.c.nghttp2_hd_deflate_change_table_size(deflater, table_size) != 0) {
            return false;
        }
        transcoder.applied_table_size = table_size;
    }
    var nv: [middleware.max_header_fields]source_namespace.c.nghttp2_nv = undefined;
    for (transformed.fields[0..transformed.len], 0..) |field, index| nv[index] = .{
        .name = @constCast(transformed.name(field).ptr),
        .value = @constCast(transformed.value(field).ptr),
        .namelen = field.name_len,
        .valuelen = field.value_len,
        .flags = if (field.sensitive) source_namespace.c.NGHTTP2_NV_FLAG_NO_INDEX else 0,
    };
    const deflater = transcoder.deflater orelse return false;
    const bound = source_namespace.c.nghttp2_hd_deflate_bound(deflater, &nv, transformed.len);
    if (bound > transcoder.encoded.len) {
        return false;
    }
    const encoded_len = source_namespace.c.nghttp2_hd_deflate_hd2(
        deflater,
        &transcoder.encoded,
        transcoder.encoded.len,
        &nv,
        transformed.len,
    );
    if (encoded_len < 0) {
        return false;
    }
    if (!transcoder.writeHeaderBlock(port, @intCast(encoded_len))) {
        return false;
    }

    const status_code = source_namespace.parseStatusHeader(&transformed);
    if (direction == .response and status_code >= 200) {
        _ = transcoder.streams.setResponse(.{
            .stream_id = transcoder.block_stream,
            .status_code = status_code,
            .sse_body = middleware.hasObservableSseBody(&original),
        });
    }

    if (transcoder.block_flags & source_namespace.flag_end_stream != 0) {
        switch (direction) {
            .request => {
                port.emit(.{ .request_finished = .{ .stream_id = transcoder.block_stream } });
                transcoder.streams.finishRequest(transcoder.block_stream);
            },
            .response => {
                const final_status = transcoder.streams.status(transcoder.block_stream);
                port.emit(.{ .lifecycle = .{
                    .phase = if (final_status >= 400) .request_failed else .response_finished,
                    .stream_id = transcoder.block_stream,
                    .status_code = final_status,
                } });
                transcoder.streams.finishResponse(transcoder.block_stream);
            },
        }
    }
    return true;
}

fn decodeHeaders(transcoder: *Transcoder) ?middleware.Headers {
    const inflater = transcoder.inflater orelse return null;
    var headers: middleware.Headers = .{};
    var input = transcoder.compressed[0..transcoder.compressed_len];
    while (true) {
        var field: source_namespace.c.nghttp2_nv = undefined;
        var flags: c_int = 0;
        const consumed = source_namespace.c.nghttp2_hd_inflate_hd2(
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
        if (flags & source_namespace.c.NGHTTP2_HD_INFLATE_EMIT != 0) {
            headers.append(.{
                .name = field.name[0..field.namelen],
                .value = field.value[0..field.valuelen],
                .sensitive = field.flags & source_namespace.c.NGHTTP2_NV_FLAG_NO_INDEX != 0,
            }) catch return null;
        }
        if (flags & source_namespace.c.NGHTTP2_HD_INFLATE_FINAL != 0) {
            if (source_namespace.c.nghttp2_hd_inflate_end_headers(inflater) != 0) {
                return null;
            }
            return headers;
        }
        if (consumed == 0 and flags & source_namespace.c.NGHTTP2_HD_INFLATE_EMIT == 0) {
            return null;
        }
    }
}

fn writeHeaderBlock(transcoder: *Transcoder, port: anytype, encoded_len: usize) bool {
    const advertised_frame_size = transcoder.configuration.target_settings.max_frame_size.load(.seq_cst);
    const max_frame_size: usize = if (advertised_frame_size >= 16 * 1024 and
        advertised_frame_size <= 0x00ff_ffff)
        advertised_frame_size
    else
        16 * 1024;
    if (transcoder.block_prefix_len >= max_frame_size) {
        return false;
    }
    var offset: usize = 0;
    var first = true;
    while (first or offset < encoded_len) {
        const prefix_len: usize = if (first) transcoder.block_prefix_len else 0;
        const fragment_len = @min(encoded_len - offset, max_frame_size - prefix_len);
        const final = offset + fragment_len == encoded_len;
        var header: [source_namespace.frame_header_len]u8 = undefined;
        const kind: u8 = if (first) transcoder.block_type else source_namespace.frame_continuation;
        var flags: u8 = if (first)
            transcoder.block_flags & ~(source_namespace.flag_padded | source_namespace.flag_end_headers)
        else
            0;
        if (final) {
            flags |= source_namespace.flag_end_headers;
        }
        source_namespace.writeFrameHeader(
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
        if (transcoder.setting_len != transcoder.setting.len) {
            continue;
        }
        const identifier = std.mem.readInt(u16, transcoder.setting[0..2], .big);
        const value = std.mem.readInt(u32, transcoder.setting[2..6], .big);
        switch (identifier) {
            source_namespace.c.NGHTTP2_SETTINGS_HEADER_TABLE_SIZE => settings.header_table_size.store(value, .seq_cst),
            source_namespace.c.NGHTTP2_SETTINGS_MAX_FRAME_SIZE => if (value >= 16 * 1024 and
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

    if (frame_type == source_namespace.frame_rst_stream and frame_stream != 0) {
        port.emit(.{ .lifecycle = .{
            .phase = .request_failed,
            .stream_id = frame_stream,
            .status_code = transcoder.streams.status(frame_stream),
        } });
        transcoder.streams.finishResponse(frame_stream);
        if (direction == .request) {
            transcoder.streams.finishRequest(frame_stream);
        }
    } else if (direction == .response and frame_type == source_namespace.frame_goaway and
        transcoder.streams.hasActiveResponses())
    {
        port.emit(.{ .lifecycle = .{
            .phase = .request_failed,
            .stream_id = 0,
            .status_code = 0,
        } });
    } else if (direction == .response and frame_type == source_namespace.frame_data and
        frame_stream != 0 and frame_flags & source_namespace.flag_end_stream != 0)
    {
        const status_code = transcoder.streams.status(frame_stream);
        port.emit(.{ .lifecycle = .{
            .phase = if (status_code >= 400) .request_failed else .response_finished,
            .stream_id = frame_stream,
            .status_code = status_code,
        } });
        transcoder.streams.finishResponse(frame_stream);
    }
    if (direction == .request and frame_type == source_namespace.frame_data and
        frame_stream != 0 and frame_flags & source_namespace.flag_end_stream != 0)
    {
        port.emit(.{ .request_finished = .{ .stream_id = frame_stream } });
        transcoder.streams.finishRequest(frame_stream);
    }
}

fn dataBodyFragment(transcoder: *Transcoder, payload: []const u8) ?[]const u8 {
    const prefix: usize = @intFromBool(transcoder.framing.flags & source_namespace.flag_padded != 0);

    if (prefix != 0 and transcoder.framing.payload_offset == 0) {
        if (payload.len == 0) {
            return "";
        }

        transcoder.frame_padding = payload[0];
    }

    if (transcoder.frame_padding > transcoder.framing.payload_len -| prefix) {
        return null;
    }

    const body_end = transcoder.framing.payload_len - transcoder.frame_padding;
    const input_start = transcoder.framing.payload_offset;
    const input_end = input_start + payload.len;
    const fragment_start = @max(input_start, prefix);
    const fragment_end = @min(input_end, body_end);

    if (fragment_start >= fragment_end) {
        return "";
    }

    return payload[fragment_start - input_start .. fragment_end - input_start];
}

fn headerPayloadPrefixLength(transcoder: *const Transcoder) usize {
    if (transcoder.framing.frame_type == source_namespace.frame_continuation) {
        return 0;
    }
    return @as(usize, transcoder.block_prefix_len) +
        @intFromBool(transcoder.block_flags & source_namespace.flag_padded != 0);
}

fn hasObservableSseBody(transcoder: *const Transcoder, stream_id: u32) bool {
    return transcoder.streams.hasObservableSseBody(stream_id);
}
