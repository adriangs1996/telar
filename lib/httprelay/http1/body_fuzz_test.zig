//! Native fuzzing of HTTP/1 body relay through `relayBody`.
//!
//! This root imports the `httprelay` library as a module and runs only through
//! `zig build test-fuzz-http1` and `test-fuzz-http1-body`. No suite and no
//! coverage build reaches its `std.testing.fuzz` calls: Zig 0.16.0's test
//! runner does not compile one in Debug with error return traces, and
//! segfaults on one in an instrumented binary run without `--fuzz`.
//!
//! `fuzz generated bodies` encodes a payload under one body plan and relays
//! it whole, in scheduled read sizes and one byte at a time. Every delivery
//! must forward the same bytes, consume the same prefix and report the same
//! payload, which the generator knows. A cut input and a failed write each
//! owe a per-plan result. `fuzz mutated bodies` edits the encoded bytes, or
//! takes raw ones, and checks what holds for any input: the relay forwards
//! exactly the prefix it consumed, never reads past a declared length, and
//! the read sizes change nothing.

const std = @import("std");
const httprelay = @import("httprelay");
const fuzz_corpus = @import("fuzz_corpus.zig");
const ByteEdit = @import("ByteEdit.zig");

const http1 = httprelay.http1;
const FakeSession = http1.FakeSession;
const BodyRoute = http1.BodyRoute;
const BodyPlan = http1.BodyPlan;
const Fragment = http1.Fragment;
const Side = @FieldType(BodyRoute, "from");
const Smith = std.testing.Smith;

/// What `FakeSession` keeps per side; a relayed body must fit it.
const max_output_bytes = @typeInfo(@FieldType(FakeSession, "child_output")).array.len;

const max_body_bytes = 4096;

/// Most chunks a shape splits its payload into before the remainder.
const max_chunks = 8;

const max_trailers = 4;

/// Most read sizes one schedule cycles through.
const max_schedule = 8;

/// The largest scheduled read.
const max_read_step = 32;

/// Most edits one mutated body receives.
const max_edits = 8;

const line_end = "\r\n";

/// What follows a message with a declared end. Relaying the body must leave
/// it unread.
const next_bytes = "NEXT-BYTES";

/// The chunk-size lines of every chunk, the last chunk and the blank line,
/// and the trailers, each at its bound.
const framing_bytes = (max_chunks + 3) * http1.max_chunk_line_bytes + max_trailers * http1.max_trailer_line_bytes;

const wire_capacity = max_body_bytes + framing_bytes + (max_chunks + 1) * line_end.len + next_bytes.len;

comptime {
    std.debug.assert(wire_capacity <= max_output_bytes);
}

const Plan = enum {
    content_length,
    chunked,
    until_close,
    none,
};

const Direction = enum {
    request,
    response,
};

const SizeLine = enum {
    plain,
    uppercase,
    leading_zeros,
    extension,
    /// An extension that makes the line exactly `max_chunk_line_bytes` long.
    long_extension,
};

const Trailer = enum {
    trace,
    checksum,
    /// A field exactly `max_trailer_line_bytes` long.
    long,
};

/// Everything a generated body is built from except its payload, which
/// `Smith.slice` draws next.
const BodyShape = struct {
    plan: Plan = .content_length,
    direction: Direction = .response,
    /// Modulo `max_chunks + 1`.
    chunk_count: u8 = 0,
    chunk_sizes: [max_chunks]u16 = @splat(0),
    /// One per chunk, the last for the last chunk.
    size_lines: [max_chunks + 2]SizeLine = @splat(.plain),
    /// Modulo `max_trailers + 1`.
    trailer_count: u8 = 0,
    trailers: [max_trailers]Trailer = @splat(.trace),
    /// Modulo `max_schedule + 1`.
    schedule_len: u8 = 0,
    /// Each read takes this modulo `max_read_step`, plus one.
    schedule: [max_schedule]u8 = @splat(0),
    /// The input stops at `cut_at` modulo the message's length.
    cut: bool = false,
    cut_at: u16 = 0,
    /// Write `fail_write_at` modulo the successful relay's writes fails.
    fail_write: bool = false,
    fail_write_at: u16 = 0,
};

