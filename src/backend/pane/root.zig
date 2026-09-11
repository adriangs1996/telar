//! One runtime pane: its process, PTY, emulator, buffers, and quotas.
//!
//! Split out of `runtime.zig`; ownership rules are unchanged. The runtime
//! event loop drives these panes through `PaneStore`. Actor results cross back
//! into that owner as `PaneKey` values, never as mutable pane pointers.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const agent_process = @import("../process/root.zig");
const history = @import("../history/root.zig");
pub const blit = @import("blit.zig");
pub const damage = @import("damage.zig");
const escape = history.escape;
const media_mod = @import("../media/root.zig");
pub const shared_transfer = media_mod.shared_transfer;
const pty = @import("../pty/root.zig");

pub const Io = std.Io;
pub const schema = core.schema;
pub const diagnostics = core.diagnostics;

pub const max_panes = schema.max_panes_per_tab;

pub const output_chunk_size = 16 * 1024;

pub const max_pty_response_bytes = 1024;

pub const max_pty_responses = 64;

/// Retained VT history per pane. This matches herdr's default and stays a byte
/// quota so wide, styled terminal rows are charged for what they retain.
pub const default_scrollback_bytes = 10_000_000;

/// How long a child's synchronized-output block (DEC mode 2026) may hold
/// frames back before it is ignored. Same value ghostty uses to reset the
/// mode when a program forgets to close its block.
pub const max_sync_hold_ns = 1000 * std.time.ns_per_ms;

pub const PaneKey = @import("PaneKey.zig");

pub const PaneLaunched = @import("PaneLaunched.zig");

pub const LaunchState = enum {
    starting,
    running,
    aborting,

    pub fn commit(state: *LaunchState) void {
        std.debug.assert(state.* == .starting);
        state.* = .running;
    }

    pub fn abort(state: *LaunchState) void {
        std.debug.assert(state.* == .starting);
        state.* = .aborting;
    }

    pub fn discoverable(state: LaunchState) bool {
        return state == .running;
    }
};

pub const GraphicsLimits = media_mod.GraphicsLimits;
pub const ParkingMutex = media_mod.ParkingMutex;
pub const GraphicsBudget = media_mod.GraphicsBudget;
pub const PaneMediaAllocator = media_mod.PaneMediaAllocator;

pub const PaneIngestStats = @import("PaneIngestStats.zig");

pub const HistoryObservationBorrow = @import("HistoryObservationBorrow.zig");

pub const HistoryObservationCompletion = @import("HistoryObservationCompletion.zig");

pub const MediaProcessingBorrow = @import("MediaProcessingBorrow.zig");

pub const PtyResponseQueue = @import("PtyResponseQueue.zig");

pub const PaneInputQueue = @import("PaneInputQueue.zig");

pub const PtyWriteResult = enum {
    succeeded,
    failed,
};

pub const PtyOutputReadResult = enum {
    data,
    finished,
};

pub const KittyFramingCounter = escape.KittyFramingCounter;

pub const CwdState = @import("CwdState.zig");

pub const TitleState = @import("TitleState.zig");

pub fn sanitizeTitle(storage: *[schema.max_pane_title_bytes]u8, raw: []const u8) usize {
    var len: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(raw);
    var iterator = view.iterator();
    while (iterator.nextCodepointSlice()) |sequence| {
        if (sequence.len == 1 and (sequence[0] < 0x20 or sequence[0] == 0x7f)) {
            continue;
        }
        if (!std.unicode.utf8ValidateSlice(sequence)) {
            continue;
        }
        if (len + sequence.len > storage.len) {
            break;
        }

        @memcpy(storage[len .. len + sequence.len], sequence);
        len += sequence.len;
    }

    return len;
}

pub const LaunchRecord = @import("LaunchRecord.zig");

pub const TextSearch = @import("text_search.zig").Cursor;
pub const max_search_rows = @import("text_search.zig").max_rows;
pub const max_search_cols = @import("text_search.zig").max_cols;

pub const SearchResult = @import("SearchResult.zig");

pub const TextRequest = @import("TextRequest.zig");

pub const TextDump = @import("TextDump.zig");

pub const Pane = @import("Pane.zig");

pub const ScreenResize = @import("ScreenResize.zig");

