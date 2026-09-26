//! Path picker in cells: a box at the focused pane's cursor with the query
//! on the edge next to it, ranked paths between and key hints on the far
//! edge. The same placement and row labels as the native picker.

const cellgrid = @import("cellgrid");
const data = @import("model");
const std = @import("std");
const Context = @import("Context.zig");
const GotoPickerOutput = @import("GotoPickerOutput.zig");
const PathPickerInput = @import("PathPickerInput.zig");

pub const max_rows = 10;
pub const width_cells = 72;
const hints = "enter insert  tab open  shift+tab up  alt+enter absolute  esc close";

/// The cells the picker covers for the current page.
///
/// ```zig
/// const placement = path_picker.modalArea(application, model, tab, layout);
/// ```
pub fn modalArea(application: cellgrid.Rect, model: *const data.ClientModel, tab: usize, layout: *const data.LayoutSnapshot) data.PathPickerPlacement {
    const visible: u16 = @max(@min(model.path_picker.len, max_rows), 1);
    const cursor = data.path_picker_placement.cursorCell(
        model,
        tab,
        layout,
    );
    return data.path_picker_placement.place(
        application,
        cursor,
        width_cells,
        visible + 4,
    );
}

/// Draws the picker and returns its area and the query cursor.
///
/// ```zig
/// const output = path_picker.render(context, input);
/// ```
pub fn render(context: *Context, input: PathPickerInput) GotoPickerOutput {
    const area = input.placement.area;
    if (area.w < 12 or area.h < 5) {
        return .{
            .area = .{},
            .cursor = null,
        };
    }

    const background = context.palette.surface0;
    const style: cellgrid.Style = .{
        .fg = context.palette.text,
        .bg = background,
    };
    if (input.graphical_frame) {
        context.buffer.fillWithoutCorners(area, style);
    } else {
        context.buffer.fill(
            area,
            .{
                .glyph = " ",
                .style = style,
            },
        );
        context.buffer.box(
            area,
            .{ .style = .{
                .fg = context.palette.overlay0,
                .bg = background,
            } },
        );
    }

    const inner = area.inner(1);
    const flipped = input.placement.flipped;
    const query_row = if (flipped) inner.row(inner.h - 1) else inner.row(0);
    const footer_row = if (flipped) inner.row(0) else inner.row(inner.h - 1);
    const rows = inner.splitTop(1)[1].splitBottom(1)[0];
    const cursor_x = drawQuery(
        context,
        query_row,
        input,
    );

    const state = input.state;
    const total: u16 = state.len;
    const selected: u16 = if (total == 0) 0 else @min(input.selection, total - 1);
    const count = @min(rows.h, @min(total, max_rows));
    const start = (selected + 1) -| count;
    if (total == 0) {
        const empty = if (flipped) rows.row(rows.h - 1) else rows.row(0);
        _ = context.buffer.writeTruncated(
            empty,
            .{
                .point = .{
                    .x = empty.x + 1,
                    .y = empty.y,
                },
                .text = emptyText(state),
                .max_width = empty.w -| 1,
                .style = .{
                    .fg = context.palette.subtext0,
                    .bg = background,
                },
            },
        );
    }

    for (0..count) |offset| {
        const index = start + @as(u16, @intCast(offset));
        const line = if (flipped) rows.row(rows.h - 1 - @as(u16, @intCast(offset))) else rows.row(@intCast(offset));
        drawMatch(
            context,
            line,
            .{
                .state = state,
                .match = &state.slice()[index],
                .selected = index == selected,
            },
        );
    }

    drawFooter(
        context,
        footer_row,
        state,
    );
    return .{
        .area = area,
        .cursor = .{
            .cursor_x = cursor_x,
            .cursor_y = query_row.y,
        },
    };
}

