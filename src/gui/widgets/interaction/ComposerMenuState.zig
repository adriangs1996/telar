const Menu = @This();

selector: ?@import("ComposerSelector.zig") = null,
attachment_generation: u64 = 0,
generation: u64 = 0,
anchor: @import("../../render/Rect.zig") = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
selected: u8 = 0,
first: u8 = 0,

pub const visible_rows = 8;

/// Keeps keyboard selection in the bounded visible page. Example: `menu.reveal(12);`
pub fn reveal(menu: *Menu, count: u8) void {
    menu.selected = @min(menu.selected, count -| 1);
    if (menu.selected < menu.first) {
        menu.first = menu.selected;
    } else if (menu.selected >= @as(u16, menu.first) + visible_rows) {
        menu.first = menu.selected - visible_rows + 1;
    }

    menu.first = @min(menu.first, count -| visible_rows);
}
