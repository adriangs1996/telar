const std = @import("std");
const Result = @import("Result.zig");
const Role = @import("role.zig").Role;
const Store = @import("Store.zig");
const captures = @import("captures.zig");
const language = @import("language.zig");
const limits = @import("limits.zig");

const source = "fn run(context: *anyopaque) void { _ = context; }\n";

test "captures map whole dotted segments to roles" {
    try std.testing.expectEqual(Role.keyword, captures.role("keyword"));
    try std.testing.expectEqual(Role.keyword, captures.role("keyword.return"));
    try std.testing.expectEqual(Role.parameter, captures.role("variable.parameter"));
    try std.testing.expectEqual(Role.func, captures.role("function.method"));
    try std.testing.expectEqual(Role.plain, captures.role("keywordish"));
    try std.testing.expectEqual(Role.plain, captures.role("variable"));
}

test "language aliases keep C and C++ case-sensitive and ambiguous headers explicit" {
    const paths = .{ "review.csx", "review.kts", "review.h", "review.C", "review.cc", "review.cxx", "review.c++", "review.hh", "review.hpp", "review.hxx", "review.h++", "review.H", "review.mm", "review.unknown" };
    const languages = [_]language.Language{ .c_sharp, .kotlin, .c, .cpp, .cpp, .cpp, .cpp, .cpp, .cpp, .cpp, .cpp, .cpp, .plain, .plain };
    inline for (paths, languages) |path, expected| {
        try std.testing.expectEqual(expected, language.fromPath(path));
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
