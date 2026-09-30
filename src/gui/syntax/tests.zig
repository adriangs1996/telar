const syntaxhl = @import("syntaxhl");
const std = @import("std");
const DiffHighlighter = @import("DiffHighlighter.zig");
const limits = @import("limits.zig");

const source = "Updated main.zig\n@@ -0,0 +1 @@\n+fn run(context: *anyopaque) void { _ = context; }\n";
const hunk = "@@ -0,0 +1 @@\n+const value = 1;\n";

test "new language extensions select bundled grammars and project keyword captures" {
    const files = .{ "main.go", "Review.cs", "Review.java", "review.kt", "Review.swift", "review.c", "review.cpp", "Review.m" };
    const lines = .{ "package main", "public class Review {}", "public class Review {}", "fun run() = 42", "func run() {}", "int run(void) { return 42; }", "int run() { return 42; }", "@implementation Review @end" };
    const keywords = .{ "package", "public", "public", "fun", "func", "return", "return", "@implementation" };
    inline for (files, lines, keywords) |file, line, keyword| {
        const text = "Updated " ++ file ++ "\n@@ -0,0 +1 @@\n+" ++ line ++ "\n";
        var roles: [text.len]syntaxhl.Role = undefined;
        var worker: DiffHighlighter = .{ .allocator = std.testing.allocator, .io = std.testing.io, .text = text, .roles = &roles };
        try std.testing.expect((try worker.run()) == null);
        try std.testing.expectEqual(syntaxhl.Role.keyword, roles[std.mem.indexOf(u8, text, keyword).?]);
    }
}

test "Tree-sitter captures map to original diff bytes with independent versions and hunks" {
    const text = "Updated main.ts\n@@ -1,2 +1 @@\n-/* old comment\n-let stale = true; */\n+const fresh = 1;\n@@ -20 +20 @@\n-old\n+const next = 2;\n";
    var roles: [text.len]syntaxhl.Role = undefined;
    var worker: DiffHighlighter = .{ .allocator = std.testing.allocator, .io = std.testing.io, .text = text, .roles = &roles };
    try std.testing.expect((try worker.run()) == null);
    try std.testing.expectEqual(syntaxhl.Role.comment, roles[std.mem.indexOf(u8, text, "stale").?]);
    try std.testing.expectEqual(syntaxhl.Role.keyword, roles[std.mem.indexOf(u8, text, "const fresh").?]);
    try std.testing.expectEqual(syntaxhl.Role.keyword, roles[std.mem.indexOf(u8, text, "const next").?]);
    try std.testing.expectEqual(syntaxhl.Role.plain, roles[0]);
    try std.testing.expectEqual(syntaxhl.Role.plain, roles[std.mem.indexOf(u8, text, "+const").?]);
}

test "syntax worker returns allocator failure for its caller to show plain text" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var roles: [source.len]syntaxhl.Role = undefined;
    var worker: DiffHighlighter = .{ .allocator = failing.allocator(), .io = std.testing.io, .text = source, .roles = &roles };
    try std.testing.expectError(error.OutOfMemory, worker.run());
}

test "syntax worker highlights every fragment up to its limit and keeps them past it" {
    const at_limit = try hunks(limits.fragments);
    defer std.testing.allocator.free(at_limit);

    const full = try std.testing.allocator.alloc(syntaxhl.Role, at_limit.len);
    defer std.testing.allocator.free(full);

    var worker: DiffHighlighter = .{ .allocator = std.testing.allocator, .io = std.testing.io, .text = at_limit, .roles = full, .job_ms = std.math.maxInt(i64) };
    try std.testing.expect((try worker.run()) == null);
    try std.testing.expectEqual(syntaxhl.Role.keyword, full[std.mem.lastIndexOf(u8, at_limit, "const").?]);

    const past_limit = try hunks(limits.fragments + 1);
    defer std.testing.allocator.free(past_limit);

    const partial = try std.testing.allocator.alloc(syntaxhl.Role, past_limit.len);
    defer std.testing.allocator.free(partial);

    worker = .{ .allocator = std.testing.allocator, .io = std.testing.io, .text = past_limit, .roles = partial, .job_ms = std.math.maxInt(i64) };
    const reach = (try worker.run()).?;
    try std.testing.expectEqualStrings("syntax.job_fragments", reach.limit.name);
    try std.testing.expectEqual(@as(u64, limits.fragments), reach.limit.value);

    const last = std.mem.lastIndexOf(u8, past_limit, "const").?;
    const kept = std.mem.lastIndexOf(u8, past_limit[0..last], "const").?;
    try std.testing.expectEqual(syntaxhl.Role.keyword, partial[kept]);
    try std.testing.expectEqual(syntaxhl.Role.plain, partial[last]);
}

test "syntax worker past its time budget keeps the fragments it highlighted" {
    const text = try hunks(3);
    defer std.testing.allocator.free(text);

    const roles = try std.testing.allocator.alloc(syntaxhl.Role, text.len);
    defer std.testing.allocator.free(roles);

    var worker: DiffHighlighter = .{ .allocator = std.testing.allocator, .io = std.testing.io, .text = text, .roles = roles, .job_ms = 0 };
    const reach = (try worker.run()).?;
    try std.testing.expectEqualStrings("syntax.job_ms", reach.limit.name);
    try std.testing.expectEqual(@as(u64, limits.job_ms), reach.limit.value);

    const first = std.mem.indexOf(u8, text, "const").?;
    const second = std.mem.indexOfPos(u8, text, first + 1, "const").?;
    try std.testing.expectEqual(syntaxhl.Role.keyword, roles[first]);
    try std.testing.expectEqual(syntaxhl.Role.plain, roles[second]);
    try std.testing.expectEqual(syntaxhl.Role.plain, roles[std.mem.lastIndexOf(u8, text, "const").?]);
}

test "syntax worker leaves a source past its byte limit plain and names the limit" {
    const text = try std.testing.allocator.alloc(u8, syntaxhl.limits.source_bytes + 1);
    defer std.testing.allocator.free(text);

    @memset(text, 'x');
    const roles = try std.testing.allocator.alloc(syntaxhl.Role, text.len);
    defer std.testing.allocator.free(roles);

    var worker: DiffHighlighter = .{ .allocator = std.testing.allocator, .io = std.testing.io, .text = text[0..syntaxhl.limits.source_bytes], .roles = roles[0..syntaxhl.limits.source_bytes] };
    try std.testing.expect((try worker.run()) == null);

    @memset(roles, .keyword);
    worker = .{ .allocator = std.testing.allocator, .io = std.testing.io, .text = text, .roles = roles };
    const reach = (try worker.run()).?;
    try std.testing.expectEqualStrings("syntax.source_bytes", reach.limit.name);
    try std.testing.expectEqual(@as(?u64, text.len), reach.requested);
    try std.testing.expect(std.mem.allEqual(syntaxhl.Role, roles, .plain));
}

// A Zig diff of `count` hunks that each add one line: one fragment per hunk.
fn hunks(count: usize) ![]u8 {
    const header = "Updated main.zig\n";
    const text = try std.testing.allocator.alloc(u8, header.len + count * hunk.len);
    @memcpy(text[0..header.len], header);
    for (0..count) |index| {
        @memcpy(text[header.len + index * hunk.len ..][0..hunk.len], hunk);
    }

    return text;
}
