//! What an adapter draws around a configured panel's components: its name,
//! title, mark and width. Copied from configuration into the presentation.
const bar_text = @import("bar_text.zig");
const core = @import("telar-core");
const Mark = @import("Mark.zig").Mark;
const std = @import("std");
const ui_icons = @import("../layout/icons.zig");
const PanelHeading = @This();

pub const max_name_bytes = 32;
/// About 40 characters of non-Latin text; a configured title longer than
/// this is cut at a character.
pub const max_title_bytes = 128;
pub const title_limit = core.Limit.declare("panels.title_bytes", "title bytes", max_title_bytes);
pub const default_width: u16 = 420;
pub const min_width: u16 = 240;
pub const max_width: u16 = 720;

name_bytes: [max_name_bytes]u8 = @splat(0),
name_len: u8 = 0,
title_bytes: [max_title_bytes]u8 = @splat(0),
title_len: u8 = 0,
mark: ?Mark = null,
icon: ?ui_icons.Icon = null,
/// Logical pixels in the GUI; the TUI derives its columns from it.
width: u16 = default_width,

pub fn name(self: *const PanelHeading) []const u8 {
    return self.name_bytes[0..self.name_len];
}

pub fn title(self: *const PanelHeading) []const u8 {
    return self.title_bytes[0..self.title_len];
}

/// Example: `try heading.setName("claude");`
pub fn setName(self: *PanelHeading, value: []const u8) !void {
    if (value.len == 0 or value.len > max_name_bytes) {
        return error.InvalidPanelName;
    }
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') {
            return error.InvalidPanelName;
        }
    }

    @memcpy(self.name_bytes[0..value.len], value);
    self.name_len = @intCast(value.len);
}

/// Example: `try heading.setTitle("Claude usage");`
pub fn setTitle(self: *PanelHeading, value: []const u8) !void {
    if (value.len > max_title_bytes or !bar_text.valid(value)) {
        return error.InvalidPanelTitle;
    }

    @memcpy(self.title_bytes[0..value.len], value);
    self.title_len = @intCast(value.len);
}
