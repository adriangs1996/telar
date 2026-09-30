//! Native fuzzing of the HTTP/2 header observer.
//!
//! This root imports `httprelay` as a module and runs only through
//! `zig build test-fuzz-http2`, so the ordinary suites and the coverage build
//! never compile a `std.testing.fuzz` call (see `handshake_fuzz_test.zig`).
//! The observer is private to the module, so every run reaches it through
//! `http2.relay` over a session that lives in memory: the relay makes the
//! header memory from `gpa` with `header_memory.of`, starts one observer,
//! feeds it what the session reads and always deinits it.
//!
//! A run generates a small wire from frame operations: header blocks encoded
//! with HPACK literals and indexes against a model of the dynamic table,
//! PUSH_PROMISE, DATA, RST_STREAM, GOAWAY, SETTINGS, raw HPACK blocks and raw
//! bytes, optionally broken in one named way. It relays the wire whole, a
//! byte at a time and in a generated partition, and once more with one
//! allocation failing.

const std = @import("std");
const httprelay = @import("httprelay");
const http2 = httprelay.http2;
const RouteMatch = httprelay.RouteMatch;

const frame_header_bytes = 9;

const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    continuation = 0x9,
};

const flag_end_stream: u8 = 0x1;
const flag_end_headers: u8 = 0x4;
const flag_padded: u8 = 0x8;
const flag_priority: u8 = 0x20;

/// Bytes after the pad length that a PRIORITY flag and a promised stream id
/// put before a header block fragment.
const priority_bytes = 5;
const promised_stream_bytes = 4;
const rst_stream_bytes = 4;
const goaway_bytes = 8;
const ping_bytes = 8;

/// RFC 7541 section 6 representation patterns, before their integer prefix.
const indexed_pattern: u8 = 0x80;
const incremental_pattern: u8 = 0x40;
const size_update_pattern: u8 = 0x20;
const never_indexed_pattern: u8 = 0x10;
const plain_pattern: u8 = 0x00;

/// Integer prefix widths that follow each pattern.
const indexed_prefix_bits: u3 = 7;
const incremental_prefix_bits: u3 = 6;
const size_update_prefix_bits: u3 = 5;
const plain_prefix_bits: u3 = 4;
const string_prefix_bits: u3 = 7;

/// RFC 7541 section 5.1: each integer continuation byte carries seven bits
/// under this flag.
const integer_continuation: u8 = 0x80;
const integer_continuation_bits = 7;

/// A PRIORITY prefix: no exclusive bit, stream dependency zero, weight 16.
const priority_prefix = [priority_bytes]u8{ 0, 0, 0, 0, 15 };

/// RFC 7541 section 4.1: an entry costs its name, its value and 32 bytes.
const hpack_entry_overhead = 32;

/// RFC 7541 section 6.5.2 default, which the inflater keeps until a block
/// updates it.
const hpack_default_table_bytes = 4096;

const max_table_entries = hpack_default_table_bytes / hpack_entry_overhead;

/// Operations a run generates at most, and the bounds of each.
const max_frame_ops = 12;
const max_block_fields = 6;
const max_value_bytes = 24;
const max_body_bytes = 48;
const max_raw_bytes = 48;
const max_fragments = 4;
const max_padding = 8;

/// The largest allocation index one fuzz run makes fail; zero leaves every
/// allocation alone.
const max_fail_index = 96;

const max_partition_chunks = 8;
const max_chunk_bytes = 64;

/// Room the sink keeps for normalized observations and their bytes; beyond
/// it the trace records that it overflowed and stops.
const max_observations = 256;
const max_observed_bytes = 8 * 1024;

/// A dynamic table size update, then per field: a representation byte, a
/// name index or length of two bytes, the name, a value length byte and the
/// value.
const max_field_bytes = 2 + 1 + longestName() + 1 + max_value_bytes;
const max_block_bytes = 3 + max_block_fields * max_field_bytes;

const max_op_bytes: usize = max_fragments * frame_header_bytes + 1 + priority_bytes + promised_stream_bytes + max_padding +
    @max(max_block_bytes, max_raw_bytes, max_body_bytes) + frame_header_bytes + ping_bytes;

const max_wire_bytes = http2.client_preface.len + max_frame_ops * max_op_bytes;

/// Every field keeps at most one value, fuzzed or from a table.
const max_generated_text = max_frame_ops * max_block_fields * max_value_bytes;

const max_expected_fields = max_frame_ops * max_block_fields;

/// Requests the observer flags as watched, shaped like inference routes.
const watched_routes = [_]RouteMatch{
    .{
        .method = "POST",
        .paths = &.{"/v1/messages"},
    },
};

const client_streams = [_]u31{ 1, 3, 5, 7 };
const promised_streams = [_]u31{ 2, 4, 6, 8 };
const table_sizes = [_]u16{ 0, 64, 256, hpack_default_table_bytes };

/// RFC 7541 Appendix A entries a block may name by index.
const StaticField = struct {
    index: u8,
    name: []const u8,
    value: []const u8,
};

const static_fields = [_]StaticField{
    .{
        .index = 2,
        .name = ":method",
        .value = "GET",
    },
    .{
        .index = 3,
        .name = ":method",
        .value = "POST",
    },
    .{
        .index = 4,
        .name = ":path",
        .value = "/",
    },
    .{
        .index = 5,
        .name = ":path",
        .value = "/index.html",
    },
    .{
        .index = 7,
        .name = ":scheme",
        .value = "https",
    },
    .{
        .index = 8,
        .name = ":status",
        .value = "200",
    },
    .{
        .index = 13,
        .name = ":status",
        .value = "404",
    },
    .{
        .index = 14,
        .name = ":status",
        .value = "500",
    },
    .{
        .index = 16,
        .name = "accept-encoding",
        .value = "gzip, deflate",
    },
};

const static_names = [_]StaticField{
    .{
        .index = 1,
        .name = ":authority",
        .value = "",
    },
    .{
        .index = 2,
        .name = ":method",
        .value = "",
    },
    .{
        .index = 4,
        .name = ":path",
        .value = "",
    },
    .{
        .index = 8,
        .name = ":status",
        .value = "",
    },
    .{
        .index = 26,
        .name = "content-encoding",
        .value = "",
    },
    .{
        .index = 31,
        .name = "content-type",
        .value = "",
    },
};

const literal_names = [_][]const u8{
    ":method",
    ":path",
    ":status",
    "content-type",
    "content-encoding",
    "x-telar-seed",
    "grpc-status",
};

/// Values a literal picks by index; one past the end reads fuzzed text.
const literal_values = [_][]const u8{
    "POST",
    "GET",
    "/v1/messages",
    "/v1/messages?beta=true",
    "200",
    "429",
    "text/event-stream",
    "gzip",
    "identity",
    "",
};

const printable = [_]std.testing.Smith.Weight{.rangeAtMost(u8, 0x20, 0x7e, 1)};

const FrameOp = enum(u8) {
    headers,
    push_promise,
    data,
    rst_stream,
    goaway,
    settings,
    raw_block,
    raw,
};

