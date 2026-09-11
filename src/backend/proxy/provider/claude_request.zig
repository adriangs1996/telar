//! Bounded semantic classification of streamed Claude Messages request bodies.

const std = @import("std");

pub const max_inspected_bytes = 8 * 1024 * 1024;
pub const max_json_depth = 64;

pub const allocator_bytes = 512;
pub const max_key_bytes = 32;

pub const Field = enum {
    other,
    stream,
    tools,
};

pub const Position = enum {
    document,
    key,
    value,
    nested_value,
    done,
};

pub const Decoder = @import("Decoder.zig");

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