const Source = enum {
    shaped,
    /// A `Smith.slice` drawn after the shape replaces its bytes.
    raw,
};

const MutatedBody = struct {
    base: BodyShape = .{},
    source: Source = .shaped,
    /// Modulo `max_edits + 1`.
    edit_count: u8 = 0,
    edits: [max_edits]ByteEdit = @splat(.{}),
};

const Pacing = enum {
    whole,
    scheduled,
    single_byte,
};

/// An encoded body, what follows it, and what relaying it owes.
const BodyWire = struct {
    bytes: [wire_capacity]u8 = undefined,
    message_len: usize = 0,
    input_len: usize = 0,
    /// Where the input stops early, or null when the message is complete.
    cut: ?usize = null,
    payload: []const u8 = "",
    /// Body activity a complete relay reports.
    forwarded: usize = 0,

    fn build(self: *BodyWire, shape: BodyShape, payload: []const u8) void {
        var writer: std.Io.Writer = .fixed(&self.bytes);
        self.payload = if (shape.plan == .none) "" else payload;
        self.forwarded = writeBody(&writer, shape, payload) catch @panic("a generated body outgrew its wire");
        self.message_len = writer.end;

        if (shape.cut and self.message_len != 0) {
            const cut = shape.cut_at % self.message_len;
            self.cut = cut;
            self.input_len = cut;
            return;
        }

        if (shape.plan != .until_close) {
            writer.writeAll(next_bytes) catch @panic("a generated body outgrew its wire");
        }

        self.input_len = writer.end;
    }

    fn message(self: *const BodyWire) []const u8 {
        return self.bytes[0..self.message_len];
    }

    fn input(self: *const BodyWire) []const u8 {
        return self.bytes[0..self.input_len];
    }
};

/// Records what the relay reports and checks, as each fragment arrives, that
/// its bytes were already written and its payload fits what it forwarded.
const BodyWitness = struct {
    output_len: *const usize,
    forwarded: usize = 0,
    calls: usize = 0,
    payload_buffer: [wire_capacity]u8 = undefined,
    payload_len: usize = 0,
    consistent: bool = true,

    pub fn observe(self: *BodyWitness, fragment: Fragment) void {
        self.calls += 1;
        self.forwarded += fragment.forwarded_bytes;
        self.consistent = self.consistent and
            fragment.payload.len <= fragment.forwarded_bytes and
            self.forwarded <= self.output_len.* and
            fragment.payload.len <= self.payload_buffer.len - self.payload_len;
        if (!self.consistent) {
            return;
        }

        @memcpy(self.payload_buffer[self.payload_len..][0..fragment.payload.len], fragment.payload);
        self.payload_len += fragment.payload.len;
    }

    fn payload(self: *const BodyWitness) []const u8 {
        return self.payload_buffer[0..self.payload_len];
    }
};

/// A `FakeSession` whose reads take the sizes of a schedule, in a cycle. An
/// empty schedule leaves reads unlimited.
const ScheduledSession = struct {
    fake: FakeSession,
    schedule: []const u8,
    reads: usize = 0,

    pub fn read(self: *ScheduledSession, side: Side, buffer: []u8) ?usize {
        if (self.schedule.len != 0) {
            const step = self.schedule[self.reads % self.schedule.len];
            self.fake.max_read_bytes = step % max_read_step + 1;
        }

        self.reads += 1;
        return self.fake.read(side, buffer);
    }

    pub fn writeAll(self: *ScheduledSession, side: Side, bytes: []const u8) bool {
        return self.fake.writeAll(side, bytes);
    }
};

/// A schedule whose every read takes one byte.
const single_byte_schedule = [_]u8{0};

