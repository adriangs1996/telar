//! Kitty Unicode placeholders: cells holding U+10EEEE that show fragments of
//! an image a virtual placement (`U=1`) sizes. Decodes one cell, and resolves
//! the fragment a run of cells shows the way Ghostty's
//! `graphics_unicode.zig` does: the image is fitted into the placement's grid
//! keeping its aspect ratio and centered, and each run draws its share.
//! Nothing here allocates.
const std = @import("std");
const PlaceholderCell = @import("PlaceholderCell.zig");
const PlaceholderDraw = @import("PlaceholderDraw.zig");
const PlaceholderRequest = @import("PlaceholderRequest.zig");

pub const codepoint: u21 = 0x10EEEE;
/// The placeholder in UTF-8, the prefix of every placeholder grapheme.
pub const bytes = "\u{10EEEE}";

/// Whether a grapheme is a placeholder cell. Example: `if (unicode_placeholder.starts(cell.text())) continue;`
pub fn starts(text: []const u8) bool {
    return std.mem.startsWith(u8, text, bytes);
}

/// Decodes one placeholder grapheme with the ids its colors carry; null when
/// `text` is not a placeholder. Diacritics outside the table count as
/// missing and later ones are ignored, as in kitty.
/// Example: `const cell = unicode_placeholder.parseCell(text, fg_id, underline_id) orelse continue;`
pub fn parseCell(text: []const u8, image_id_low: u24, placement_id: u24) ?PlaceholderCell {
    if (!starts(text)) {
        return null;
    }

    var cell: PlaceholderCell = .{
        .image_id_low = image_id_low,
        .placement_id = placement_id,
    };

    const view = std.unicode.Utf8View.init(text[bytes.len..]) catch return cell;
    var marks = view.iterator();
    const row = marks.nextCodepoint() orelse return cell;
    cell.row = diacriticIndex(row);

    const column = marks.nextCodepoint() orelse return cell;
    cell.column = diacriticIndex(column);

    const high = marks.nextCodepoint() orelse return cell;
    cell.image_id_high = if (diacriticIndex(high)) |value| std.math.cast(u8, value) else null;
    return cell;
}

/// The fragment one run shows and its box from the run's first cell; null
/// when the run falls in the margin the fit leaves, the grid is too large or
/// the cell size is unknown.
/// Example: `const draw = unicode_placeholder.draw(request) orelse continue;`
pub fn draw(request: PlaceholderRequest) ?PlaceholderDraw {
    if (request.cell_width == 0 or request.cell_height == 0 or request.image_width == 0 or request.image_height == 0) {
        return null;
    }

    const grid_columns = gridSide(request.grid_columns, request.image_width, request.cell_width) orelse return null;
    const grid_rows = gridSide(request.grid_rows, request.image_height, request.cell_height) orelse return null;
    const run = request.run;
    const image_width: f64 = @floatFromInt(request.image_width);
    const image_height: f64 = @floatFromInt(request.image_height);
    const grid_width: f64 = @floatFromInt(@as(u64, grid_columns) * request.cell_width);
    const grid_height: f64 = @floatFromInt(@as(u64, grid_rows) * request.cell_height);

    // Fit the image into the grid keeping its aspect ratio; the margin it
    // leaves is split evenly on both sides, in image pixels.
    const scale = @min(grid_width / image_width, grid_height / image_height);
    const margin_x = (grid_width - image_width * scale) / 2 / scale;
    const margin_y = (grid_height - image_height * scale) / 2 / scale;
    const padded_width = image_width + 2 * margin_x;
    const padded_height = image_height + 2 * margin_y;
    const columns: f64 = @floatFromInt(grid_columns);
    const rows: f64 = @floatFromInt(grid_rows);

    const horizontal = clip(.{
        .start = padded_width * @as(f64, @floatFromInt(run.column)) / columns,
        .length = padded_width * @as(f64, @floatFromInt(run.width)) / columns,
        .margin = margin_x,
        .image = image_width,
    });
    const vertical = clip(.{
        .start = padded_height * @as(f64, @floatFromInt(run.row)) / rows,
        .length = padded_height / rows,
        .margin = margin_y,
        .image = image_height,
    });
    if (horizontal.length <= 0 or vertical.length <= 0) {
        return null;
    }

    const source_x = pixels(horizontal.start) orelse return null;
    const source_y = pixels(vertical.start) orelse return null;
    if (source_x >= request.image_width or source_y >= request.image_height) {
        return null;
    }

    const source_width = @min(pixels(horizontal.length) orelse return null, request.image_width - source_x);
    const source_height = @min(pixels(vertical.length) orelse return null, request.image_height - source_y);
    const width = pixels(horizontal.length * scale) orelse return null;
    const height = pixels(vertical.length * scale) orelse return null;
    if (source_width == 0 or source_height == 0 or width == 0 or height == 0) {
        return null;
    }

    return .{
        .source_x = source_x,
        .source_y = source_y,
        .source_width = source_width,
        .source_height = source_height,
        .box = .{
            .offset_x = pixels(horizontal.inset * scale) orelse return null,
            .offset_y = pixels(vertical.inset * scale) orelse return null,
            .width = width,
            .height = height,
        },
    };
}

