//! Native fuzzing of the HTTP/2 frame `Reader`.
//!
//! This root imports `h2frames` as a module and runs only through
//! `zig build test-fuzz-http2`, so the ordinary suites and the coverage build
//! never compile a `std.testing.fuzz` call (see `handshake_fuzz_test.zig`).
//!
//! Every run feeds one wire whole, split at every position, a byte at a time
//! and in a generated partition. After each accepted chunk the frames the
//! receiver saw must equal an independent model of the prefix fed so far, and
//! the reader's pending header and payload must match it. A receiver may
//! reject one callback; `feed` must then return false on the chunk that holds
//! the rejected byte and call nothing more.

const std = @import("std");
const h2frames = @import("h2frames");
const Reader = h2frames.Reader;
const framing = h2frames.framing;

/// Largest wire a run feeds, small enough to feed it split at every position.
const max_wire_bytes = 256;

/// Every frame has a whole header, so at most this many frames begin in the
/// largest wire, counting a trailing partial one.
const max_frames = max_wire_bytes / framing.header_bytes + 1;

/// Chunk lengths a generated partition cycles through.
const max_partition_chunks = 8;

const max_chunk_bytes = 64;

/// The callback a receiver refuses. `ordinal` picks the frame for `begin`
/// and `finish`, and the wire byte for `payload`.
const Rejection = enum(u8) {
    none,
    begin,
    payload,
    finish,
};

const RejectionPlan = struct {
    rejection: Rejection,
    ordinal: u16,
};

/// The wire byte whose feeding triggers a rejection and the frame it
/// belongs to.
const Trigger = struct {
    rejection: Rejection,
    position: usize,
    frame: usize,
};

/// One frame as the receiver saw it, in wire positions.
const ObservedFrame = struct {
    frame_type: u8,
    flags: u8,
    stream_id: u32,
    length: usize,
    payload_start: usize,
    delivered: usize,
    finished: bool,
};

/// The frames seen so far and the bytes of a header still being gathered.
const FrameTrace = struct {
    frames: [max_frames]ObservedFrame = undefined,
    frame_count: usize = 0,
    header_seen: usize = 0,

    fn last(self: *FrameTrace) ?*ObservedFrame {
        if (self.frame_count == 0) {
            return null;
        }

        return &self.frames[self.frame_count - 1];
    }
};

/// What a broken callback saw; the driver turns it into a failure.
const CallbackFault = enum {
    begin_inside_frame,
    begin_before_header,
    payload_outside_frame,
    empty_payload,
    payload_outside_chunk,
    payload_offset,
    payload_beyond_length,
    payload_bytes,
    finish_outside_frame,
    finish_before_payload,
    callback_after_rejection,
    frame_overflow,
};