/// One relay of an input, kept in place so the witness can watch the output.
const BodyRun = struct {
    session: ScheduledSession = undefined,
    witness: BodyWitness = undefined,
    route: BodyRoute = undefined,
    relayed: bool = false,

    fn start(self: *BodyRun, route: BodyRoute, input: []const u8, schedule: []const u8, fail_write_at: ?usize) void {
        self.route = route;
        self.session = .{
            .fake = .{ .fail_write_at = fail_write_at },
            .schedule = schedule,
        };

        const output_len = switch (route.from) {
            .child => output: {
                self.session.fake.child_input = input;
                break :output &self.session.fake.origin_output_len;
            },
            .origin => output: {
                self.session.fake.origin_input = input;
                break :output &self.session.fake.child_output_len;
            },
        };

        self.witness = .{ .output_len = output_len };
        self.relayed = http1.relayBody(&self.session, route, &self.witness);
    }

    fn consumed(self: *const BodyRun) usize {
        return switch (self.route.from) {
            .child => self.session.fake.child_offset,
            .origin => self.session.fake.origin_offset,
        };
    }

    fn output(self: *const BodyRun) []const u8 {
        return switch (self.route.to) {
            .child => self.session.fake.childOutput(),
            .origin => self.session.fake.originOutput(),
        };
    }

    fn backwards(self: *const BodyRun) []const u8 {
        return switch (self.route.from) {
            .child => self.session.fake.childOutput(),
            .origin => self.session.fake.originOutput(),
        };
    }

    fn writes(self: *const BodyRun) usize {
        return self.session.fake.write_calls;
    }
};

fn scheduleOf(shape: *const BodyShape, pacing: Pacing) []const u8 {
    return switch (pacing) {
        .whole => &.{},
        .scheduled => shape.schedule[0 .. shape.schedule_len % (max_schedule + 1)],
        .single_byte => &single_byte_schedule,
    };
}

/// The route a shape's body takes; a content-length body declares `declared`.
fn bodyRoute(shape: BodyShape, declared: usize) BodyRoute {
    const framing: BodyPlan = switch (shape.plan) {
        .content_length => .{ .content_length = declared },
        .chunked => .chunked,
        .until_close => .until_close,
        .none => .none,
    };

    return switch (shape.direction) {
        .request => .{
            .from = .child,
            .to = .origin,
            .framing = framing,
        },
        .response => .{
            .from = .origin,
            .to = .child,
            .framing = framing,
        },
    };
}

/// Encodes `payload` under the shape's plan and returns the body activity a
/// complete relay reports.
fn writeBody(writer: *std.Io.Writer, shape: BodyShape, payload: []const u8) std.Io.Writer.Error!usize {
    switch (shape.plan) {
        .content_length, .until_close => {
            try writer.writeAll(payload);
            return payload.len;
        },
        .none => return 0,
        .chunked => return writeChunked(writer, shape, payload),
    }
}

/// Splits `payload` into the shape's chunk sizes, skipping empty ones, and
/// sends what is left as one more chunk.
fn writeChunked(writer: *std.Io.Writer, shape: BodyShape, payload: []const u8) std.Io.Writer.Error!usize {
    var offset: usize = 0;
    var chunks: usize = 0;
    for (shape.chunk_sizes[0 .. shape.chunk_count % (max_chunks + 1)]) |requested| {
        const size = @min(requested, payload.len - offset);
        if (size == 0) {
            continue;
        }

        try writeChunk(writer, shape.size_lines[chunks], payload[offset..][0..size]);
        offset += size;
        chunks += 1;
    }

    if (offset < payload.len) {
        try writeChunk(writer, shape.size_lines[chunks], payload[offset..]);
        chunks += 1;
    }

    try writeSizeLine(writer, shape.size_lines[chunks], 0);
    for (shape.trailers[0 .. shape.trailer_count % (max_trailers + 1)]) |trailer| {
        try writeTrailer(writer, trailer);
    }

    try writer.writeAll(line_end);
    return payload.len + chunks * line_end.len;
}

fn writeChunk(writer: *std.Io.Writer, size_line: SizeLine, data: []const u8) std.Io.Writer.Error!void {
    try writeSizeLine(writer, size_line, data.len);
    try writer.writeAll(data);
    try writer.writeAll(line_end);
}

