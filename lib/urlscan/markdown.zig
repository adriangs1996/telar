//! Recognition of an inline Markdown link, `[label](destination)`, around a
//! byte offset in one line, the form coding agents print for references.
//! The whole span from the opening bracket to the closing parenthesis is the
//! link, and the destination must classify as a supported URI. Emphasis,
//! code spans, angle-bracket destinations, titles and reference links stay
//! literal.
const std = @import("std");
const uri = @import("uri.zig");
const MarkdownLink = @import("MarkdownLink.zig");

/// The longest label a link may carry; longer brackets stay plain text.
pub const max_label_bytes = 512;
/// Brackets and parentheses around a label and its destination.
const delimiter_bytes = 4;

/// Finds the Markdown link containing `byte_offset`, label and destination
/// included, so hovering either part reaches the same destination.
///
/// ```zig
/// const link = markdown.linkAt("see [docs](https://example.com) now", 6).?;
/// const target = link.destinationText(line);
/// ```
pub fn linkAt(line: []const u8, byte_offset: usize) ?MarkdownLink {
    if (line.len == 0 or byte_offset >= line.len) {
        return null;
    }

    const lower_bound = byte_offset -| (max_label_bytes + uri.max_uri_bytes + delimiter_bytes);
    var index = byte_offset + 1;
    while (index > lower_bound) {
        index -= 1;
        if (line[index] != '[') {
            continue;
        }

        const link = parseAt(line, index) orelse continue;
        return if (byte_offset < link.end) link else null;
    }

    return null;
}

fn parseAt(line: []const u8, start: usize) ?MarkdownLink {
    const label_limit = @min(line.len, start + 2 + max_label_bytes);
    var index = start + 1;
    while (index < label_limit and line[index] != ']') : (index += 1) {
        if (std.ascii.isControl(line[index])) {
            return null;
        }
    }

    if (index >= label_limit or index + 1 >= line.len or line[index] != ']' or line[index + 1] != '(') {
        return null;
    }

    const destination_start = index + 2;
    const destination_limit = @min(line.len, destination_start + uri.max_uri_bytes + 1);
    var depth: usize = 0;
    var cursor = destination_start;
    while (cursor < destination_limit) : (cursor += 1) {
        switch (line[cursor]) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) {
                    break;
                }

                depth -= 1;
            },
            else => |byte| if (uri.isSeparator(byte)) {
                return null;
            },
        }
    }

    if (cursor >= destination_limit) {
        return null;
    }

    const destination = line[destination_start..cursor];
    const scheme = uri.classify(destination) orelse return null;
    return .{ .scheme = scheme, .start = start, .end = cursor + 1, .destination = .{ destination_start, cursor } };
}

test "markdown links span the whole bracketed source under every byte" {
    const line = "see [docs](https://example.com/a_(b)) now";
    const expected = "[docs](https://example.com/a_(b))";
    const start = std.mem.indexOf(u8, line, expected).?;
    for (start..start + expected.len) |offset| {
        const link = linkAt(line, offset).?;
        try std.testing.expectEqual(uri.Scheme.https, link.scheme);
        try std.testing.expectEqual(start, link.start);
        try std.testing.expectEqual(start + expected.len, link.end);
        try std.testing.expectEqualStrings("https://example.com/a_(b)", link.destinationText(line));
    }

    try std.testing.expect(linkAt(line, start - 1) == null);
    try std.testing.expect(linkAt(line, start + expected.len) == null);
    try std.testing.expect(linkAt("", 0) == null);
}

test "markdown links stay literal without a supported terminated destination" {
    const literal = [_][]const u8{ "[x](javascript:alert(1))", "[x](https://e/unterminated", "[x] (https://e)", "[x](https://e y)", "[x]", "[x](<https://e>)", "[a\tb](https://e)" };
    for (literal) |line| {
        try std.testing.expect(linkAt(line, 1) == null);
    }

    try std.testing.expectEqualStrings("https://e", linkAt("[](https://e)", 0).?.destinationText("[](https://e)"));
    const bounded = "[" ++ "a" ** max_label_bytes ++ "](https://e)";
    try std.testing.expectEqualStrings("https://e", linkAt(bounded, 2).?.destinationText(bounded));
    const overlong = "[" ++ "a" ** (max_label_bytes + 1) ++ "](https://e)";
    try std.testing.expect(linkAt(overlong, 2) == null);
}

test "the enclosing markdown link wins on a line with several" {
    const line = "[a](https://a.example) [b](https://b.example)";
    const second = std.mem.indexOf(u8, line, "[b]").?;
    try std.testing.expectEqualStrings("https://a.example", linkAt(line, 1).?.destinationText(line));
    try std.testing.expectEqualStrings("https://b.example", linkAt(line, second + 5).?.destinationText(line));
    try std.testing.expect(linkAt(line, second - 1) == null);
}
