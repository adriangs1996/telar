//! Borrowed inline Markdown spans. Lookahead is linear-budgeted; unsupported or
//! unfinished syntax stays literal. Block parsing owns fenced-code isolation.
const std = @import("std");
const Span = @import("MessageSpan.zig");
const Scope = @import("MessageSpanScope.zig");
const Spans = @This();

text: []const u8,
index: usize = 0,
literal: bool = false,
table_cell: bool = false,
code_end: usize = 0,
code_after: ?usize = null,
scopes: [8]Scope = undefined,
depth: usize = 0,
lookahead_left: ?usize = null,

/// Yields styled labels with the original destination and link source offset.
/// Reference links are left literal. Exhausted lookahead also stays literal.
/// Example: `while (spans.next()) |span| try paintSpan(span);`
pub fn next(spans: *Spans) ?Span {
    if (spans.code_after) |after| {
        if (spans.index < spans.code_end) {
            return spans.nextTableCode();
        }

        spans.index = after;
        spans.code_after = null;
    }

    if (spans.lookahead_left == null) {
        spans.lookahead_left = spans.text.len *| 16 +| 64;
    }

    next_scope: while (true) {
        while (spans.depth > 0 and spans.index >= spans.scopes[spans.depth - 1].end) {
            spans.depth -= 1;
            spans.index = spans.scopes[spans.depth].after;
        }

        if (spans.index >= spans.text.len) {
            return null;
        }

        const scope = spans.context();
        const start = spans.index;
        if (spans.literal) {
            spans.index = spans.text.len;
            return .{ .text = spans.text[start..] };
        }

        while (spans.index < scope.end) {
            const at = spans.index;
            if (spans.escaped(at, scope.end)) {
                if (at > start) {
                    return spans.span(start, at);
                }

                spans.index += 2;
                return spans.span(at + 1, at + 2);
            }

            if (spans.text[at] == '`') {
                if (spans.code(.{ at, scope.end })) |value| {
                    if (at > start) {
                        return spans.span(start, at);
                    }

                    if (spans.table_cell and value.end > value.start) {
                        spans.index = value.start;
                        spans.code_end = value.end;
                        spans.code_after = value.after;
                        return spans.nextTableCode();
                    }

                    spans.index = value.after;
                    var result = spans.span(value.start, value.end);
                    result.kind = .code;
                    return result;
                }

                spans.index += 1;
                while (spans.index < scope.end and spans.text[spans.index] == '`') {
                    spans.index += 1;
                }

                continue;
            }

            var nested: ?Scope = null;
            if (spans.depth < spans.scopes.len) {
                if (scope.destination == null and spans.text[at] == '[' and (at == 0 or spans.text[at - 1] != '!')) {
                    nested = spans.link(.{ at, scope.end });
                } else if (scope.destination == null and spans.text[at] == '<') {
                    if (spans.autolink(.{ at, scope.end })) |value| {
                        if (at > start) {
                            return spans.span(start, at);
                        }

                        spans.index = value.after;
                        return .{ .text = spans.text[value.start..value.end], .kind = scope.kind, .destination = value.destination, .link_offset = value.link_offset };
                    }
                } else if (spans.text[at] == '*' or spans.text[at] == '_') {
                    nested = spans.emphasis(.{ at, scope.end });
                }
            }

            if (nested) |value| {
                if (at > start) {
                    return spans.span(start, at);
                }

                spans.scopes[spans.depth] = value;
                spans.depth += 1;
                spans.index = value.start;
                continue :next_scope;
            }

            spans.index += 1;
        }

        return spans.span(start, spans.index);
    }
}

fn nextTableCode(spans: *Spans) Span {
    const start = spans.index;
    while (spans.index < spans.code_end) {
        const at = spans.index;
        if (spans.text[at] == '\\' and at + 1 < spans.code_end and spans.text[at + 1] == '|') {
            if (at > start) {
                var result = spans.span(start, at);
                result.kind = .code;
                return result;
            }

            spans.index += 2;
            var result = spans.span(at + 1, at + 2);
            result.kind = .code;
            return result;
        }

        spans.index += 1;
    }

    var result = spans.span(start, spans.index);
    result.kind = .code;
    return result;
}

fn context(spans: *const Spans) Scope {
    return if (spans.depth == 0) .{ .start = 0, .end = spans.text.len, .after = spans.text.len } else spans.scopes[spans.depth - 1];
}