fn writeSizeLine(writer: *std.Io.Writer, size_line: SizeLine, size: usize) std.Io.Writer.Error!void {
    const start = writer.end;
    switch (size_line) {
        .plain, .extension, .long_extension => try writer.print("{x}", .{size}),
        .uppercase => try writer.print("{X}", .{size}),
        .leading_zeros => try writer.print("00{x}", .{size}),
    }

    switch (size_line) {
        .plain, .uppercase, .leading_zeros => {},
        .extension => try writer.writeAll(";name=value"),
        .long_extension => {
            try writer.writeAll(";");
            try writer.splatByteAll('e', http1.max_chunk_line_bytes - (writer.end - start) - line_end.len);
        },
    }

    try writer.writeAll(line_end);
}

fn writeTrailer(writer: *std.Io.Writer, trailer: Trailer) std.Io.Writer.Error!void {
    switch (trailer) {
        .trace => try writer.writeAll("X-Trace: present"),
        .checksum => try writer.writeAll("X-Checksum: synthetic"),
        .long => {
            const name = "X-Long: ";
            try writer.writeAll(name);
            try writer.splatByteAll('l', http1.max_trailer_line_bytes - name.len - line_end.len);
        },
    }

    try writer.writeAll(line_end);
}

/// What one delivery of a generated body owes, whatever its read sizes.
fn expectDelivered(run: *const BodyRun, wire: *const BodyWire, plan: Plan) !void {
    try std.testing.expect(run.witness.consistent);
    try std.testing.expectEqualStrings("", run.backwards());

    const cut = wire.cut orelse {
        try std.testing.expect(run.relayed);
        try std.testing.expectEqual(wire.message_len, run.consumed());
        try std.testing.expectEqualStrings(wire.message(), run.output());
        try std.testing.expectEqualStrings(wire.payload, run.witness.payload());
        try std.testing.expectEqual(wire.forwarded, run.witness.forwarded);
        return;
    };

    // EOF inside a declared end fails; a close-delimited body ends there.
    try std.testing.expectEqual(plan == .until_close, run.relayed);
    try std.testing.expectEqual(cut, run.consumed());
    try std.testing.expectEqualStrings(wire.input(), run.output());
    try std.testing.expect(std.mem.startsWith(u8, wire.payload, run.witness.payload()));
    try std.testing.expect(run.witness.forwarded <= cut);
    if (plan != .chunked) {
        try std.testing.expectEqualStrings(wire.input(), run.witness.payload());
    }
}

/// A failed write stops the relay at once: it reports failure, writes
/// nothing more, and what it forwarded and reported is a prefix of the
/// message it was relaying.
fn expectFailedWrite(run: *const BodyRun, wire: *const BodyWire, failing: usize) !void {
    try std.testing.expect(!run.relayed);
    try std.testing.expect(run.witness.consistent);
    try std.testing.expectEqual(failing + 1, run.writes());
    try std.testing.expect(std.mem.startsWith(u8, wire.message(), run.output()));
    try std.testing.expect(std.mem.startsWith(u8, wire.payload, run.witness.payload()));
    try std.testing.expect(run.consumed() <= wire.message_len);
}

/// Relays one generated body under every pacing, then once more with a
/// failing write when the shape asks for one.
fn expectGeneratedBody(shape: *const BodyShape, payload: []const u8) !void {
    var wire: BodyWire = .{};
    wire.build(shape.*, payload);

    const route = bodyRoute(shape.*, payload.len);
    var run: BodyRun = .{};
    var scheduled_writes: usize = 0;
    for (std.enums.values(Pacing)) |pacing| {
        run.start(route, wire.input(), scheduleOf(shape, pacing), null);
        try expectDelivered(&run, &wire, shape.plan);
        if (pacing == .scheduled) {
            scheduled_writes = run.writes();
        }
    }

    if (!shape.fail_write or wire.cut != null or scheduled_writes == 0) {
        return;
    }

    const failing = shape.fail_write_at % scheduled_writes;
    run.start(route, wire.input(), scheduleOf(shape, .scheduled), failing);
    try expectFailedWrite(&run, &wire, failing);
}