const Representation = enum(u8) {
    indexed_static,
    indexed_dynamic,
    incremental_new_name,
    incremental_static_name,
    plain_new_name,
    plain_static_name,
    never_indexed_new_name,
};

/// One way a header block operation breaks the protocol on purpose.
const Breakage = enum(u8) {
    none,
    stream_zero,
    padding_overflow,
    interleaved_frame,
    wrong_continuation_stream,
    missing_end_headers,
    corrupt_block,
    truncated_block,
};

/// Bytes of `SyntheticStream.text`.
const TextSpan = struct {
    start: usize,
    len: usize,
};

const TableField = struct {
    name: []const u8,
    value: TextSpan,
};

/// The inflater's dynamic table as RFC 7541 section 4 evicts it, oldest
/// first.
const DynamicTable = struct {
    fields: [max_table_entries]TableField = undefined,
    len: usize = 0,
    bytes: usize = 0,
    capacity: usize = hpack_default_table_bytes,

    fn insert(self: *DynamicTable, field: TableField) void {
        const size = field.name.len + field.value.len + hpack_entry_overhead;
        if (size > self.capacity) {
            self.len = 0;
            self.bytes = 0;
            return;
        }

        while (self.bytes + size > self.capacity) {
            self.evictOldest();
        }

        self.fields[self.len] = field;
        self.len += 1;
        self.bytes += size;
    }

    fn resize(self: *DynamicTable, capacity: usize) void {
        self.capacity = capacity;
        while (self.bytes > capacity) {
            self.evictOldest();
        }
    }

    /// Field `offset` places from the newest, which HPACK names 62 + offset.
    fn newest(self: *const DynamicTable, offset: usize) TableField {
        return self.fields[self.len - 1 - offset];
    }

    fn evictOldest(self: *DynamicTable) void {
        const oldest = self.fields[0];
        self.bytes -= oldest.name.len + oldest.value.len + hpack_entry_overhead;
        std.mem.copyForwards(TableField, self.fields[0 .. self.len - 1], self.fields[1..self.len]);
        self.len -= 1;
    }
};

const ExpectedField = struct {
    stream_id: u32,
    name: []const u8,
    value: TextSpan,
};

/// A generated wire and what it promises. `valid` wires must relay without
/// a decode failure and emit exactly `expected`; `opaque` wires carry bytes
/// the model does not follow.
const SyntheticStream = struct {
    direction: http2.Direction,
    wire: std.ArrayList(u8),
    wire_buffer: [max_wire_bytes]u8 = undefined,
    text: [max_generated_text]u8 = undefined,
    text_len: usize = 0,
    table: DynamicTable = .{},
    expected: [max_expected_fields]ExpectedField = undefined,
    expected_len: usize = 0,
    valid: bool = true,
    is_opaque: bool = false,
    expects_failure: bool = false,

    fn textOf(self: *const SyntheticStream, span: TextSpan) []const u8 {
        return self.text[span.start..][0..span.len];
    }

    fn addText(self: *SyntheticStream, bytes: []const u8) TextSpan {
        @memcpy(self.text[self.text_len..][0..bytes.len], bytes);
        const span: TextSpan = .{
            .start = self.text_len,
            .len = bytes.len,
        };
        self.text_len += bytes.len;
        return span;
    }

    /// The wire breaks the protocol in a way the observer must fail on.
    fn breaks(self: *SyntheticStream) void {
        self.valid = false;
        self.expects_failure = true;
    }

    /// The wire now holds bytes the model does not follow.
    fn loses(self: *SyntheticStream) void {
        self.valid = false;
        self.is_opaque = true;
    }
};

/// Starts `synthetic` in place: its wire points into its own buffer, so it
/// must not move afterwards.
fn startSynthetic(synthetic: *SyntheticStream, direction: http2.Direction) void {
    synthetic.* = .{
        .direction = direction,
        .wire = .empty,
    };
    synthetic.wire = .initBuffer(&synthetic.wire_buffer);
    if (direction == .request) {
        synthetic.wire.appendSliceAssumeCapacity(http2.client_preface);
    }
}

fn appendFrameHeader(wire: *std.ArrayList(u8), length: usize, frame_type: FrameType, flags: u8, stream_id: u31) void {
    var header: [frame_header_bytes]u8 = undefined;
    std.mem.writeInt(u24, header[0..3], @intCast(length), .big);
    header[3] = @intFromEnum(frame_type);
    header[4] = flags;
    std.mem.writeInt(u32, header[5..9], stream_id, .big);
    wire.appendSliceAssumeCapacity(&header);
}

/// RFC 7541 section 5.1 integer with a `prefix_bits` prefix after `pattern`.
fn appendInteger(block: *std.ArrayList(u8), pattern: u8, prefix_bits: u3, integer: usize) void {
    const limit = (@as(usize, 1) << prefix_bits) - 1;
    if (integer < limit) {
        block.appendAssumeCapacity(pattern | @as(u8, @intCast(integer)));
        return;
    }

    block.appendAssumeCapacity(pattern | @as(u8, @intCast(limit)));
    var rest = integer - limit;
    while (rest >= integer_continuation) : (rest >>= integer_continuation_bits) {
        block.appendAssumeCapacity(@as(u8, @intCast(rest & ~integer_continuation)) | integer_continuation);
    }

    block.appendAssumeCapacity(@intCast(rest));
}

/// RFC 7541 section 5.2 string without Huffman coding.
fn appendString(block: *std.ArrayList(u8), bytes: []const u8) void {
    appendInteger(block, plain_pattern, string_prefix_bits, bytes.len);
    block.appendSliceAssumeCapacity(bytes);
}

/// Reads one field, encodes it into `block`, updates the table model and
/// records it when the block's fields are emitted.
fn generateField(synthetic: *SyntheticStream, smith: *std.testing.Smith, block: *std.ArrayList(u8), stream_id: u31, emitted: bool) void {
    const representation = smith.value(Representation);
    const name_choice = smith.valueRangeAtMost(u8, 0, std.math.maxInt(u8));
    const value_choice = smith.valueRangeAtMost(u8, 0, literal_values.len);
    var fuzzed: [max_value_bytes]u8 = undefined;
    const value_bytes = if (value_choice < literal_values.len)
        literal_values[value_choice]
    else
        fuzzed[0..smith.sliceWeightedBytes(&fuzzed, &printable)];

    const field: TableField = switch (representation) {
        .indexed_dynamic => if (synthetic.table.len == 0)
            indexedStatic(block, name_choice, synthetic)
        else dynamic: {
            const offset = name_choice % synthetic.table.len;
            appendInteger(block, indexed_pattern, indexed_prefix_bits, static_table_len + 1 + offset);
            break :dynamic synthetic.table.newest(offset);
        },
        .indexed_static => indexedStatic(block, name_choice, synthetic),
        .incremental_new_name, .plain_new_name, .never_indexed_new_name => literal: {
            const name = literal_names[name_choice % literal_names.len];
            block.appendAssumeCapacity(switch (representation) {
                .incremental_new_name => incremental_pattern,
                .plain_new_name => plain_pattern,
                else => never_indexed_pattern,
            });
            appendString(block, name);
            appendString(block, value_bytes);
            break :literal .{
                .name = name,
                .value = synthetic.addText(value_bytes),
            };
        },
        .incremental_static_name, .plain_static_name => literal: {
            const indexed = static_names[name_choice % static_names.len];
            if (representation == .incremental_static_name) {
                appendInteger(block, incremental_pattern, incremental_prefix_bits, indexed.index);
            } else {
                appendInteger(block, plain_pattern, plain_prefix_bits, indexed.index);
            }

            appendString(block, value_bytes);
            break :literal .{
                .name = indexed.name,
                .value = synthetic.addText(value_bytes),
            };
        },
    };

    if (representation == .incremental_new_name or representation == .incremental_static_name) {
        synthetic.table.insert(field);
    }

    if (emitted) {
        synthetic.expected[synthetic.expected_len] = .{
            .stream_id = stream_id,
            .name = field.name,
            .value = field.value,
        };
        synthetic.expected_len += 1;
    }
}

