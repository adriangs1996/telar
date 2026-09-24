//! Borrowed inline Markdown spans. Lookahead is linear-budgeted; unsupported or
//! unfinished syntax stays literal. Block parsing owns fenced-code isolation.
const urlscan = @import("urlscan");
const std = @import("std");
const Span = @import("Span.zig");
const Scope = @import("Scope.zig");
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
pub fn next(self: *Spans) ?Span {
    if (self.code_after) |after| {
        if (self.index < self.code_end) {
            return self.nextTableCode();
        }

        self.index = after;
        self.code_after = null;
    }

    if (self.lookahead_left == null) {
        self.lookahead_left = self.text.len *| 16 +| 64;
    }

    next_scope: while (true) {
        while (self.depth > 0 and self.index >= self.scopes[self.depth - 1].end) {
            self.depth -= 1;
            self.index = self.scopes[self.depth].after;
        }

        if (self.index >= self.text.len) {
            return null;
        }

        const scope = self.context();
        const start = self.index;
        if (self.literal) {
            self.index = self.text.len;
            return .{ .text = self.text[start..] };
        }

        while (self.index < scope.end) {
            const at = self.index;
            if (self.escaped(at, scope.end)) {
                if (at > start) {
                    return self.span(start, at);
                }

                self.index += 2;
                return self.span(at + 1, at + 2);
            }

            if (self.text[at] == '`') {
                if (self.code(.{ at, scope.end })) |value| {
                    if (at > start) {
                        return self.span(start, at);
                    }

                    if (self.table_cell and value.end > value.start) {
                        self.index = value.start;
                        self.code_end = value.end;
                        self.code_after = value.after;
                        return self.nextTableCode();
                    }

                    self.index = value.after;
                    var result = self.span(value.start, value.end);
                    result.kind = .code;
                    return result;
                }

                self.index += 1;
                while (self.index < scope.end and self.text[self.index] == '`') {
                    self.index += 1;
                }

                continue;
            }

            if (scope.destination == null) {
                if (self.bareLink(.{ at, scope.end })) |end| {
                    if (at > start) {
                        return self.span(start, at);
                    }

                    self.index = end;
                    return .{ .text = self.text[at..end], .kind = scope.kind, .destination = self.text[at..end], .link_offset = @intCast(at) };
                }
            }

            var nested: ?Scope = null;
            if (self.depth < self.scopes.len) {
                if (scope.destination == null and self.text[at] == '[' and (at == 0 or self.text[at - 1] != '!')) {
                    nested = self.link(.{ at, scope.end });
                } else if (scope.destination == null and self.text[at] == '<') {
                    if (self.autolink(.{ at, scope.end })) |value| {
                        if (at > start) {
                            return self.span(start, at);
                        }

                        self.index = value.after;
                        return .{ .text = self.text[value.start..value.end], .kind = scope.kind, .destination = value.destination, .link_offset = value.link_offset };
                    }
                } else if (self.text[at] == '*' or self.text[at] == '_') {
                    nested = self.emphasis(.{ at, scope.end });
                }
            }

            if (nested) |value| {
                if (at > start) {
                    return self.span(start, at);
                }

                self.scopes[self.depth] = value;
                self.depth += 1;
                self.index = value.start;
                continue :next_scope;
            }

            self.index += 1;
        }

        return self.span(start, self.index);
    }
}

fn nextTableCode(self: *Spans) Span {
    const start = self.index;
    while (self.index < self.code_end) {
        const at = self.index;
        if (self.text[at] == '\\' and at + 1 < self.code_end and self.text[at + 1] == '|') {
            if (at > start) {
                var result = self.span(start, at);
                result.kind = .code;
                return result;
            }

            self.index += 2;
            var result = self.span(at + 1, at + 2);
            result.kind = .code;
            return result;
        }

        self.index += 1;
    }

    var result = self.span(start, self.index);
    result.kind = .code;
    return result;
}