/// What any input owes one delivery, and what every other pacing must
/// repeat: the same result, the same consumed prefix forwarded unchanged and
/// the same reported body.
fn expectBodyContract(shape: *const BodyShape, route: BodyRoute, input: []const u8) !void {
    var whole: BodyRun = .{};
    whole.start(route, input, scheduleOf(shape, .whole), null);
    try expectForwardedPrefix(&whole, input);

    switch (route.framing) {
        .none => {
            try std.testing.expect(whole.relayed);
            try std.testing.expectEqual(0, whole.consumed());
        },
        .content_length => |declared| {
            try std.testing.expectEqual(input.len >= declared, whole.relayed);
            try std.testing.expectEqual(@min(declared, input.len), whole.consumed());
        },
        .until_close => {
            try std.testing.expect(whole.relayed);
            try std.testing.expectEqual(input.len, whole.consumed());
        },
        .chunked => {},
    }

    var paced: BodyRun = .{};
    for ([_]Pacing{ .scheduled, .single_byte }) |pacing| {
        paced.start(route, input, scheduleOf(shape, pacing), null);
        try expectForwardedPrefix(&paced, input);
        try std.testing.expectEqual(whole.relayed, paced.relayed);
        try std.testing.expectEqual(whole.consumed(), paced.consumed());
        try std.testing.expectEqualStrings(whole.witness.payload(), paced.witness.payload());
        try std.testing.expectEqual(whole.witness.forwarded, paced.witness.forwarded);
    }
}

fn expectForwardedPrefix(run: *const BodyRun, input: []const u8) !void {
    try std.testing.expect(run.witness.consistent);
    try std.testing.expectEqualStrings("", run.backwards());
    try std.testing.expect(run.consumed() <= input.len);
    try std.testing.expectEqualStrings(input[0..run.consumed()], run.output());
    try std.testing.expect(run.witness.forwarded <= run.consumed());
}

fn expectMutatedBody(mutated: *const MutatedBody, smith: *Smith) !void {
    var payload: [max_body_bytes]u8 = undefined;
    var wire: BodyWire = .{};
    var declared: usize = 0;
    switch (mutated.source) {
        .shaped => {
            declared = smith.slice(&payload);
            wire.build(mutated.base, payload[0..declared]);
        },
        .raw => {
            wire.input_len = smith.slice(&wire.bytes);
            declared = wire.input_len;
        },
    }

    const count = mutated.edit_count % (max_edits + 1);
    const len = ByteEdit.applyAll(&wire.bytes, wire.input_len, mutated.edits[0..count]);
    try expectBodyContract(&mutated.base, bodyRoute(mutated.base, declared), wire.bytes[0..len]);
}

/// A broken property panics instead of returning its error: Zig 0.16.0's
/// fuzzer saves the failing input on an abort, but leaves it empty when the
/// test returns an error and the runner exits.
fn fuzzGeneratedBody(_: void, smith: *Smith) anyerror!void {
    const shape = smith.value(BodyShape);
    var payload: [max_body_bytes]u8 = undefined;
    const len = smith.slice(&payload);
    expectGeneratedBody(&shape, payload[0..len]) catch |err| std.debug.panic("generated body property failed: {t}", .{err});
}

fn fuzzMutatedBody(_: void, smith: *Smith) anyerror!void {
    const mutated = smith.value(MutatedBody);
    expectMutatedBody(&mutated, smith) catch |err| std.debug.panic("mutated body property failed: {t}", .{err});
}

/// A generated body the fuzzer starts from and whether its whole delivery
/// relays, written by hand from the body tests and `body.zig`.
const BodySeed = struct {
    shape: BodyShape,
    payload: []const u8,
    relayed: bool,
};

const wikipedia_chunks: [max_chunks]u16 = .{ 4, 5 } ++ @as([max_chunks - 2]u16, @splat(0));