/// Drops the block's last byte. When that byte is a whole one-byte field the
/// block stays valid without it; a field or table size update cut short must
/// fail the observer. A lone one-byte size update would vanish after the
/// model applied it, so the model stops following that wire.
fn truncateBlock(synthetic: *SyntheticStream, block: *std.ArrayList(u8), last_field_start: ?usize, emitted: bool) void {
    if (block.items.len == 0) {
        return;
    }

    block.items.len -= 1;
    const start = last_field_start orelse {
        if (block.items.len == 0) {
            synthetic.loses();
        } else {
            synthetic.breaks();
        }

        return;
    };

    if (start != block.items.len) {
        return synthetic.breaks();
    }

    if (emitted) {
        synthetic.expected_len -= 1;
    }
}

/// RFC 7541 Appendix A has 61 entries; dynamic indexes start after it.
const static_table_len = 61;

fn indexedStatic(block: *std.ArrayList(u8), choice: u8, synthetic: *SyntheticStream) TableField {
    const indexed = static_fields[choice % static_fields.len];
    appendInteger(block, indexed_pattern, indexed_prefix_bits, indexed.index);
    return .{
        .name = indexed.name,
        .value = synthetic.addText(indexed.value),
    };
}

/// A HEADERS or PUSH_PROMISE block split over CONTINUATION frames, with
/// optional padding, priority, table size update and one breakage.
fn generateHeaderBlock(synthetic: *SyntheticStream, smith: *std.testing.Smith, kind: FrameType) void {
    var stream_id = client_streams[smith.valueRangeAtMost(u8, 0, client_streams.len - 1)];
    const end_stream = smith.value(bool) and kind == .headers;
    const padding = smith.valueRangeAtMost(u8, 0, max_padding + 1);
    const priority = smith.value(bool) and kind == .headers;
    var fragments: usize = smith.valueRangeAtMost(u8, 1, max_fragments);
    const table_choice = smith.valueRangeAtMost(u8, 0, table_sizes.len);
    const promised = promised_streams[smith.valueRangeAtMost(u8, 0, promised_streams.len - 1)];
    const field_count = smith.valueRangeAtMost(u8, 0, max_block_fields);

    var block_buffer: [max_block_bytes]u8 = undefined;
    var block: std.ArrayList(u8) = .initBuffer(&block_buffer);
    if (table_choice != 0) {
        appendInteger(&block, size_update_pattern, size_update_prefix_bits, table_sizes[table_choice - 1]);
        synthetic.table.resize(table_sizes[table_choice - 1]);
    }

    var last_field_start: ?usize = null;
    for (0..field_count) |_| {
        last_field_start = block.items.len;
        generateField(synthetic, smith, &block, stream_id, kind == .headers);
    }

    const breakage = smith.value(Breakage);
    switch (breakage) {
        .none => {},
        .stream_zero => {
            stream_id = 0;
            synthetic.breaks();
        },
        .interleaved_frame, .wrong_continuation_stream => {
            fragments = @max(fragments, 2);
            synthetic.breaks();
        },
        .missing_end_headers => synthetic.breaks(),
        .corrupt_block => {
            if (block.items.len == 0) {
                block.appendAssumeCapacity(indexed_pattern);
            }

            // Index zero is not a table entry (RFC 7541 section 6.1).
            block.items[0] = indexed_pattern;
            synthetic.breaks();
        },
        .truncated_block => truncateBlock(synthetic, &block, last_field_start, kind == .headers),
        .padding_overflow => {},
    }

    appendBlockFrames(synthetic, .{
        .kind = kind,
        .stream_id = stream_id,
        .end_stream = end_stream,
        .padding = padding,
        .priority = priority,
        .fragments = fragments,
        .promised = promised,
        .breakage = breakage,
    }, block.items);
}

const BlockFraming = struct {
    kind: FrameType,
    stream_id: u31,
    end_stream: bool,
    /// Zero leaves the frame unpadded; `n` pads it with `n - 1` bytes.
    padding: u8,
    priority: bool,
    fragments: usize,
    promised: u31,
    breakage: Breakage,
};

fn appendBlockFrames(synthetic: *SyntheticStream, framing: BlockFraming, block: []const u8) void {
    const wire = &synthetic.wire;
    const padded = framing.padding != 0 or framing.breakage == .padding_overflow;
    const pad_len: usize = if (framing.padding == 0) 0 else framing.padding - 1;
    const priority_len: usize = if (framing.priority) priority_bytes else 0;
    const promised_len: usize = if (framing.kind == .push_promise) promised_stream_bytes else 0;
    const prefix = @as(usize, @intFromBool(padded)) + priority_len + promised_len;
    const first_end = block.len / framing.fragments;
    const last_ends_headers = framing.breakage != .missing_end_headers;
    var flags: u8 = 0;

    if (framing.end_stream) {
        flags |= flag_end_stream;
    }

    if (padded) {
        flags |= flag_padded;
    }

    if (framing.priority) {
        flags |= flag_priority;
    }

    if (framing.fragments == 1 and last_ends_headers) {
        flags |= flag_end_headers;
    }

    const length = prefix + first_end + pad_len;
    appendFrameHeader(wire, length, framing.kind, flags, framing.stream_id);
    if (padded) {
        const pad_byte: u8 = if (framing.breakage == .padding_overflow) std.math.maxInt(u8) else @intCast(pad_len);
        wire.appendAssumeCapacity(pad_byte);
        // Padding that fits cuts the block at a place the model cannot
        // follow, which may still decode.
        if (framing.breakage == .padding_overflow and pad_byte > length - prefix) {
            synthetic.breaks();
        } else if (framing.breakage == .padding_overflow) {
            synthetic.loses();
        }
    }

    if (framing.priority) {
        wire.appendSliceAssumeCapacity(&priority_prefix);
    }

    if (framing.kind == .push_promise) {
        var promised: [promised_stream_bytes]u8 = undefined;
        std.mem.writeInt(u32, &promised, framing.promised, .big);
        wire.appendSliceAssumeCapacity(&promised);
    }

    wire.appendSliceAssumeCapacity(block[0..first_end]);
    wire.appendNTimesAssumeCapacity(0, pad_len);

    if (framing.breakage == .interleaved_frame) {
        appendFrameHeader(wire, ping_bytes, .ping, 0, 0);
        wire.appendNTimesAssumeCapacity(0, ping_bytes);
    }

    const continuation_stream = if (framing.breakage == .wrong_continuation_stream) framing.stream_id + 2 else framing.stream_id;
    for (1..framing.fragments) |fragment| {
        const start = block.len * fragment / framing.fragments;
        const end = block.len * (fragment + 1) / framing.fragments;
        const last = fragment == framing.fragments - 1;
        appendFrameHeader(wire, end - start, .continuation, if (last and last_ends_headers) flag_end_headers else 0, continuation_stream);
        wire.appendSliceAssumeCapacity(block[start..end]);
    }
}