/// Writes the root's last segment and the query; returns the caret column.
fn drawQuery(context: *Context, row: cellgrid.Rect, input: PathPickerInput) u16 {
    const background = context.palette.surface0;
    var count_storage: [32]u8 = undefined;
    const count = std.fmt.bufPrint(
        &count_storage,
        "{d}/{d}",
        .{ input.state.len, input.state.scanned },
    ) catch "";
    const count_cells = @min(cellgrid.text.measure(count), row.w / 4);
    _ = context.buffer.writeText(
        row,
        .{
            .point = .{
                .x = row.x + row.w - count_cells,
                .y = row.y,
            },
            .text = count,
            .style = .{
                .fg = context.palette.subtext0,
                .bg = background,
            },
        },
    );

    const root = rootLabel(input.state.rootSlice());
    const root_width = context.buffer.writeTruncated(
        row,
        .{
            .point = .{
                .x = row.x + 1,
                .y = row.y,
            },
            .text = root,
            .max_width = row.w / 2,
            .style = .{
                .fg = context.palette.subtext0,
                .bg = background,
            },
        },
    );
    const field_x = row.x + 1 + root_width + 1;
    const field_width = (row.x + row.w) -| (field_x + count_cells + 1);
    const view = input.field.view(field_width);
    _ = context.buffer.writeTruncated(
        row,
        .{
            .point = .{
                .x = field_x,
                .y = row.y,
            },
            .text = view.text,
            .max_width = field_width,
            .style = .{
                .fg = context.palette.text,
                .bg = background,
            },
        },
    );
    return field_x + view.cursor;
}

fn rootLabel(root: []const u8) []const u8 {
    if (root.len <= 1) {
        return "/";
    }

    const split = std.mem.lastIndexOfScalar(
        u8,
        root,
        '/',
    ) orelse return root;
    return root[split + 1 ..];
}

const MatchRow = struct {
    state: *const data.PathPickerState,
    match: *const data.PathPickerMatch,
    selected: bool,
};

fn drawMatch(context: *Context, line: cellgrid.Rect, row: MatchRow) void {
    const palette = context.palette;
    const background = if (row.selected) palette.surface1 else palette.surface0;
    context.buffer.fill(
        line,
        .{
            .glyph = " ",
            .style = .{
                .fg = palette.text,
                .bg = background,
            },
        },
    );
    if (row.selected) {
        _ = context.buffer.writeText(
            line,
            .{
                .point = .{
                    .x = line.x,
                    .y = line.y,
                },
                .text = "›",
                .style = .{
                    .fg = palette.accent,
                    .bg = background,
                },
            },
        );
    }

    var label: data.PathLabel = .{};
    const width = line.w -| 2;
    label.layout(
        row.state.path(row.match),
        row.match.positions[0..row.match.position_count],
        width,
    );
    var x = line.x + 2;
    for (label.slice()) |run| {
        const color = switch (run.tone) {
            .directory, .ellipsis => palette.subtext0,
            .name => if (row.match.kind == .directory) palette.blue else palette.text,
            .match => palette.accent,
        };
        x += context.buffer.writeTruncated(line, .{
            .point = .{
                .x = x,
                .y = line.y,
            },
            .text = run.text,
            .max_width = (line.x + line.w) -| x,
            .style = .{
                .fg = color,
                .bg = background,
                .flags = .{ .bold = run.tone == .match },
            },
        });
    }
}

fn drawFooter(context: *Context, row: cellgrid.Rect, state: *const data.PathPickerState) void {
    const background = context.palette.surface0;
    var status_storage: [64]u8 = undefined;
    const failed = state.phase == .failed;
    const status = if (failed)
        state.errorSlice()
    else if (!state.complete)
        std.fmt.bufPrint(
            &status_storage,
            "indexing {d}",
            .{state.scanned},
        ) catch "indexing"
    else
        std.fmt.bufPrint(
            &status_storage,
            "{d} paths",
            .{state.scanned},
        ) catch "";
    const used = context.buffer.writeTruncated(
        row,
        .{
            .point = .{
                .x = row.x + 1,
                .y = row.y,
            },
            .text = status,
            .max_width = row.w -| 1,
            .style = .{
                .fg = if (failed) context.palette.red else context.palette.subtext0,
                .bg = background,
            },
        },
    );
    const hints_x = row.x + 1 + used + 2;
    if (hints_x >= row.x + row.w) {
        return;
    }

    _ = context.buffer.writeTruncated(
        row,
        .{
            .point = .{
                .x = hints_x,
                .y = row.y,
            },
            .text = hints,
            .max_width = (row.x + row.w) - hints_x,
            .style = .{
                .fg = context.palette.subtext0,
                .bg = background,
            },
        },
    );
}

fn emptyText(state: *const data.PathPickerState) []const u8 {
    return switch (state.phase) {
        .idle, .loading => "Searching…",
        .failed => "No paths",
        .ready => if (state.complete) "No paths match" else "Searching…",
    };
}