const body_seeds = [_]BodySeed{
    .{
        .shape = .{},
        .payload = "",
        .relayed = true,
    },
    .{
        .shape = .{
            .direction = .request,
            .schedule_len = 2,
            .schedule = .{ 0, 1 } ++ @as([max_schedule - 2]u8, @splat(0)),
        },
        .payload = "body",
        .relayed = true,
    },
    .{
        .shape = .{
            .cut = true,
            .cut_at = 2,
        },
        .payload = "body",
        .relayed = false,
    },
    .{
        .shape = .{
            .fail_write = true,
            .fail_write_at = 1,
            .schedule_len = 1,
        },
        .payload = "body",
        .relayed = true,
    },
    .{
        .shape = .{
            .plan = .chunked,
            .chunk_count = 2,
            .chunk_sizes = wikipedia_chunks,
            .size_lines = .{.extension} ++ @as([max_chunks + 1]SizeLine, @splat(.plain)),
            .trailer_count = 1,
            .schedule_len = 1,
            .schedule = @splat(1),
        },
        .payload = "Wikipedia",
        .relayed = true,
    },
    .{
        .shape = .{
            .plan = .chunked,
            .chunk_count = 3,
            .chunk_sizes = .{ 1, 0, 200 } ++ @as([max_chunks - 3]u16, @splat(0)),
            .size_lines = .{ .uppercase, .leading_zeros, .long_extension, .long_extension } ++
                @as([max_chunks - 2]SizeLine, @splat(.plain)),
            .trailer_count = 3,
            .trailers = .{ .long, .checksum, .trace, .trace },
            .schedule_len = 3,
            .schedule = .{ 31, 6, 0 } ++ @as([max_schedule - 3]u8, @splat(0)),
        },
        .payload = "x" ** 300,
        .relayed = true,
    },
    .{
        .shape = .{
            .plan = .chunked,
            .size_lines = @splat(.leading_zeros),
            .trailer_count = 2,
        },
        .payload = "",
        .relayed = true,
    },
    .{
        .shape = .{
            .plan = .chunked,
            .chunk_count = 2,
            .chunk_sizes = wikipedia_chunks,
            .cut = true,
            .cut_at = "4\r\nWi".len,
        },
        .payload = "Wikipedia",
        .relayed = false,
    },
    .{
        .shape = .{
            .plan = .chunked,
            .chunk_count = 2,
            .chunk_sizes = wikipedia_chunks,
            .cut = true,
            .cut_at = "4\r\nWiki\r".len,
        },
        .payload = "Wikipedia",
        .relayed = false,
    },
    .{
        .shape = .{
            .plan = .chunked,
            .trailer_count = 1,
            .cut = true,
            .cut_at = "0\r\nX-Trace: pre".len,
        },
        .payload = "",
        .relayed = false,
    },
    .{
        .shape = .{
            .plan = .chunked,
            .chunk_count = 2,
            .chunk_sizes = wikipedia_chunks,
            .fail_write = true,
            .fail_write_at = 5,
        },
        .payload = "Wikipedia",
        .relayed = true,
    },
    .{
        .shape = .{
            .plan = .until_close,
            .schedule_len = 1,
            .schedule = @splat(2),
        },
        .payload = "streamed response",
        .relayed = true,
    },
    .{
        .shape = .{
            .plan = .until_close,
            .cut = true,
            .cut_at = 8,
            .fail_write = true,
        },
        .payload = "streamed response",
        .relayed = true,
    },
    .{
        .shape = .{ .plan = .none },
        .payload = "untouched",
        .relayed = true,
    },
};

const body_corpus = corpus: {
    var entries: [body_seeds.len][]const u8 = undefined;
    for (body_seeds, &entries) |seed, *entry| {
        entry.* = fuzz_corpus.value(BodyShape, seed.shape) ++ fuzz_corpus.slice(seed.payload);
    }

    break :corpus entries;
};

/// A mutated body the fuzzer starts from. It only has to keep the contract.
const MutatedSeed = struct {
    mutated: MutatedBody,
    bytes: []const u8,
};

fn withEdits(comptime base: BodyShape, comptime edits: []const ByteEdit) MutatedBody {
    var mutated: MutatedBody = .{
        .base = base,
        .edit_count = edits.len,
    };
    for (edits, 0..) |edit, index| {
        mutated.edits[index] = edit;
    }

    return mutated;
}

fn rawBody(comptime plan: Plan) MutatedBody {
    return .{
        .base = .{ .plan = plan },
        .source = .raw,
    };
}