/// Resizes the cell grid and its per-row damage flags together.
///
/// The two lengths are one invariant: `blit` writes `damaged[row]` for every
/// row of the screen, so a screen that grew without its flags is an
/// out-of-bounds write in release builds. Either both carry the new geometry
/// after this returns, or an error left both untouched.
///
/// ```zig
/// try resizeScreenStorage(.{ .gpa = gpa, .screen = screen, .damaged_rows = damaged, .cols = cols, .rows = rows });
/// ```
pub fn resizeScreenStorage(resize_request: ScreenResize) !void {
    const gpa = resize_request.gpa;
    const screen = resize_request.screen;
    const damaged_rows = resize_request.damaged_rows;
    const cols = resize_request.cols;
    const rows = resize_request.rows;

    const damaged = try gpa.alloc(bool, rows);
    screen.resize(cols, rows) catch |err| {
        gpa.free(damaged);
        return err;
    };
    @memset(damaged, false);
    gpa.free(damaged_rows.*);
    damaged_rows.* = damaged;
}

/// Fixed-capacity open-addressed map from a raw u64 id to a store slot.
///
/// `find` runs on the interactive path - per keystroke through
/// `attachedPane`, per event through `collectFinished` - where a linear scan
/// of the store was O(pane count) each time. Ids are never zero and never
/// `maxInt`, which the empty and tombstone markers rely on.
pub const SlotIndex = core.fixed_index.SlotIndex;

pub const PaneExitTransition = @import("PaneExitTransition.zig");

pub const PaneStore = @import("PaneStore.zig");

pub fn historyClock(io: Io) history.osc.Clock {
    return .{
        .real_ms = Io.Timestamp.now(io, .real).toMilliseconds(),
        .awake_ns = @intCast(Io.Timestamp.now(io, .awake).toNanoseconds()),
    };
}

test "pane color defaults answer fragmented OSC queries and preserve overrides" {
    const gpa = std.testing.allocator;
    var pane: Pane = undefined;
    pane.terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 4, .rows = 2 });
    defer pane.terminal.deinit(gpa);
    pane.ingest_pending = false;
    pane.pty_responses = .{};
    var handler = pane.terminal.vtHandler();
    handler.effects.write_pty = Pane.writePty;
    pane.stream = vt.TerminalStream.init(.{ .allocator = gpa, .handler = handler });
    defer pane.stream.deinit();
    pane.setTerminalColors(.{ .foreground = .{ 255, 255, 255 }, .background = .{ 16, 16, 16 } });

    const query = "\x1b]10;?\x07\x1b]11;?\x1b\\";
    for (0..query.len + 1) |split| {
        pane.stream.nextSlice(query[0..split]);
        pane.stream.nextSlice(query[split..]);
        try std.testing.expectEqualStrings("\x1b]10;rgb:ffff/ffff/ffff\x07", pane.pty_responses.peek().?);
        pane.pty_responses.pop();
        try std.testing.expectEqualStrings("\x1b]11;rgb:1010/1010/1010\x1b\\", pane.pty_responses.peek().?);
        pane.pty_responses.pop();
    }

    pane.stream.nextSlice("\x1b]10;rgb:aa/bb/cc\x07\x1b]11;rgb:12/34/56\x07");
    pane.setTerminalColors(.{ .foreground = .{ 1, 2, 3 }, .background = .{ 4, 5, 6 } });
    try std.testing.expectEqual(vt.color.RGB{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, pane.terminal.colors.foreground.get().?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 0x12, .g = 0x34, .b = 0x56 }, pane.terminal.colors.background.get().?);
    pane.stream.nextSlice("\x1b]110\x07\x1b]111\x1b\\");
    try std.testing.expectEqual(vt.color.RGB{ .r = 1, .g = 2, .b = 3 }, pane.terminal.colors.foreground.get().?);
    try std.testing.expectEqual(vt.color.RGB{ .r = 4, .g = 5, .b = 6 }, pane.terminal.colors.background.get().?);

    pane.actor_count = 0;
    pane.output_pending = false;
    _ = pane.beginOutputIngest(1);
    pane.setTerminalColors(.{ .background = .{ 7, 8, 9 } });
    pane.setTerminalColors(.{ .background = .{ 10, 11, 12 } });
    try std.testing.expectEqual(@as(u8, 4), pane.terminal.colors.background.get().?.r);
    pane.completeOutputIngest();
    try std.testing.expect(pane.pending_terminal_colors == null);
    try std.testing.expectEqual(@as(u8, 10), pane.terminal.colors.background.get().?.r);
    try std.testing.expect(pane.terminal.colors.foreground.get() == null);
}

