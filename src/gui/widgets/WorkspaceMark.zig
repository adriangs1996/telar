//! A workspace's mark in navigation: its landed favicon, else a tile tinted
//! with a hue its name picks from the palette and holding its initial, else
//! the folder glyph in the caller's ink. The top-bar indicators and the rail
//! draw the same mark, so a workspace looks alike wherever it is picked and
//! two workspaces without favicons still differ.
const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const data = @import("model");
const std = @import("std");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const label_size = @import("label_size.zig");
const AgentCard = @import("AgentCard.zig");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Label = @import("Label.zig");
const WorkspaceMark = @This();

/// Opacity of a favicon whose workspace is neither selected nor hovered.
pub const muted_alpha: f32 = 0.7;

const tile_radius: f32 = 5;
const tile_alpha: f32 = 0.22;
const tile_emphasized_alpha: f32 = 0.3;
const letter_muted_alpha: f32 = 0.8;

context: *const Context,
workspace: core.WorkspaceId,
bounds: Rect,
ink: cellgrid.Color,
emphasized: bool,
size: label_size.Size = .small,
/// The workspace's name; without a favicon its initial stands in.
name: []const u8 = "",

/// Example: `try (WorkspaceMark{ .context = context, .workspace = id, .bounds = icon, .ink = ink, .emphasized = selected }).draw(canvas);`
pub fn draw(self: WorkspaceMark, canvas: *Canvas) !void {
    const sprite = if (self.context.favicons) |favicons| favicons.sprite(.{ .workspace = self.workspace }) else null;
    if (sprite) |value| {
        try canvas.spriteTintedAt(self.bounds, .{
            .sprite = value,
            .alpha = if (self.emphasized) 1 else muted_alpha,
        });
        return;
    }

    var storage: [4]u8 = undefined;
    if (initial(&storage, self.name)) |letter| {
        const hue = tileHue(canvas.theme.palette, self.name);
        try canvas.fillRoundedAt(self.bounds, .{
            .radius = canvas.chrome.px(tile_radius),
            .color = hue,
            .alpha = if (self.emphasized) tile_emphasized_alpha else tile_alpha,
        });
        const label: Label = .{ .text = letter, .color = hue, .alpha = if (self.emphasized) 1 else letter_muted_alpha, .bold = true, .face = .sans, .size = self.size };
        const width = @min(self.bounds.width, try canvas.measure(label));
        _ = try canvas.textAt(.{ .x = self.bounds.x + (self.bounds.width - width) / 2, .y = self.bounds.y, .width = width, .height = self.bounds.height }, label);
        return;
    }

    try canvas.iconAt(self.bounds, .{
        .text = AgentCard.project_glyph,
        .color = self.ink,
        .face = .sans,
        .size = self.size,
    });
}

// A hue from the palette's accents chosen by the name alone, so a workspace
// keeps its colour across sessions and themes keep their own tones.
fn tileHue(palette: data.Palette, name: []const u8) cellgrid.Color {
    const hues = [_]cellgrid.Color{ palette.red, palette.peach, palette.yellow, palette.green, palette.teal, palette.blue, palette.mauve };
    return hues[std.hash.Fnv1a_32.hash(name) % hues.len];
}

// The name's first code point, upper-cased when it is ASCII; null for an
// empty or malformed name.
fn initial(storage: *[4]u8, name: []const u8) ?[]const u8 {
    if (name.len == 0) {
        return null;
    }

    const length = std.unicode.utf8ByteSequenceLength(name[0]) catch return null;
    if (length > name.len) {
        return null;
    }

    _ = std.unicode.utf8Decode(name[0..length]) catch return null;
    @memcpy(storage[0..length], name[0..length]);
    storage[0] = std.ascii.toUpper(storage[0]);
    return storage[0..length];
}

test "a name always picks the same tile hue" {
    const palette = data.theme_support.default_theme.palette;
    try std.testing.expectEqual(tileHue(palette, "telar"), tileHue(palette, "telar"));
}

test "the initial is the first code point, upper-cased when ASCII" {
    var storage: [4]u8 = undefined;
    try std.testing.expectEqualStrings("R", initial(&storage, "replay-web").?);
    try std.testing.expectEqualStrings("\u{00e9}", initial(&storage, "\u{00e9}clair").?);
    try std.testing.expect(initial(&storage, "") == null);
    try std.testing.expect(initial(&storage, &[_]u8{0xff}) == null);
}