fn span(spans: *const Spans, start: usize, end: usize) Span {
    const scope = spans.context();
    return .{ .text = spans.text[start..end], .kind = scope.kind, .destination = scope.destination, .link_offset = scope.link_offset };
}

fn scan(spans: *Spans) bool {
    if (spans.lookahead_left.? == 0) {
        return false;
    }

    spans.lookahead_left.? -= 1;
    return true;
}

fn escaped(spans: *const Spans, at: usize, end: usize) bool {
    return spans.text[at] == '\\' and at + 1 < end and std.ascii.isPunctuation(spans.text[at + 1]);
}

fn code(spans: *Spans, range: [2]usize) ?Scope {
    const start = range[0];
    const limit = range[1];
    var content = start;
    while (content < limit and spans.text[content] == '`') : (content += 1) {
        if (!spans.scan()) {
            return null;
        }
    }

    const length = content - start;
    var at = content;
    while (at < limit) {
        if (!spans.scan()) {
            return null;
        }

        if (spans.text[at] != '`') {
            at += 1;
            continue;
        }

        const close = at;
        while (at < limit and spans.text[at] == '`') : (at += 1) {
            if (!spans.scan()) {
                return null;
            }
        }

        if (at - close == length) {
            var end = close;
            if (end > content + 1 and spans.text[content] == ' ' and spans.text[end - 1] == ' ' and std.mem.indexOfNone(u8, spans.text[content..end], " ") != null) {
                content += 1;
                end -= 1;
            }

            return .{ .start = content, .end = end, .after = at, .kind = .code };
        }
    }

    return null;
}

fn emphasis(spans: *Spans, range: [2]usize) ?Scope {
    const start = range[0];
    const limit = range[1];
    const marker = spans.text[start];
    const count: usize = if (start + 1 < limit and spans.text[start + 1] == marker) 2 else 1;
    const content = start + count;
    if (content >= limit or std.ascii.isWhitespace(spans.text[content]) or (marker == '_' and start > 0 and std.ascii.isAlphanumeric(spans.text[start - 1]))) {
        return null;
    }

    var at = content;
    while (at + count <= limit) : (at += 1) {
        if (!spans.scan()) {
            return null;
        }

        if (spans.escaped(at, limit)) {
            at += 1;
            continue;
        }

        if (spans.text[at] == '`') {
            if (spans.code(.{ at, limit })) |value| {
                at = value.after - 1;
                continue;
            }
        }

        if (spans.text[at] == '[' and spans.context().destination == null) {
            if (spans.link(.{ at, limit })) |value| {
                at = value.after - 1;
                continue;
            }
        }

        if (spans.text[at] == marker and (count == 1 or spans.text[at + 1] == marker) and at > content and !std.ascii.isWhitespace(spans.text[at - 1])) {
            var result = spans.context();
            result.start = content;
            result.end = at;
            result.after = at + count;
            result.kind = if (count == 2) .strong else .emphasis;
            return result;
        }
    }

    return null;
}

fn link(spans: *Spans, range: [2]usize) ?Scope {
    const start = range[0];
    const limit = range[1];
    if (start > std.math.maxInt(u32)) {
        return null;
    }

    var at = start + 1;
    var depth: usize = 0;
    while (at < limit) : (at += 1) {
        if (!spans.scan()) {
            return null;
        }

        if (spans.escaped(at, limit)) {
            at += 1;
            continue;
        }

        switch (spans.text[at]) {
            '`' => if (spans.code(.{ at, limit })) |value| {
                at = value.after - 1;
            },
            '[' => {
                depth += 1;
                if (depth > 32) {
                    return null;
                }
            },
            ']' => {
                if (depth == 0) {
                    break;
                }

                // Nested inline links cannot give the same label two targets.
                if (at + 1 < limit and spans.text[at + 1] == '(') {
                    return null;
                }

                depth -= 1;
            },
            '<' => if (spans.autolink(.{ at, limit }) != null) {
                return null;
            },
            else => {},
        }
    }

    if (at + 1 >= limit or spans.text[at + 1] != '(') {
        return null;
    }

    const label_end = at;
    at = spans.whitespace(at + 2, limit) orelse return null;
    const angled = at < limit and spans.text[at] == '<';
    const destination_start = at + @intFromBool(angled);
    at = destination_start;
    depth = 0;
    while (at < limit) : (at += 1) {
        if (!spans.scan()) {
            return null;
        }

        if (spans.escaped(at, limit)) {
            at += 1;
            continue;
        }

        const byte = spans.text[at];
        if (angled) {
            if (byte == '>') {
                break;
            }
            if (byte == '<' or byte == '\n' or byte == '\r' or byte == 0) {
                return null;
            }
        } else {
            if ((byte == ')' and depth == 0) or std.ascii.isWhitespace(byte)) {
                break;
            }
            if (std.ascii.isControl(byte)) {
                return null;
            }
            if (byte == '(') {
                depth += 1;
                if (depth > 32) {
                    return null;
                }
            } else if (byte == ')') {
                depth -= 1;
            }
        }
    }

    if (at >= limit or depth != 0) {
        return null;
    }

    const destination_end = at;
    at += @intFromBool(angled);
    const before_space = at;
    at = spans.whitespace(at, limit) orelse return null;
    if (at < limit and spans.text[at] != ')' and at > before_space) {
        at = spans.title(at, limit) orelse return null;
        at = spans.whitespace(at, limit) orelse return null;
    }
    if (at >= limit or spans.text[at] != ')') {
        return null;
    }

    var result = spans.context();
    result.start = start + 1;
    result.end = label_end;
    result.after = at + 1;
    result.destination = spans.text[destination_start..destination_end];
    result.link_offset = @intCast(start);
    return result;
}

