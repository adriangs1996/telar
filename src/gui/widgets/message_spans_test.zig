const std = @import("std");
const Spans = @import("MessageSpans.zig");

fn visible(source: []const u8, destination: []u8) []const u8 {
    var spans: Spans = .{ .text = source };
    var len: usize = 0;
    while (spans.next()) |span| {
        @memcpy(destination[len..][0..span.text.len], span.text);
        len += span.text.len;
    }

    return destination[0..len];
}

test "Markdown link labels retain inline code strong emphasis and one source identity" {
    var spans: Spans = .{ .text = "See [**documentation** and `input` or *examples*](../input.zig) now" };
    try std.testing.expectEqualStrings("See ", spans.next().?.text);
    const expected_text = [_][]const u8{ "documentation", " and ", "input", " or ", "examples" };
    const expected_kind = [_]@FieldType(@import("MessageSpan.zig"), "kind"){ .strong, .plain, .code, .plain, .emphasis };
    for (expected_text, expected_kind) |text, kind| {
        const span = spans.next().?;
        try std.testing.expectEqualStrings(text, span.text);
        try std.testing.expectEqual(kind, span.kind);
        try std.testing.expectEqualStrings("../input.zig", span.destination.?);
        try std.testing.expectEqual(4, span.link_offset);
    }

    const after = spans.next().?;
    try std.testing.expectEqualStrings(" now", after.text);
    try std.testing.expect(after.destination == null);
    try std.testing.expect(spans.next() == null);
}

test "Markdown links preserve enclosing style and independent source offsets" {
    var spans: Spans = .{ .text = "**[first](one)** [second](two)" };
    const first = spans.next().?;
    try std.testing.expectEqual(.strong, first.kind);
    try std.testing.expectEqualStrings("first", first.text);
    try std.testing.expectEqualStrings("one", first.destination.?);
    try std.testing.expectEqual(2, first.link_offset);
    _ = spans.next();
    const second = spans.next().?;
    try std.testing.expectEqual(.plain, second.kind);
    try std.testing.expectEqualStrings("second", second.text);
    try std.testing.expectEqualStrings("two", second.destination.?);
    try std.testing.expectEqual(17, second.link_offset);
}

test "Markdown destinations handle nesting escapes spaces and complete optional titles" {
    const inputs = [_][]const u8{
        "[x](foo(a(b(c))).zig)",
        "[x](foo\\(bar\\).zig)",
        "[x](<my folder/input.zig>)",
        "[x](<my folder/input.zig> \"A title\")",
        "[x](foo 'single \\' quoted')",
        "[x](foo (a title))",
        "[x](foo \"multi\nline\")",
        "[x](<> )",
        "[x]()",
    };
    const destinations = [_][]const u8{ "foo(a(b(c))).zig", "foo\\(bar\\).zig", "my folder/input.zig", "my folder/input.zig", "foo", "foo", "foo", "", "" };
    for (inputs, destinations) |input, destination| {
        var spans: Spans = .{ .text = input };
        const span = spans.next().?;
        try std.testing.expectEqualStrings("x", span.text);
        try std.testing.expectEqualStrings(destination, span.destination.?);
        try std.testing.expect(spans.next() == null);
    }
}

test "Markdown escaped brackets are text while bracket pairs and code belong to labels" {
    var output: [256]u8 = undefined;
    try std.testing.expectEqualStrings("[literal](url)", visible("\\[literal](url)", &output));
    try std.testing.expectEqualStrings("a]b [nested] `code`", visible("[a\\]b [nested] `` `code` ``](url)", &output));
    var spans: Spans = .{ .text = "[a `]` b](url)" };
    try std.testing.expectEqualStrings("a ", spans.next().?.text);
    const code = spans.next().?;
    try std.testing.expectEqualStrings("]", code.text);
    try std.testing.expectEqual(.code, code.kind);
    try std.testing.expectEqualStrings("url", code.destination.?);
    try std.testing.expectEqualStrings(" b", spans.next().?.text);
}