fn context(self: *const Spans) Scope {
    return if (self.depth == 0) .{ .start = 0, .end = self.text.len, .after = self.text.len } else self.scopes[self.depth - 1];
}

fn span(self: *const Spans, start: usize, end: usize) Span {
    const scope = self.context();
    return .{ .text = self.text[start..end], .kind = scope.kind, .destination = scope.destination, .link_offset = scope.link_offset };
}

fn scan(self: *Spans) bool {
    if (self.lookahead_left.? == 0) {
        return false;
    }

    self.lookahead_left.? -= 1;
    return true;
}

fn escaped(self: *const Spans, at: usize, end: usize) bool {
    return self.text[at] == '\\' and at + 1 < end and std.ascii.isPunctuation(self.text[at + 1]);
}

fn code(self: *Spans, range: [2]usize) ?Scope {
    const start = range[0];
    const limit = range[1];
    var content = start;
    while (content < limit and self.text[content] == '`') : (content += 1) {
        if (!self.scan()) {
            return null;
        }
    }

    const length = content - start;
    var at = content;
    while (at < limit) {
        if (!self.scan()) {
            return null;
        }

        if (self.text[at] != '`') {
            at += 1;
            continue;
        }

        const close = at;
        while (at < limit and self.text[at] == '`') : (at += 1) {
            if (!self.scan()) {
                return null;
            }
        }

        if (at - close == length) {
            var end = close;
            if (end > content + 1 and self.text[content] == ' ' and self.text[end - 1] == ' ' and std.mem.indexOfNone(u8, self.text[content..end], " ") != null) {
                content += 1;
                end -= 1;
            }

            return .{ .start = content, .end = end, .after = at, .kind = .code };
        }
    }

    return null;
}

fn emphasis(self: *Spans, range: [2]usize) ?Scope {
    const start = range[0];
    const limit = range[1];
    const marker = self.text[start];
    const count: usize = if (start + 1 < limit and self.text[start + 1] == marker) 2 else 1;
    const content = start + count;
    if (content >= limit or std.ascii.isWhitespace(self.text[content]) or (marker == '_' and start > 0 and std.ascii.isAlphanumeric(self.text[start - 1]))) {
        return null;
    }

    var at = content;
    while (at + count <= limit) : (at += 1) {
        if (!self.scan()) {
            return null;
        }

        if (self.escaped(at, limit)) {
            at += 1;
            continue;
        }

        if (self.text[at] == '`') {
            if (self.code(.{ at, limit })) |value| {
                at = value.after - 1;
                continue;
            }
        }

        if (self.text[at] == '[' and self.context().destination == null) {
            if (self.link(.{ at, limit })) |value| {
                at = value.after - 1;
                continue;
            }
        }

        if (self.text[at] == marker and (count == 1 or self.text[at + 1] == marker) and at > content and !std.ascii.isWhitespace(self.text[at - 1])) {
            var result = self.context();
            result.start = content;
            result.end = at;
            result.after = at + count;
            result.kind = if (count == 2) .strong else .emphasis;
            return result;
        }
    }

    return null;
}