fn generateData(synthetic: *SyntheticStream, smith: *std.testing.Smith) void {
    const stream_id = client_streams[smith.valueRangeAtMost(u8, 0, client_streams.len - 1)];
    const end_stream = smith.value(bool);
    const padding = smith.valueRangeAtMost(u8, 0, max_padding + 1);
    var body_buffer: [max_body_bytes]u8 = undefined;
    const body = body_buffer[0..smith.slice(&body_buffer)];
    const pad_len: usize = if (padding == 0) 0 else padding - 1;
    var flags: u8 = if (end_stream) flag_end_stream else 0;

    if (padding != 0) {
        flags |= flag_padded;
    }

    appendFrameHeader(&synthetic.wire, @as(usize, @intFromBool(padding != 0)) + body.len + pad_len, .data, flags, stream_id);
    if (padding != 0) {
        synthetic.wire.appendAssumeCapacity(@intCast(pad_len));
    }

    synthetic.wire.appendSliceAssumeCapacity(body);
    synthetic.wire.appendNTimesAssumeCapacity(0, pad_len);
}

/// Reads frame operations until the input ends or `max_frame_ops`.
fn generateFrames(synthetic: *SyntheticStream, smith: *std.testing.Smith) void {
    var ops: usize = 0;

    while (ops < max_frame_ops and !smith.eosWeightedSimple(3, 1)) : (ops += 1) {
        switch (smith.value(FrameOp)) {
            .headers => generateHeaderBlock(synthetic, smith, .headers),
            .push_promise => generateHeaderBlock(synthetic, smith, .push_promise),
            .data => generateData(synthetic, smith),
            .rst_stream => {
                const stream_id = client_streams[smith.valueRangeAtMost(u8, 0, client_streams.len - 1)];
                appendFrameHeader(&synthetic.wire, rst_stream_bytes, .rst_stream, 0, stream_id);
                synthetic.wire.appendNTimesAssumeCapacity(0, rst_stream_bytes);
            },
            .goaway => {
                appendFrameHeader(&synthetic.wire, goaway_bytes, .goaway, 0, 0);
                synthetic.wire.appendNTimesAssumeCapacity(0, goaway_bytes);
            },
            .settings => appendFrameHeader(&synthetic.wire, 0, .settings, 0, 0),
            .raw_block => {
                const stream_id = client_streams[smith.valueRangeAtMost(u8, 0, client_streams.len - 1)];
                var raw: [max_raw_bytes]u8 = undefined;
                const block = raw[0..smith.slice(&raw)];
                appendFrameHeader(&synthetic.wire, block.len, .headers, flag_end_headers, stream_id);
                synthetic.wire.appendSliceAssumeCapacity(block);
                synthetic.loses();
            },
            .raw => {
                var raw: [max_raw_bytes]u8 = undefined;
                synthetic.wire.appendSliceAssumeCapacity(raw[0..smith.slice(&raw)]);
                synthetic.loses();
            },
        }
    }
}

const ObservationKind = enum {
    lifecycle,
    request_headers,
    request_body,
    request_finished,
    response_headers,
    response_body,
};

/// One event after normalization. Fields an event kind lacks stay zero.
const Observation = struct {
    kind: ObservationKind,
    stage: http2.Lifecycle.Stage = .request_started,
    stream_id: u32,
    status_code: u16 = 0,
    watched: bool = false,
    sse_body: bool = false,
    name_len: usize = 0,
    text: TextSpan = .{
        .start = 0,
        .len = 0,
    },
};

/// A sink that copies what the observer emits, bounded by
/// `max_observations` and `max_observed_bytes`. Chunking may split one
/// DATA frame into several body fragments and activity events, so it joins
/// consecutive body fragments of one stream and drops an activity event
/// that continues the same stream's body.
const ObservationTrace = struct {
    observations: [max_observations]Observation = undefined,
    count: usize = 0,
    text: [max_observed_bytes]u8 = undefined,
    text_len: usize = 0,
    overflowed: bool = false,

    pub fn emit(self: *ObservationTrace, event: http2.Event) void {
        if (self.overflowed) {
            return;
        }

        switch (event) {
            .lifecycle => |lifecycle| {
                if (lifecycle.stage == .response_activity and self.continuesBody(lifecycle.stream_id, lifecycle.status_code)) {
                    return;
                }

                self.push(.{
                    .kind = .lifecycle,
                    .stage = lifecycle.stage,
                    .stream_id = lifecycle.stream_id,
                    .status_code = lifecycle.status_code,
                    .watched = lifecycle.watched,
                }, "");
            },
            .request_headers => |block| self.pushFields(.request_headers, block.stream_id, block.fields),
            .response_headers => |block| self.pushFields(.response_headers, block.stream_id, block.fields),
            .request_body => |body| self.pushBody(.{
                .kind = .request_body,
                .stream_id = body.stream_id,
            }, body.bytes),
            .response_body => |body| self.pushBody(.{
                .kind = .response_body,
                .stream_id = body.stream_id,
                .status_code = body.status_code,
                .sse_body = body.sse_body,
            }, body.bytes),
            .request_finished => |finished| self.push(.{
                .kind = .request_finished,
                .stream_id = finished.stream_id,
            }, ""),
        }
    }

    fn textOf(self: *const ObservationTrace, span: TextSpan) []const u8 {
        return self.text[span.start..][0..span.len];
    }

    fn last(self: *ObservationTrace) ?*Observation {
        if (self.count == 0) {
            return null;
        }

        return &self.observations[self.count - 1];
    }

    fn continuesBody(self: *ObservationTrace, stream_id: u32, status_code: u16) bool {
        const previous = self.last() orelse return false;
        const same_body = previous.kind == .response_body or (previous.kind == .lifecycle and previous.stage == .response_activity);
        return same_body and previous.stream_id == stream_id and previous.status_code == status_code;
    }

    fn pushFields(self: *ObservationTrace, kind: ObservationKind, stream_id: u32, fields: anytype) void {
        for (fields) |field| {
            const start = self.text_len;
            if (!self.appendText(field.name) or !self.appendText(field.value)) {
                return;
            }

            self.push(.{
                .kind = kind,
                .stream_id = stream_id,
                .name_len = field.name.len,
                .text = .{
                    .start = start,
                    .len = self.text_len - start,
                },
            }, "");
        }
    }

    fn pushBody(self: *ObservationTrace, body: Observation, bytes: []const u8) void {
        if (self.last()) |previous| {
            if (previous.kind == body.kind and previous.stream_id == body.stream_id and
                previous.status_code == body.status_code and previous.sse_body == body.sse_body)
            {
                const before = self.text_len;
                _ = self.appendText(bytes);
                previous.text.len += self.text_len - before;
                return;
            }
        }

        self.push(body, bytes);
    }

    fn push(self: *ObservationTrace, observation: Observation, bytes: []const u8) void {
        if (self.count == max_observations) {
            self.overflowed = true;
            return;
        }

        var recorded = observation;
        if (bytes.len != 0) {
            const start = self.text_len;
            _ = self.appendText(bytes);
            recorded.text = .{
                .start = start,
                .len = self.text_len - start,
            };
        }

        self.observations[self.count] = recorded;
        self.count += 1;
    }

    /// Copies what fits; a cut is the same for every chunking because the
    /// joined text is.
    fn appendText(self: *ObservationTrace, bytes: []const u8) bool {
        const room = self.text.len - self.text_len;
        const copied = @min(room, bytes.len);
        @memcpy(self.text[self.text_len..][0..copied], bytes[0..copied]);
        self.text_len += copied;
        if (copied != bytes.len) {
            self.overflowed = true;
        }

        return copied == bytes.len;
    }
};

