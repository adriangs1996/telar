//! Native fuzzing of HTTP/1 head reading and analysis through `relayHead`.
//!
//! This root imports the `httprelay` library as a module and runs only through
//! `zig build test-fuzz-http1` and `test-fuzz-http1-head`. No suite and no
//! coverage build reaches its `std.testing.fuzz` calls: Zig 0.16.0's test
//! runner does not compile one in Debug with error return traces, and
//! segfaults on one in an instrumented binary run without `--fuzz`.
//!
//! `fuzz generated heads` builds a head from a `HeadShape` and compares what
//! `relayHead` returns with an oracle that reads the shape, never the bytes.
//! `fuzz mutated heads` edits those bytes, or takes raw ones, and checks what
//! holds for any input: reading stops at the first blank line within the
//! bound, forwards exactly what it read and leaves the next byte unread, and
//! an accepted head keeps the message invariants.

const std = @import("std");
const httprelay = @import("httprelay");
const fuzz_corpus = @import("fuzz_corpus.zig");
const ByteEdit = @import("ByteEdit.zig");

const http1 = httprelay.http1;
const FakeSession = http1.FakeSession;
const Head = http1.Head;
const BodyPlan = http1.BodyPlan;
const MessageRoute = http1.MessageRoute;
const RouteMatch = httprelay.RouteMatch;
const Smith = std.testing.Smith;

/// What `FakeSession` keeps per side; a relayed head must fit it.
const max_output_bytes = @typeInfo(@FieldType(FakeSession, "child_output")).array.len;

/// Most header fields a shape declares besides its padding field.
const max_fields = 8;

/// Most edits one mutated head receives.
const max_edits = 8;

/// How far a padded head may run past `max_head_bytes`.
const overflow_bytes = 256;

/// Room for a start line and `max_fields` fields at their longest.
const fields_bytes = 1024;

/// What follows a complete head. Reading the head must leave it unread.
const next_bytes = "NEXT-BYTES";

const blank_line = "\r\n\r\n";

const line_end = "\r\n";

const padding_name = "X-Pad";

/// The longest padding value a shape asks for.
const max_padding_bytes = http1.max_head_bytes + overflow_bytes;

const wire_capacity = fields_bytes + max_padding_bytes + next_bytes.len;

/// A start line prints `arbitrary_status` modulo this, so it reaches one,
/// two and three digits.
const status_space = 1000;

/// The lowest and highest status a response may carry.
const first_status = 100;

const last_status = 599;

/// The lowest status that is not informational.
const first_final_status = 200;

comptime {
    std.debug.assert(wire_capacity <= max_output_bytes);
}

/// The routes a request is watched for, as the head tests declare them.
const watched_routes = [_]RouteMatch{.{
    .method = "POST",
    .paths = &.{"/v1/messages"},
}};

const Kind = enum {
    request,
    response,
};

const Method = enum {
    get,
    post,
    post_lowercase,
    head,
    head_lowercase,
    put,

    fn text(self: Method) []const u8 {
        return switch (self) {
            .get => "GET",
            .post => "POST",
            .post_lowercase => "post",
            .head => "HEAD",
            .head_lowercase => "head",
            .put => "PUT",
        };
    }

    /// Watched routes compare methods without case.
    fn isPost(self: Method) bool {
        return self == .post or self == .post_lowercase;
    }
};

const Target = enum {
    root,
    messages,
    messages_query,
    count_tokens,
    absolute,

    fn text(self: Target) []const u8 {
        return switch (self) {
            .root => "/",
            .messages => "/v1/messages",
            .messages_query => "/v1/messages?beta=true",
            .count_tokens => "/v1/messages/count_tokens",
            .absolute => "http://example.test/v1/messages",
        };
    }

    /// Watched paths are compared exactly, without the query.
    fn isWatchedPath(self: Target) bool {
        return self == .messages or self == .messages_query;
    }
};

const StatusCode = enum(u16) {
    @"continue" = 100,
    switching_protocols = 101,
    early_hints = 103,
    ok = 200,
    no_content = 204,
    reset_content = 205,
    not_modified = 304,
    not_found = 404,
    too_many_requests = 429,
    internal_server_error = 500,
    highest = 599,
};

const StatusForm = enum {
    named,
    /// `arbitrary_status` modulo `status_space`, in as many digits as it takes.
    arbitrary,
    zero_padded,
    word,
};

const Reason = enum {
    ok,
    words,
    empty,
    absent,
};

const LengthForm = enum {
    single,
    repeated,
    leading_zeros,
    mismatched,
    trailing_comma,
    empty,
    word,

    /// The length one field declares, or null when the field alone makes
    /// the framing invalid.
    fn declared(self: LengthForm, length: u32) ?u64 {
        return switch (self) {
            .single, .repeated, .leading_zeros => length,
            .mismatched, .trailing_comma, .empty, .word => null,
        };
    }
};

const ContentLength = struct {
    form: LengthForm,
    length: u32,
};

