const theme_support = @import("theme_support.zig");
const Palette = @import("Palette.zig");
const Overrides = @import("Overrides.zig");
const std = @import("std");
const Color = @import("telar-core").Color;
const SyntaxRole = @import("../syntax/role.zig").Role;
const SyntaxStyle = @import("SyntaxStyle.zig");
const Theme = @This();

pub const SyntaxStyles = std.EnumArray(SyntaxRole, ?SyntaxStyle);

base: theme_support.Builtin,
palette: Palette,
terminal: @import("TerminalTheme.zig") = .{},
syntax_styles: SyntaxStyles = .initFill(null),

/// Resolves syntax roles at paint time, including live palette overrides.
/// Example: `const ink = theme.syntax(.keyword);`
pub fn syntax(self: Theme, role: SyntaxRole) Color {
    return self.syntaxStyle(role).color;
}

/// Explicit syntax styles override chrome-derived defaults without changing UI ink.
/// Example: `const style = theme.syntaxStyle(.parameter);`
pub fn syntaxStyle(self: Theme, role: SyntaxRole) SyntaxStyle {
    return self.syntax_styles.get(role) orelse .{ .color = switch (role) {
        .plain => self.palette.text,
        .keyword => self.palette.mauve,
        .string => self.palette.green,
        .number, .constant, .builtin_constant => self.palette.peach,
        .comment => self.palette.subtext0,
        .builtin => self.palette.teal,
        .func => self.palette.blue,
        .type => self.palette.yellow,
        .parameter, .property => self.palette.text,
        .namespace => self.palette.mauve,
        .operator, .punctuation => self.palette.subtext0,
    } };
}

pub fn withOverrides(value: Theme, overrides: Overrides) Theme {
    var result = value;
    inline for (std.meta.fields(Overrides)) |field| {
        if (@field(overrides, field.name)) |color| {
            @field(result.palette, field.name) = color;
        }
    }
    return result;
}