fn link(self: *Spans, range: [2]usize) ?Scope {
    const start = range[0];
    const limit = range[1];
    if (start > std.math.maxInt(u32)) {
        return null;
    }

    var at = start + 1;
    var depth: usize = 0;
    while (at < limit) : (at += 1) {
        if (!self.scan()) {
            return null;
        }

        if (self.escaped(at, limit)) {
            at += 1;
            continue;
        }

        switch (self.text[at]) {
            '`' => if (self.code(.{ at, limit })) |value| {
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
                if (at + 1 < limit and self.text[at + 1] == '(') {
                    return null;
                }

                depth -= 1;
            },
            '<' => if (self.autolink(.{ at, limit }) != null) {
                return null;
            },
            else => {},
        }
    }

    if (at + 1 >= limit or self.text[at + 1] != '(') {
        return null;
    }

    const label_end = at;
    at = self.whitespace(at + 2, limit) orelse return null;
    const angled = at < limit and self.text[at] == '<';
    const destination_start = at + @intFromBool(angled);
    at = destination_start;
    depth = 0;
    while (at < limit) : (at += 1) {
        if (!self.scan()) {
            return null;
        }

        if (self.escaped(at, limit)) {
            at += 1;
            continue;
        }

        const byte = self.text[at];
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
    at = self.whitespace(at, limit) orelse return null;
    if (at < limit and self.text[at] != ')' and at > before_space) {
        at = self.title(at, limit) orelse return null;
        at = self.whitespace(at, limit) orelse return null;
    }
    if (at >= limit or self.text[at] != ')') {
        return null;
    }

    var result = self.context();
    result.start = start + 1;
    result.end = label_end;
    result.after = at + 1;
    result.destination = self.text[destination_start..destination_end];
    result.link_offset = @intCast(start);
    return result;
}

fn whitespace(self: *Spans, start: usize, limit: usize) ?usize {
    var at = start;
    var lines: u8 = 0;
    while (at < limit and (self.text[at] == ' ' or self.text[at] == '\t' or self.text[at] == '\n' or self.text[at] == '\r')) : (at += 1) {
        if (!self.scan()) {
            return null;
        }

        if (self.text[at] == '\n' or self.text[at] == '\r') {
            lines += 1;
            if (lines > 1) {
                return null;
            }

            if (self.text[at] == '\r' and at + 1 < limit and self.text[at + 1] == '\n') {
                at += 1;
            }
        }
    }

    return at;
}

fn title(self: *Spans, start: usize, limit: usize) ?usize {
    const marker = self.text[start];
    if (marker != '\'' and marker != '"' and marker != '(') {
        return null;
    }

    const close: u8 = if (marker == '(') ')' else marker;
    var at = start + 1;
    while (at < limit) : (at += 1) {
        if (!self.scan()) {
            return null;
        }

        if (self.escaped(at, limit)) {
            at += 1;
            continue;
        }
        if (self.text[at] == close) {
            return at + 1;
        }
        if (marker == '(' and self.text[at] == '(') {
            return null;
        }
        if (self.text[at] == '\n' or self.text[at] == '\r') {
            at = self.whitespace(at, limit) orelse return null;
            at -= 1;
        }
    }

    return null;
}

fn autolink(self: *Spans, range: [2]usize) ?Scope {
    const start = range[0];
    const limit = range[1];
    if (start > std.math.maxInt(u32)) {
        return null;
    }

    const content = start + 1;
    const remaining = self.text[content..limit];
    const scheme: usize = if (std.ascii.startsWithIgnoreCase(remaining, "https://")) 8 else if (std.ascii.startsWithIgnoreCase(remaining, "http://")) 7 else return null;
    var at = content + scheme;
    while (at < limit) : (at += 1) {
        if (!self.scan()) {
            return null;
        }

        const byte = self.text[at];
        if (byte == '>') {
            if (at == content + scheme) {
                return null;
            }

            return .{ .start = content, .end = at, .after = at + 1, .destination = self.text[content..at], .link_offset = @intCast(start) };
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

fn bareLink(self: *Spans, range: [2]usize) ?usize {
    const at = range[0];
    if (!std.ascii.isAlphabetic(self.text[at]) or (at > 0 and (std.ascii.isAlphanumeric(self.text[at - 1]) or self.text[at - 1] == '_' or self.text[at - 1] == '<'))) {
        return null;
    }

    var end = at;
    while (end < range[1] and std.ascii.isAlphabetic(self.text[end])) : (end += 1) {
        if (!self.scan()) {
            return null;
        }
    }

    if (end == range[1] or self.text[end] != ':') {
        return null;
    }

    const cost = @min(range[1] - at, urlscan.max_uri_bytes + 1);
    if (self.lookahead_left.? < cost) {
        return null;
    }

    self.lookahead_left.? -= cost;
    const found = urlscan.extractAt(self.text[at..range[1]], 0) orelse return null;
    return at + found.end;
}