const TransferCoding = enum {
    chunked,
    chunked_uppercase,
    gzip_chunked,
    gzip,
    chunked_gzip,
    empty,
    empty_member,

    fn text(self: TransferCoding) []const u8 {
        return switch (self) {
            .chunked => "chunked",
            .chunked_uppercase => "CHUNKED",
            .gzip_chunked => "gzip, chunked",
            .gzip => "gzip",
            .chunked_gzip => "chunked, gzip",
            .empty => "",
            .empty_member => "gzip, , chunked",
        };
    }

    fn endsChunked(self: TransferCoding) bool {
        return switch (self) {
            .chunked, .chunked_uppercase, .gzip_chunked => true,
            .gzip, .chunked_gzip, .empty, .empty_member => false,
        };
    }

    /// Chunked framing alone leaves an SSE body observable.
    fn isOnlyChunked(self: TransferCoding) bool {
        return self == .chunked or self == .chunked_uppercase;
    }
};

const ConnectionOption = enum {
    close,
    keep_alive,
    keep_alive_close,
    upgrade,
    closed,

    fn text(self: ConnectionOption) []const u8 {
        return switch (self) {
            .close => "close",
            .keep_alive => "keep-alive",
            .keep_alive_close => "keep-alive, Close",
            .upgrade => "Upgrade",
            .closed => "closed",
        };
    }

    fn closes(self: ConnectionOption) bool {
        return self == .close or self == .keep_alive_close;
    }
};

const MediaType = enum {
    event_stream,
    event_stream_parameters,
    json,

    fn text(self: MediaType) []const u8 {
        return switch (self) {
            .event_stream => "text/event-stream",
            .event_stream_parameters => "Text/Event-Stream ; charset=utf-8",
            .json => "application/json",
        };
    }

    fn isEventStream(self: MediaType) bool {
        return self != .json;
    }
};

const ContentCoding = enum {
    identity,
    identity_list,
    gzip,
    empty,

    fn text(self: ContentCoding) []const u8 {
        return switch (self) {
            .identity => "identity",
            .identity_list => "identity, IDENTITY",
            .gzip => "gzip",
            .empty => "",
        };
    }

    fn isIdentity(self: ContentCoding) bool {
        return self == .identity or self == .identity_list;
    }
};

const Field = union(enum) {
    content_length: ContentLength,
    transfer_encoding: TransferCoding,
    connection: ConnectionOption,
    content_type: MediaType,
    content_encoding: ContentCoding,
    host,
    filler,

    fn name(self: Field) []const u8 {
        return switch (self) {
            .content_length => "Content-Length",
            .transfer_encoding => "Transfer-Encoding",
            .connection => "Connection",
            .content_type => "Content-Type",
            .content_encoding => "Content-Encoding",
            .host => "Host",
            .filler => "X-Filler",
        };
    }
};

const Spacing = enum {
    tight,
    space,
    tabs,

    fn before(self: Spacing) []const u8 {
        return switch (self) {
            .tight => "",
            .space => " ",
            .tabs => "\t ",
        };
    }

    fn after(self: Spacing) []const u8 {
        return switch (self) {
            .tight, .space => "",
            .tabs => " \t",
        };
    }
};

const FieldShape = struct {
    field: Field,
    /// Bit `i % 32` swaps the case of the name's byte `i`.
    name_case: u32 = 0,
    spacing: Spacing = .space,
};

const Padding = enum {
    none,
    /// `padding_len` modulo `max_padding_bytes + 1` bytes.
    arbitrary,
    /// Exactly as long as `max_head_bytes` allows.
    fill_bound,
    /// One byte past `max_head_bytes`.
    over_bound,
};

const Ending = enum {
    complete,
    missing_final_byte,
    missing_blank_line,
    missing_line_end,

    /// How many bytes of the blank line the input leaves out.
    fn cut(self: Ending) usize {
        return @intFromEnum(self);
    }
};

/// Everything a generated head is built from, drawn with `Smith.value`.
const HeadShape = struct {
    kind: Kind = .request,
    method: Method = .get,
    target: Target = .root,
    status_form: StatusForm = .named,
    status_code: StatusCode = .ok,
    arbitrary_status: u16 = 0,
    reason: Reason = .ok,
    response_to_head: bool = false,
    /// Modulo `max_fields + 1`.
    field_count: u8 = 0,
    fields: [max_fields]FieldShape = @splat(.{ .field = .host }),
    padding: Padding = .none,
    padding_len: u32 = 0,
    ending: Ending = .complete,
    /// The session's `max_read_bytes`; zero leaves reads unlimited.
    read_limit: u8 = 0,
    /// The session fails the head's write.
    fail_write: bool = false,
};

const Source = enum {
    shaped,
    /// A `Smith.slice` drawn after the shape replaces its bytes.
    raw,
};

const MutatedHead = struct {
    base: HeadShape = .{},
    source: Source = .shaped,
    /// Modulo `max_edits + 1`.
    edit_count: u8 = 0,
    edits: [max_edits]ByteEdit = @splat(.{}),
};

