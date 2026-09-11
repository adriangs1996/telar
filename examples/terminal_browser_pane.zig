//! Reduced terminal-browser reproducer.
//!
//! It keeps only the path needed to render one graphical child inside a pane:
//!
//!   terminal-browser -> PTY -> Ghostty VT -> cells + KGP -> host Ghostty
//!
//! There is no Telar runtime, IPC, history, sidebar, tabs, or configuration.

const std = @import("std");
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const FrameGeometry = @import("FrameGeometry.zig");
const RectType = @import("telar-core").Rect;
const HostCapabilities = @import("telar-client").HostCapabilities;
const TerminalSizeType = @import("telar-core").TerminalSize;
const SizeType = @import("telar-frontend").Size;
const EventType = @import("telar-frontend").Event;
const translate = @import("telar-frontend").translate;
const settledCapabilities = @import("telar-frontend").settledCapabilities;
const InputChunk = @import("InputChunk.zig");
const OutputChunk = @import("OutputChunk.zig");
const SessionType = @import("telar-backend").Session;
const ResizeWatcherType = @import("telar-frontend").ResizeWatcher;
const timeout_ns = @import("telar-frontend").timeout_ns;
const BufferType = @import("telar-core").Buffer;
const StyleType = @import("telar-core").Style;
const Emulator = @import("Emulator.zig");
const ScreenType = @import("telar-frontend").Screen;
const CellDrawOptions = @import("CellDrawOptions.zig");
const PresentContext = @import("PresentContext.zig");
const ExteriorGraphics = @import("ExteriorGraphics.zig");
const GraphicsReadiness = @import("GraphicsReadiness.zig");
const PaneGeometryContext = @import("PaneGeometryContext.zig");
const invalidatePlacements_module = @import("telar-frontend").invalidatePlacements;
const max_args_module = @import("telar-backend").max_args;
const CommandType = @import("telar-backend").Command;
const ChildEnvironmentType = @import("telar-backend").ChildEnvironment;
const TtyType = @import("telar-frontend").Tty;
const installCrashRestore_module = @import("telar-frontend").installCrashRestore;
const pane_enter = @import("telar-frontend").pane_enter;
const query = @import("telar-frontend").query;
const pane_leave = @import("telar-frontend").pane_leave;
const StoreType = @import("telar-frontend").Store;
const GraphicsMirror = @import("GraphicsMirror.zig");
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const HostInput = @import("HostInput.zig");
const KittyGraphicsWriterType = @import("telar-frontend").KittyGraphicsWriter;

pub const std_options: std.Options = .{ .log_level = .err };

pub const pane_id: PaneIdType = @enumFromInt(1);
const location: TabLocationType = .{
    .workspace = .{ .workspace = @enumFromInt(1) },
    .tab_id = @enumFromInt(1),
};
const frame_interval_ns = std.time.ns_per_s / 60;

fn centeredFrame(cols: u16, rows: u16) !FrameGeometry {
    if (cols < 8 or rows < 8) {
        return error.TerminalTooSmall;
    }
    const width = cols / 2;
    const height = rows / 2;
    if (width < 3 or height < 3) {
        return error.TerminalTooSmall;
    }
    const outer: RectType = .{
        .x = (cols - width) / 2,
        .y = (rows - height) / 2,
        .w = width,
        .h = height,
    };
    return .{ .outer = outer, .content = outer.inner(1) };
}

fn paneTerminalSize(frame: FrameGeometry, capabilities: *const HostCapabilities) TerminalSizeType {
    const cell = capabilities.cellSize(0, 0);
    return .{
        .cols = frame.content.w,
        .rows = frame.content.h,
        .cell_width_px = cell.width,
        .cell_height_px = cell.height,
    };
}

