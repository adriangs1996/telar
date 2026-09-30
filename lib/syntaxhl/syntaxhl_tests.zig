const std = @import("std");
const Role = @import("role.zig").Role;
const captures = @import("captures.zig");
const language = @import("language.zig");

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
