const Menu = @This();

selector: ?@import("ComposerSelector.zig") = null,
attachment_generation: u64 = 0,
generation: u64 = 0,
anchor: @import("../../render/Rect.zig") = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
selected: u8 = 0,
first: u8 = 0,

pub const visible_rows = 8;

/// Keeps keyboard selection in the bounded visible page. Example: `menu.reveal(12);`
pub fn reveal(self: *Menu, count: u8) void {
    self.selected = @min(self.selected, count -| 1);
    if (self.selected < self.first) {
        self.first = self.selected;
    } else if (self.selected >= @as(u16, self.first) + visible_rows) {
        self.first = self.selected - visible_rows + 1;
    }

    self.first = @min(self.first, count -| visible_rows);
}