test "Markdown HTTP autolinks are borrowed and code remains literal" {
    var spans: Spans = .{ .text = "<https://example.com/a?x=1&y=2> ` [no](link) ` ``a`[no](link)``" };
    const link = spans.next().?;
    try std.testing.expectEqualStrings("https://example.com/a?x=1&y=2", link.text);
    try std.testing.expectEqualStrings(link.text, link.destination.?);
    _ = spans.next();
    const code = spans.next().?;
    try std.testing.expectEqualStrings("[no](link)", code.text);
    try std.testing.expect(code.destination == null);
    try std.testing.expectEqual(.code, code.kind);
    _ = spans.next();
    const multiple = spans.next().?;
    try std.testing.expectEqualStrings("a`[no](link)", multiple.text);
    try std.testing.expect(multiple.destination == null);
}

test "Markdown unmatched backtick runs stay whole and links outrank crossing emphasis" {
    var output: [256]u8 = undefined;
    try std.testing.expectEqualStrings("``unfinished`", visible("``unfinished`", &output));
    var spans: Spans = .{ .text = "*[foo*](url)" };
    try std.testing.expectEqualStrings("*", spans.next().?.text);
    const link = spans.next().?;
    try std.testing.expectEqualStrings("foo*", link.text);
    try std.testing.expectEqualStrings("url", link.destination.?);
    try std.testing.expect(spans.next() == null);
}

test "Markdown nested links select the inner destination without overlapping ownership" {
    var spans: Spans = .{ .text = "[outer [inner](inside)](outside)" };
    try std.testing.expectEqualStrings("[outer ", spans.next().?.text);
    const inner = spans.next().?;
    try std.testing.expectEqualStrings("inner", inner.text);
    try std.testing.expectEqualStrings("inside", inner.destination.?);
    const tail = spans.next().?;
    try std.testing.expectEqualStrings("](outside)", tail.text);
    try std.testing.expect(tail.destination == null);
    try std.testing.expect(spans.next() == null);
}

test "Markdown incomplete links titles and autolinks never expose a destination" {
    const inputs = [_][]const u8{
        "[label",                           "[label]",                   "[label](",        "[label](dest",     "[label](dest \"unfinished)",
        "[label](dest \"title\" trailing)", "[label](foo(a)",            "[label](<path)",  "[label](foo bar)", "[label](foo \"blank\n\nline\")",
        "<https://example.com",             "<https://example.com/a b>", "[reference][id]", "[reference]",      "![image](file.png)",
    };
    for (inputs) |input| {
        var spans: Spans = .{ .text = input };
        while (spans.next()) |span| {
            try std.testing.expect(span.destination == null);
        }

        var output: [256]u8 = undefined;
        try std.testing.expectEqualStrings(input, visible(input, &output));
    }
}

test "Markdown code fence content uses literal mode and streaming link completes atomically" {
    const source = "[input](src/input.zig)";
    for (0..source.len) |end| {
        var spans: Spans = .{ .text = source[0..end] };
        while (spans.next()) |span| {
            try std.testing.expect(span.destination == null);
        }
    }

    var spans: Spans = .{ .text = source, .literal = true };
    const literal = spans.next().?;
    try std.testing.expectEqualStrings(source, literal.text);
    try std.testing.expect(literal.destination == null);
    try std.testing.expect(spans.next() == null);
}

test "Markdown repeated unclosed brackets have bounded linear lookahead and exact literal fallback" {
    var source: [48 * 1024]u8 = @splat('[');
    var spans: Spans = .{ .text = &source };
    var count: usize = 0;
    while (spans.next()) |span| {
        try std.testing.expect(span.destination == null);
        count += span.text.len;
    }

    try std.testing.expectEqual(source.len, count);
    try std.testing.expectEqual(0, spans.lookahead_left.?);
    try std.testing.expect(@sizeOf(Spans) <= 640);
}
