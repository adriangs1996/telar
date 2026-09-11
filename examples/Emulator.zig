/// One canonical emulator for both cells and graphics. Production isolates KGP
/// parsing behind its media queue; this example intentionally removes that
/// concurrency while preserving the same parser and placement semantics.
const Emulator = @This();
const std = @import("std");
const source_namespace = @import("terminal_browser_pane.zig");
const vt = @import("ghostty-vt");
const ResponseQueue = @import("ResponseQueue.zig");
const core = @import("telar-core");
gpa: std.mem.Allocator,
size: source_namespace.schema.TerminalSize,
terminal: vt.Terminal,
stream: vt.TerminalStream,
render_state: vt.RenderState = .empty,
responses: ResponseQueue = .{},

const InitOptions = struct {
    io: source_namespace.Io,
    allocator: std.mem.Allocator,
    size: source_namespace.schema.TerminalSize,
};

const DrawOptions = struct {
    area: source_namespace.ui.Rect,
    force: bool,
};

pub fn init(emulator: *Emulator, options: InitOptions) !void {
    const io = options.io;
    const gpa = options.allocator;
    const size = options.size;
    emulator.* = .{
        .gpa = gpa,
        .size = size,
        .terminal = undefined,
        .stream = undefined,
    };
    emulator.terminal = try .init(io, gpa, .{
        .cols = size.cols,
        .rows = size.rows,
        .kitty_image_storage_limit = core.graphics.max_image_bytes_per_screen,
        .kitty_image_loading_limits = source_namespace.media.image_loading_limits,
    });
    errdefer emulator.terminal.deinit(gpa);

    var handler = emulator.terminal.vtHandler();
    handler.apc_handler.max_bytes.put(.kitty, core.graphics.max_encoded_chunk_bytes);
    handler.apc_handler.enable(.glyph, false);
    handler.effects.write_pty = writePty;
    handler.effects.size = reportSize;
    emulator.stream = .init(.{ .allocator = gpa, .handler = handler });
    errdefer emulator.stream.deinit();
    try emulator.resize(size);
}

pub fn deinit(emulator: *Emulator) void {
    emulator.render_state.deinit(emulator.gpa);
    emulator.stream.deinit();
    emulator.terminal.deinit(emulator.gpa);
}

pub fn ingest(emulator: *Emulator, bytes: []const u8) void {
    emulator.stream.nextSlice(bytes);
}

fn resize(emulator: *Emulator, size: source_namespace.schema.TerminalSize) !void {
    try emulator.stream.handler.resize(.{
        .cols = size.cols,
        .rows = size.rows,
        .cell_size_px = if (size.cell_width_px != 0 and size.cell_height_px != 0) .{
            .width = size.cell_width_px,
            .height = size.cell_height_px,
        } else null,
    });
    emulator.size = size;
}

fn draw(emulator: *Emulator, buffer: *source_namespace.ui.Buffer, options: DrawOptions) !?source_namespace.term.Screen.Position {
    const area = options.area;
    try emulator.render_state.update(emulator.gpa, &emulator.terminal);
    _ = source_namespace.blit.blit(.{
        .buffer = buffer,
        .area = area,
        .terminal = &emulator.terminal,
        .state = &emulator.render_state,
        .options = .{ .force = options.force },
    });
    const cursor = emulator.render_state.cursor;
    if (!cursor.visible or cursor.viewport == null or
        cursor.viewport.?.x >= area.w or cursor.viewport.?.y >= area.h)
    {
        return null;
    }
    return .{
        .x = area.x + cursor.viewport.?.x,
        .y = area.y + cursor.viewport.?.y,
    };
}

fn writePty(handler: *vt.TerminalStream.Handler, response: [:0]const u8) void {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
    const emulator: *Emulator = @fieldParentPtr("stream", stream);
    emulator.responses.push(response);
}

fn reportSize(handler: *vt.TerminalStream.Handler) ?vt.size_report.Size {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
    const emulator: *Emulator = @fieldParentPtr("stream", stream);
    const size = emulator.size;
    if (size.cell_width_px == 0 or size.cell_height_px == 0) {
        return null;
    }
    return .{
        .rows = size.rows,
        .columns = size.cols,
        .cell_width = size.cell_width_px,
        .cell_height = size.cell_height_px,
    };
}