/// Records every callback against the chunk being fed and refuses the one
/// the plan names.
const TraceReceiver = struct {
    reader: *const Reader,
    wire: []const u8,
    trigger: ?Trigger,
    chunk: []const u8 = "",
    chunk_start: usize = 0,
    trace: FrameTrace = .{},
    rejected: bool = false,
    fault: ?CallbackFault = null,

    pub fn beginFrame(self: *TraceReceiver) bool {
        if (self.rejected) {
            return self.broken(.callback_after_rejection);
        }

        if (self.trace.last()) |frame| {
            if (!frame.finished) {
                return self.broken(.begin_inside_frame);
            }
        }

        if (self.reader.header_len != framing.header_bytes or self.reader.payload_offset != 0) {
            return self.broken(.begin_before_header);
        }

        if (self.trace.frame_count == max_frames) {
            return self.broken(.frame_overflow);
        }

        self.trace.frames[self.trace.frame_count] = .{
            .frame_type = self.reader.frame_type,
            .flags = self.reader.flags,
            .stream_id = self.reader.stream_id,
            .length = self.reader.payload_len,
            .payload_start = 0,
            .delivered = 0,
            .finished = false,
        };
        self.trace.frame_count += 1;
        return self.accepts(.begin, self.trace.frame_count - 1);
    }

    pub fn payload(self: *TraceReceiver, fragment: []const u8) bool {
        if (self.rejected) {
            return self.broken(.callback_after_rejection);
        }

        const frame = self.trace.last() orelse return self.broken(.payload_outside_frame);
        if (frame.finished) {
            return self.broken(.payload_outside_frame);
        }

        if (fragment.len == 0) {
            return self.broken(.empty_payload);
        }

        const chunk_first = @intFromPtr(self.chunk.ptr);
        const fragment_first = @intFromPtr(fragment.ptr);
        if (fragment_first < chunk_first or fragment_first - chunk_first > self.chunk.len - fragment.len) {
            return self.broken(.payload_outside_chunk);
        }

        if (self.reader.payload_offset != frame.delivered) {
            return self.broken(.payload_offset);
        }

        if (fragment.len > frame.length - frame.delivered) {
            return self.broken(.payload_beyond_length);
        }

        const position = self.chunk_start + (fragment_first - chunk_first);
        if (frame.delivered == 0) {
            frame.payload_start = position;
        }

        if (position != frame.payload_start + frame.delivered or !std.mem.eql(u8, fragment, self.wire[position..][0..fragment.len])) {
            return self.broken(.payload_bytes);
        }

        frame.delivered += fragment.len;
        return self.accepts(.payload, position + fragment.len - 1);
    }

    pub fn finishFrame(self: *TraceReceiver) bool {
        if (self.rejected) {
            return self.broken(.callback_after_rejection);
        }

        const frame = self.trace.last() orelse return self.broken(.finish_outside_frame);
        if (frame.finished) {
            return self.broken(.finish_outside_frame);
        }

        if (frame.delivered != frame.length or self.reader.payload_left != 0) {
            return self.broken(.finish_before_payload);
        }

        frame.finished = true;
        return self.accepts(.finish, self.trace.frame_count - 1);
    }

    /// Whether the callback `rejection` for frame or last byte `reached`
    /// passes; a payload is refused once it covers the trigger byte.
    fn accepts(self: *TraceReceiver, rejection: Rejection, reached: usize) bool {
        const trigger = self.trigger orelse return true;
        const refused = switch (rejection) {
            .none => false,
            .begin, .finish => trigger.rejection == rejection and trigger.frame == reached,
            .payload => trigger.rejection == .payload and reached >= trigger.position,
        };
        if (refused) {
            self.rejected = true;
        }

        return !refused;
    }

    fn broken(self: *TraceReceiver, fault: CallbackFault) bool {
        if (self.fault == null) {
            self.fault = fault;
        }

        return true;
    }
};

/// The frames an independent walk of `prefix` finds, as `Reader` must have
/// reported them after it was fed exactly those bytes.
fn modelTrace(prefix: []const u8) FrameTrace {
    var trace: FrameTrace = .{};
    var position: usize = 0;

    while (prefix.len - position >= framing.header_bytes) {
        const header = prefix[position..][0..framing.header_bytes];
        const length = std.mem.readInt(u24, header[0..3], .big);
        const payload_start = position + framing.header_bytes;
        const available = @min(length, prefix.len - payload_start);

        trace.frames[trace.frame_count] = .{
            .frame_type = header[3],
            .flags = header[4],
            .stream_id = std.mem.readInt(u32, header[5..9], .big) & std.math.maxInt(u31),
            .length = length,
            .payload_start = if (available == 0) 0 else payload_start,
            .delivered = available,
            .finished = available == length,
        };
        trace.frame_count += 1;
        if (available != length) {
            return trace;
        }

        position = payload_start + length;
    }

    trace.header_seen = prefix.len - position;
    return trace;
}

