//! Bounded semantic classification of streamed Claude Messages request bodies.

const std = @import("std");

pub const max_inspected_bytes = 8 * 1024 * 1024;
pub const max_json_depth = 64;

const allocator_bytes = 512;
const max_key_bytes = 32;

const Field = enum {
    other,
    stream,
    tools,
};

const Position = enum {
    document,
    key,
    value,
    nested_value,
    done,
};

/// Incrementally recognizes a primary Claude Code request without retaining
/// prompts, tool inputs, or any other body content.
///
/// The decoder must remain at a stable address between `init` and `deinit`
/// because its JSON scanner uses the decoder's fixed allocator storage.
pub const Decoder = struct {
    allocator_storage: [allocator_bytes]u8 = undefined,
    fixed_allocator: std.heap.FixedBufferAllocator = undefined,
    scanner: std.json.Scanner = undefined,
    initialized: bool = false,
    invalid: bool = false,
    document_finished: bool = false,
    bytes_seen: usize = 0,
    position: Position = .document,
    field: Field = .other,
    value_depth: usize = 0,
    tools_array_depth: usize = 0,
    stream_seen: bool = false,
    stream_enabled: bool = false,
    tools_seen: bool = false,
    tools_nonempty: bool = false,
    key: [max_key_bytes]u8 = undefined,
    key_len: usize = 0,
    key_overflow: bool = false,

    /// Initializes an empty decoder at its final memory address.
    ///
    /// ```zig
    /// var decoder: Decoder = .{};
    /// decoder.init();
    /// defer decoder.deinit();
    /// ```
    pub fn init(decoder: *Decoder) void {
        decoder.* = .{};
        decoder.fixed_allocator = .init(&decoder.allocator_storage);
        decoder.scanner = .initStreaming(decoder.fixed_allocator.allocator());
        decoder.initialized = true;
        decoder.scanner.ensureTotalStackCapacity(max_json_depth) catch {
            decoder.invalid = true;
        };
    }

    /// Consumes one borrowed body fragment without retaining its content.
    ///
    /// ```zig
    /// decoder.feed(fragment);
    /// ```
    pub fn feed(decoder: *Decoder, input: []const u8) void {
        std.debug.assert(decoder.initialized);

        if (decoder.invalid or decoder.document_finished or input.len == 0) {
            return;
        }

        if (input.len > max_inspected_bytes -| decoder.bytes_seen) {
            decoder.invalid = true;
            return;
        }

        decoder.bytes_seen += input.len;
        decoder.scanner.feedInput(input);
        decoder.consume(false);
    }

    /// Ends the JSON document and returns whether its validated shape belongs
    /// to a primary Claude Code exchange. Calling it repeatedly is harmless.
    ///
    /// ```zig
    /// const inference = decoder.finish();
    /// ```
    pub fn finish(decoder: *Decoder) bool {
        std.debug.assert(decoder.initialized);

        if (!decoder.document_finished and !decoder.invalid) {
            decoder.scanner.endInput();
            decoder.consume(true);
        }

        return !decoder.invalid and decoder.document_finished and
            decoder.stream_enabled and decoder.tools_nonempty;
    }

    /// Releases and erases the bounded parsing state.
    ///
    /// ```zig
    /// decoder.deinit();
    /// ```
    pub fn deinit(decoder: *Decoder) void {
        if (!decoder.initialized) {
            return;
        }

        decoder.scanner.deinit();
        std.crypto.secureZero(u8, std.mem.asBytes(decoder));
    }

    fn consume(decoder: *Decoder, finishing: bool) void {
        while (!decoder.invalid and !decoder.document_finished) {
            const token = decoder.scanner.next() catch |failure| switch (failure) {
                error.BufferUnderrun => {
                    if (finishing) {
                        decoder.invalid = true;
                    }

                    return;
                },
                else => {
                    decoder.invalid = true;
                    return;
                },
            };

            if (token == .end_of_document) {
                if (decoder.position == .done) {
                    decoder.document_finished = true;
                } else {
                    decoder.invalid = true;
                }

                return;
            }

            decoder.consumeToken(token);
        }
    }

    fn consumeToken(decoder: *Decoder, token: std.json.Token) void {
        switch (decoder.position) {
            .document => decoder.consumeDocumentStart(token),
            .key => decoder.consumeKey(token),
            .value => decoder.consumeValue(token),
            .nested_value => decoder.consumeNestedValue(token),
            .done => decoder.invalid = token != .end_of_document,
        }
    }

    fn consumeDocumentStart(decoder: *Decoder, token: std.json.Token) void {
        if (token != .object_begin or decoder.scanner.stackHeight() != 1) {
            decoder.invalid = true;
            return;
        }

        decoder.position = .key;
    }

    fn consumeKey(decoder: *Decoder, token: std.json.Token) void {
        switch (token) {
            .partial_string => |fragment| decoder.appendKey(fragment),
            .partial_string_escaped_1 => |fragment| decoder.appendKey(&fragment),
            .partial_string_escaped_2 => |fragment| decoder.appendKey(&fragment),
            .partial_string_escaped_3 => |fragment| decoder.appendKey(&fragment),
            .partial_string_escaped_4 => |fragment| decoder.appendKey(&fragment),
            .string => |fragment| {
                decoder.appendKey(fragment);
                decoder.selectField();
                decoder.position = .value;
            },
            .object_end => {
                if (decoder.scanner.stackHeight() != 0) {
                    decoder.invalid = true;
                    return;
                }

                decoder.position = .done;
            },
            else => decoder.invalid = true,
        }
    }

    fn consumeValue(decoder: *Decoder, token: std.json.Token) void {
        switch (token) {
            .object_begin, .array_begin => {
                const depth = decoder.scanner.stackHeight();
                if (depth > max_json_depth) {
                    decoder.invalid = true;
                    return;
                }

                decoder.value_depth = depth;
                decoder.tools_array_depth = if (decoder.field == .tools and token == .array_begin) depth else 0;
                decoder.position = .nested_value;
            },
            .partial_number,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            => {},
            .true => {
                if (decoder.field == .stream) {
                    decoder.stream_enabled = true;
                }

                decoder.completeValue();
            },
            .false, .null, .number, .string => decoder.completeValue(),
            else => decoder.invalid = true,
        }
    }

    fn consumeNestedValue(decoder: *Decoder, token: std.json.Token) void {
        if (token == .object_begin or token == .array_begin) {
            if (decoder.scanner.stackHeight() > max_json_depth) {
                decoder.invalid = true;
                return;
            }
        }

        if (decoder.tools_array_depth != 0 and !decoder.tools_nonempty) {
            const empty_tools = token == .array_end and
                decoder.scanner.stackHeight() + 1 == decoder.tools_array_depth;

            if (!empty_tools) {
                decoder.tools_nonempty = true;
            }
        }

        const closes_value = (token == .object_end or token == .array_end) and
            decoder.scanner.stackHeight() + 1 == decoder.value_depth;
        if (closes_value) {
            decoder.completeValue();
        }
    }

    fn completeValue(decoder: *Decoder) void {
        decoder.field = .other;
        decoder.value_depth = 0;
        decoder.tools_array_depth = 0;
        decoder.position = .key;
    }

    fn appendKey(decoder: *Decoder, fragment: []const u8) void {
        if (decoder.key_overflow or fragment.len > decoder.key.len -| decoder.key_len) {
            decoder.key_overflow = true;
            return;
        }

        @memcpy(decoder.key[decoder.key_len..][0..fragment.len], fragment);
        decoder.key_len += fragment.len;
    }

    fn selectField(decoder: *Decoder) void {
        const name = decoder.key[0..decoder.key_len];
        decoder.field = if (!decoder.key_overflow and std.mem.eql(u8, name, "stream"))
            .stream
        else if (!decoder.key_overflow and std.mem.eql(u8, name, "tools"))
            .tools
        else
            .other;

        decoder.key_len = 0;
        decoder.key_overflow = false;

        switch (decoder.field) {
            .stream => {
                if (decoder.stream_seen) {
                    decoder.invalid = true;
                }

                decoder.stream_seen = true;
            },
            .tools => {
                if (decoder.tools_seen) {
                    decoder.invalid = true;
                }

                decoder.tools_seen = true;
            },
            .other => {},
        }
    }
};