/// Chunk lengths the session reads with; none reads the whole rest.
const Partition = struct {
    lengths: [max_partition_chunks]usize = undefined,
    len: usize = 0,

    fn next(self: Partition, chunk_index: usize, remaining: usize) usize {
        if (self.len == 0) {
            return remaining;
        }

        return @min(remaining, self.lengths[chunk_index % self.len]);
    }
};

/// Both relay sides in memory: reads walk the wire in `partition`'s chunks
/// and writes collect what the relay forwards.
const ChunkedSession = struct {
    wire: []const u8,
    partition: Partition,
    offset: usize = 0,
    chunk_index: usize = 0,
    forwarded: [max_wire_bytes]u8 = undefined,
    forwarded_len: usize = 0,
    half_closed: bool = false,

    pub fn read(self: *ChunkedSession, _: anytype, buffer: []u8) ?usize {
        if (self.offset == self.wire.len) {
            return null;
        }

        const len = @min(buffer.len, self.partition.next(self.chunk_index, self.wire.len - self.offset));
        @memcpy(buffer[0..len], self.wire[self.offset..][0..len]);
        self.offset += len;
        self.chunk_index += 1;
        return len;
    }

    pub fn writeAll(self: *ChunkedSession, _: anytype, bytes: []const u8) bool {
        if (bytes.len > self.forwarded.len - self.forwarded_len) {
            return false;
        }

        @memcpy(self.forwarded[self.forwarded_len..][0..bytes.len], bytes);
        self.forwarded_len += bytes.len;
        return true;
    }

    pub fn halfClose(self: *ChunkedSession, _: anytype) void {
        self.half_closed = true;
    }
};

/// Relays `wire` once with the header memory on `allocator`; the relay
/// forwards every byte unchanged whatever the observer decides.
fn relayWire(allocator: std.mem.Allocator, synthetic: *const SyntheticStream, partition: Partition, trace: *ObservationTrace) !http2.Stats {
    var session: ChunkedSession = .{
        .wire = synthetic.wire.items,
        .partition = partition,
    };
    const stats = http2.relay(&session, http2.relayOptions(synthetic.direction, .{
        .gpa = allocator,
        .watched_routes = &watched_routes,
    }), trace);

    try std.testing.expectEqualSlices(u8, synthetic.wire.items, session.forwarded[0..session.forwarded_len]);
    try std.testing.expect(session.half_closed);
    return stats;
}

fn expectSameTrace(expected: *const ObservationTrace, actual: *const ObservationTrace) !void {
    try std.testing.expectEqual(expected.overflowed, actual.overflowed);
    try std.testing.expectEqual(expected.count, actual.count);

    for (expected.observations[0..expected.count], actual.observations[0..actual.count]) |wanted, seen| {
        try std.testing.expectEqual(wanted.kind, seen.kind);
        try std.testing.expectEqual(wanted.stage, seen.stage);
        try std.testing.expectEqual(wanted.stream_id, seen.stream_id);
        try std.testing.expectEqual(wanted.status_code, seen.status_code);
        try std.testing.expectEqual(wanted.watched, seen.watched);
        try std.testing.expectEqual(wanted.sse_body, seen.sse_body);
        try std.testing.expectEqual(wanted.name_len, seen.name_len);
        try std.testing.expectEqualSlices(u8, expected.textOf(wanted.text), actual.textOf(seen.text));
    }
}

fn isHeaderObservation(observation: Observation) bool {
    return observation.kind == .request_headers or observation.kind == .response_headers;
}

/// Decoded fields of `actual`, in order, must start `expected`'s: a failure
/// may stop decoding, never change what was already decoded.
fn expectHeaderPrefix(expected: *const ObservationTrace, actual: *const ObservationTrace) !void {
    var wanted_index: usize = 0;

    for (actual.observations[0..actual.count]) |seen| {
        if (!isHeaderObservation(seen)) {
            continue;
        }

        while (wanted_index < expected.count and !isHeaderObservation(expected.observations[wanted_index])) {
            wanted_index += 1;
        }

        if (wanted_index == expected.count) {
            return error.ExtraHeaderField;
        }

        const wanted = expected.observations[wanted_index];
        try std.testing.expectEqual(wanted.kind, seen.kind);
        try std.testing.expectEqual(wanted.stream_id, seen.stream_id);
        try std.testing.expectEqual(wanted.name_len, seen.name_len);
        try std.testing.expectEqualSlices(u8, expected.textOf(wanted.text), actual.textOf(seen.text));
        wanted_index += 1;
    }
}

/// The observed header fields against the generated ones: all of them for
/// a valid wire, a prefix when a breakage may stop decoding.
fn expectGeneratedFields(synthetic: *const SyntheticStream, trace: *const ObservationTrace) !void {
    var generated_index: usize = 0;
    const kind: ObservationKind = switch (synthetic.direction) {
        .request => .request_headers,
        .response => .response_headers,
    };

    for (trace.observations[0..trace.count]) |seen| {
        if (!isHeaderObservation(seen)) {
            continue;
        }

        if (generated_index == synthetic.expected_len) {
            return error.ExtraHeaderField;
        }

        const generated = synthetic.expected[generated_index];
        const text = trace.textOf(seen.text);
        try std.testing.expectEqual(kind, seen.kind);
        try std.testing.expectEqual(generated.stream_id, seen.stream_id);
        try std.testing.expectEqualStrings(generated.name, text[0..seen.name_len]);
        try std.testing.expectEqualStrings(synthetic.textOf(generated.value), text[seen.name_len..]);
        generated_index += 1;
    }

    if (synthetic.valid) {
        try std.testing.expectEqual(synthetic.expected_len, generated_index);
    }
}

