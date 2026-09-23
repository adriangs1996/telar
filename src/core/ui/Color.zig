//! One cell color with a canonical representation: every byte is defined and
//! unused channels are zero, so equal colors are equal bytes. That lets a
//! whole `Cell` compare as one 32-byte vector in the diff, the damage scan
//! and the native renderer.
const std = @import("std");

pub const Color = extern struct {
    kind: Kind = .default,
    /// `indexed` stores its palette index in the first channel.
    value: [3]u8 = .{ 0, 0, 0 },

    pub const Kind = enum(u8) {
        default = 0,
        indexed = 1,
        rgb = 2,
    };

    pub const default: Color = .{};

    /// Example: `const accent: Color = .indexed(4);`
    pub fn indexed(palette_index: u8) Color {
        return .{
            .kind = .indexed,
            .value = .{ palette_index, 0, 0 },
        };
    }

    /// Example: `const red: Color = .rgb(.{ 255, 0, 0 });`
    pub fn rgb(channels: [3]u8) Color {
        return .{
            .kind = .rgb,
            .value = channels,
        };
    }

    /// The palette index of an indexed color. Example: `palette[color.index()]`
    pub fn index(self: Color) u8 {
        std.debug.assert(self.kind == .indexed);
        return self.value[0];
    }

    /// The explicit channels of an RGB color. Example: `const value = color.rgbChannels() orelse return;`
    pub fn rgbChannels(self: Color) ?[3]u8 {
        return if (self.kind == .rgb) self.value else null;
    }

    pub fn eql(self: Color, b: Color) bool {
        return @as(u32, @bitCast(self)) == @as(u32, @bitCast(b));
    }

    comptime {
        std.debug.assert(@sizeOf(Color) == 4);
        std.debug.assert(std.meta.hasUniqueRepresentation(Color));
    }
};