/// The grid side in cells: the placement's, or what the image covers at its
/// own size when the placement leaves it out.
fn gridSide(requested: u32, image: u32, cell: u32) ?u32 {
    // SAFETY: draw rejects a zero cell size before resolving the grid.
    const side = if (requested != 0) requested else std.math.divCeil(u32, image, cell) catch unreachable;
    if (side == 0 or side > std.math.maxInt(u16)) {
        return null;
    }

    return side;
}

/// Cuts one axis of a run's share of the padded image to the image itself:
/// where the visible part starts in the image, how long it is, and how far
/// it is inset from the run's first cell, all in image pixels.
fn clip(axis: Axis) Clipped {
    const end = axis.start + axis.length;
    const visible_start = @max(axis.start, axis.margin);
    const visible_end = @min(end, axis.margin + axis.image);
    return .{
        .start = visible_start - axis.margin,
        .length = visible_end - visible_start,
        .inset = visible_start - axis.start,
    };
}

fn pixels(value: f64) ?u32 {
    const rounded = @round(value);
    if (!std.math.isFinite(rounded) or rounded < 0 or rounded > std.math.maxInt(u32)) {
        return null;
    }

    return @intFromFloat(rounded);
}

/// The row or column a diacritic encodes. Example: `diacriticIndex(0x0305) == 0`
pub fn diacriticIndex(mark: u21) ?u32 {
    const index = std.sort.binarySearch(u21, &diacritics, mark, orderMark) orelse return null;
    return @intCast(index);
}

fn orderMark(mark: u21, item: u21) std.math.Order {
    return std.math.order(mark, item);
}

const Axis = struct {
    start: f64,
    length: f64,
    margin: f64,
    image: f64,
};

const Clipped = struct {
    start: f64,
    length: f64,
    inset: f64,
};

/// Kitty's row and column diacritics; the index is the value. From
/// https://sw.kovidgoyal.net/kitty/_downloads/f0a0de9ec8d9ff4456206db8e0814937/rowcolumn-diacritics.txt
const diacritics = [_]u21{
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F,
    0x0346, 0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357,
    0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
    0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484,
    0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
    0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
    0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611,
    0x0612, 0x0613, 0x0614, 0x0615, 0x0616, 0x0617, 0x0657, 0x0658,
    0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
    0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2,
    0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733,
    0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
    0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE,
    0x07EF, 0x07F0, 0x07F1, 0x07F3, 0x0816, 0x0817, 0x0818, 0x0819,
    0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
    0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C,
    0x082D, 0x0951, 0x0953, 0x0954, 0x0F82, 0x0F83, 0x0F86, 0x0F87,
    0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
    0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D,
    0x1B6E, 0x1B6F, 0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1,
    0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
    0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1,
    0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5, 0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9,
    0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
    0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1,
    0x20D4, 0x20D5, 0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1, 0x20E7,
    0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
    0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA,
    0x2DEB, 0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2,
    0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
    0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D,
    0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5,
    0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9, 0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED,
    0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2, 0xAAB3, 0xAAB7,
    0xAAB8, 0xAABE, 0xAABF, 0xAAC1, 0xFE20, 0xFE21, 0xFE22, 0xFE23,
    0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187,
    0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243,
    0x1D244,
};