/// Every property of one generated wire: the same normalized trace and
/// outcome for whole, bytewise and partitioned reads, the generated fields,
/// the promised failure, and one allocation failure that must fail the
/// observer, keep decoded fields a prefix and free everything.
fn expectObservation(synthetic: *const SyntheticStream, partition: Partition, fail_index: u8) !void {
    var whole: ObservationTrace = .{};
    const whole_stats = try relayWire(std.testing.allocator, synthetic, .{}, &whole);

    var bytewise_partition: Partition = .{
        .len = 1,
    };
    bytewise_partition.lengths[0] = 1;
    var bytewise: ObservationTrace = .{};
    const bytewise_stats = try relayWire(std.testing.allocator, synthetic, bytewise_partition, &bytewise);
    try std.testing.expectEqual(whole_stats.decode_failed, bytewise_stats.decode_failed);
    try expectSameTrace(&whole, &bytewise);

    var partitioned: ObservationTrace = .{};
    const partitioned_stats = try relayWire(std.testing.allocator, synthetic, partition, &partitioned);
    try std.testing.expectEqual(whole_stats.decode_failed, partitioned_stats.decode_failed);
    try expectSameTrace(&whole, &partitioned);

    if (synthetic.valid) {
        try std.testing.expect(!whole_stats.decode_failed);
        try std.testing.expect(!whole.overflowed);
    }

    if (synthetic.expects_failure) {
        try std.testing.expect(whole_stats.decode_failed);
    }

    if (!synthetic.is_opaque) {
        try expectGeneratedFields(synthetic, &whole);
    }

    if (fail_index != 0) {
        try expectAllocationFailure(synthetic, &whole, whole_stats, fail_index - 1);
    }
}

fn expectAllocationFailure(synthetic: *const SyntheticStream, whole: *const ObservationTrace, whole_stats: http2.Stats, fail_index: usize) !void {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{
        .fail_index = fail_index,
    });
    var starved: ObservationTrace = .{};
    const stats = try relayWire(failing.allocator(), synthetic, .{}, &starved);

    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    try std.testing.expectEqual(failing.allocations, failing.deallocations);
    if (!failing.has_induced_failure) {
        try std.testing.expectEqual(whole_stats.decode_failed, stats.decode_failed);
        return expectSameTrace(whole, &starved);
    }

    try std.testing.expect(stats.decode_failed);
    try expectHeaderPrefix(whole, &starved);
}

/// A broken property panics instead of returning its error: Zig 0.16.0's
/// fuzzer saves the failing input only on an abort.
fn observeFuzzedWire(_: void, smith: *std.testing.Smith) anyerror!void {
    expectFuzzedObservation(smith) catch |err| std.debug.panic("Observer property failed: {t}", .{err});
}

/// Reads a direction, an allocation index to fail, a partition and the
/// frame operations, in that order.
fn expectFuzzedObservation(smith: *std.testing.Smith) anyerror!void {
    var synthetic: SyntheticStream = undefined;
    const direction = smith.value(http2.Direction);
    const fail_index = smith.valueRangeAtMost(u8, 0, max_fail_index);
    const partition = generatePartition(smith);

    startSynthetic(&synthetic, direction);
    generateFrames(&synthetic, smith);
    try expectObservation(&synthetic, partition, fail_index);
}

fn generatePartition(smith: *std.testing.Smith) Partition {
    var partition: Partition = .{};

    while (partition.len < max_partition_chunks and !smith.eosWeightedSimple(1, 1)) {
        partition.lengths[partition.len] = smith.valueRangeAtMost(u8, 1, max_chunk_bytes);
        partition.len += 1;
    }

    return partition;
}

fn longestName() usize {
    var longest: usize = 0;

    for (literal_names) |name| {
        longest = @max(longest, name.len);
    }

    return longest;
}

/// What a seed must show when relayed whole.
const SeedOutcome = enum {
    /// Valid: decoded fields, no failure.
    decodes,
    /// A breakage the observer must fail on.
    fails,
    /// Bytes the model does not follow.
    is_opaque,
};

const FieldSeed = struct {
    representation: Representation,
    name: u8 = 0,
    value: u8 = 0,
    custom: ?[]const u8 = null,
};

const BlockSeed = struct {
    stream: u8 = 0,
    end_stream: bool = false,
    padding: u8 = 0,
    priority: bool = false,
    fragments: u8 = 1,
    table_size: u8 = 0,
    promised: u8 = 0,
    fields: []const FieldSeed = &.{},
    breakage: Breakage = .none,
};

const ObservationSeed = struct {
    direction: http2.Direction,
    fail_index: u8 = 0,
    partition: []const u8 = &.{},
    ops: []const []const u8,
    outcome: SeedOutcome,
};

/// The seed's choices in `std.testing.Smith` input form: a little-endian u64
/// per value, one byte per end-of-sequence question (zero continues) and a
/// little-endian u32 length before slice bytes. A crash the fuzzer saves has
/// the same form, so it can join this corpus as it is.
fn smithInput(comptime seed: ObservationSeed) []const u8 {
    comptime {
        var bytes: []const u8 = number(@intFromEnum(seed.direction)) ++ number(seed.fail_index);
        for (seed.partition) |length| {
            bytes = bytes ++ proceed ++ number(length);
        }

        bytes = bytes ++ stop;
        for (seed.ops) |op| {
            bytes = bytes ++ proceed ++ op;
        }

        const entry = (bytes ++ stop)[0..].*;
        return &entry;
    }
}

const proceed: []const u8 = &.{0};
const stop: []const u8 = &.{1};

