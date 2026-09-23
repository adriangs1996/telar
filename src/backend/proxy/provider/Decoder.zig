const claude_request = @import("claude_request.zig");
const std = @import("std");
/// Incrementally recognizes a primary Claude Code request without retaining
/// prompts, tool inputs, or any other body content.
///
/// The decoder must remain at a stable address between `init` and `deinit`
/// because its JSON scanner uses the decoder's fixed allocator storage.
const Decoder = @This();

allocator_storage: [claude_request.allocator_bytes]u8 = undefined,
fixed_allocator: std.heap.FixedBufferAllocator = undefined,
scanner: std.json.Scanner = undefined,
initialized: bool = false,
invalid: bool = false,
document_finished: bool = false,
bytes_seen: usize = 0,
position: claude_request.Position = .document,
field: claude_request.Field = .other,
value_depth: usize = 0,
tools_array_depth: usize = 0,
stream_seen: bool = false,
stream_enabled: bool = false,
tools_seen: bool = false,
tools_nonempty: bool = false,
key: [claude_request.max_key_bytes]u8 = undefined,
key_len: usize = 0,
key_overflow: bool = false,

/// Initializes an empty decoder at its final memory address.
///
/// ```zig
/// var decoder: Decoder = .{};
/// decoder.init();
/// defer decoder.deinit();
/// ```
pub fn init(self: *Decoder) void {
    self.* = .{};
    self.fixed_allocator = .init(&self.allocator_storage);
    self.scanner = .initStreaming(self.fixed_allocator.allocator());
    self.initialized = true;
    self.scanner.ensureTotalStackCapacity(claude_request.max_json_depth) catch {
        self.invalid = true;
    };
}

/// Consumes one borrowed body fragment without retaining its content.
///
/// ```zig
/// decoder.feed(fragment);
/// ```
pub fn feed(self: *Decoder, input: []const u8) void {
    std.debug.assert(self.initialized);

    if (self.invalid or self.document_finished or input.len == 0) {
        return;
    }

    if (input.len > claude_request.max_inspected_bytes -| self.bytes_seen) {
        self.invalid = true;
        return;
    }

    self.bytes_seen += input.len;
    self.scanner.feedInput(input);
    self.consume(false);
}

/// Ends the JSON document and returns whether its validated shape belongs
/// to a primary Claude Code exchange. Calling it repeatedly is harmless.
///
/// ```zig
/// const inference = decoder.finish();
/// ```
pub fn finish(self: *Decoder) bool {
    std.debug.assert(self.initialized);

    if (!self.document_finished and !self.invalid) {
        self.scanner.endInput();
        self.consume(true);
    }

    return !self.invalid and self.document_finished and
        self.stream_enabled and self.tools_nonempty;
}

/// Releases and erases the bounded parsing state.
///
/// ```zig
/// decoder.deinit();
/// ```
pub fn deinit(self: *Decoder) void {
    if (!self.initialized) {
        return;
    }

    self.scanner.deinit();
    std.crypto.secureZero(u8, std.mem.asBytes(self));
}

fn consume(self: *Decoder, finishing: bool) void {
    while (!self.invalid and !self.document_finished) {
        const token = self.scanner.next() catch |failure| switch (failure) {
            error.BufferUnderrun => {
                if (finishing) {
                    self.invalid = true;
                }

                return;
            },
            else => {
                self.invalid = true;
                return;
            },
        };

        if (token == .end_of_document) {
            if (self.position == .done) {
                self.document_finished = true;
            } else {
                self.invalid = true;
            }

            return;
        }

        self.consumeToken(token);
    }
}

fn consumeToken(self: *Decoder, token: std.json.Token) void {
    switch (self.position) {
        .document => self.consumeDocumentStart(token),
        .key => self.consumeKey(token),
        .value => self.consumeValue(token),
        .nested_value => self.consumeNestedValue(token),
        .done => self.invalid = token != .end_of_document,
    }
}

fn consumeDocumentStart(self: *Decoder, token: std.json.Token) void {
    if (token != .object_begin or self.scanner.stackHeight() != 1) {
        self.invalid = true;
        return;
    }

    self.position = .key;
}

fn consumeKey(self: *Decoder, token: std.json.Token) void {
    switch (token) {
        .partial_string => |fragment| self.appendKey(fragment),
        .partial_string_escaped_1 => |fragment| self.appendKey(&fragment),
        .partial_string_escaped_2 => |fragment| self.appendKey(&fragment),
        .partial_string_escaped_3 => |fragment| self.appendKey(&fragment),
        .partial_string_escaped_4 => |fragment| self.appendKey(&fragment),
        .string => |fragment| {
            self.appendKey(fragment);
            self.selectField();
            self.position = .value;
        },
        .object_end => {
            if (self.scanner.stackHeight() != 0) {
                self.invalid = true;
                return;
            }

            self.position = .done;
        },
        else => self.invalid = true,
    }
}

fn consumeValue(self: *Decoder, token: std.json.Token) void {
    switch (token) {
        .object_begin, .array_begin => {
            const depth = self.scanner.stackHeight();
            if (depth > claude_request.max_json_depth) {
                self.invalid = true;
                return;
            }

            self.value_depth = depth;
            self.tools_array_depth = if (self.field == .tools and token == .array_begin) depth else 0;
            self.position = .nested_value;
        },
        .partial_number,
        .partial_string,
        .partial_string_escaped_1,
        .partial_string_escaped_2,
        .partial_string_escaped_3,
        .partial_string_escaped_4,
        => {},
        .true => {
            if (self.field == .stream) {
                self.stream_enabled = true;
            }

            self.completeValue();
        },
        .false, .null, .number, .string => self.completeValue(),
        else => self.invalid = true,
    }
}

fn consumeNestedValue(self: *Decoder, token: std.json.Token) void {
    if (token == .object_begin or token == .array_begin) {
        if (self.scanner.stackHeight() > claude_request.max_json_depth) {
            self.invalid = true;
            return;
        }
    }

    if (self.tools_array_depth != 0 and !self.tools_nonempty) {
        const empty_tools = token == .array_end and
            self.scanner.stackHeight() + 1 == self.tools_array_depth;

        if (!empty_tools) {
            self.tools_nonempty = true;
        }
    }

    const closes_value = (token == .object_end or token == .array_end) and
        self.scanner.stackHeight() + 1 == self.value_depth;
    if (closes_value) {
        self.completeValue();
    }
}

fn completeValue(self: *Decoder) void {
    self.field = .other;
    self.value_depth = 0;
    self.tools_array_depth = 0;
    self.position = .key;
}

fn appendKey(self: *Decoder, fragment: []const u8) void {
    if (self.key_overflow or fragment.len > self.key.len -| self.key_len) {
        self.key_overflow = true;
        return;
    }

    @memcpy(self.key[self.key_len..][0..fragment.len], fragment);
    self.key_len += fragment.len;
}

fn selectField(self: *Decoder) void {
    const name = self.key[0..self.key_len];
    self.field = if (!self.key_overflow and std.mem.eql(u8, name, "stream"))
        .stream
    else if (!self.key_overflow and std.mem.eql(u8, name, "tools"))
        .tools
    else
        .other;

    self.key_len = 0;
    self.key_overflow = false;

    switch (self.field) {
        .stream => {
            if (self.stream_seen) {
                self.invalid = true;
            }

            self.stream_seen = true;
        },
        .tools => {
            if (self.tools_seen) {
                self.invalid = true;
            }

            self.tools_seen = true;
        },
        .other => {},
    }
}