fn observePlatformPixels(capabilities: *HostCapabilities, size: SizeType) void {
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

pub fn observeHostCapability(capabilities: *HostCapabilities, response: EventType.TerminalResponse) bool {
    const observation = translate(response) orelse return false;
    const next = capabilities.withObservation(observation);
    if (std.meta.eql(capabilities.*, next)) {
        return false;
    }

    capabilities.* = next;
    return true;
}

fn expireHostCapabilities(capabilities: *HostCapabilities) bool {
    const next = settledCapabilities(capabilities.*);
    if (std.meta.eql(capabilities.*, next)) {
        return false;
    }

    capabilities.* = next;
    return true;
}

const Message = union(enum) {
    input: InputChunk,
    output: OutputChunk,
    resized,
    capability_timeout,
    child_closed,
};

fn inputActor(io: std.Io, file: std.Io.File, queue: *std.Io.Queue(Message)) std.Io.Cancelable!void {
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

fn outputActor(io: std.Io, session: *SessionType, queue: *std.Io.Queue(Message)) std.Io.Cancelable!void {
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

fn resizeActor(io: std.Io, watcher: *ResizeWatcherType, queue: *std.Io.Queue(Message)) std.Io.Cancelable!void {
    while (true) {
        try watcher.wait(io);
        queue.putOne(io, .resized) catch |err| switch (err) {
            error.Canceled => |cancelled| return cancelled,
            error.Closed => return,
        };
    }
}

fn capabilityTimeoutActor(io: std.Io, queue: *std.Io.Queue(Message)) std.Io.Cancelable!void {
    const deadline = std.Io.Timestamp.fromNanoseconds(
        @intCast(monotonic(io) + timeout_ns),
    ).withClock(.awake);
    try deadline.wait(io);
    queue.putOne(io, .capability_timeout) catch |err| switch (err) {
        error.Canceled => |cancelled| return cancelled,
        error.Closed => return,
    };
}

fn drawFrame(buffer: *BufferType, frame: FrameGeometry) void {
    const background: StyleType = .{ .bg = .{ .rgb = .{ 0x10, 0x10, 0x10 } } };
    const border: StyleType = .{
        .fg = .{ .rgb = .{ 0xff, 0xc7, 0x99 } },
        .bg = .{ .rgb = .{ 0x10, 0x10, 0x10 } },
    };
    buffer.clear(background);
    buffer.fill(frame.outer.row(0), .{ .glyph = "─", .style = border });
    buffer.fill(frame.outer.row(frame.outer.h - 1), .{ .glyph = "─", .style = border });
    buffer.fill(.{ .x = frame.outer.x, .y = frame.outer.y, .w = 1, .h = frame.outer.h }, .{ .glyph = "│", .style = border });
    buffer.fill(.{
        .x = frame.outer.x + frame.outer.w - 1,
        .y = frame.outer.y,
        .w = 1,
        .h = frame.outer.h,
    }, .{ .glyph = "│", .style = border });
    buffer.setCell(.{ .x = frame.outer.x, .y = frame.outer.y }, .{ .text = "┌", .width = 1, .style = border });
    buffer.setCell(.{ .x = frame.outer.x + frame.outer.w - 1, .y = frame.outer.y }, .{ .text = "┐", .width = 1, .style = border });
    buffer.setCell(.{ .x = frame.outer.x, .y = frame.outer.y + frame.outer.h - 1 }, .{ .text = "└", .width = 1, .style = border });
    buffer.setCell(
        .{ .x = frame.outer.x + frame.outer.w - 1, .y = frame.outer.y + frame.outer.h - 1 },
        .{ .text = "┘", .style = border },
    );
    if (frame.outer.w > 22) {
        _ = buffer.writeText(frame.outer.row(0), .{ .point = .{ .x = frame.outer.x + 2, .y = frame.outer.y }, .text = " terminal-browser ", .style = border });
    }
}

fn drainResponses(io: std.Io, session: *SessionType, emulator: *Emulator) !void {
    if (emulator.responses.overflowed) {
        return error.PtyResponseOverflow;
    }
    while (emulator.responses.peek()) |response| {
        try session.writeAll(io, response);
        emulator.responses.pop();
    }
}

fn drawCells(screen: *ScreenType, emulator: *Emulator, options: CellDrawOptions) !void {
    const frame = options.frame;
    const rebuild_frame = options.rebuild_frame;
    const buffer = screen.buffer();
    if (rebuild_frame) {
        drawFrame(buffer, frame);
    }
    screen.cursor = try emulator.draw(buffer, .{ .area = frame.content, .force = rebuild_frame });
}

fn present(context: PresentContext) !void {
    const screen = context.screen;
    const writer = context.writer;
    const emulator = context.emulator;
    const mirror = context.mirror;
    const graphics_store = context.graphics_store;
    const model = context.model;
    const frame = context.frame;
    const capabilities = context.capabilities;
    _ = try mirror.sync(emulator, graphics_store);
    const cell = capabilities.cellSize(0, 0);
    var exterior: ExteriorGraphics = .{ .writer = .{
        .store = graphics_store,
        .layout_snapshot = model.layoutSnapshot(frame.content),
        .cell_width = cell.width,
        .cell_height = cell.height,
    } };
    if (capabilities.images == .supported and
        cell.width != 0 and cell.height != 0 and graphics_store.damage)
    {
        screen.graphics = .{
            .context = &exterior,
            .write = ExteriorGraphics.writeOpaque,
        };
    }
    _ = try screen.flush(writer);
}

fn graphicsReady(state: GraphicsReadiness) bool {
    const cell = state.capabilities.cellSize(0, 0);
    if (state.capabilities.images != .supported or cell.width == 0 or cell.height == 0) {
        return false;
    }
    return state.store.damage or state.mirror.ready(state.emulator);
}

fn applyPaneGeometry(context: PaneGeometryContext) !bool {
    const next = paneTerminalSize(context.frame, context.capabilities);
    if (std.meta.eql(next, context.emulator.size)) {
        return false;
    }
    try context.session.resize(.{
        .cols = next.cols,
        .rows = next.rows,
        .cell_width_px = next.cell_width_px,
        .cell_height_px = next.cell_height_px,
    });
    try context.emulator.resize(next);
    context.model.setCellSize(next.cell_width_px, next.cell_height_px);
    invalidatePlacements_module(context.graphics_store);
    return true;
}

fn collectCommand(init: std.process.Init, storage: *[max_args_module][*:0]const u8) !CommandType {
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
    return CommandType.fromArgv(storage[0..len]);
}

fn monotonic(io: std.Io) u64 {
    const timestamp = std.Io.Timestamp.now(io, .awake);
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
    var child_environment = try ChildEnvironmentType.init(
        gpa,
        init.minimal.environ,
        "telar-pane-example",
    );
    defer child_environment.deinit();

    var tty = TtyType.open() catch |err| {
        std.debug.print("terminal-browser-pane needs a terminal: {s}\n", .{@errorName(err)});
        return err;
    };
    defer tty.deinit();
    installCrashRestore_module(&tty);

    var tty_file = tty.writeHandle();
    var output_buffer: [512 * 1024]u8 = undefined;
    var output = tty_file.writer(io, &output_buffer);
    const writer = &output.interface;
    try writer.writeAll(pane_enter);
    try writer.writeAll(query);
    try writer.flush();
    defer {
        writer.writeAll(pane_leave) catch {};
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

    var argument_storage: [max_args_module][*:0]const u8 = undefined;
    var command = try collectCommand(init, &argument_storage);
    command.environment = &child_environment;
    var session = try SessionType.spawn(&command, .{
        .cols = initial_size.cols,
        .rows = initial_size.rows,
        .cell_width_px = initial_size.cell_width_px,
        .cell_height_px = initial_size.cell_height_px,
    });
    defer session.deinit();

    var emulator: Emulator = undefined;
    try emulator.init(.{ .io = io, .allocator = gpa, .size = initial_size });
    defer emulator.deinit();

    var screen = try ScreenType.init(gpa, host_size.cols, host_size.rows);
    defer screen.deinit();
    var graphics_store = StoreType.init(gpa);
    defer graphics_store.deinit();
    var mirror: GraphicsMirror = .{};
    var model = MultiplexerModel.init(gpa);
    defer model.deinit();
    try model.addRoot(.{
        .pane_id = pane_id,
        .location = location,
        .size = initial_size,
    });
    model.setCellSize(initial_size.cell_width_px, initial_size.cell_height_px);

    var watcher = try ResizeWatcherType.init(&tty);
    defer watcher.deinit();

    var queue_storage: [32]Message = undefined;
    var queue: std.Io.Queue(Message) = .init(&queue_storage);
    var actors: std.Io.Group = .init;
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
        if (capabilities.images == .supported) {
            screen.graphics = .{ .context = &exterior, .write = ExteriorGraphics.writeOpaque };
            _ = screen.flush(writer) catch {};
        }
    }

    try drawCells(&screen, &emulator, .{ .frame = frame, .rebuild_frame = true });
    try present(.{
        .screen = &screen,
        .writer = writer,
        .emulator = &emulator,
        .mirror = &mirror,
        .graphics_store = &graphics_store,
        .model = &model,
        .frame = frame,
        .capabilities = &capabilities,
    });

    var host_input: HostInput = .{};
    var batch: [32]Message = undefined;
    var last_frame_ns = monotonic(io);
    var redraw_cells = false;
    var rebuild_frame = false;
    var stop = false;
    var child_closed = false;

    while (!stop and !child_closed) {
        const scheduled = redraw_cells or rebuild_frame or graphicsReady(.{
            .capabilities = &capabilities,
            .emulator = &emulator,
            .mirror = &mirror,
            .store = &graphics_store,
        });
        if (scheduled) {
            const deadline_ns = last_frame_ns + frame_interval_ns;
            if (monotonic(io) < deadline_ns) {
                const deadline = std.Io.Timestamp.fromNanoseconds(@intCast(deadline_ns)).withClock(.awake);
                deadline.wait(io) catch {};
            }
        }
        const minimum: usize = if (scheduled) 0 else 1;
        const count = queue.get(io, &batch, minimum) catch break;
        var should_present = scheduled;

        for (batch[0..count]) |message| switch (message) {
            .input => |chunk| {
                const result = try host_input.feed(
                    .{ .io = io, .session = &session, .capabilities = &capabilities },
                    chunk.bytes[0..chunk.len],
                );
                stop = stop or result.stop;
                if (result.capabilities_changed) {
                    if (try applyPaneGeometry(.{
                        .session = &session,
                        .emulator = &emulator,
                        .model = &model,
                        .graphics_store = &graphics_store,
                        .frame = frame,
                        .capabilities = &capabilities,
                    })) {
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
                _ = try applyPaneGeometry(.{
                    .session = &session,
                    .emulator = &emulator,
                    .model = &model,
                    .graphics_store = &graphics_store,
                    .frame = frame,
                    .capabilities = &capabilities,
                });
                invalidatePlacements_module(&graphics_store);
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
            try drawCells(&screen, &emulator, .{ .frame = frame, .rebuild_frame = rebuild_frame });
            redraw_cells = false;
            rebuild_frame = false;
            should_present = true;
        }
        if (should_present or graphicsReady(.{
            .capabilities = &capabilities,
            .emulator = &emulator,
            .mirror = &mirror,
            .store = &graphics_store,
        })) {
            try present(.{
                .screen = &screen,
                .writer = writer,
                .emulator = &emulator,
                .mirror = &mirror,
                .graphics_store = &graphics_store,
                .model = &model,
                .frame = frame,
                .capabilities = &capabilities,
            });
            last_frame_ns = monotonic(io);
        }
    }

    if (child_closed) {
        _ = session.wait() catch {};
    }
}

test "the frame is centered and exactly half the host" {
    const frame = try centeredFrame(120, 40);
    try std.testing.expectEqual(RectType{ .x = 30, .y = 10, .w = 60, .h = 20 }, frame.outer);
    try std.testing.expectEqual(RectType{ .x = 31, .y = 11, .w = 58, .h = 18 }, frame.content);
}

test "child KGP becomes an exterior placement at the centered pane offset" {
    const size: TerminalSizeType = .{
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

    var store = StoreType.init(std.testing.allocator);
    defer store.deinit();
    var mirror: GraphicsMirror = .{};
    try std.testing.expect(try mirror.sync(&emulator, &store));

    var model = MultiplexerModel.init(std.testing.allocator);
    defer model.deinit();
    try model.addRoot(.{ .pane_id = pane_id, .location = location, .size = size });
    const area: RectType = .{ .x = 10, .y = 5, .w = 20, .h = 10 };
    var graphics_writer: KittyGraphicsWriterType = .{
        .store = &store,
        .layout_snapshot = model.layoutSnapshot(area),
        .cell_width = 10,
        .cell_height = 20,
    };
    var bytes: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    _ = try graphics_writer.write(&writer);
    const output = writer.buffered();

    // Child image ID 7 is terminated; the exterior owns ID 1. The placement
    // starts at host row 6, column 11, which is area (10, 5) in zero-based cells.
    try std.testing.expect(std.mem.indexOf(u8, output, "a=t,f=32,s=1,v=1,t=d,i=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[6;11H") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "i=7") == null);
}
