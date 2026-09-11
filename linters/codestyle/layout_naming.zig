const std = @import("std");

/// Recognizes an ASCII PascalCase type filename stem. Example: `pascalCase("Pane")`.
pub fn pascalCase(stem: []const u8) bool {
    if (stem.len == 0 or !std.ascii.isUpper(stem[0])) {
        return false;
    }

    for (stem[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) {
            return false;
        }
    }

    return true;
}

/// Recognizes a snake_case namespace filename stem. Example: `snakeCase("pane_input")`.
pub fn snakeCase(stem: []const u8) bool {
    if (stem.len == 0 or !std.ascii.isLower(stem[0]) or stem[stem.len - 1] == '_') {
        return false;
    }

    var separator = false;
    for (stem[1..]) |byte| {
        if (byte == '_') {
            if (separator) {
                return false;
            }
        } else if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte)) {
            return false;
        }

        separator = byte == '_';
    }

    return true;
}

test "type and namespace filename categories do not overlap" {
    for ([_][]const u8{ "Pane", "GenericRouter", "COORD", "Rgb8" }) |stem| {
        try std.testing.expect(pascalCase(stem));
        try std.testing.expect(!snakeCase(stem));
    }

    for ([_][]const u8{ "pane_input", "layout", "fuzz_schema_client", "h2" }) |stem| {
        try std.testing.expect(snakeCase(stem));
        try std.testing.expect(!pascalCase(stem));
    }

    for ([_][]const u8{ "", "_private", "two__words", "trailing_", "Some_Type", "9Type", "with-dashes" }) |stem| {
        try std.testing.expect(!snakeCase(stem));
        try std.testing.expect(!pascalCase(stem));
    }
}
