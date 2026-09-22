const client = @import("telar-client");
const std = @import("std");

pub fn role(name: []const u8) client.SyntaxRole {
    const names = .{ "variable.parameter", "parameter", "variable.member", "property", "constant.builtin", "boolean", "function.builtin", "function", "method", "constructor", "type", "string", "number", "float", "comment", "constant", "keyword", "operator", "punctuation", "module", "namespace", "tag", "attribute", "character", "conditional", "repeat", "exception", "include", "preproc", "storageclass", "variable.builtin" };
    const roles = [_]client.SyntaxRole{ .parameter, .parameter, .property, .property, .builtin_constant, .builtin_constant, .builtin, .func, .func, .type, .type, .string, .number, .number, .comment, .constant, .keyword, .operator, .punctuation, .namespace, .namespace, .func, .property, .string, .keyword, .keyword, .keyword, .keyword, .keyword, .keyword, .builtin_constant };
    inline for (names, roles) |prefix, result| {
        if (std.mem.eql(u8, name, prefix) or (std.mem.startsWith(u8, name, prefix) and name.len > prefix.len and name[prefix.len] == '.')) {
            return result;
        }
    }

    return .plain;
}
