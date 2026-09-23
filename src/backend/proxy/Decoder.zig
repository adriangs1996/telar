const sse = @import("sse.zig");
const std = @import("std");
/// Incremental decoder for one SSE response body.
///
/// Initialize with `.{}`, call `feed` for every response-body chunk in order,
/// then call `deinit` when the response ends. A decoder owns the unfinished
/// state of one stream and must not be shared by concurrent responses.
const Decoder = @This();

/// The current logical line without its CR, LF, or CRLF terminator.
/// `feed` consumes terminators instead of storing them here.
line: [sse.max_line_bytes]u8 = undefined,
line_len: usize = 0,

/// Whether `feed` is ignoring the rest of a line that exceeded
/// `max_line_bytes`.
discarding_line: bool = false,

/// Fields accumulated for the event that has not reached its blank line.
event_name: [sse.max_event_name_bytes]u8 = undefined,
event_name_len: usize = 0,
event_data: [sse.max_data_bytes]u8 = undefined,
event_data_len: usize = 0,
has_data: bool = false,
event_truncated: bool = false,

/// Whether the previous byte was CR. The next LF, if present, belongs to
/// the same CRLF terminator and must not create another empty line.
swallow_lf: bool = false,

/// Whether `feed` has decided if the stream starts with a UTF-8 BOM.
/// Once true, every later byte is ordinary SSE input.
bom_checked: bool = false,

/// Number of leading bytes that currently match `utf8_bom` while the
/// stream-start decision remains incomplete.
bom_prefix_len: usize = 0,

/// Consumes the next contiguous bytes from one SSE response body.
///
/// `input` may contain part of a line, several complete events, or nothing.
/// The method retains incomplete state for the next call. Every blank-line
/// terminated event with at least one `data` field invokes `sink.emit`
/// exactly once. One call may therefore emit zero, one, or many events.
///
/// `sink.emit` receives borrowed slices into this decoder. The sink must
/// copy them if it needs to retain them. `feed` returns no value because
/// events are its output. It must not allocate, parse JSON, or report
/// malformed input as a transport failure. An oversized line contributes
/// the prefix that fits, marks the current event as truncated, and discards
/// its tail until the next line boundary.
///
/// At the start of the stream, this method must ignore one leading UTF-8
/// BOM when present, including when its three bytes arrive in separate
/// calls. A later BOM is ordinary input.
///
/// Example:
///
/// ```zig
/// const std = @import("std");
/// const sse = @import("sse.zig");
///
/// const Sink = struct {
///     count: usize = 0,
///
///     pub fn emit(sink: *Sink, event: sse.Event) void {
///         std.debug.assert(std.mem.eql(u8, event.name, "message_stop"));
///         std.debug.assert(std.mem.eql(u8, event.data, "{}"));
///         sink.count += 1;
///     }
/// };
///
/// pub fn main() void {
///     var decoder: sse.Decoder = .{};
///     defer decoder.deinit();
///     var sink: Sink = .{};
///
///     decoder.feed("event: message_stop\ndata: {}\n\n", &sink);
///     std.debug.assert(sink.count == 1);
/// }
/// ```
pub fn feed(self: *Decoder, input: []const u8, sink: anytype) void {
    for (input) |byte| {
        if (!self.bom_checked) {
            if (byte == sse.utf8_bom[self.bom_prefix_len]) {
                self.bom_prefix_len += 1;

                if (self.bom_prefix_len == sse.utf8_bom.len) {
                    self.bom_checked = true;
                    self.bom_prefix_len = 0;
                }

                continue;
            }

            const prefix_len = self.bom_prefix_len;
            self.bom_checked = true;
            self.bom_prefix_len = 0;
            for (sse.utf8_bom[0..prefix_len]) |prefix_byte| {
                self.consumeByte(prefix_byte, sink);
            }
        }
        self.consumeByte(byte, sink);
    }
}

/// Erases every buffered response byte and invalidates the decoder.
///
/// This method emits nothing and returns nothing. Call it when the HTTP
/// response, HTTP/2 stream, or owning connection is destroyed. The secure
/// wipe matters because SSE data may contain model output or secrets.
/// Assign `.{}` to the decoder before using it again.
///
/// Example:
///
/// ```zig
/// const sse = @import("sse.zig");
///
/// pub fn main() void {
///     var decoder: sse.Decoder = .{};
///     defer decoder.deinit();
/// }
/// ```
pub fn deinit(self: *Decoder) void {
    std.crypto.secureZero(u8, std.mem.asBytes(self));
}

/// Consumes one byte after the optional stream-start BOM is resolved.
///
/// This method handles CR, LF, and CRLF line endings, skips the remainder
/// of oversized lines, and appends ordinary bytes to the current line. It
/// may emit an event when the byte completes a blank line. It never handles
/// BOM state; `feed` owns that stream-level decision.
fn consumeByte(self: *Decoder, byte: u8, sink: anytype) void {
    const byte_is_lf = byte == '\n';
    const byte_is_cr = byte == '\r';

    if (self.swallow_lf) {
        self.swallow_lf = false;
        if (byte_is_lf) {
            return;
        }
    }

    if (self.discarding_line) {
        if (byte_is_lf or byte_is_cr) {
            self.discarding_line = false;
            self.resetLine();
            self.swallow_lf = byte_is_cr;
        }
        return;
    }

    switch (byte) {
        '\r' => {
            self.finishLine(sink);
            self.swallow_lf = true;
        },
        '\n' => self.finishLine(sink),
        else => self.pushByte(byte),
    }
}