test "agent reports capture runtime geometry without accessing the observation terminal" {
    const io = std.testing.io;
    var service = try history.Service.init(std.testing.allocator, .{ .database_path = ":memory:" });
    defer service.deinit(io);
    const pane = try std.testing.allocator.create(Pane);
    defer std.testing.allocator.destroy(pane);
    pane.io = io;
    pane.history_service = &service;
    pane.history_sequence = .{};
    pane.history_session_id = @splat(1);
    pane.id = @enumFromInt(7);
    pane.location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(2) };
    pane.workspace_path = &.{};
    pane.size = .{ .cols = 80, .rows = 24 };

    try std.testing.expect(pane.recordAgentCommand(.{
        .command = .{ .bytes = "echo hello", .cwd = "/", .started_at_ms = 1, .duration_ns = 0, .exit_code = 0, .status = .completed, .truncated = false },
        .provider = "pi",
        .tool_call_id = "call-1",
        .origin = .hook,
    }));
    const request = try service.channel.receiveRequest(io, &service.stats);
    defer history.model.deinitRequest(request, std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 80), request.command_finished.cols);
    try std.testing.expectEqual(@as(u16, 24), request.command_finished.rows);
    try std.testing.expectEqual(@as(u64, 1), request.command_finished.sequence);
}

test "cwd state is bounded and advances only for a new valid path" {
    var state = try CwdState.init("/work/telar");
    try std.testing.expectEqualStrings("/work/telar", state.slice());
    try std.testing.expectEqual(@as(u64, 1), state.revision);
    try std.testing.expect(!state.update("/work/telar"));
    try std.testing.expectEqual(@as(u64, 1), state.revision);

    try std.testing.expect(state.update("/work/agents"));
    try std.testing.expectEqualStrings("/work/agents", state.slice());
    try std.testing.expectEqual(@as(u64, 2), state.revision);

    try std.testing.expect(!state.update(""));
    try std.testing.expect(!state.update("/work\x00hidden"));
    const oversized = [_]u8{'x'} ** (schema.max_cwd_bytes + 1);
    try std.testing.expect(!state.update(&oversized));
    try std.testing.expectEqualStrings("/work/agents", state.slice());
    try std.testing.expectError(error.InvalidCwd, CwdState.init(""));
}

test "pane store rejects an event from another generation" {
    var store: PaneStore = .{};
    var pane: Pane = undefined;
    pane.id = @enumFromInt(7);
    pane.generation = 11;
    try store.insert(&pane);

    try std.testing.expectEqual(&pane, store.resolve(.{
        .id = pane.id,
        .generation = pane.generation,
    }).?);
    try std.testing.expect(store.resolve(.{
        .id = pane.id,
        .generation = pane.generation + 1,
    }) == null);

    store.index.remove(schema.id.raw(pane.id));
    store.items = @splat(null);
    store.count = 0;
}

test "graphics allocator reserves pane and global bytes before allocation" {
    var budget = GraphicsBudget.init(64);
    var first = PaneMediaAllocator.init(std.testing.allocator, &budget, 48);
    var second = PaneMediaAllocator.init(std.testing.allocator, &budget, 48);
    const first_allocator = first.allocator();
    const second_allocator = second.allocator();

    const a = try first_allocator.alloc(u8, 40);
    defer first_allocator.free(a);
    const b = try second_allocator.alloc(u8, 24);
    defer second_allocator.free(b);
    try std.testing.expectError(error.OutOfMemory, second_allocator.alloc(u8, 1));
    try std.testing.expectEqual(@as(usize, 64), budget.used);
    try std.testing.expectEqual(@as(usize, 40), first.used);
    try std.testing.expectEqual(@as(usize, 24), second.used);
}

test "frozen graphics transfers use the same reservation as VT media" {
    var budget = GraphicsBudget.init(64);
    var media = PaneMediaAllocator.init(std.testing.allocator, &budget, 64);
    const allocator = media.allocator();
    const decoded = try allocator.alloc(u8, 40);
    defer allocator.free(decoded);

    try std.testing.expect(media.reserveManual(24));
    try std.testing.expect(!media.reserveManual(1));
    media.releaseManual(24);
    try std.testing.expectEqual(@as(usize, 40), budget.used);
}

