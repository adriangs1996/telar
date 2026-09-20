const std = @import("std");
const client = @import("telar-client");
const Store = @import("Store.zig");
const Service = @import("Service.zig");
const Result = @import("Result.zig");
const DiffHighlighter = @import("DiffHighlighter.zig");
const Inbox = @import("../gui_event.zig").Inbox;
const limits = @import("limits.zig");

const source = "Updated main.zig\n@@ -0,0 +1 @@\n+fn run(context: *anyopaque) void { _ = context; }\n";

test "new language extensions select bundled grammars and project keyword captures" {
    const files = .{ "main.go", "Review.cs", "Review.java", "review.kt", "Review.swift", "review.c", "review.cpp", "Review.m" };
    const lines = .{ "package main", "public class Review {}", "public class Review {}", "fun run() = 42", "func run() {}", "int run(void) { return 42; }", "int run() { return 42; }", "@implementation Review @end" };
    const keywords = .{ "package", "public", "public", "fun", "func", "return", "return", "@implementation" };
    inline for (files, lines, keywords) |file, line, keyword| {
        const text = "Updated " ++ file ++ "\n@@ -0,0 +1 @@\n+" ++ line ++ "\n";
        var roles: [text.len]client.SyntaxRole = undefined;
        var worker: DiffHighlighter = .{ .allocator = std.testing.allocator, .io = std.testing.io, .text = text, .roles = &roles };
        try worker.run();
        try std.testing.expectEqual(client.SyntaxRole.keyword, roles[std.mem.indexOf(u8, text, keyword).?]);
    }
}

test "language aliases keep C and C++ case-sensitive and ambiguous headers explicit" {
    const paths = .{ "review.csx", "review.kts", "review.h", "review.C", "review.cc", "review.cxx", "review.c++", "review.hh", "review.hpp", "review.hxx", "review.h++", "review.H", "review.mm", "review.unknown" };
    const languages = [_]client.syntax_language.Language{ .c_sharp, .kotlin, .c, .cpp, .cpp, .cpp, .cpp, .cpp, .cpp, .cpp, .cpp, .cpp, .plain, .plain };
    inline for (paths, languages) |path, language| {
        try std.testing.expectEqual(language, client.syntax_language.fromPath(path));
    }
}

test "Tree-sitter captures map to original diff bytes with independent versions and hunks" {
    const text = "Updated main.ts\n@@ -1,2 +1 @@\n-/* old comment\n-let stale = true; */\n+const fresh = 1;\n@@ -20 +20 @@\n-old\n+const next = 2;\n";
    var roles: [text.len]client.SyntaxRole = undefined;
    var worker: DiffHighlighter = .{ .allocator = std.testing.allocator, .io = std.testing.io, .text = text, .roles = &roles };
    try worker.run();
    try std.testing.expectEqual(client.SyntaxRole.comment, roles[std.mem.indexOf(u8, text, "stale").?]);
    try std.testing.expectEqual(client.SyntaxRole.keyword, roles[std.mem.indexOf(u8, text, "const fresh").?]);
    try std.testing.expectEqual(client.SyntaxRole.keyword, roles[std.mem.indexOf(u8, text, "const next").?]);
    try std.testing.expectEqual(client.SyntaxRole.plain, roles[0]);
    try std.testing.expectEqual(client.SyntaxRole.plain, roles[std.mem.indexOf(u8, text, "+const").?]);
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
        try std.testing.expectEqual(client.SyntaxRole.parameter, roles[parameter]);
        try std.testing.expect(store.nextJob() == null);
    }
}

test "syntax cache ignores stale completions and does not retry failed immutable content" {
    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    _ = store.request(source);
    const old = store.nextJob().?;
    var buffer: [32]u8 = undefined;
    for (0..limits.cache_entries) |index| {
        store.beginFrame();
        const text = try std.fmt.bufPrint(&buffer, "replacement {d}", .{index});
        _ = store.request(text);
    }

    var result: Result = .{ .id = old.id };
    @memset(&result.roles, .keyword);
    store.finish(&result);
    const replacement = try std.fmt.bufPrint(&buffer, "replacement {d}", .{limits.cache_entries - 1});
    try std.testing.expect(store.request(replacement) == null);
    const current = store.nextJob().?;
    result.id = current.id;
    result.status = error.SyntaxUnavailable;
    store.finish(&result);
    try std.testing.expect(store.request(replacement) == null);
    try std.testing.expect(store.nextJob() == null);
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
    var inbox: Inbox = .init(std.testing.io, .{});
    defer inbox.deinit();
    inbox.close();
    _ = service.store.request("Updated other.zig\n+const x = 0;\n");
    service.start(&inbox);
    try std.testing.expect(service.job == null);
    try std.testing.expect(service.store.nextJob() == null);
}

test "syntax worker rejects allocator failure and oversized jobs without publishing partial colors" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var roles: [source.len]client.SyntaxRole = undefined;
    var worker: DiffHighlighter = .{ .allocator = failing.allocator(), .io = std.testing.io, .text = source, .roles = &roles };
    try std.testing.expectError(error.OutOfMemory, worker.run());
    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    const oversized: [limits.source_bytes + 1]u8 = @splat('x');
    try std.testing.expect(store.request(&oversized) == null);
    try std.testing.expect(store.nextJob() == null);
}
