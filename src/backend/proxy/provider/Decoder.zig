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
pub fn init(decoder: *Decoder) void {
    decoder.* = .{};
    decoder.fixed_allocator = .init(&decoder.allocator_storage);
    decoder.scanner = .initStreaming(decoder.fixed_allocator.allocator());
    decoder.initialized = true;
    decoder.scanner.ensureTotalStackCapacity(claude_request.max_json_depth) catch {
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

    if (input.len > claude_request.max_inspected_bytes -| decoder.bytes_seen) {
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
            if (depth > claude_request.max_json_depth) {
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
        if (decoder.scanner.stackHeight() > claude_request.max_json_depth) {
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
