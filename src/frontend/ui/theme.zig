const Theme = @This();
const source_namespace = @import("theme_support.zig");
const Palette = @import("Palette.zig");
const Overrides = @import("Overrides.zig");
const std = @import("std");
base: source_namespace.Builtin,
palette: Palette,

pub fn withOverrides(value: Theme, overrides: Overrides) Theme {
    var result = value;
    inline for (std.meta.fields(Overrides)) |field| {
        if (@field(overrides, field.name)) |color| {
            @field(result.palette, field.name) = color;
        }
    }
    return result;
}