fn classifyEverySplit(input: []const u8, expected: bool) !void {
    for (0..input.len + 1) |split| {
        var decoder: Decoder = .{};
        decoder.init();
        defer decoder.deinit();

        decoder.feed(input[0..split]);
        decoder.feed(input[split..]);

        try std.testing.expectEqual(expected, decoder.finish());
    }
}

test "a startup probe is auxiliary across every two-chunk split" {
    try classifyEverySplit(
        "{\"model\":\"claude-haiku\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}",
        false,
    );
}

test "a streaming request with declared tools is primary across every two-chunk split" {
    try classifyEverySplit(
        "{\"model\":\"claude\",\"messages\":[{\"role\":\"user\",\"content\":\"private\"}],\"tools\":[{\"name\":\"Read\",\"input_schema\":{\"type\":\"object\"}}],\"stream\":true}",
        true,
    );
}

test "field order does not affect primary classification" {
    try classifyEverySplit(
        "{\"stream\":true,\"ignored\":{\"deep\":[1,2,3]},\"tools\":[{}]}",
        true,
    );
}

test "escaped top-level field names are decoded" {
    try classifyEverySplit("{\"str\\u0065am\":true,\"to\\u006fls\":[{}]}", true);
}

test "streaming helper requests without tools remain auxiliary" {
    try classifyEverySplit("{\"tools\":[],\"stream\":true}", false);
    try classifyEverySplit("{\"stream\":true}", false);
}