/// The byte that triggers `plan` in `wire`, or null when the wire never
/// reaches the callback it names.
fn triggerOf(wire: []const u8, plan: RejectionPlan) ?Trigger {
    if (plan.rejection == .none) {
        return null;
    }

    const whole = modelTrace(wire);
    for (whole.frames[0..whole.frame_count], 0..) |frame, index| {
        const header_end = frameHeaderEnd(whole, index);
        switch (plan.rejection) {
            .none => unreachable,
            .begin => if (index == plan.ordinal) {
                return .{
                    .position = header_end - 1,
                    .frame = index,
                    .rejection = .begin,
                };
            },
            .finish => if (index == plan.ordinal and frame.finished) {
                return .{
                    .position = header_end + frame.length - 1,
                    .frame = index,
                    .rejection = .finish,
                };
            },
            .payload => if (plan.ordinal >= header_end and plan.ordinal < header_end + frame.delivered) {
                return .{
                    .position = plan.ordinal,
                    .frame = index,
                    .rejection = .payload,
                };
            },
        }
    }

    return null;
}

/// Where frame `index` of a trace starts its payload; frames are
/// contiguous, so it follows from the lengths before it.
fn frameHeaderEnd(trace: FrameTrace, index: usize) usize {
    var position: usize = 0;

    for (trace.frames[0..index]) |frame| {
        position += framing.header_bytes + frame.length;
    }

    return position + framing.header_bytes;
}

/// The trace a rejection leaves. A refused begin sees no payload, a refused
/// payload holds its whole fragment, which ends with the chunk or the frame,
/// and a refused finish ends its frame; only the last one finishes it.
fn rejectedTrace(wire: []const u8, trigger: Trigger, stopped_at: usize) FrameTrace {
    const whole = modelTrace(wire);
    const payload_end = frameHeaderEnd(whole, trigger.frame) + whole.frames[trigger.frame].length;
    const cut = switch (trigger.rejection) {
        .none => unreachable,
        .begin, .finish => trigger.position + 1,
        .payload => @min(stopped_at, payload_end),
    };
    var trace = modelTrace(wire[0..cut]);

    trace.frame_count = trigger.frame + 1;
    trace.header_seen = 0;
    trace.frames[trigger.frame].finished = trigger.rejection == .finish;
    return trace;
}

/// Frames only: callbacks never see a partial header, so `header_seen` is
/// checked against the reader by `expectPendingState`.
fn expectSameTrace(expected: FrameTrace, actual: FrameTrace) !void {
    try std.testing.expectEqual(expected.frame_count, actual.frame_count);

    for (expected.frames[0..expected.frame_count], actual.frames[0..actual.frame_count]) |wanted, seen| {
        try std.testing.expectEqual(wanted.frame_type, seen.frame_type);
        try std.testing.expectEqual(wanted.flags, seen.flags);
        try std.testing.expectEqual(wanted.stream_id, seen.stream_id);
        try std.testing.expectEqual(wanted.length, seen.length);
        try std.testing.expectEqual(wanted.payload_start, seen.payload_start);
        try std.testing.expectEqual(wanted.delivered, seen.delivered);
        try std.testing.expectEqual(wanted.finished, seen.finished);
    }
}

/// The reader's pending header and payload after an accepted prefix.
fn expectPendingState(reader: *const Reader, expected: FrameTrace) !void {
    if (expected.header_seen != 0) {
        return std.testing.expectEqual(expected.header_seen, reader.header_len);
    }

    const frame = if (expected.frame_count == 0) null else expected.frames[expected.frame_count - 1];
    if (frame == null or frame.?.finished) {
        try std.testing.expectEqual(@as(u8, 0), reader.header_len);
        return std.testing.expectEqual(@as(usize, 0), reader.payload_left);
    }

    try std.testing.expectEqual(@as(u8, framing.header_bytes), reader.header_len);
    try std.testing.expectEqual(frame.?.length, reader.payload_len);
    try std.testing.expectEqual(frame.?.delivered, reader.payload_offset);
    try std.testing.expectEqual(frame.?.length - frame.?.delivered, reader.payload_left);
}