fn number(comptime value: u64) []const u8 {
    comptime {
        var bytes: [@sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        const encoded = bytes;
        return &encoded;
    }
}

fn sliceInput(comptime bytes: []const u8) []const u8 {
    comptime {
        var length: [@sizeOf(u32)]u8 = undefined;
        std.mem.writeInt(u32, &length, bytes.len, .little);
        const encoded = length ++ bytes[0..bytes.len].*;
        return &encoded;
    }
}

fn blockOp(comptime kind: FrameOp, comptime seed: BlockSeed) []const u8 {
    comptime {
        var bytes: []const u8 = number(@intFromEnum(kind)) ++ number(seed.stream) ++ number(@intFromBool(seed.end_stream)) ++
            number(seed.padding) ++ number(@intFromBool(seed.priority)) ++ number(seed.fragments) ++
            number(seed.table_size) ++ number(seed.promised) ++ number(seed.fields.len);
        for (seed.fields) |field| {
            bytes = bytes ++ number(@intFromEnum(field.representation)) ++ number(field.name);
            if (field.custom) |custom| {
                bytes = bytes ++ number(literal_values.len) ++ sliceInput(custom);
            } else {
                bytes = bytes ++ number(field.value);
            }
        }

        return bytes ++ number(@intFromEnum(seed.breakage));
    }
}

fn dataOp(comptime stream: u8, comptime end_stream: bool, comptime padding: u8, comptime body: []const u8) []const u8 {
    return comptime number(@intFromEnum(FrameOp.data)) ++ number(stream) ++ number(@intFromBool(end_stream)) ++
        number(padding) ++ sliceInput(body);
}

fn rawBlockOp(comptime stream: u8, comptime block: []const u8) []const u8 {
    return comptime number(@intFromEnum(FrameOp.raw_block)) ++ number(stream) ++ sliceInput(block);
}

const goaway_op = number(@intFromEnum(FrameOp.goaway));
const settings_op = number(@intFromEnum(FrameOp.settings));

fn rstStreamOp(comptime stream: u8) []const u8 {
    return comptime number(@intFromEnum(FrameOp.rst_stream)) ++ number(stream);
}

fn rawOp(comptime bytes: []const u8) []const u8 {
    return comptime number(@intFromEnum(FrameOp.raw)) ++ sliceInput(bytes);
}

/// Indexes into the tables above, named so seeds read as fields.
const post_method: FieldSeed = .{
    .representation = .indexed_static,
    .name = 1,
};
const messages_path: FieldSeed = .{
    .representation = .incremental_static_name,
    .name = 2,
    .value = 2,
};
const status_ok: FieldSeed = .{
    .representation = .indexed_static,
    .name = 5,
};
const event_stream_type: FieldSeed = .{
    .representation = .incremental_static_name,
    .name = 5,
    .value = 6,
};
const seed_marker: FieldSeed = .{
    .representation = .incremental_new_name,
    .name = 5,
    .custom = "agent-7",
};
const newest_entry: FieldSeed = .{
    .representation = .indexed_dynamic,
    .name = 0,
};

/// RFC 7541 C.4.1: a request block with Huffman-coded literals.
const huffman_request_block = "\x82\x86\x84\x41\x8c\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff";

/// The request block the relay tests decode.
const watched_request_block = "\x83\x04\x0c/v1/messages";

const watched_request = blockOp(.headers, .{
    .fields = &.{ post_method, messages_path },
});

const watched_request_seed: ObservationSeed = .{
    .direction = .request,
    .ops = &.{ watched_request, dataOp(0, true, 0, "{\"stream\":true}") },
    .outcome = .decodes,
};

const huffman_seed: ObservationSeed = .{
    .direction = .request,
    .ops = &.{rawBlockOp(0, huffman_request_block)},
    .outcome = .is_opaque,
};

const observation_seeds = [_]ObservationSeed{
    .{
        .direction = .request,
        .ops = &.{},
        .outcome = .decodes,
    },
    .{
        .direction = .response,
        .ops = &.{},
        .outcome = .decodes,
    },
    watched_request_seed,
    .{
        .direction = .request,
        .partition = &.{ 3, 17 },
        .ops = &.{
            blockOp(.headers, .{
                .end_stream = true,
                .fields = &.{ post_method, messages_path, seed_marker },
            }),
            blockOp(.headers, .{
                .stream = 1,
                .table_size = 3,
                .fields = &.{ newest_entry, post_method, newest_entry },
            }),
            blockOp(.headers, .{
                .stream = 2,
                .table_size = 1,
                .fields = &.{newest_entry},
            }),
        },
        .outcome = .decodes,
    },
    .{
        .direction = .response,
        .ops = &.{
            blockOp(.headers, .{
                .padding = 3,
                .priority = true,
                .fragments = 3,
                .fields = &.{ status_ok, event_stream_type, seed_marker },
            }),
            dataOp(0, false, 4, "event: message_delta\ndata: {}\n\n"),
            dataOp(0, true, 1, "data: [DONE]\n\n"),
        },
        .outcome = .decodes,
    },
    // The first frame holds only padding, which fills its payload exactly.
    .{
        .direction = .response,
        .ops = &.{
            blockOp(.headers, .{
                .end_stream = true,
                .padding = 4,
                .fragments = 2,
                .fields = &.{status_ok},
            }),
        },
        .outcome = .decodes,
    },
    .{
        .direction = .response,
        .fail_index = 3,
        .ops = &.{
            blockOp(.push_promise, .{
                .padding = 2,
                .fragments = 2,
                .fields = &.{ post_method, seed_marker },
            }),
            blockOp(.headers, .{
                .fields = &.{ status_ok, newest_entry },
            }),
            dataOp(0, false, 0, "partial"),
            rstStreamOp(0),
            blockOp(.headers, .{
                .stream = 1,
                .fields = &.{status_ok},
            }),
            goaway_op,
            settings_op,
        },
        .outcome = .decodes,
    },
    .{
        .direction = .request,
        .ops = &.{
            blockOp(.headers, .{
                .fields = &.{post_method},
                .breakage = .stream_zero,
            }),
        },
        .outcome = .fails,
    },
    .{
        .direction = .response,
        .ops = &.{
            blockOp(.headers, .{
                .fields = &.{status_ok},
                .breakage = .padding_overflow,
            }),
        },
        .outcome = .fails,
    },
    .{
        .direction = .request,
        .ops = &.{
            blockOp(.headers, .{
                .fields = &.{ post_method, messages_path },
                .breakage = .interleaved_frame,
            }),
        },
        .outcome = .fails,
    },
    .{
        .direction = .response,
        .ops = &.{
            blockOp(.headers, .{
                .fragments = 2,
                .fields = &.{ status_ok, event_stream_type },
                .breakage = .wrong_continuation_stream,
            }),
        },
        .outcome = .fails,
    },
    .{
        .direction = .request,
        .ops = &.{
            blockOp(.headers, .{
                .fields = &.{post_method},
                .breakage = .missing_end_headers,
            }),
            dataOp(0, true, 0, "late"),
        },
        .outcome = .fails,
    },
    .{
        .direction = .request,
        .ops = &.{
            watched_request,
            blockOp(.headers, .{
                .stream = 1,
                .fields = &.{ post_method, messages_path },
                .breakage = .corrupt_block,
            }),
        },
        .outcome = .fails,
    },
    .{
        .direction = .response,
        .ops = &.{
            blockOp(.headers, .{
                .fields = &.{ status_ok, seed_marker },
                .breakage = .truncated_block,
            }),
        },
        .outcome = .fails,
    },
    // Found by fuzzing: a cut that drops a whole indexed field leaves a
    // valid block, so decoding goes on.
    .{
        .direction = .response,
        .fail_index = 3,
        .ops = &.{
            blockOp(.push_promise, .{
                .fields = &.{seed_marker},
            }),
            blockOp(.headers, .{
                .fields = &.{ status_ok, newest_entry },
                .breakage = .truncated_block,
            }),
            blockOp(.headers, .{
                .stream = 1,
                .fields = &.{status_ok},
            }),
            dataOp(1, true, 0, "done"),
        },
        .outcome = .decodes,
    },
    huffman_seed,
    .{
        .direction = .request,
        .ops = &.{rawBlockOp(0, watched_request_block)},
        .outcome = .is_opaque,
    },
    .{
        .direction = .response,
        .ops = &.{ rawOp("\x00\x00\x05\x01\x04\x00\x00\x00\x01\x88"), rawOp("\x00\x00") },
        .outcome = .is_opaque,
    },
};

const observation_corpus = corpus: {
    var entries: [observation_seeds.len][]const u8 = undefined;
    for (observation_seeds, &entries) |seed, *entry| {
        entry.* = smithInput(seed);
    }

    break :corpus entries;
};

/// Replays one corpus entry through the generator alone.
fn generateSeed(synthetic: *SyntheticStream, entry: []const u8) Partition {
    var smith: std.testing.Smith = .{
        .in = entry,
    };
    const direction = smith.value(http2.Direction);
    _ = smith.valueRangeAtMost(u8, 0, max_fail_index);
    const partition = generatePartition(&smith);

    startSynthetic(synthetic, direction);
    generateFrames(synthetic, &smith);
    return partition;
}

fn countHeaderObservations(trace: *const ObservationTrace) usize {
    var count: usize = 0;

    for (trace.observations[0..trace.count]) |observation| {
        count += @intFromBool(isHeaderObservation(observation));
    }

    return count;
}

test "every observer fuzz seed reaches its outcome and holds every property" {
    for (observation_seeds, observation_corpus, 0..) |seed, entry, seed_index| {
        errdefer std.debug.print("observer seed {d} failed\n", .{seed_index});
        var synthetic: SyntheticStream = undefined;
        _ = generateSeed(&synthetic, entry);
        try std.testing.expectEqual(seed.direction, synthetic.direction);
        try std.testing.expectEqual(seed.outcome == .decodes, synthetic.valid);
        try std.testing.expectEqual(seed.outcome == .is_opaque, synthetic.is_opaque);

        var trace: ObservationTrace = .{};
        const stats = try relayWire(std.testing.allocator, &synthetic, .{}, &trace);
        if (seed.outcome != .is_opaque) {
            try std.testing.expectEqual(seed.outcome == .fails, stats.decode_failed);
        }

        var smith: std.testing.Smith = .{
            .in = entry,
        };
        try expectFuzzedObservation(&smith);
    }
}

test "valid observer seeds decode every HPACK field and emit more than fields" {
    for (observation_seeds, observation_corpus) |seed, entry| {
        if (seed.outcome != .decodes or seed.ops.len == 0) {
            continue;
        }

        var synthetic: SyntheticStream = undefined;
        _ = generateSeed(&synthetic, entry);
        var trace: ObservationTrace = .{};
        _ = try relayWire(std.testing.allocator, &synthetic, .{}, &trace);

        try std.testing.expect(synthetic.expected_len != 0);
        try std.testing.expectEqual(synthetic.expected_len, countHeaderObservations(&trace));
        try std.testing.expect(trace.count > synthetic.expected_len);
    }
}

test "the watched request seed starts a watched request and finishes it" {
    var synthetic: SyntheticStream = undefined;
    _ = generateSeed(&synthetic, comptime smithInput(watched_request_seed));
    var trace: ObservationTrace = .{};
    _ = try relayWire(std.testing.allocator, &synthetic, .{}, &trace);

    const started = trace.observations[2];
    try std.testing.expectEqual(ObservationKind.lifecycle, started.kind);
    try std.testing.expectEqual(http2.Lifecycle.Stage.request_started, started.stage);
    try std.testing.expect(started.watched);
    try std.testing.expectEqual(ObservationKind.request_finished, trace.observations[trace.count - 1].kind);
}

test "the Huffman seed decodes to the RFC 7541 C.4.1 fields" {
    var synthetic: SyntheticStream = undefined;
    _ = generateSeed(&synthetic, comptime smithInput(huffman_seed));
    var trace: ObservationTrace = .{};
    const stats = try relayWire(std.testing.allocator, &synthetic, .{}, &trace);
    const fields = [_][2][]const u8{
        .{ ":method", "GET" },
        .{ ":scheme", "http" },
        .{ ":path", "/" },
        .{ ":authority", "www.example.com" },
    };

    try std.testing.expect(!stats.decode_failed);
    try std.testing.expectEqual(fields.len, countHeaderObservations(&trace));
    for (fields, trace.observations[0..fields.len]) |field, observation| {
        const text = trace.textOf(observation.text);
        try std.testing.expectEqualStrings(field[0], text[0..observation.name_len]);
        try std.testing.expectEqualStrings(field[1], text[observation.name_len..]);
    }
}

test "every observer seed keeps its trace when split at every position" {
    for (observation_corpus) |entry| {
        var synthetic: SyntheticStream = undefined;
        _ = generateSeed(&synthetic, entry);
        var whole: ObservationTrace = .{};
        const whole_stats = try relayWire(std.testing.allocator, &synthetic, .{}, &whole);

        for (1..@max(1, synthetic.wire.items.len)) |split| {
            errdefer std.debug.print("observer wire split at {d}\n", .{split});
            var two_chunks: Partition = .{
                .len = 2,
            };
            two_chunks.lengths[0] = split;
            two_chunks.lengths[1] = synthetic.wire.items.len;
            var split_trace: ObservationTrace = .{};
            const stats = try relayWire(std.testing.allocator, &synthetic, two_chunks, &split_trace);

            try std.testing.expectEqual(whole_stats.decode_failed, stats.decode_failed);
            try expectSameTrace(&whole, &split_trace);
        }
    }
}

/// Fails the observer's allocations at every index for `checkAllAllocationFailures`:
/// a run that lost an allocation must report a decode failure, which this
/// turns into the `error.OutOfMemory` the checker expects, and keep its
/// decoded fields a prefix of the unfailed run's.
fn relayUnderAllocation(allocator: std.mem.Allocator, synthetic: *const SyntheticStream, unfailed: *const ObservationTrace) !void {
    var trace: ObservationTrace = .{};
    const stats = try relayWire(allocator, synthetic, .{}, &trace);

    try expectHeaderPrefix(unfailed, &trace);
    if (stats.decode_failed) {
        return error.OutOfMemory;
    }
}

test "every allocation failure in valid observer seeds fails the observer and frees its memory" {
    for (observation_seeds, observation_corpus) |seed, entry| {
        if (seed.outcome != .decodes or seed.ops.len == 0) {
            continue;
        }

        var synthetic: SyntheticStream = undefined;
        _ = generateSeed(&synthetic, entry);
        var counting: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
        var unfailed: ObservationTrace = .{};
        _ = try relayWire(counting.allocator(), &synthetic, .{}, &unfailed);
        try std.testing.expect(counting.allocations != 0);

        try std.testing.checkAllAllocationFailures(std.testing.allocator, relayUnderAllocation, .{ &synthetic, &unfailed });
    }
}

test "fuzz HTTP/2 header observation" {
    try std.testing.fuzz({}, observeFuzzedWire, .{
        .corpus = &observation_corpus,
    });
}