/// What `relayHead` owes a generated head.
const HeadOutcome = union(enum) {
    /// The head is forwarded and analysis yields this framing.
    framing: BodyPlan,
    /// The head is forwarded and analysis rejects it.
    rejected,
    /// EOF or the bound stops reading before a complete head.
    unread,
    /// The head is read but its write fails.
    unforwarded,
};

/// A generated head, what follows it, and where the head ends.
const HeadWire = struct {
    bytes: [wire_capacity]u8 = undefined,
    head_len: usize = 0,
    input_len: usize = 0,

    fn build(self: *HeadWire, shape: HeadShape) void {
        var writer: std.Io.Writer = .fixed(&self.bytes);
        writeHead(&writer, shape) catch @panic("a generated head outgrew its wire");
        self.head_len = writer.end;

        const cut = shape.ending.cut();
        if (cut != 0) {
            self.input_len = self.head_len - cut;
            return;
        }

        writer.writeAll(next_bytes) catch @panic("a generated head outgrew its wire");
        self.input_len = writer.end;
    }

    fn head(self: *const HeadWire) []const u8 {
        return self.bytes[0..self.head_len];
    }

    fn input(self: *const HeadWire) []const u8 {
        return self.bytes[0..self.input_len];
    }
};

/// Copies the head `relayHead` reports; its buffer does not outlive the call.
const HeadWitness = struct {
    calls: usize = 0,
    len: usize = 0,
    buffer: [http1.max_head_bytes]u8 = undefined,

    pub fn head(self: *HeadWitness, read: []const u8) void {
        self.calls += 1;
        @memcpy(self.buffer[0..read.len], read);
        self.len = read.len;
    }

    fn bytes(self: *const HeadWitness) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// What a shape's fields declare, gathered from the shape, never its bytes.
const Declarations = struct {
    transfer_codings: usize = 0,
    last_coding: TransferCoding = .chunked,
    content_length: ?u64 = null,
    invalid_framing: bool = false,
    closes: bool = false,
    media_types: usize = 0,
    event_stream: bool = false,
    identity: bool = true,

    fn gather(shape: HeadShape) Declarations {
        var declarations: Declarations = .{};
        for (shape.fields[0..fieldCount(shape)]) |field_shape| {
            declarations.add(field_shape.field);
        }

        return declarations;
    }

    fn add(self: *Declarations, declared: Field) void {
        switch (declared) {
            .content_length => |content_length| self.addLength(content_length),
            .transfer_encoding => |coding| {
                self.transfer_codings += 1;
                self.last_coding = coding;
                self.invalid_framing = self.invalid_framing or coding == .empty or self.transfer_codings > 1;
                self.identity = self.identity and coding.isOnlyChunked();
            },
            .connection => |option| self.closes = self.closes or option.closes(),
            .content_type => |media_type| {
                self.media_types += 1;
                self.event_stream = media_type.isEventStream();
            },
            .content_encoding => |coding| self.identity = self.identity and coding.isIdentity(),
            .host, .filler => {},
        }
    }

    fn addLength(self: *Declarations, content_length: ContentLength) void {
        const length = content_length.form.declared(content_length.length) orelse {
            self.invalid_framing = true;
            return;
        };

        if (self.content_length) |previous| {
            self.invalid_framing = self.invalid_framing or previous != length;
        }

        self.content_length = length;
    }
};

fn fieldCount(shape: HeadShape) usize {
    return shape.field_count % (max_fields + 1);
}

fn writeHead(writer: *std.Io.Writer, shape: HeadShape) std.Io.Writer.Error!void {
    switch (shape.kind) {
        .request => try writer.print("{s} {s} HTTP/1.1", .{ shape.method.text(), shape.target.text() }),
        .response => try writeStatusLine(writer, shape),
    }

    try writer.writeAll(line_end);
    for (shape.fields[0..fieldCount(shape)]) |field_shape| {
        try writeField(writer, field_shape);
    }

    try writePadding(writer, shape);
    try writer.writeAll(line_end);
}

fn writeStatusLine(writer: *std.Io.Writer, shape: HeadShape) std.Io.Writer.Error!void {
    try writer.writeAll("HTTP/1.1 ");
    switch (shape.status_form) {
        .named => try writer.print("{d}", .{@intFromEnum(shape.status_code)}),
        .arbitrary => try writer.print("{d}", .{shape.arbitrary_status % status_space}),
        .zero_padded => try writer.print("0{d}", .{@intFromEnum(shape.status_code)}),
        .word => try writer.writeAll("two"),
    }

    try writer.writeAll(switch (shape.reason) {
        .ok => " OK",
        .words => " Too Many Requests",
        .empty => " ",
        .absent => "",
    });
}

fn writeField(writer: *std.Io.Writer, field_shape: FieldShape) std.Io.Writer.Error!void {
    for (field_shape.field.name(), 0..) |byte, index| {
        const swapped = (field_shape.name_case >> @intCast(index % @bitSizeOf(u32))) & 1 == 1;
        try writer.writeByte(if (swapped) swapCase(byte) else byte);
    }

    try writer.writeAll(":");
    try writer.writeAll(field_shape.spacing.before());
    switch (field_shape.field) {
        .content_length => |content_length| try writeLength(writer, content_length),
        .transfer_encoding => |coding| try writer.writeAll(coding.text()),
        .connection => |option| try writer.writeAll(option.text()),
        .content_type => |media_type| try writer.writeAll(media_type.text()),
        .content_encoding => |coding| try writer.writeAll(coding.text()),
        .host => try writer.writeAll("example.test"),
        .filler => try writer.writeAll("synthetic"),
    }

    try writer.writeAll(field_shape.spacing.after());
    try writer.writeAll(line_end);
}

fn writeLength(writer: *std.Io.Writer, content_length: ContentLength) std.Io.Writer.Error!void {
    const length: u64 = content_length.length;
    switch (content_length.form) {
        .single => try writer.print("{d}", .{length}),
        .repeated => try writer.print("{d}, {d}", .{ length, length }),
        .leading_zeros => try writer.print("00{d}", .{length}),
        .mismatched => try writer.print("{d}, {d}", .{ length, length + 1 }),
        .trailing_comma => try writer.print("{d},", .{length}),
        .empty => {},
        .word => try writer.writeAll("four"),
    }
}

/// Writes the padding field last, sized against the head's bound when the
/// shape asks for it.
fn writePadding(writer: *std.Io.Writer, shape: HeadShape) std.Io.Writer.Error!void {
    const overhead = padding_name.len + ": ".len + line_end.len + line_end.len;
    const fill = http1.max_head_bytes -| (writer.end + overhead);
    const len = switch (shape.padding) {
        .none => return,
        .arbitrary => shape.padding_len % (max_padding_bytes + 1),
        .fill_bound => fill,
        .over_bound => fill + 1,
    };

    try writer.print("{s}: ", .{padding_name});
    try writer.splatByteAll('p', len);
    try writer.writeAll(line_end);
}

fn swapCase(byte: u8) u8 {
    return if (std.ascii.isUpper(byte)) std.ascii.toLower(byte) else std.ascii.toUpper(byte);
}

fn messageRoute(shape: HeadShape) MessageRoute {
    return switch (shape.kind) {
        .request => .{
            .from = .child,
            .to = .origin,
            .is_response = false,
            .response_to_head = false,
            .watched_routes = &watched_routes,
        },
        .response => .{
            .from = .origin,
            .to = .child,
            .is_response = true,
            .response_to_head = shape.response_to_head,
            .watched_routes = &watched_routes,
        },
    };
}

fn prepareSession(fake: *FakeSession, shape: HeadShape, input: []const u8) void {
    fake.* = .{
        .max_read_bytes = if (shape.read_limit == 0) std.math.maxInt(usize) else shape.read_limit,
        .fail_write_at = if (shape.fail_write) 0 else null,
    };

    switch (shape.kind) {
        .request => fake.child_input = input,
        .response => fake.origin_input = input,
    }
}

fn consumed(fake: *const FakeSession, route: MessageRoute) usize {
    return switch (route.from) {
        .child => fake.child_offset,
        .origin => fake.origin_offset,
    };
}

fn forwarded(fake: *const FakeSession, route: MessageRoute) []const u8 {
    return switch (route.to) {
        .child => fake.childOutput(),
        .origin => fake.originOutput(),
    };
}

fn backwards(fake: *const FakeSession, route: MessageRoute) []const u8 {
    return switch (route.from) {
        .child => fake.childOutput(),
        .origin => fake.originOutput(),
    };
}

/// The status a response's start line declares, or null when analysis must
/// reject it.
fn expectedStatus(shape: HeadShape) ?u16 {
    const code: u16 = switch (shape.status_form) {
        .named => @intFromEnum(shape.status_code),
        .arbitrary => shape.arbitrary_status % status_space,
        .zero_padded, .word => return null,
    };

    return if (code >= first_status and code <= last_status) code else null;
}

fn isBodylessStatus(code: u16) bool {
    return code < first_final_status or
        code == @intFromEnum(StatusCode.no_content) or
        code == @intFromEnum(StatusCode.reset_content) or
        code == @intFromEnum(StatusCode.not_modified);
}

fn expectedFraming(declarations: Declarations, is_response: bool) ?BodyPlan {
    if (declarations.invalid_framing) {
        return null;
    }

    if (declarations.transfer_codings != 0) {
        if (declarations.content_length != null) {
            return null;
        }

        if (declarations.last_coding.endsChunked()) {
            return .chunked;
        }

        return if (is_response) .until_close else null;
    }

    if (declarations.content_length) |length| {
        return .{ .content_length = length };
    }

    return if (is_response) .until_close else .none;
}

/// What `analyze` owes a complete generated head, read from its shape.
fn expectedHead(shape: HeadShape) ?Head {
    const is_response = shape.kind == .response;
    const status_code: u16 = if (is_response) expectedStatus(shape) orelse return null else 0;
    const bodyless = is_response and (shape.response_to_head or isBodylessStatus(status_code));
    const declarations = Declarations.gather(shape);
    const framing: BodyPlan = if (bodyless) .none else expectedFraming(declarations, is_response) orelse return null;
    const switching = @intFromEnum(StatusCode.switching_protocols);

    return .{
        .message = .{
            .status_code = status_code,
            .head_request = !is_response and shape.method == .head,
            .informational = is_response and status_code < first_final_status and status_code != switching,
            .upgrade = is_response and status_code == switching,
            .closes = framing == .until_close or declarations.closes,
        },
        .framing = framing,
        .watched = !is_response and shape.method.isPost() and shape.target.isWatchedPath(),
        .sse_body = is_response and declarations.media_types == 1 and declarations.event_stream and declarations.identity,
    };
}

fn expectedOutcome(shape: HeadShape, wire: *const HeadWire) HeadOutcome {
    if (shape.ending != .complete or wire.head_len > http1.max_head_bytes) {
        return .unread;
    }

    if (shape.fail_write) {
        return .unforwarded;
    }

    const head = expectedHead(shape) orelse return .rejected;
    return .{ .framing = head.framing };
}

/// Relays one generated head and compares every observable effect with the
/// oracle: bytes consumed, the head reported and forwarded, and the analysis.
fn expectGeneratedHead(shape: HeadShape) !void {
    var wire: HeadWire = .{};
    wire.build(shape);

    const route = messageRoute(shape);
    var fake: FakeSession = undefined;
    prepareSession(&fake, shape, wire.input());

    var witness: HeadWitness = .{};
    const parsed = http1.relayHead(&fake, route, &witness);

    try std.testing.expectEqualStrings("", backwards(&fake, route));
    switch (expectedOutcome(shape, &wire)) {
        .unread => {
            try std.testing.expectEqual(null, parsed);
            try std.testing.expectEqual(@min(wire.input_len, http1.max_head_bytes), consumed(&fake, route));
            try std.testing.expectEqual(0, witness.calls);
            try std.testing.expectEqual(0, fake.write_calls);
            return;
        },
        .unforwarded => {
            try std.testing.expectEqual(null, parsed);
            try std.testing.expectEqualStrings("", forwarded(&fake, route));
        },
        .rejected, .framing => {
            try std.testing.expectEqualStrings(wire.head(), forwarded(&fake, route));
            try std.testing.expectEqualDeep(expectedHead(shape), parsed);
        },
    }

    try std.testing.expectEqual(wire.head_len, consumed(&fake, route));
    try std.testing.expectEqual(1, witness.calls);
    try std.testing.expectEqualStrings(wire.head(), witness.bytes());
    try std.testing.expectEqual(1, fake.write_calls);
}

/// What any accepted head keeps, whatever its bytes.
fn expectMessageInvariants(head: Head, route: MessageRoute) !void {
    const message = head.message;
    if (!route.is_response) {
        try std.testing.expectEqual(0, message.status_code);
        try std.testing.expect(!message.informational and !message.upgrade and !head.sse_body);
        try std.testing.expect(head.framing != .until_close);
        return;
    }

    const switching = @intFromEnum(StatusCode.switching_protocols);
    try std.testing.expect(message.status_code >= first_status and message.status_code <= last_status);
    try std.testing.expect(!message.head_request and !head.watched);
    try std.testing.expectEqual(message.status_code < first_final_status and message.status_code != switching, message.informational);
    try std.testing.expectEqual(message.status_code == switching, message.upgrade);
    if (route.response_to_head or isBodylessStatus(message.status_code)) {
        try std.testing.expectEqual(BodyPlan.none, head.framing);
    }

    if (head.framing == .until_close) {
        try std.testing.expect(message.closes);
    }
}

/// Relays arbitrary input as a head. Reading stops right after the first
/// blank line inside the bound, or at EOF or the bound without one; what was
/// read is reported once and forwarded unchanged.
fn expectHeadContract(shape: HeadShape, input: []const u8) !void {
    const route = messageRoute(shape);
    var fake: FakeSession = undefined;
    prepareSession(&fake, shape, input);

    var witness: HeadWitness = .{};
    const parsed = http1.relayHead(&fake, route, &witness);
    const window = input[0..@min(input.len, http1.max_head_bytes)];

    try std.testing.expectEqualStrings("", backwards(&fake, route));
    const head_end = std.mem.indexOf(u8, window, blank_line) orelse {
        try std.testing.expectEqual(null, parsed);
        try std.testing.expectEqual(window.len, consumed(&fake, route));
        try std.testing.expectEqual(0, witness.calls);
        try std.testing.expectEqual(0, fake.write_calls);
        return;
    };

    const head = input[0 .. head_end + blank_line.len];
    try std.testing.expectEqual(head.len, consumed(&fake, route));
    try std.testing.expectEqual(1, witness.calls);
    try std.testing.expectEqualStrings(head, witness.bytes());
    try std.testing.expectEqual(1, fake.write_calls);
    if (shape.fail_write) {
        try std.testing.expectEqual(null, parsed);
        try std.testing.expectEqualStrings("", forwarded(&fake, route));
        return;
    }

    try std.testing.expectEqualStrings(head, forwarded(&fake, route));
    try expectMessageInvariants(parsed orelse return, route);
}

fn expectMutatedHead(mutated: MutatedHead, smith: *Smith) !void {
    var wire: HeadWire = .{};
    switch (mutated.source) {
        .shaped => wire.build(mutated.base),
        .raw => wire.input_len = smith.slice(&wire.bytes),
    }

    const count = mutated.edit_count % (max_edits + 1);
    const len = ByteEdit.applyAll(&wire.bytes, wire.input_len, mutated.edits[0..count]);
    try expectHeadContract(mutated.base, wire.bytes[0..len]);
}

/// A broken property panics instead of returning its error: Zig 0.16.0's
/// fuzzer saves the failing input on an abort, but leaves it empty when the
/// test returns an error and the runner exits.
fn fuzzGeneratedHead(_: void, smith: *Smith) anyerror!void {
    expectGeneratedHead(smith.value(HeadShape)) catch |err| std.debug.panic("generated head property failed: {t}", .{err});
}

fn fuzzMutatedHead(_: void, smith: *Smith) anyerror!void {
    expectMutatedHead(smith.value(MutatedHead), smith) catch |err| std.debug.panic("mutated head property failed: {t}", .{err});
}

fn field(comptime value: Field) FieldShape {
    return .{ .field = value };
}

fn lengthField(comptime form: LengthForm, comptime declared: u32) FieldShape {
    return field(.{ .content_length = .{
        .form = form,
        .length = declared,
    } });
}

fn withFields(comptime shape: HeadShape, comptime fields: []const FieldShape) HeadShape {
    var shaped = shape;
    shaped.field_count = fields.len;
    for (fields, 0..) |field_shape, index| {
        shaped.fields[index] = field_shape;
    }

    return shaped;
}

fn withEdits(comptime base: HeadShape, comptime edits: []const ByteEdit) MutatedHead {
    var mutated: MutatedHead = .{
        .base = base,
        .edit_count = edits.len,
    };
    for (edits, 0..) |edit, index| {
        mutated.edits[index] = edit;
    }

    return mutated;
}

/// A generated head the fuzzer starts from and what `relayHead` owes it,
/// written by hand from the head tests and `head_support.zig`.
const HeadSeed = struct {
    shape: HeadShape,
    outcome: HeadOutcome,
};

const response: HeadShape = .{ .kind = .response };

const head_seeds = [_]HeadSeed{
    .{
        .shape = .{},
        .outcome = .{ .framing = .none },
    },
    .{
        .shape = withFields(.{ .method = .post, .target = .messages_query }, &.{
            field(.host),
            lengthField(.single, 4),
        }),
        .outcome = .{ .framing = .{ .content_length = 4 } },
    },
    .{
        .shape = withFields(.{ .method = .post_lowercase }, &.{
            field(.{ .transfer_encoding = .chunked_uppercase }),
        }),
        .outcome = .{ .framing = .chunked },
    },
    .{
        .shape = withFields(.{ .method = .head, .target = .messages }, &.{field(.host)}),
        .outcome = .{ .framing = .none },
    },
    .{
        .shape = withFields(.{ .method = .put }, &.{
            lengthField(.repeated, 4),
            lengthField(.single, 4),
            lengthField(.leading_zeros, 4),
        }),
        .outcome = .{ .framing = .{ .content_length = 4 } },
    },
    .{
        .shape = withFields(.{ .method = .post }, &.{
            lengthField(.single, 4),
            lengthField(.single, 5),
        }),
        .outcome = .rejected,
    },
    .{
        .shape = withFields(.{ .method = .post }, &.{lengthField(.mismatched, 4)}),
        .outcome = .rejected,
    },
    .{
        .shape = withFields(.{ .method = .post }, &.{lengthField(.trailing_comma, 4)}),
        .outcome = .rejected,
    },
    .{
        .shape = withFields(.{ .method = .post }, &.{lengthField(.empty, 0)}),
        .outcome = .rejected,
    },
    .{
        .shape = withFields(.{ .method = .post }, &.{lengthField(.word, 0)}),
        .outcome = .rejected,
    },
    .{
        .shape = withFields(.{ .method = .post }, &.{
            field(.{ .transfer_encoding = .chunked }),
            lengthField(.single, 4),
        }),
        .outcome = .rejected,
    },
    .{
        .shape = withFields(.{ .method = .post }, &.{
            field(.{ .transfer_encoding = .chunked }),
            field(.{ .transfer_encoding = .chunked }),
        }),
        .outcome = .rejected,
    },
    .{
        .shape = withFields(.{ .method = .post }, &.{field(.{ .transfer_encoding = .gzip })}),
        .outcome = .rejected,
    },
    .{
        .shape = withFields(.{ .method = .post }, &.{field(.{ .transfer_encoding = .empty })}),
        .outcome = .rejected,
    },
    .{
        .shape = withFields(response, &.{lengthField(.single, 42)}),
        .outcome = .{ .framing = .{ .content_length = 42 } },
    },
    .{
        .shape = withFields(response, &.{field(.{ .transfer_encoding = .gzip_chunked })}),
        .outcome = .{ .framing = .chunked },
    },
    .{
        .shape = response,
        .outcome = .{ .framing = .until_close },
    },
    .{
        .shape = withFields(response, &.{field(.{ .transfer_encoding = .chunked_gzip })}),
        .outcome = .{ .framing = .until_close },
    },
    .{
        .shape = withFields(response, &.{field(.{ .transfer_encoding = .empty_member })}),
        .outcome = .{ .framing = .until_close },
    },
    .{
        .shape = withFields(.{
            .kind = .response,
            .status_code = .no_content,
            .reason = .absent,
        }, &.{lengthField(.single, 42)}),
        .outcome = .{ .framing = .none },
    },
    .{
        .shape = withFields(.{
            .kind = .response,
            .status_code = .not_modified,
        }, &.{
            lengthField(.single, 4),
            lengthField(.single, 5),
        }),
        .outcome = .{ .framing = .none },
    },
    .{
        .shape = withFields(.{
            .kind = .response,
            .status_code = .reset_content,
            .reason = .empty,
        }, &.{field(.{ .transfer_encoding = .gzip })}),
        .outcome = .{ .framing = .none },
    },
    .{
        .shape = withFields(.{
            .kind = .response,
            .status_code = .switching_protocols,
        }, &.{field(.{ .connection = .upgrade })}),
        .outcome = .{ .framing = .none },
    },
    .{
        .shape = withFields(.{
            .kind = .response,
            .status_code = .early_hints,
        }, &.{field(.filler)}),
        .outcome = .{ .framing = .none },
    },
    .{
        .shape = withFields(.{
            .kind = .response,
            .response_to_head = true,
        }, &.{lengthField(.single, 42)}),
        .outcome = .{ .framing = .none },
    },
    .{
        .shape = withFields(.{
            .kind = .response,
            .status_code = .too_many_requests,
            .reason = .words,
        }, &.{
            lengthField(.single, 0),
            field(.{ .connection = .keep_alive_close }),
        }),
        .outcome = .{ .framing = .{ .content_length = 0 } },
    },
    .{
        .shape = withFields(response, &.{
            .{
                .field = .{ .content_type = .event_stream_parameters },
                .name_case = 0b1010_1010_1010,
                .spacing = .tabs,
            },
            field(.{ .content_encoding = .identity_list }),
            field(.{ .transfer_encoding = .chunked }),
        }),
        .outcome = .{ .framing = .chunked },
    },
    .{
        .shape = withFields(response, &.{
            field(.{ .content_type = .event_stream }),
            field(.{ .content_type = .event_stream }),
            lengthField(.single, 0),
        }),
        .outcome = .{ .framing = .{ .content_length = 0 } },
    },
    .{
        .shape = withFields(response, &.{
            field(.{ .content_type = .event_stream }),
            field(.{ .content_encoding = .gzip }),
            lengthField(.single, 0),
        }),
        .outcome = .{ .framing = .{ .content_length = 0 } },
    },
    .{
        .shape = withFields(response, &.{
            .{
                .field = .{ .transfer_encoding = .chunked },
                .name_case = std.math.maxInt(u32),
                .spacing = .tight,
            },
            .{
                .field = .{ .connection = .closed },
                .spacing = .tabs,
            },
        }),
        .outcome = .{ .framing = .chunked },
    },
    .{
        .shape = .{
            .kind = .response,
            .status_form = .arbitrary,
            .arbitrary_status = 99,
        },
        .outcome = .rejected,
    },
    .{
        .shape = .{
            .kind = .response,
            .status_form = .arbitrary,
            .arbitrary_status = 600,
        },
        .outcome = .rejected,
    },
    .{
        .shape = .{
            .kind = .response,
            .status_form = .zero_padded,
        },
        .outcome = .rejected,
    },
    .{
        .shape = .{
            .kind = .response,
            .status_form = .word,
        },
        .outcome = .rejected,
    },
    .{
        .shape = .{ .padding = .fill_bound },
        .outcome = .{ .framing = .none },
    },
    .{
        .shape = .{ .padding = .over_bound },
        .outcome = .unread,
    },
    .{
        .shape = withFields(.{ .ending = .missing_final_byte }, &.{field(.host)}),
        .outcome = .unread,
    },
    .{
        .shape = withFields(.{ .ending = .missing_blank_line }, &.{field(.host)}),
        .outcome = .unread,
    },
    .{
        .shape = .{ .ending = .missing_line_end },
        .outcome = .unread,
    },
    .{
        .shape = withFields(.{
            .kind = .response,
            .fail_write = true,
        }, &.{lengthField(.single, 2)}),
        .outcome = .unforwarded,
    },
    .{
        .shape = withFields(.{
            .kind = .response,
            .read_limit = 1,
            .padding = .arbitrary,
            .padding_len = 4096,
        }, &.{lengthField(.single, 2)}),
        .outcome = .{ .framing = .{ .content_length = 2 } },
    },
};

const head_corpus = corpus: {
    var entries: [head_seeds.len][]const u8 = undefined;
    for (head_seeds, &entries) |seed, *entry| {
        entry.* = fuzz_corpus.value(HeadShape, seed.shape);
    }

    break :corpus entries;
};

/// Mutated heads the fuzzer starts from. Each only has to keep the contract.
const mutated_seeds = [_]MutatedHead{
    withEdits(head_seeds[1].shape, &.{.{
        .kind = .delete,
        .position = "POST /v1/messages?beta=true HTTP/1.1\r\nHost".len,
    }}),
    withEdits(head_seeds[14].shape, &.{
        .{
            .kind = .insert_line_end,
            .position = "HTTP/1.1 200 OK\r\n".len,
        },
        .{
            .kind = .replace,
            .position = "HTTP/1.1".len,
            .byte = '\n',
        },
    }),
    withEdits(head_seeds[15].shape, &.{.{
        .kind = .insert,
        .position = "HTTP/1.1 200 OK\r\nTransfer-Encoding".len,
        .byte = ' ',
    }}),
    withEdits(.{ .padding = .fill_bound }, &.{.{
        .kind = .insert,
        .position = "GET / HTTP/1.1\r\n".len,
        .byte = 'x',
    }}),
};

const raw_seeds = [_][]const u8{
    "",
    "HTTP/1.1 200 OK\r\n\n\r\n\r\n",
    "GET / HTTP/1.1\n\n\r\n\r\nGET / HTTP/1.1\r\n\r\n",
    "HTTP/1.1 101 Switching Protocols\r\nContent-Length: 1\r\n\r\nx",
    "\r\n\r\n",
};

const mutated_corpus = corpus: {
    var entries: [mutated_seeds.len + raw_seeds.len][]const u8 = undefined;
    for (mutated_seeds, entries[0..mutated_seeds.len]) |seed, *entry| {
        entry.* = fuzz_corpus.value(MutatedHead, seed);
    }

    for (raw_seeds, entries[mutated_seeds.len..]) |raw, *entry| {
        entry.* = fuzz_corpus.value(MutatedHead, .{ .source = .raw }) ++ fuzz_corpus.slice(raw);
    }

    break :corpus entries;
};

test "every generated head seed reaches its outcome and corpus encoding" {
    for (head_seeds, head_corpus) |seed, entry| {
        var wire: HeadWire = .{};
        wire.build(seed.shape);
        try std.testing.expectEqualDeep(seed.outcome, expectedOutcome(seed.shape, &wire));
        try expectGeneratedHead(seed.shape);

        var smith: Smith = .{ .in = entry };
        try std.testing.expectEqualDeep(seed.shape, smith.value(HeadShape));
    }
}

test "a head that fills the bound is read and one byte more is not" {
    var wire: HeadWire = .{};
    wire.build(.{ .padding = .fill_bound });
    try std.testing.expectEqual(http1.max_head_bytes, wire.head_len);

    wire.build(.{ .padding = .over_bound });
    try std.testing.expectEqual(http1.max_head_bytes + 1, wire.head_len);
}

test "every mutated head seed keeps the head contract and its corpus encoding" {
    for (mutated_seeds, mutated_corpus[0..mutated_seeds.len]) |seed, entry| {
        var smith: Smith = .{ .in = entry };
        try std.testing.expectEqualDeep(seed, smith.value(MutatedHead));
        try expectMutatedHead(seed, &smith);
    }

    for (raw_seeds, mutated_corpus[mutated_seeds.len..]) |raw, entry| {
        var smith: Smith = .{ .in = entry };
        const drawn = smith.value(MutatedHead);
        try std.testing.expectEqual(Source.raw, drawn.source);

        var wire: HeadWire = .{};
        try std.testing.expectEqualStrings(raw, wire.bytes[0..smith.slice(&wire.bytes)]);
        try expectHeadContract(drawn.base, raw);
    }
}

test "fuzz generated heads" {
    try std.testing.fuzz({}, fuzzGeneratedHead, .{
        .corpus = &head_corpus,
    });
}

test "fuzz mutated heads" {
    try std.testing.fuzz({}, fuzzMutatedHead, .{
        .corpus = &mutated_corpus,
    });
}
