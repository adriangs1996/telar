//! Reduced terminal-browser reproducer.
//!
//! It keeps only the path needed to render one graphical child inside a pane:
//!
//!   terminal-browser -> PTY -> Ghostty VT -> cells + KGP -> host Ghostty
//!
//! There is no Telar runtime, IPC, history, sidebar, tabs, or configuration.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const ui = core.ui;
const pty = backend.pty;
const media = backend.media;
const blit = backend.blit;
const term = frontend.term;
const kitty = frontend.kitty;
const platform = frontend.platform;
const multiplexer = frontend.multiplexer;
const HostCapabilities = frontend.client.HostCapabilities;

pub const std_options: std.Options = .{ .log_level = .err };

const pane_id: schema.PaneId = @enumFromInt(1);
const location: schema.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(1) },
    .tab_id = @enumFromInt(1),
};
const frame_interval_ns = std.time.ns_per_s / 60;

const FrameGeometry = struct {
    /// Exactly half of the host in both dimensions, rounded down.
    outer: ui.Rect,
    /// The PTY geometry after reserving a one-cell border.
    content: ui.Rect,
};

fn centeredFrame(cols: u16, rows: u16) !FrameGeometry {
    if (cols < 8 or rows < 8) {
        return error.TerminalTooSmall;
    }
    const width = cols / 2;
    const height = rows / 2;
    if (width < 3 or height < 3) {
        return error.TerminalTooSmall;
    }
    const outer: ui.Rect = .{
        .x = (cols - width) / 2,
        .y = (rows - height) / 2,
        .w = width,
        .h = height,
    };
    return .{ .outer = outer, .content = outer.inner(1) };
}

fn paneTerminalSize(frame: FrameGeometry, capabilities: *const HostCapabilities) schema.TerminalSize {
    const cell = capabilities.cellSize(0, 0);
    return .{
        .cols = frame.content.w,
        .rows = frame.content.h,
        .cell_width_px = cell.width,
        .cell_height_px = cell.height,
    };
}

fn observePlatformPixels(capabilities: *HostCapabilities, size: platform.Size) void {
    if (size.width_px != 0) {
        capabilities.window_width_px = size.width_px;
    }
    if (size.height_px != 0) {
        capabilities.window_height_px = size.height_px;
    }
    if (size.cols != 0 and size.width_px != 0) {
        capabilities.cell_width_px = size.width_px / size.cols;
    }
    if (size.rows != 0 and size.height_px != 0) {
        capabilities.cell_height_px = size.height_px / size.rows;
    }
}

const ResponseQueue = struct {
    const capacity = 64;
    const max_response_bytes = 1024;

    bytes: [capacity][max_response_bytes]u8 = undefined,
    lengths: [capacity]u16 = @splat(0),
    head: u8 = 0,
    len: u8 = 0,
    overflowed: bool = false,

    fn push(queue: *ResponseQueue, response: []const u8) void {
        if (response.len > max_response_bytes or queue.len == capacity) {
            queue.overflowed = true;
            return;
        }
        const index = (@as(usize, queue.head) + queue.len) % capacity;
        @memcpy(queue.bytes[index][0..response.len], response);
        queue.lengths[index] = @intCast(response.len);
        queue.len += 1;
    }

    fn peek(queue: *const ResponseQueue) ?[]const u8 {
        if (queue.len == 0) {
            return null;
        }
        return queue.bytes[queue.head][0..queue.lengths[queue.head]];
    }

    fn pop(queue: *ResponseQueue) void {
        std.debug.assert(queue.len != 0);
        queue.lengths[queue.head] = 0;
        queue.head = @intCast((@as(usize, queue.head) + 1) % capacity);
        queue.len -= 1;
    }
};