/// Chunk lengths a feed walks the wire with; zero means the whole rest.
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

/// Feeds `wire` to a fresh reader in the chunks `partition` gives and checks
/// every accepted prefix and the rejection against the model.
fn expectFeeding(wire: []const u8, plan: RejectionPlan, partition: Partition) !void {
    var reader: Reader = .{};
    const trigger = triggerOf(wire, plan);
    var receiver: TraceReceiver = .{
        .reader = &reader,
        .wire = wire,
        .trigger = trigger,
    };
    var fed: usize = 0;
    var chunk_index: usize = 0;

    while (fed < wire.len) : (chunk_index += 1) {
        const chunk = wire[fed..][0..partition.next(chunk_index, wire.len - fed)];
        receiver.chunk = chunk;
        receiver.chunk_start = fed;
        const accepted = reader.feed(chunk, &receiver);
        fed += chunk.len;

        if (receiver.fault) |fault| {
            std.debug.print("callback fault {t} after {d} of {d} bytes\n", .{ fault, fed, wire.len });
            return error.CallbackFault;
        }

        if (!accepted) {
            const reached = trigger orelse return error.UnplannedRejection;
            try std.testing.expect(receiver.rejected);
            try std.testing.expect(reached.position >= fed - chunk.len and reached.position < fed);
            return expectSameTrace(rejectedTrace(wire, reached, fed), receiver.trace);
        }

        try std.testing.expect(!receiver.rejected);
        if (trigger) |reached| {
            try std.testing.expect(reached.position >= fed);
        }

        const expected = modelTrace(wire[0..fed]);
        try expectSameTrace(expected, receiver.trace);
        try expectPendingState(&reader, expected);
    }

    if (trigger != null) {
        return error.MissedRejection;
    }
}

/// Every feeding one run makes: whole, split at every position, a byte at a
/// time, and in the generated partition.
fn expectEveryFeeding(wire: []const u8, plan: RejectionPlan, partition: Partition) !void {
    try expectFeeding(wire, plan, .{});

    for (0..wire.len + 1) |split| {
        errdefer std.debug.print("reader wire split at {d}\n", .{split});
        var two_chunks: Partition = .{
            .len = 2,
        };
        two_chunks.lengths[0] = split;
        two_chunks.lengths[1] = wire.len;
        if (split == 0) {
            two_chunks.len = 0;
        }

        try expectFeeding(wire, plan, two_chunks);
    }

    var bytewise: Partition = .{
        .len = 1,
    };
    bytewise.lengths[0] = 1;
    try expectFeeding(wire, plan, bytewise);
    try expectFeeding(wire, plan, partition);
}

/// A broken property panics instead of returning its error: Zig 0.16.0's
/// fuzzer saves the failing input only on an abort.
fn feedFuzzedWire(_: void, smith: *std.testing.Smith) anyerror!void {
    expectFuzzedFeeding(smith) catch |err| std.debug.panic("Reader property failed: {t}", .{err});
}

/// Reads one wire of at most `max_wire_bytes`, a rejection plan and a
/// partition of at most `max_partition_chunks` chunk lengths.
fn expectFuzzedFeeding(smith: *std.testing.Smith) anyerror!void {
    var buffer: [max_wire_bytes]u8 = undefined;
    const wire = buffer[0..smith.slice(&buffer)];
    const plan: RejectionPlan = .{
        .rejection = smith.value(Rejection),
        .ordinal = smith.valueRangeAtMost(u16, 0, max_wire_bytes),
    };
    var partition: Partition = .{};

    while (partition.len < max_partition_chunks and !smith.eosWeightedSimple(1, 1)) {
        partition.lengths[partition.len] = smith.valueRangeAtMost(u8, 1, max_chunk_bytes);
        partition.len += 1;
    }

    try expectEveryFeeding(wire, plan, partition);
}