/// Processes the logical line whose terminator `feed` just consumed.
///
/// A non-empty line updates the pending event through `processLine`. An
/// empty line emits that event when it contains at least one `data` field,
/// then clears the event even when nothing was emitted. The callback must
/// finish using its borrowed slices before this method resets the buffers.
/// The line buffer is cleared on every return path.
///
/// `feed` must not call this method for a discarded oversized line because
/// that line has no valid field to process.
fn finishLine(self: *Decoder, sink: anytype) void {
    defer self.resetLine();

    if (!self.isLineEmpty()) {
        self.processLine();
        return;
    }

    if (self.has_data) {
        const event_name = if (self.isEventNameEmpty())
            "message"
        else
            self.getEventName();

        sink.emit(.{
            .data = self.getEventData(),
            .name = event_name,
            .truncated = self.event_truncated,
        });
    }
    self.resetEvent();
}

fn isLineEmpty(self: *Decoder) bool {
    return self.line_len == 0;
}

/// Appends one non-terminator byte to the current line without allocating.
///
/// Once the fixed line buffer is full, this method processes the retained
/// prefix as a truncated field, then ignores the tail until the next line
/// terminator. The prefix is processed exactly once.
fn pushByte(self: *Decoder, byte: u8) void {
    if (self.line_len < sse.max_line_bytes) {
        self.line[self.line_len] = byte;
        self.line_len += 1;
    } else {
        self.event_truncated = true;
        self.processLine();
        self.resetLine();
        self.discarding_line = true;
    }
}

/// Clears pending event metadata without wiping its buffers.
fn resetEvent(self: *Decoder) void {
    self.event_name_len = 0;
    self.event_data_len = 0;
    self.has_data = false;
    self.event_truncated = false;
}

/// Clears the current line length without wiping its buffer.
fn resetLine(self: *Decoder) void {
    self.line_len = 0;
}

fn isEventNameEmpty(self: *Decoder) bool {
    return self.event_name_len == 0;
}

fn getEventName(self: *Decoder) []const u8 {
    return self.event_name[0..self.event_name_len];
}

fn getEventData(self: *Decoder) []const u8 {
    return self.event_data[0..self.event_data_len];
}

pub fn getLine(self: *Decoder) []const u8 {
    return self.line[0..self.line_len];
}

/// Interprets the buffered SSE line and updates the pending event.
///
/// The buffer contains either a complete line or the retained prefix of an
/// oversized line. It is split at its first colon. A line without a colon
/// has an empty value. Exactly one leading ASCII space is removed from the
/// value. Comment lines and unknown fields are ignored. An `event` field
/// replaces the pending name. A `data` field appends its value, inserting
/// one LF between consecutive data fields. This method never emits an event.
fn processLine(self: *Decoder) void {
    const line = self.getLine();
    const colon = std.mem.indexOfScalar(u8, line, ':');
    const field_name = line[0..(colon orelse line.len)];
    var field_value = if (colon) |index|
        line[index + 1 ..]
    else
        "";

    if (field_value.len > 0 and field_value[0] == ' ') {
        field_value = field_value[1..];
    }

    if (std.mem.eql(u8, field_name, "event")) {
        self.setEventName(field_value);
    } else if (std.mem.eql(u8, field_name, "data")) {
        if (self.has_data) {
            self.appendData("\n");
        }
        self.appendData(field_value);
    }
}

/// Replaces the pending event name with a bounded copy of `event_name`.
///
/// An empty value clears the name, which makes `finishLine` use `"message"`.
/// If the value exceeds `max_event_name_bytes`, this method keeps the
/// prefix that fits and marks the pending event as truncated.
fn setEventName(self: *Decoder, event_name: []const u8) void {
    self.event_name_len = 0;
    const n = @min(sse.max_event_name_bytes, event_name.len);
    if (n < event_name.len) {
        self.event_truncated = true;
    }

    @memcpy(self.event_name[0..n], event_name[0..n]);
    self.event_name_len = n;
}

/// Appends bytes to the bounded event-data buffer.
///
/// Calling this method records the presence of a `data` field even when
/// `bytes` is empty. If the value does not fit, the method copies the
/// prefix that fits and marks the pending event as truncated. It does not
/// add separators. `processLine` inserts the LF between data fields.
fn appendData(self: *Decoder, bytes: []const u8) void {
    const room = sse.max_data_bytes - self.event_data_len;
    const n = @min(room, bytes.len);
    if (n < bytes.len) {
        self.event_truncated = true;
    }

    @memcpy(self.event_data[self.event_data_len..][0..n], bytes[0..n]);
    self.event_data_len += n;
    self.has_data = true;
}