test "the slot index survives collisions, removals, and slot reuse" {
    var index: SlotIndex(8) = .{};
    // More keys than buckets divided by two forces probe chains.
    index.put(1, 0);
    index.put(9, 1);
    index.put(17, 2);
    try std.testing.expectEqual(@as(?usize, 0), index.get(1));
    try std.testing.expectEqual(@as(?usize, 1), index.get(9));
    try std.testing.expectEqual(@as(?usize, 2), index.get(17));
    try std.testing.expectEqual(@as(?usize, null), index.get(25));

    // A tombstone must not break the probe chain behind it.
    index.remove(9);
    try std.testing.expectEqual(@as(?usize, null), index.get(9));
    try std.testing.expectEqual(@as(?usize, 2), index.get(17));

    // And its bucket is reusable.
    index.put(33, 5);
    try std.testing.expectEqual(@as(?usize, 5), index.get(33));

    index.reset();
    try std.testing.expectEqual(@as(?usize, null), index.get(1));
    try std.testing.expectEqual(@as(?usize, null), index.get(17));
}

test "pane launch state settles exactly once" {
    var committed: LaunchState = .starting;
    committed.commit();
    try std.testing.expectEqual(LaunchState.running, committed);
    try std.testing.expect(committed.discoverable());

    var aborted: LaunchState = .starting;
    aborted.abort();
    try std.testing.expectEqual(LaunchState.aborting, aborted);
    try std.testing.expect(!aborted.discoverable());
}

test "PaneStore discovers only committed launches" {
    const pane_id = try schema.id.pane(1);
    const location: schema.TabLocation = .{
        .workspace = .{ .workspace = try schema.id.workspace(1) },
        .tab_id = try schema.id.tab(1),
    };
    var pane: Pane = undefined;
    pane.id = pane_id;
    pane.generation = 1;
    pane.location = location;
    pane.launch_state = .starting;
    pane.close_requested = false;
    pane.exit = null;

    var store: PaneStore = .{};
    try store.insert(&pane);
    try std.testing.expect(store.find(pane_id) == &pane);
    try std.testing.expect(store.findRunning(pane_id) == null);
    try std.testing.expect(store.firstAt(location) == null);
    try std.testing.expectEqual(@as(u16, 0), store.countAt(location));
    try std.testing.expect(store.hasAt(location));

    pane.launch_state.commit();
    try std.testing.expect(store.findRunning(pane_id) == &pane);
    try std.testing.expect(store.firstAt(location) == &pane);
    try std.testing.expectEqual(@as(u16, 1), store.countAt(location));
}

test "pane creation releases every partial allocation" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var history_service = try history.Service.init(gpa, .{ .database_path = ":memory:" });
    defer history_service.deinit(io);
    const argv = [_][*:0]const u8{"/usr/bin/true"};
    const command = try pty.Command.fromArgv(&argv);
    const limits: GraphicsLimits = .{};
    var fail_index: usize = 0;
    var completed = false;
    while (!completed) : (fail_index += 1) {
        try std.testing.expect(fail_index < 256);
        var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        var budget = GraphicsBudget.init(limits.global_bytes);
        const result = Pane.create(.{
            .io = io,
            .gpa = failing.allocator(),
            .history_service = &history_service,
            .graphics_budget = &budget,
        }, .{
            .identity = .{ .id = @enumFromInt(1), .generation = 1 },
            .location = .{
                .workspace = .{ .workspace = @enumFromInt(1) },
                .tab_id = @enumFromInt(1),
            },
            .command = &command,
            .launch_cwd = "/work/telar",
            .workspace_path = "/work/telar",
            .size = .{ .cols = 20, .rows = 5 },
            .graphics_limits = limits,
        });
        if (result) |pane| {
            pane.abortLaunch();
            pane.destroy();
            completed = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        try std.testing.expectEqual(@as(usize, 0), budget.used);
    }
}