/// A seed's wire and plan, encoded the way `expectFuzzedFeeding` reads them.
const WireSeed = struct {
    wire: []const u8,
    rejection: Rejection = .none,
    ordinal: u16 = 0,
    partition: []const u8 = &.{},
};

/// Frame types the seeds use; the reader passes any byte through.
const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    settings = 0x4,
    window_update = 0x8,
    unknown = 0xff,
};

const flag_end_stream: u8 = 0x1;
const flag_ack: u8 = 0x1;
const flag_end_headers: u8 = 0x4;
const flag_padded: u8 = 0x8;
const every_flag: u8 = 0xff;

/// The reserved bit sits on top of the stream id's first byte.
const stream_id_offset = 5;
const reserved_stream_bit: u8 = 0x80;

const settings_ack = encodedFrame(.settings, flag_ack, 0, "");
const data_frame = encodedFrame(.data, flag_end_stream, 7, "abc");
const headers_frame = encodedFrame(.headers, flag_end_headers, 1, "\x83\x04\x0c/v1/messages");
const padded_frame = encodedFrame(.data, flag_padded | flag_end_stream, 3, "\x02hi\x00\x00");
const reserved_bit_frame = withBits(encodedFrame(.window_update, 0, 5, "\x00\x00\x10\x00"), stream_id_offset, reserved_stream_bit);
const unknown_frame = encodedFrame(.unknown, every_flag, std.math.maxInt(u31), "x");
const empty_data_frame = encodedFrame(.data, 0, 1, "");
const three_frames = settings_ack ++ headers_frame ++ data_frame;

/// `data_frame` declaring the largest length, 16 MiB - 1.
const huge_length_frame = withLength(data_frame, std.math.maxInt(u24));

/// `data_frame` declaring the first length that needs the middle byte.
const two_byte_length_frame = withLength(data_frame, std.math.maxInt(u8) + 1);

const wire_seeds = [_]WireSeed{
    .{
        .wire = "",
    },
    .{
        .wire = settings_ack[0..1],
    },
    .{
        .wire = settings_ack[0 .. framing.header_bytes - 1],
    },
    .{
        .wire = &settings_ack,
    },
    .{
        .wire = &data_frame,
    },
    .{
        .wire = data_frame[0 .. data_frame.len - 1],
    },
    .{
        .wire = &(empty_data_frame ++ empty_data_frame),
    },
    .{
        .wire = &(headers_frame ++ data_frame[0..4].*),
    },
    // A 16 MiB length: the reader must wait for bytes, never size a buffer.
    .{
        .wire = &huge_length_frame,
    },
    .{
        .wire = &two_byte_length_frame,
    },
    .{
        .wire = &padded_frame,
    },
    .{
        .wire = &reserved_bit_frame,
    },
    .{
        .wire = &unknown_frame,
    },
    .{
        .wire = &three_frames,
        .partition = &.{ 1, 5, 13 },
    },
    .{
        .wire = &three_frames,
        .rejection = .begin,
        .ordinal = 1,
    },
    .{
        .wire = &three_frames,
        .rejection = .begin,
        .ordinal = 0,
    },
    .{
        .wire = &three_frames,
        .rejection = .payload,
        .ordinal = settings_ack.len + framing.header_bytes + 3,
    },
    .{
        .wire = &three_frames,
        .rejection = .finish,
        .ordinal = 0,
    },
    .{
        .wire = &three_frames,
        .rejection = .finish,
        .ordinal = 2,
        .partition = &.{ 2, 3 },
    },
    .{
        .wire = &three_frames,
        .rejection = .finish,
        .ordinal = 9,
    },
};

