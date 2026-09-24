const syntaxhl = @import("syntaxhl");
const gui_event = @import("../gui_event.zig");
const std = @import("std");
const client = @import("telar-client");
const Store = syntaxhl.Store;
const Service = @import("Service.zig");
const Result = syntaxhl.Result;
const DiffHighlighter = @import("DiffHighlighter.zig");
const limits = @import("limits.zig");

const source = "Updated main.zig\n@@ -0,0 +1 @@\n+fn run(context: *anyopaque) void { _ = context; }\n";

test "new language extensions select bundled grammars and project keyword captures" {
    const files = .{ "main.go", "Review.cs", "Review.java", "review.kt", "Review.swift", "review.c", "review.cpp", "Review.m" };
    const lines = .{ "package main", "public class Review {}", "public class Review {}", "fun run() = 42", "func run() {}", "int run(void) { return 42; }", "int run() { return 42; }", "@implementation Review @end" };
    const keywords = .{ "package", "public", "public", "fun", "func", "return", "return", "@implementation" };
    inline for (files, lines, keywords) |file, line, keyword| {
        const text = "Updated " ++ file ++ "\n@@ -0,0 +1 @@\n+" ++ line ++ "\n";
        var roles: [text.len]syntaxhl.Role = undefined;
        var worker: DiffHighlighter = .{ .allocator = std.testing.allocator, .io = std.testing.io, .text = text, .roles = &roles };
        try worker.run();
        try std.testing.expectEqual(syntaxhl.Role.keyword, roles[std.mem.indexOf(u8, text, keyword).?]);
    }
}

test "Tree-sitter captures map to original diff bytes with independent versions and hunks" {
    const text = "Updated main.ts\n@@ -1,2 +1 @@\n-/* old comment\n-let stale = true; */\n+const fresh = 1;\n@@ -20 +20 @@\n-old\n+const next = 2;\n";
    var roles: [text.len]syntaxhl.Role = undefined;
    var worker: DiffHighlighter = .{ .allocator = std.testing.allocator, .io = std.testing.io, .text = text, .roles = &roles };
    try worker.run();
    try std.testing.expectEqual(syntaxhl.Role.comment, roles[std.mem.indexOf(u8, text, "stale").?]);
    try std.testing.expectEqual(syntaxhl.Role.keyword, roles[std.mem.indexOf(u8, text, "const fresh").?]);
    try std.testing.expectEqual(syntaxhl.Role.keyword, roles[std.mem.indexOf(u8, text, "const next").?]);
    try std.testing.expectEqual(syntaxhl.Role.plain, roles[0]);
    try std.testing.expectEqual(syntaxhl.Role.plain, roles[std.mem.indexOf(u8, text, "+const").?]);
}

test "syntax cache retains tokens without jobs on repaint and owns immutable input" {
    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    var mutable = source.*;
    try std.testing.expect(store.request(&mutable) == null);
    var job = store.nextJob().?;
    @memset(&mutable, 'x');
    try std.testing.expectEqualStrings(source, job.source[0..job.len]);
    var result: Result = .{ .id = job.id };
    var worker: DiffHighlighter = .{ .allocator = std.testing.allocator, .io = std.testing.io, .text = job.source[0..job.len], .roles = result.roles[0..job.len] };
    try worker.run();
    store.finish(&result);
    const parameter = std.mem.indexOf(u8, source, "context").?;
    for (0..3) |_| {
        store.beginFrame();
        const roles = store.request(source).?;
        try std.testing.expectEqual(syntaxhl.Role.parameter, roles[parameter]);
        try std.testing.expect(store.nextJob() == null);
    }
}

test "syntax service adopts only notified results and rolls back closed inbox admission" {
    const service = try std.testing.allocator.create(Service);
    defer std.testing.allocator.destroy(service);
    service.* = .{ .allocator = std.testing.allocator };
    _ = service.store.request(source);
    service.job = service.store.nextJob().?;
    service.execute(std.testing.io);
    try std.testing.expect(service.store.request(source) == null);
    service.notify();
    try std.testing.expect(service.store.request(source) == null);
    service.beginFrame();
    try std.testing.expect(service.store.request(source) != null);
    try std.testing.expect(service.job == null);
    var inbox: gui_event.Inbox = .init(std.testing.io, .{});
    defer inbox.deinit();
    inbox.close();
    _ = service.store.request("Updated other.zig\n+const x = 0;\n");
    service.start(&inbox);
    try std.testing.expect(service.job == null);
    try std.testing.expect(service.store.nextJob() == null);
}

test "syntax worker rejects allocator failure and oversized jobs without publishing partial colors" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var roles: [source.len]syntaxhl.Role = undefined;
    var worker: DiffHighlighter = .{ .allocator = failing.allocator(), .io = std.testing.io, .text = source, .roles = &roles };
    try std.testing.expectError(error.OutOfMemory, worker.run());
    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    const oversized: [syntaxhl.limits.source_bytes + 1]u8 = @splat('x');
    try std.testing.expect(store.request(&oversized) == null);
    try std.testing.expect(store.nextJob() == null);
}