test "pane keeps launch cwd separate from workspace path" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var history_service = try history.Service.init(gpa, .{ .database_path = ":memory:" });
    defer history_service.deinit(io);
    const argv = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try pty.Command.fromArgv(&argv);
    var budget = GraphicsBudget.init(core.graphics.max_image_bytes_global);
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &history_service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = @enumFromInt(1), .generation = 1 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .command = &command,
        .launch_cwd = "/",
        .workspace_path = "/work/telar",
        .size = .{ .cols = 20, .rows = 5 },
        .graphics_limits = .{},
    });
    defer {
        pane.session.shutdown();
        pane.destroy();
    }
    try std.testing.expectEqualStrings("/", pane.cwd.slice());
    try std.testing.expectEqualStrings("/work/telar", pane.workspace_path);
}

test "pane retains OSC 9 progress without painting it into terminal cells" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var history_service = try history.Service.init(gpa, .{ .database_path = ":memory:" });
    defer history_service.deinit(io);
    const argv = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try pty.Command.fromArgv(&argv);
    var budget = GraphicsBudget.init(core.graphics.max_image_bytes_global);
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &history_service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = @enumFromInt(1), .generation = 1 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .command = &command,
        .launch_cwd = "/",
        .workspace_path = "/work/telar",
        .size = .{ .cols = 20, .rows = 5 },
        .graphics_limits = .{},
    });
    defer {
        pane.session.shutdown();
        pane.destroy();
    }

    const initial_revision = pane.progress_revision;
    _ = try pane.ingest(io, "\x1b]9;4;1;42\x1b\\");

    try std.testing.expectEqual(schema.PaneProgressState.set, pane.progress_state);
    try std.testing.expectEqual(@as(?u8, 42), pane.progress_percent);
    try std.testing.expectEqual(initial_revision + 1, pane.progress_revision);

    _ = try pane.ingest(io, "\x1b]9;4;0\x1b\\");
    try std.testing.expectEqual(schema.PaneProgressState.remove, pane.progress_state);
    try std.testing.expectEqual(@as(?u8, null), pane.progress_percent);
}

test "shell regaining the terminal expires the job's progress report" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var history_service = try history.Service.init(gpa, .{ .database_path = ":memory:" });
    defer history_service.deinit(io);
    const argv = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try pty.Command.fromArgv(&argv);
    var budget = GraphicsBudget.init(core.graphics.max_image_bytes_global);
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &history_service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = @enumFromInt(1), .generation = 1 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .command = &command,
        .launch_cwd = "/",
        .workspace_path = "/work/telar",
        .size = .{ .cols = 20, .rows = 5 },
        .graphics_limits = .{},
    });
    defer {
        pane.session.shutdown();
        pane.destroy();
    }

    _ = try pane.ingest(io, "\x1b]9;4;3\x1b\\");
    const reported_revision = pane.progress_revision;

    pane.expireProgress(false);
    try std.testing.expectEqual(schema.PaneProgressState.indeterminate, pane.progress_state);
    try std.testing.expectEqual(reported_revision, pane.progress_revision);

    pane.expireProgress(true);
    try std.testing.expectEqual(schema.PaneProgressState.remove, pane.progress_state);
    try std.testing.expectEqual(@as(?u8, null), pane.progress_percent);
    try std.testing.expectEqual(reported_revision + 1, pane.progress_revision);

    pane.expireProgress(true);
    try std.testing.expectEqual(reported_revision + 1, pane.progress_revision);
}

test "pane close requests shut down the PTY exactly once" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var history_service = try history.Service.init(gpa, .{ .database_path = ":memory:" });
    defer history_service.deinit(io);
    const argv = [_][*:0]const u8{ "/bin/sleep", "600" };
    const command = try pty.Command.fromArgv(&argv);
    var budget = GraphicsBudget.init(core.graphics.max_image_bytes_global);
    const pane = try Pane.create(.{
        .io = io,
        .gpa = gpa,
        .history_service = &history_service,
        .graphics_budget = &budget,
    }, .{
        .identity = .{ .id = @enumFromInt(1), .generation = 1 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .command = &command,
        .launch_cwd = "/",
        .workspace_path = "/work/telar",
        .size = .{ .cols = 20, .rows = 5 },
        .graphics_limits = .{},
    });
    defer pane.destroy();

    try std.testing.expect(pane.requestClose());
    try std.testing.expect(!pane.requestClose());
    try std.testing.expect(pane.close_requested);
}