/// One canonical emulator for both cells and graphics. Production isolates KGP
/// parsing behind its media queue; this example intentionally removes that
/// concurrency while preserving the same parser and placement semantics.
const Emulator = struct {
    gpa: std.mem.Allocator,
    size: schema.TerminalSize,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    render_state: vt.RenderState = .empty,
    responses: ResponseQueue = .{},

    const InitOptions = struct {
        io: Io,
        allocator: std.mem.Allocator,
        size: schema.TerminalSize,
    };

    const DrawOptions = struct {
        area: ui.Rect,
        force: bool,
    };

    fn init(emulator: *Emulator, options: InitOptions) !void {
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
            .kitty_image_loading_limits = media.image_loading_limits,
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

    fn deinit(emulator: *Emulator) void {
        emulator.render_state.deinit(emulator.gpa);
        emulator.stream.deinit();
        emulator.terminal.deinit(emulator.gpa);
    }

    fn ingest(emulator: *Emulator, bytes: []const u8) void {
        emulator.stream.nextSlice(bytes);
    }

    fn resize(emulator: *Emulator, size: schema.TerminalSize) !void {
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

    fn draw(emulator: *Emulator, buffer: *ui.Buffer, options: DrawOptions) !?term.Screen.Position {
        const area = options.area;
        try emulator.render_state.update(emulator.gpa, &emulator.terminal);
        _ = blit.blit(.{
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
};

/// Latest-wins in-memory bridge from Ghostty VT storage to Telar's exterior
/// graphics store. Updating the store does not write to the host; its Kitty
/// writer alone owns and completes any open multipart stream.
const GraphicsMirror = struct {
    revision: u64 = 0,
    image: ?core.graphics.ImageKey = null,
    placement: ?core.graphics.Placement = null,

    fn ready(mirror: *const GraphicsMirror, emulator: *const Emulator) bool {
        _ = mirror;
        const storage = &emulator.terminal.screens.active.kitty_images;
        return storage.dirty and storage.loading == null;
    }

    fn sync(mirror: *GraphicsMirror, emulator: *Emulator, store: *kitty.Store) !bool {
        if (!mirror.ready(emulator)) {
            return false;
        }
        const storage = &emulator.terminal.screens.active.kitty_images;
        mirror.revision +%= 1;
        if (mirror.revision == 0) {
            mirror.revision = 1;
        }
        const revision = mirror.revision;
        var next_image: ?struct {
            metadata: core.graphics.Image,
            pixels: []const u8,
        } = null;
        var images = storage.images.iterator();
        while (images.next()) |entry| {
            const image = entry.value_ptr;
            const pixels = image.data.bytes() orelse continue;
            const format: core.graphics.Format = switch (image.format) {
                .rgb => .rgb,
                .rgba => .rgba,
                else => continue,
            };
            const metadata: core.graphics.Image = .{
                .key = .{ .image_id = image.id, .generation = image.generation },
                .format = format,
                .width = image.width,
                .height = image.height,
                .byte_len = @intCast(pixels.len),
            };
            if (next_image != null) {
                return error.ExampleImageLimitExceeded;
            }
            next_image = .{ .metadata = metadata, .pixels = pixels };
        }

        if (next_image) |next| {
            if (mirror.image == null or !std.meta.eql(mirror.image.?, next.metadata.key)) {
                try store.applyImage(.{
                    .pane_id = pane_id,
                    .revision = revision,
                    .image = next.metadata,
                });
                var offset: usize = 0;
                while (offset < next.pixels.len) {
                    const take = @min(core.graphics.max_ipc_chunk_bytes, next.pixels.len - offset);
                    try store.applyChunk(.{
                        .pane_id = pane_id,
                        .revision = revision,
                        .key = next.metadata.key,
                        .offset = offset,
                        .bytes = next.pixels[offset..][0..take],
                    });
                    offset += take;
                }
            }
        }

        var next_placement: ?core.graphics.Placement = null;
        if (next_image) |next| {
            var placements = storage.placements.iterator();
            while (placements.next()) |entry| {
                if (entry.key_ptr.image_id != next.metadata.key.image_id) {
                    continue;
                }
                const image = storage.imageById(entry.key_ptr.image_id) orelse continue;
                const placement = media.placementValue(&emulator.terminal, .{
                    .key = entry.key_ptr.*,
                    .placement = entry.value_ptr.*,
                    .image = image,
                }) orelse continue;
                if (next_placement != null) {
                    return error.ExamplePlacementLimitExceeded;
                }
                next_placement = placement;
            }
        }

        if (next_placement) |next| {
            if (mirror.placement == null or !std.meta.eql(mirror.placement.?, next)) {
                try store.applyPlacement(.{
                    .pane_id = pane_id,
                    .revision = revision,
                    .placement = next,
                });
            }
        }
        if (mirror.placement) |previous| {
            if (next_placement == null or previous.virtual_id != next_placement.?.virtual_id) {
                try store.deletePlacement(.{
                    .pane_id = pane_id,
                    .revision = revision,
                    .key = previous.key,
                    .virtual_id = previous.virtual_id,
                    .placement_id = previous.placement_id,
                });
            }
        }
        if (mirror.image) |previous| {
            if (next_image == null or previous.image_id != next_image.?.metadata.key.image_id) {
                try store.deleteImage(.{
                    .pane_id = pane_id,
                    .revision = revision,
                    .key = previous,
                });
            }
        }

        mirror.image = if (next_image) |next| next.metadata.key else null;
        mirror.placement = next_placement;
        storage.dirty = false;
        return true;
    }
};

const ExteriorGraphics = struct {
    writer: kitty.KittyGraphicsWriter,

    fn writeOpaque(context: *anyopaque, writer: *Io.Writer) Io.Writer.Error!usize {
        const exterior: *ExteriorGraphics = @ptrCast(@alignCast(context));
        return exterior.writer.write(writer);
    }
};

const HostInput = struct {
    pending: [4096]u8 = undefined,
    len: usize = 0,

    const Result = struct {
        stop: bool = false,
        capabilities_changed: bool = false,
    };

    fn feed(input: *HostInput, io: Io, session: *pty.Session, capabilities: *HostCapabilities, bytes: []const u8) !Result {
        if (bytes.len > input.pending.len - input.len) {
            return error.HostInputOverflow;
        }
        @memcpy(input.pending[input.len..][0..bytes.len], bytes);
        input.len += bytes.len;

        var result: Result = .{};
        while (input.len != 0) {
            const parsed = term.parse(input.pending[0..input.len]) orelse break;
            if (parsed.len == 0) {
                break;
            }
            const raw = input.pending[0..parsed.len];
            switch (parsed.event) {
                .terminal_response => |response| {
                    result.capabilities_changed = observeHostCapability(capabilities, response) or
                        result.capabilities_changed;
                },
                // Unknown host responses are not child input.
                .incomplete => {},
                else => {
                    // Ctrl+] is the reproducer's only local binding.
                    if (raw.len == 1 and raw[0] == 0x1d) {
                        result.stop = true;
                    } else {
                        try session.writeAll(io, raw);
                    }
                },
            }
            input.discard(parsed.len);
            if (result.stop) {
                break;
            }
        }
        return result;
    }

    fn discard(input: *HostInput, count: usize) void {
        std.mem.copyForwards(
            u8,
            input.pending[0 .. input.len - count],
            input.pending[count..input.len],
        );
        input.len -= count;
    }
};

fn observeHostCapability(capabilities: *HostCapabilities, response: term.Event.TerminalResponse) bool {
    const observation = frontend.client.translateHostCapability(response) orelse return false;
    const next = capabilities.withObservation(observation);
    if (std.meta.eql(capabilities.*, next)) {
        return false;
    }

    capabilities.* = next;
    return true;
}

fn expireHostCapabilities(capabilities: *HostCapabilities) bool {
    const next = capabilities.withExpiredProbes();
    if (std.meta.eql(capabilities.*, next)) {
        return false;
    }

    capabilities.* = next;
    return true;
}

const InputChunk = struct {
    bytes: [512]u8 = undefined,
    len: u16 = 0,
};

const OutputChunk = struct {
    bytes: [16 * 1024]u8 = undefined,
    len: u16 = 0,
};

const Message = union(enum) {
    input: InputChunk,
    output: OutputChunk,
    resized,
    capability_timeout,
    child_closed,
};

fn inputActor(io: Io, file: File, queue: *Io.Queue(Message)) Io.Cancelable!void {
    while (true) {
        var chunk: InputChunk = .{};
        const len = file.readStreaming(io, &.{&chunk.bytes}) catch |err| switch (err) {
            error.Canceled => |cancelled| return cancelled,
            else => return,
        };
        if (len == 0) {
            return;
        }
        chunk.len = @intCast(len);
        queue.putOne(io, .{ .input = chunk }) catch |err| switch (err) {
            error.Canceled => |cancelled| return cancelled,
            error.Closed => return,
        };
    }
}

fn outputActor(io: Io, session: *pty.Session, queue: *Io.Queue(Message)) Io.Cancelable!void {
    while (true) {
        var chunk: OutputChunk = .{};
        const len = session.read(io, &chunk.bytes) catch |err| switch (err) {
            error.Canceled => |cancelled| return cancelled,
            else => {
                queue.putOne(io, .child_closed) catch {};
                return;
            },
        };
        if (len == 0) {
            queue.putOne(io, .child_closed) catch {};
            return;
        }
        chunk.len = @intCast(len);
        queue.putOne(io, .{ .output = chunk }) catch |err| switch (err) {
            error.Canceled => |cancelled| return cancelled,
            error.Closed => return,
        };
    }
}

fn resizeActor(io: Io, watcher: *platform.ResizeWatcher, queue: *Io.Queue(Message)) Io.Cancelable!void {
    while (true) {
        try watcher.wait(io);
        queue.putOne(io, .resized) catch |err| switch (err) {
            error.Canceled => |cancelled| return cancelled,
            error.Closed => return,
        };
    }
}

fn capabilityTimeoutActor(io: Io, queue: *Io.Queue(Message)) Io.Cancelable!void {
    const deadline = Io.Timestamp.fromNanoseconds(
        @intCast(monotonic(io) + kitty.capability_timeout_ns),
    ).withClock(.awake);
    try deadline.wait(io);
    queue.putOne(io, .capability_timeout) catch |err| switch (err) {
        error.Canceled => |cancelled| return cancelled,
        error.Closed => return,
    };
}

fn drawFrame(buffer: *ui.Buffer, frame: FrameGeometry) void {
    const background: ui.Style = .{ .bg = .{ .rgb = .{ 0x10, 0x10, 0x10 } } };
    const border: ui.Style = .{
        .fg = .{ .rgb = .{ 0xff, 0xc7, 0x99 } },
        .bg = .{ .rgb = .{ 0x10, 0x10, 0x10 } },
    };
    buffer.clear(background);
    buffer.fill(frame.outer.row(0), "─", border);
    buffer.fill(frame.outer.row(frame.outer.h - 1), "─", border);
    buffer.fill(.{ .x = frame.outer.x, .y = frame.outer.y, .w = 1, .h = frame.outer.h }, "│", border);
    buffer.fill(.{
        .x = frame.outer.x + frame.outer.w - 1,
        .y = frame.outer.y,
        .w = 1,
        .h = frame.outer.h,
    }, "│", border);
    buffer.setCell(frame.outer.x, frame.outer.y, "┌", 1, border);
    buffer.setCell(frame.outer.x + frame.outer.w - 1, frame.outer.y, "┐", 1, border);
    buffer.setCell(frame.outer.x, frame.outer.y + frame.outer.h - 1, "└", 1, border);
    buffer.setCell(
        frame.outer.x + frame.outer.w - 1,
        frame.outer.y + frame.outer.h - 1,
        "┘",
        1,
        border,
    );
    if (frame.outer.w > 22) {
        _ = buffer.writeText(
            frame.outer.row(0),
            frame.outer.x + 2,
            frame.outer.y,
            " terminal-browser ",
            border,
        );
    }
}

fn drainResponses(io: Io, session: *pty.Session, emulator: *Emulator) !void {
    if (emulator.responses.overflowed) {
        return error.PtyResponseOverflow;
    }
    while (emulator.responses.peek()) |response| {
        try session.writeAll(io, response);
        emulator.responses.pop();
    }
}

fn drawCells(screen: *term.Screen, emulator: *Emulator, frame: FrameGeometry, rebuild_frame: bool) !void {
    const buffer = screen.buffer();
    if (rebuild_frame) {
        drawFrame(buffer, frame);
    }
    screen.cursor = try emulator.draw(buffer, .{ .area = frame.content, .force = rebuild_frame });
}

fn present(screen: *term.Screen, writer: *Io.Writer, emulator: *Emulator, mirror: *GraphicsMirror, graphics_store: *kitty.Store, model: *multiplexer.Model, frame: FrameGeometry, capabilities: *const HostCapabilities) !void {
    _ = try mirror.sync(emulator, graphics_store);
    const cell = capabilities.cellSize(0, 0);
    var exterior: ExteriorGraphics = .{ .writer = .{
        .store = graphics_store,
        .layout_snapshot = model.layoutSnapshot(frame.content),
        .cell_width = cell.width,
        .cell_height = cell.height,
    } };
    if (capabilities.kitty_graphics == .supported and
        cell.width != 0 and cell.height != 0 and graphics_store.damage)
    {
        screen.graphics = .{
            .context = &exterior,
            .write = ExteriorGraphics.writeOpaque,
        };
    }
    _ = try screen.flush(writer);
}

fn graphicsReady(capabilities: *const HostCapabilities, emulator: *const Emulator, mirror: *const GraphicsMirror, store: *const kitty.Store) bool {
    const cell = capabilities.cellSize(0, 0);
    if (capabilities.kitty_graphics != .supported or cell.width == 0 or cell.height == 0) {
        return false;
    }
    return store.damage or mirror.ready(emulator);
}

fn applyPaneGeometry(io: Io, session: *pty.Session, emulator: *Emulator, model: *multiplexer.Model, graphics_store: *kitty.Store, frame: FrameGeometry, capabilities: *const HostCapabilities) !bool {
    _ = io;
    const next = paneTerminalSize(frame, capabilities);
    if (std.meta.eql(next, emulator.size)) {
        return false;
    }
    try session.resize(.{
        .cols = next.cols,
        .rows = next.rows,
        .cell_width_px = next.cell_width_px,
        .cell_height_px = next.cell_height_px,
    });
    try emulator.resize(next);
    model.setCellSize(next.cell_width_px, next.cell_height_px);
    graphics_store.invalidatePlacements();
    return true;
}

fn collectCommand(init: std.process.Init, storage: *[pty.max_args][*:0]const u8) !pty.Command {
    storage[0] = "terminal-browser";
    var len: usize = 1;
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (len == storage.len) {
            return error.TooManyArguments;
        }
        storage[len] = arg.ptr;
        len += 1;
    }
    return pty.Command.fromArgv(storage[0..len]);
}

fn monotonic(io: Io) u64 {
    const timestamp = Io.Timestamp.now(io, .awake);
    return @intCast(@max(timestamp.nanoseconds, 0));
}

/// A child of this example is attached to our PTY, not to the terminal which
/// launched us. Leaving an outer terminal's discovery variables in place lets
/// applications mistake this PTY for a surface owned by that outer terminal.
/// In particular, terminal-browser's Ghostty pane discovery writes OSC 7 to
/// the PTY concurrently with its Kitty APC stream, which can split an image
/// command and expose the remaining base64 as printable text.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var child_environment = try pty.ChildEnvironment.init(
        gpa,
        init.minimal.environ,
        "telar-pane-example",
    );
    defer child_environment.deinit();

    var tty = platform.Tty.open() catch |err| {
        std.debug.print("terminal-browser-pane needs a terminal: {s}\n", .{@errorName(err)});
        return err;
    };
    defer tty.deinit();
    platform.installCrashRestore(&tty);

    var tty_file = tty.writeHandle();
    var output_buffer: [512 * 1024]u8 = undefined;
    var output = tty_file.writer(io, &output_buffer);
    const writer = &output.interface;
    try writer.writeAll(platform.pane_enter_sequence);
    try writer.writeAll(kitty.capability_query);
    try writer.flush();
    defer {
        writer.writeAll(platform.pane_leave_sequence) catch {};
        writer.flush() catch {};
    }

    var host_size = tty.size();
    if (host_size.cols == 0) {
        host_size.cols = 80;
    }
    if (host_size.rows == 0) {
        host_size.rows = 24;
    }
    var capabilities: HostCapabilities = .{};
    observePlatformPixels(&capabilities, host_size);
    var frame = try centeredFrame(host_size.cols, host_size.rows);
    const initial_size = paneTerminalSize(frame, &capabilities);

    var argument_storage: [pty.max_args][*:0]const u8 = undefined;
    var command = try collectCommand(init, &argument_storage);
    command.environment = &child_environment;
    var session = try pty.Session.spawn(&command, .{
        .cols = initial_size.cols,
        .rows = initial_size.rows,
        .cell_width_px = initial_size.cell_width_px,
        .cell_height_px = initial_size.cell_height_px,
    });
    defer session.deinit();

    var emulator: Emulator = undefined;
    try emulator.init(.{ .io = io, .allocator = gpa, .size = initial_size });
    defer emulator.deinit();

    var screen = try term.Screen.init(gpa, host_size.cols, host_size.rows);
    defer screen.deinit();
    var graphics_store = kitty.Store.init(gpa);
    defer graphics_store.deinit();
    var mirror: GraphicsMirror = .{};
    var model = multiplexer.Model.init(gpa);
    defer model.deinit();
    try model.addRoot(pane_id, location, initial_size);
    model.setCellSize(initial_size.cell_width_px, initial_size.cell_height_px);

    var watcher = try platform.ResizeWatcher.init(&tty);
    defer watcher.deinit();

    var queue_storage: [32]Message = undefined;
    var queue: Io.Queue(Message) = .init(&queue_storage);
    var actors: Io.Group = .init;
    try actors.concurrent(io, inputActor, .{ io, tty.readHandle(), &queue });
    try actors.concurrent(io, outputActor, .{ io, &session, &queue });
    try actors.concurrent(io, resizeActor, .{ io, &watcher, &queue });
    try actors.concurrent(io, capabilityTimeoutActor, .{ io, &queue });
    defer {
        session.shutdown();
        queue.close(io);
        actors.cancel(io);
    }

    defer {
        graphics_store.clearPane(pane_id);
        const cell = capabilities.cellSize(0, 0);
        var exterior: ExteriorGraphics = .{ .writer = .{
            .store = &graphics_store,
            .layout_snapshot = model.layoutSnapshot(frame.content),
            .cell_width = cell.width,
            .cell_height = cell.height,
        } };
        if (capabilities.kitty_graphics == .supported) {
            screen.graphics = .{ .context = &exterior, .write = ExteriorGraphics.writeOpaque };
            _ = screen.flush(writer) catch {};
        }
    }

    try drawCells(&screen, &emulator, frame, true);
    try present(
        &screen,
        writer,
        &emulator,
        &mirror,
        &graphics_store,
        &model,
        frame,
        &capabilities,
    );

    var host_input: HostInput = .{};
    var batch: [32]Message = undefined;
    var last_frame_ns = monotonic(io);
    var redraw_cells = false;
    var rebuild_frame = false;
    var stop = false;
    var child_closed = false;

    while (!stop and !child_closed) {
        const scheduled = redraw_cells or rebuild_frame or
            graphicsReady(&capabilities, &emulator, &mirror, &graphics_store);
        if (scheduled) {
            const deadline_ns = last_frame_ns + frame_interval_ns;
            if (monotonic(io) < deadline_ns) {
                const deadline = Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
                deadline.wait(io) catch {};
            }
        }
        const minimum: usize = if (scheduled) 0 else 1;
        const count = queue.get(io, &batch, minimum) catch break;
        var should_present = scheduled;

        for (batch[0..count]) |message| switch (message) {
            .input => |chunk| {
                const result = try host_input.feed(
                    io,
                    &session,
                    &capabilities,
                    chunk.bytes[0..chunk.len],
                );
                stop = stop or result.stop;
                if (result.capabilities_changed) {
                    if (try applyPaneGeometry(
                        io,
                        &session,
                        &emulator,
                        &model,
                        &graphics_store,
                        frame,
                        &capabilities,
                    )) {
                        redraw_cells = true;
                    }
                }
            },
            .output => |chunk| {
                emulator.ingest(chunk.bytes[0..chunk.len]);
                try drainResponses(io, &session, &emulator);
                redraw_cells = true;
            },
            .resized => {
                host_size = tty.size();
                if (host_size.cols == 0) {
                    host_size.cols = 80;
                }
                if (host_size.rows == 0) {
                    host_size.rows = 24;
                }
                observePlatformPixels(&capabilities, host_size);
                frame = try centeredFrame(host_size.cols, host_size.rows);
                try screen.resize(host_size.cols, host_size.rows);
                _ = try applyPaneGeometry(
                    io,
                    &session,
                    &emulator,
                    &model,
                    &graphics_store,
                    frame,
                    &capabilities,
                );
                graphics_store.invalidatePlacements();
                rebuild_frame = true;
                redraw_cells = true;
            },
            .capability_timeout => {
                if (expireHostCapabilities(&capabilities)) {
                    redraw_cells = true;
                }
            },
            .child_closed => child_closed = true,
        };
        if (stop or child_closed) {
            break;
        }

        if (redraw_cells or rebuild_frame) {
            try drawCells(&screen, &emulator, frame, rebuild_frame);
            redraw_cells = false;
            rebuild_frame = false;
            should_present = true;
        }
        if (should_present or graphicsReady(&capabilities, &emulator, &mirror, &graphics_store)) {
            try present(
                &screen,
                writer,
                &emulator,
                &mirror,
                &graphics_store,
                &model,
                frame,
                &capabilities,
            );
            last_frame_ns = monotonic(io);
        }
    }

    if (child_closed) {
        _ = session.wait() catch {};
    }
}

test "the frame is centered and exactly half the host" {
    const frame = try centeredFrame(120, 40);
    try std.testing.expectEqual(ui.Rect{ .x = 30, .y = 10, .w = 60, .h = 20 }, frame.outer);
    try std.testing.expectEqual(ui.Rect{ .x = 31, .y = 11, .w = 58, .h = 18 }, frame.content);
}

test "child KGP becomes an exterior placement at the centered pane offset" {
    const size: schema.TerminalSize = .{
        .cols = 20,
        .rows = 10,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };
    var emulator: Emulator = undefined;
    try emulator.init(.{ .io = std.testing.io, .allocator = std.testing.allocator, .size = size });
    defer emulator.deinit();
    emulator.ingest(
        "\x1b_Ga=T,f=32,s=1,v=1,t=d,i=7,p=3,c=2,r=1;AQID/w==\x1b\\",
    );

    var store = kitty.Store.init(std.testing.allocator);
    defer store.deinit();
    var mirror: GraphicsMirror = .{};
    try std.testing.expect(try mirror.sync(&emulator, &store));

    var model = multiplexer.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(pane_id, location, size);
    const area: ui.Rect = .{ .x = 10, .y = 5, .w = 20, .h = 10 };
    var graphics_writer: kitty.KittyGraphicsWriter = .{
        .store = &store,
        .layout_snapshot = model.layoutSnapshot(area),
        .cell_width = 10,
        .cell_height = 20,
    };
    var bytes: [16 * 1024]u8 = undefined;
    var writer = Io.Writer.fixed(&bytes);
    _ = try graphics_writer.write(&writer);
    const output = writer.buffered();

    // Child image ID 7 is terminated; the exterior owns ID 1. The placement
    // starts at host row 6, column 11, which is area (10, 5) in zero-based cells.
    try std.testing.expect(std.mem.indexOf(u8, output, "a=t,f=32,s=1,v=1,t=d,i=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[6;11H") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "i=7") == null);
}