test "tools without enabled streaming remain auxiliary" {
    try classifyEverySplit("{\"tools\":[{}]}", false);
    try classifyEverySplit("{\"tools\":[{}],\"stream\":false}", false);
    try classifyEverySplit("{\"tools\":[{}],\"stream\":null}", false);
}

test "nested lookalike fields do not classify the request" {
    try classifyEverySplit(
        "{\"payload\":{\"stream\":true,\"tools\":[{}]},\"note\":\"tools and stream\"}",
        false,
    );
}

test "duplicate semantic fields fail closed" {
    try classifyEverySplit("{\"stream\":false,\"stream\":true,\"tools\":[{}]}", false);
    try classifyEverySplit("{\"stream\":true,\"tools\":[],\"tools\":[{}]}", false);
}

test "malformed and truncated JSON fail closed" {
    try classifyEverySplit("{\"stream\":true,\"tools\":[{}]", false);
    try classifyEverySplit("{\"stream\":true,\"tools\":[{}]} trailing", false);
    try classifyEverySplit("[\"stream\",\"tools\"]", false);
}

test "one-byte feeds preserve classification state" {
    const input = "{\"tools\":[{\"name\":\"Read\"}],\"stream\":true}";
    var decoder: Decoder = .{};
    decoder.init();
    defer decoder.deinit();

    for (input) |byte| {
        decoder.feed(&.{byte});
    }

    try std.testing.expect(decoder.finish());
}

test "a tool result continuation remains a primary request" {
    try classifyEverySplit(
        "{\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"tool-1\"}]},{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tool-1\",\"content\":\"private\"}]}],\"tools\":[{\"name\":\"Read\"}],\"stream\":true}",
        true,
    );
}

test "the byte budget fails closed without retaining the body" {
    var decoder: Decoder = .{};
    decoder.init();
    defer decoder.deinit();
    const whitespace = " " ** 1024;

    for (0..max_inspected_bytes / whitespace.len) |_| {
        decoder.feed(whitespace);
    }

    decoder.feed(" ");
    try std.testing.expect(!decoder.finish());
}

test "excessive JSON depth fails closed" {
    var decoder: Decoder = .{};
    decoder.init();
    defer decoder.deinit();

    decoder.feed("{\"payload\":");
    for (0..max_json_depth) |_| {
        decoder.feed("[");
    }

    try std.testing.expect(!decoder.finish());
}