test "a pane is destroyable only when no actor can still borrow it" {
    var pane: Pane = undefined;
    pane.exit = .{ .exited = 0 };
    pane.output_done = true;
    pane.actor_count = 0;
    pane.pty_responses = .{};
    pane.history_observer.active = 0;
    pane.history_observer.worker = null;
    pane.history_observer.batches = .{ .{}, .{} };
    pane.media.active = 0;
    pane.media.worker = null;
    pane.media.batches = .{ .{}, .{} };
    try std.testing.expect(pane.readyToDestroy());

    pane.actorStarted();
    try std.testing.expect(!pane.readyToDestroy());
    pane.actorStarted();
    try std.testing.expect(!pane.readyToDestroy());
    pane.actorFinished();
    try std.testing.expect(!pane.readyToDestroy());
    pane.actorFinished();
    try std.testing.expect(pane.readyToDestroy());
    _ = pane.pty_responses.push("late reply");
    try std.testing.expect(!pane.readyToDestroy());
    pane.pty_responses.clear();
    pane.exit = null;
    try std.testing.expect(!pane.readyToDestroy());
}

test "a child's synchronized-output block holds frames until it closes or expires" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pane: Pane = undefined;
    pane.terminal = try vt.Terminal.init(io, gpa, .{ .cols = 10, .rows = 4 });
    defer pane.terminal.deinit(gpa);
    pane.sync_hold_started_ns = null;

    // No block: frames flow and no hold is recorded.
    try std.testing.expect(!pane.holdFrames(io));
    try std.testing.expectEqual(@as(?u64, null), pane.sync_hold_started_ns);

    // Inside the block frames are held, against one stable deadline.
    pane.terminal.modes.set(.synchronized_output, true);
    try std.testing.expect(pane.holdFrames(io));
    const started = pane.sync_hold_started_ns.?;
    try std.testing.expect(pane.holdFrames(io));
    try std.testing.expectEqual(started, pane.sync_hold_started_ns.?);

    // A block the child never closes expires instead of freezing the pane.
    pane.sync_hold_started_ns = started -| max_sync_hold_ns;
    try std.testing.expect(!pane.holdFrames(io));

    // Closing the block releases the hold and forgets the deadline.
    pane.sync_hold_started_ns = started;
    pane.terminal.modes.set(.synchronized_output, false);
    try std.testing.expect(!pane.holdFrames(io));
    try std.testing.expectEqual(@as(?u64, null), pane.sync_hold_started_ns);
}

test "inline output admits only a bounded simple row run without allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var pane: Pane = undefined;
    pane.terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 80, .rows = 4 });
    defer pane.terminal.deinit(gpa);
    pane.stream = pane.terminal.vtStream();
    defer pane.stream.deinit();
    pane.ingest_pending = true;

    try std.testing.expect(pane.canInlineOutput("~"));
    for ([_][]const u8{ "", "x" ** 33, "\n", "\x08 \x08", "\x1b[2J", "é" }) |bytes| {
        try std.testing.expect(!pane.canInlineOutput(bytes));
    }

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    for (0..1000) |_| {
        pane.stream.nextSlice("\x1b[H");
        try std.testing.expect(pane.canInlineOutput("~" ** 32));
        pane.stream.nextSlice("~" ** 32);
    }

    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(u21, '~'), pane.terminal.screens.active.cursorCellLeft(1).codepoint());
}

test "inline output never completes a partial control or UTF-8 sequence" {
    const gpa = std.testing.allocator;
    const sequences = [_][]const u8{ "\x1b[31m", "\x1b]2;title\x1b\\", "\x1b_Ga=d\x1b\\", "\xf0\x9f\x98\x80" };
    for (sequences) |sequence| {
        for (1..sequence.len) |split| {
            var pane: Pane = undefined;
            pane.terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 80, .rows = 4 });
            defer pane.terminal.deinit(gpa);
            pane.stream = pane.terminal.vtStream();
            defer pane.stream.deinit();
            pane.ingest_pending = true;
            pane.stream.nextSlice(sequence[0..split]);
            try std.testing.expect(!pane.canInlineOutput("~"));
        }
    }
}