const mutated_seeds = [_]MutatedSeed{
    .{
        .mutated = withEdits(body_seeds[4].shape, &.{.{
            .kind = .delete,
            .position = "4;name=value".len,
        }}),
        .bytes = "Wikipedia",
    },
    .{
        .mutated = withEdits(body_seeds[4].shape, &.{.{
            .kind = .replace,
            .position = 0,
            .byte = 'g',
        }}),
        .bytes = "Wikipedia",
    },
    .{
        .mutated = withEdits(body_seeds[5].shape, &.{
            .{
                .kind = .insert,
                .position = "1".len,
                .byte = 'e',
            },
            .{
                .kind = .insert_line_end,
                .position = 0,
            },
        }),
        .bytes = "x" ** 300,
    },
    .{
        .mutated = withEdits(body_seeds[1].shape, &.{.{
            .kind = .delete,
            .position = 1,
        }}),
        .bytes = "body",
    },
    .{
        .mutated = rawBody(.chunked),
        .bytes = "ffffffffffffffffffff\r\n",
    },
    .{
        .mutated = rawBody(.chunked),
        .bytes = "1\r\nxZZ0\r\n\r\n",
    },
    .{
        .mutated = rawBody(.chunked),
        .bytes = "0\r\n" ++ "t" ** (http1.max_trailer_line_bytes + 2),
    },
    .{
        .mutated = rawBody(.chunked),
        .bytes = "5;" ++ "e" ** (http1.max_chunk_line_bytes + 2),
    },
    .{
        .mutated = rawBody(.until_close),
        .bytes = "any bytes at all\r\n0\r\n\r\n",
    },
};

const mutated_corpus = corpus: {
    var entries: [mutated_seeds.len][]const u8 = undefined;
    for (mutated_seeds, &entries) |seed, *entry| {
        entry.* = fuzz_corpus.value(MutatedBody, seed.mutated) ++ fuzz_corpus.slice(seed.bytes);
    }

    break :corpus entries;
};

test "every generated body seed reaches its outcome and corpus encoding" {
    for (body_seeds, body_corpus) |seed, entry| {
        var wire: BodyWire = .{};
        wire.build(seed.shape, seed.payload);

        var run: BodyRun = .{};
        run.start(bodyRoute(seed.shape, seed.payload.len), wire.input(), scheduleOf(&seed.shape, .whole), null);
        try std.testing.expectEqual(seed.relayed, run.relayed);
        try expectGeneratedBody(&seed.shape, seed.payload);

        var smith: Smith = .{ .in = entry };
        try std.testing.expectEqualDeep(seed.shape, smith.value(BodyShape));

        var payload: [max_body_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(seed.payload, payload[0..smith.slice(&payload)]);
    }
}

test "long size lines and trailers fill their line bounds exactly" {
    var wire: BodyWire = .{};
    wire.build(body_seeds[5].shape, body_seeds[5].payload);

    var lines = std.mem.splitSequence(u8, wire.message(), line_end);
    var size_lines: usize = 0;
    var trailer_lines: usize = 0;
    while (lines.next()) |line| {
        const len = line.len + line_end.len;
        try std.testing.expect(len <= http1.max_trailer_line_bytes or line[0] == 'x');
        if (len == http1.max_chunk_line_bytes) {
            size_lines += 1;
        }

        if (len == http1.max_trailer_line_bytes) {
            trailer_lines += 1;
        }
    }

    try std.testing.expectEqual(2, size_lines);
    try std.testing.expectEqual(1, trailer_lines);
}

test "every mutated body seed keeps the body contract and its corpus encoding" {
    for (mutated_seeds, mutated_corpus) |seed, entry| {
        var smith: Smith = .{ .in = entry };
        const drawn = smith.value(MutatedBody);
        try std.testing.expectEqualDeep(seed.mutated, drawn);
        try expectMutatedBody(&drawn, &smith);
    }
}

test "fuzz generated bodies" {
    try std.testing.fuzz({}, fuzzGeneratedBody, .{
        .corpus = &body_corpus,
    });
}

test "fuzz mutated bodies" {
    try std.testing.fuzz({}, fuzzMutatedBody, .{
        .corpus = &mutated_corpus,
    });
}
