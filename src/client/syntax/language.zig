const std = @import("std");

pub const Language = enum { plain, zig, ruby, python, javascript, typescript, tsx, json, rust, bash, go, c_sharp, java, kotlin, swift, c, cpp, objc };

pub fn fromPath(path: []const u8) Language {
    const extension = std.fs.path.extension(path);
    const extensions = .{ .zig, .rb, .py, .js, .mjs, .cjs, .jsx, .ts, .tsx, .json, .jsonc, .rs, .sh, .bash, .go, .cs, .csx, .java, .kt, .kts, .swift, .c, .h, .cc, .cpp, .cxx, .@"c++", .C, .hh, .hpp, .hxx, .@"h++", .H, .m };
    const languages = [_]Language{ .zig, .ruby, .python, .javascript, .javascript, .javascript, .javascript, .typescript, .tsx, .json, .json, .rust, .bash, .bash, .go, .c_sharp, .c_sharp, .java, .kotlin, .kotlin, .swift, .c, .c, .cpp, .cpp, .cpp, .cpp, .cpp, .cpp, .cpp, .cpp, .cpp, .cpp, .objc };
    inline for (extensions, languages) |suffix, language| {
        if (std.mem.eql(u8, extension, "." ++ @tagName(suffix))) {
            return language;
        }
    }

    return .plain;
}