fn whitespace(spans: *Spans, start: usize, limit: usize) ?usize {
    var at = start;
    var lines: u8 = 0;
    while (at < limit and (spans.text[at] == ' ' or spans.text[at] == '\t' or spans.text[at] == '\n' or spans.text[at] == '\r')) : (at += 1) {
        if (!spans.scan()) {
            return null;
        }

        if (spans.text[at] == '\n' or spans.text[at] == '\r') {
            lines += 1;
            if (lines > 1) {
                return null;
            }

            if (spans.text[at] == '\r' and at + 1 < limit and spans.text[at + 1] == '\n') {
                at += 1;
            }
        }
    }

    return at;
}

fn title(spans: *Spans, start: usize, limit: usize) ?usize {
    const marker = spans.text[start];
    if (marker != '\'' and marker != '"' and marker != '(') {
        return null;
    }

    const close: u8 = if (marker == '(') ')' else marker;
    var at = start + 1;
    while (at < limit) : (at += 1) {
        if (!spans.scan()) {
            return null;
        }

        if (spans.escaped(at, limit)) {
            at += 1;
            continue;
        }
        if (spans.text[at] == close) {
            return at + 1;
        }
        if (marker == '(' and spans.text[at] == '(') {
            return null;
        }
        if (spans.text[at] == '\n' or spans.text[at] == '\r') {
            at = spans.whitespace(at, limit) orelse return null;
            at -= 1;
        }
    }

    return null;
}

fn autolink(spans: *Spans, range: [2]usize) ?Scope {
    const start = range[0];
    const limit = range[1];
    if (start > std.math.maxInt(u32)) {
        return null;
    }

    const content = start + 1;
    const remaining = spans.text[content..limit];
    const scheme: usize = if (std.ascii.startsWithIgnoreCase(remaining, "https://")) 8 else if (std.ascii.startsWithIgnoreCase(remaining, "http://")) 7 else return null;
    var at = content + scheme;
    while (at < limit) : (at += 1) {
        if (!spans.scan()) {
            return null;
        }

        const byte = spans.text[at];
        if (byte == '>') {
            if (at == content + scheme) {
                return null;
            }

            return .{ .start = content, .end = at, .after = at + 1, .destination = spans.text[content..at], .link_offset = @intCast(start) };
        }
        if (byte == '<' or byte <= ' ' or byte == 127) {
            return null;
        }
    }

    return null;
}

test "inline Markdown removes only complete presentation delimiters" {
    var spans: Spans = .{ .text = "Use **strong text** and `code` or *emphasis*; **stream" };
    try std.testing.expectEqualStrings("Use ", spans.next().?.text);
    try std.testing.expectEqual(.strong, spans.next().?.kind);
    try std.testing.expectEqualStrings(" and ", spans.next().?.text);
    try std.testing.expectEqual(.code, spans.next().?.kind);
    _ = spans.next();
    try std.testing.expectEqual(.emphasis, spans.next().?.kind);
    try std.testing.expectEqualStrings("; **stream", spans.next().?.text);
    try std.testing.expect(spans.next() == null);
}

test {
    _ = @import("message_spans_test.zig");
    _ = @import("MessageLinkDestination.zig");
}