/// The seeds in `std.testing.Smith` input form: a little-endian u32 length
/// and the wire, two little-endian u64 values for the plan, then one eos
/// byte and one u64 per chunk length and a final eos byte. A crash the
/// fuzzer saves has the same form, so it can join this corpus as it is.
const wire_corpus = corpus: {
    var entries: [wire_seeds.len][]const u8 = undefined;
    for (wire_seeds, &entries) |seed, *entry| {
        entry.* = smithInput(seed);
    }

    break :corpus entries;
};

fn encodedFrame(comptime frame_type: FrameType, comptime flags: u8, comptime stream_id: u31, comptime payload: []const u8) [framing.header_bytes + payload.len]u8 {
    var bytes: [framing.header_bytes + payload.len]u8 = undefined;
    std.mem.writeInt(u24, bytes[0..3], payload.len, .big);
    bytes[3] = @intFromEnum(frame_type);
    bytes[4] = flags;
    std.mem.writeInt(u32, bytes[5..9], stream_id, .big);
    @memcpy(bytes[framing.header_bytes..], payload);
    return bytes;
}

fn withBits(bytes: anytype, index: usize, byte: u8) @TypeOf(bytes) {
    var changed = bytes;
    changed[index] |= byte;
    return changed;
}

fn withLength(bytes: anytype, length: u24) @TypeOf(bytes) {
    var changed = bytes;
    std.mem.writeInt(u24, changed[0..3], length, .big);
    return changed;
}

fn smithInput(comptime seed: WireSeed) []const u8 {
    comptime {
        var bytes: []const u8 = &littleEndian(u32, seed.wire.len);
        bytes = bytes ++ seed.wire;
        bytes = bytes ++ &littleEndian(u64, @intFromEnum(seed.rejection));
        bytes = bytes ++ &littleEndian(u64, seed.ordinal);
        for (seed.partition) |length| {
            bytes = bytes ++ &[_]u8{0} ++ &littleEndian(u64, length);
        }

        const entry = (bytes ++ &[_]u8{1})[0..].*;
        return &entry;
    }
}

fn littleEndian(comptime T: type, comptime number: T) [@sizeOf(T)]u8 {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, number, .little);
    return bytes;
}

test "every reader fuzz seed decodes to its wire and holds every property" {
    for (wire_seeds, wire_corpus, 0..) |seed, entry, seed_index| {
        var smith: std.testing.Smith = .{
            .in = entry,
        };
        var buffer: [max_wire_bytes]u8 = undefined;
        try std.testing.expectEqualSlices(u8, seed.wire, buffer[0..smith.slice(&buffer)]);
        try std.testing.expectEqual(seed.rejection, smith.value(Rejection));
        try std.testing.expectEqual(seed.ordinal, smith.valueRangeAtMost(u16, 0, max_wire_bytes));

        smith = .{
            .in = entry,
        };
        expectFuzzedFeeding(&smith) catch |err| {
            std.debug.print("reader seed {d} failed\n", .{seed_index});
            return err;
        };
    }
}

test "rejection seeds stop where their plan says" {
    try std.testing.expect(triggerOf(&three_frames, .{
        .rejection = .begin,
        .ordinal = 1,
    }) != null);
    try std.testing.expect(triggerOf(&three_frames, .{
        .rejection = .payload,
        .ordinal = settings_ack.len + framing.header_bytes + 3,
    }) != null);
    try std.testing.expect(triggerOf(&three_frames, .{
        .rejection = .finish,
        .ordinal = 2,
    }) != null);
    try std.testing.expectEqual(null, triggerOf(&three_frames, .{
        .rejection = .finish,
        .ordinal = 9,
    }));
    try std.testing.expectEqual(null, triggerOf(settings_ack[0..3], .{
        .rejection = .begin,
        .ordinal = 0,
    }));
}

test "fuzz HTTP/2 frame reading" {
    try std.testing.fuzz({}, feedFuzzedWire, .{
        .corpus = &wire_corpus,
    });
}