test "inline output defers wrapping and complex terminal state to its actor" {
    const gpa = std.testing.allocator;
    const sequences = [_][]const u8{
        "\x1b[80G",                          "\x1b[80Gx",                                          "\x1b[4h",     "\x1b[?7l", "\x1b(0",
        "\x1bN",                             "\x1b[31m",                                           "e\xcc\x81\r",
        "界\r",
        "\x1b]8;;https://example.com\x1b\\", "\x1b]8;;https://example.com\x1b\\x\x1b]8;;\x1b\\\r",
    };
    for (sequences) |sequence| {
        var pane: Pane = undefined;
        pane.terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 80, .rows = 4 });
        defer pane.terminal.deinit(gpa);
        pane.stream = pane.terminal.vtStream();
        defer pane.stream.deinit();
        pane.ingest_pending = true;
        pane.stream.nextSlice(sequence);
        try std.testing.expect(!pane.canInlineOutput("~"));
    }
}

test "pane input modes expose child focus reporting" {
    const gpa = std.testing.allocator;
    var pane: Pane = undefined;
    pane.terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 2, .rows = 1 });
    defer pane.terminal.deinit(gpa);

    try std.testing.expect(!pane.inputModeState().focus_events);
    pane.terminal.modes.set(.focus_event, true);
    try std.testing.expect(pane.inputModeState().focus_events);
}

test "pane pointer shapes follow every VT shape across every OSC read boundary" {
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = allocator.allocator();
    var pane: Pane = undefined;
    pane.terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 2, .rows = 1 });
    defer pane.terminal.deinit(gpa);
    var stream = pane.terminal.vtStream();
    defer stream.deinit();
    try std.testing.expectEqual(schema.frame.PointerShape.text, pane.pointerShape());
    allocator.fail_index = allocator.alloc_index;
    allocator.resize_fail_index = allocator.resize_index;

    for (std.meta.tags(schema.frame.PointerShape)) |shape| {
        var buffer: [64]u8 = undefined;
        const command = try std.fmt.bufPrint(&buffer, "\x1b]22;{s}\x1b\\", .{@tagName(shape)});
        for (command) |*byte| {
            if (byte.* == '_') {
                byte.* = '-';
            }
        }

        for (0..command.len + 1) |split| {
            stream.nextSlice("\x1b]22;default\x1b\\");
            stream.nextSlice(command[0..split]);
            if (split < command.len - 1) {
                try std.testing.expectEqual(schema.frame.PointerShape.default, pane.pointerShape());
            }

            stream.nextSlice(command[split..]);
            try std.testing.expectEqual(shape, pane.pointerShape());
        }
    }

    stream.nextSlice("\x1b]22;hand\x07");
    try std.testing.expectEqual(schema.frame.PointerShape.pointer, pane.pointerShape());
    stream.nextSlice("\x1b]22;not-a-cursor\x1b\\");
    try std.testing.expectEqual(schema.frame.PointerShape.pointer, pane.pointerShape());
    stream.nextSlice("\x1b]22;default\x1b\\");
    try std.testing.expectEqual(schema.frame.PointerShape.default, pane.pointerShape());
}

test "pane keyboard modes follow VT negotiation and screen-local stacks" {
    const gpa = std.testing.allocator;
    var pane: Pane = undefined;
    pane.terminal = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = 2, .rows = 1 });
    defer pane.terminal.deinit(gpa);
    var stream = pane.terminal.vtStream();
    defer stream.deinit();

    const steps = [_]struct { sequence: []const u8, flags: u5, modify_other_keys: bool = false }{
        .{ .sequence = "\x1b[>1u", .flags = 1 },
        .{ .sequence = "\x1b[>7u", .flags = 7 },
        .{ .sequence = "\x1b[<u", .flags = 1 },
        .{ .sequence = "\x1b[?1049h", .flags = 0 },
        .{ .sequence = "\x1b[>8u", .flags = 8 },
        .{ .sequence = "\x1b[?1049l", .flags = 1 },
        .{ .sequence = "\x1b[<u", .flags = 0 },
        .{ .sequence = "\x1b[>4;2m", .flags = 0, .modify_other_keys = true },
        .{ .sequence = "\x1b[>4;0m", .flags = 0 },
    };
    for (steps) |step| {
        // VT parsing must retain a control sequence across arbitrary PTY reads.
        for (step.sequence) |byte| stream.nextSlice(&.{byte});
        const modes = pane.inputModeState();
        try std.testing.expectEqual(step.flags, modes.kitty_keyboard_flags);
        try std.testing.expectEqual(step.modify_other_keys, modes.modify_other_keys_2);
    }
}

test "a failed resize cannot split the screen from its damage flags" {
    const gpa = std.testing.allocator;
    var fail_index: usize = 0;
    var completed = false;
    while (!completed) : (fail_index += 1) {
        try std.testing.expect(fail_index < 64);
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var screen = core.ui.Buffer.init(allocator, 10, 4) catch continue;
        defer screen.deinit();
        var damaged = allocator.alloc(bool, 4) catch continue;
        defer allocator.free(damaged);
        const result = resizeScreenStorage(.{
            .gpa = allocator,
            .screen = &screen,
            .damaged_rows = &damaged,
            .cols = 20,
            .rows = 9,
        });
        // The invariant `blit` depends on, success and failure alike.
        try std.testing.expectEqual(@as(usize, screen.h), damaged.len);
        if (result) |_| {
            completed = true;
        } else |_| {}
    }
}

test "the PTY response queue bounds depth and entry size" {
    var queue: PtyResponseQueue = .{};
    try std.testing.expect(queue.push("first"));
    try std.testing.expect(queue.push("second"));
    try std.testing.expectEqualStrings("first", queue.peek().?);
    queue.pop();
    try std.testing.expectEqualStrings("second", queue.peek().?);

    const oversized = [_]u8{'x'} ** (max_pty_response_bytes + 1);
    try std.testing.expect(!queue.push(&oversized));
    try std.testing.expectEqual(@as(u64, 1), queue.dropped);

    while (queue.len < max_pty_responses) _ = queue.push("fill");
    try std.testing.expect(!queue.push("overflow"));
    try std.testing.expectEqual(@as(u64, 2), queue.dropped);
    queue.clear();
    try std.testing.expectEqual(@as(u8, 0), queue.len);
    try std.testing.expect(queue.peek() == null);
}

test "the pane input queue reports whole-message loss" {
    var queue: PaneInputQueue = .{};
    const first = [_]u8{'a'} ** schema.max_input_bytes;
    const second = [_]u8{'b'} ** schema.max_input_bytes;
    try std.testing.expect(queue.push(&first));
    try std.testing.expect(queue.push(&second));
    try std.testing.expect(!queue.push("lost"));
    try std.testing.expectEqual(@as(u64, 4), queue.dropped_bytes);
    try std.testing.expectEqual(@as(usize, PaneInputQueue.capacity), queue.len);

    queue.consume(schema.max_input_bytes);
    try std.testing.expect(queue.push("kept"));
    try std.testing.expectEqualStrings(second[0..], queue.nextChunk().?);
}

test "launch records keep restorable commands and reject the rest" {
    var arguments_buffer: [128]u8 = undefined;
    var encoder = core.schema.wire.Encoder.init(&arguments_buffer);
    try encoder.writeSized16("/bin/zsh");
    try encoder.writeSized16("-l");
    const encoded = encoder.finish();
    var record: LaunchRecord = .{};

    record.capture(.{
        .cwd = "/work",
        .argument_count = 2,
        .encoded_arguments = encoded,
        .environment_mode = .inherit_runtime,
        .environment_count = 0,
        .encoded_environment = "",
    });
    try std.testing.expect(record.restorable());
    try std.testing.expectEqualStrings("/bin/zsh\x00-l\x00", record.slice());

    record.capture(.{
        .cwd = "/work",
        .argument_count = 2,
        .encoded_arguments = encoded,
        .environment_mode = .replace,
        .environment_count = 0,
        .encoded_environment = "",
    });
    try std.testing.expect(!record.restorable());
}

test "restored pane keys are reserved in order and counters only advance" {
    var store: PaneStore = .{};

    try store.reserveRestoredKey(4, 9);
    try std.testing.expectEqual(@as(u64, 4), store.next_id);
    try std.testing.expectEqual(@as(u64, 9), store.next_generation);
    try std.testing.expectError(error.InvalidCheckpointIdentity, store.reserveRestoredKey(3, 1));
    store.advanceCounters(2, 3);
    try std.testing.expectEqual(@as(u64, 4), store.next_id);
    store.advanceCounters(10, 12);
    try std.testing.expectEqual(@as(u64, 10), store.next_id);
    try std.testing.expectEqual(@as(u64, 12), store.next_generation);
}
