const std = @import("std");
const vt = @import("ghostty-vt");
const TerminalTracker = @import("TerminalTracker.zig");
const Batch = @import("Batch.zig");
const SampleType = @import("Sample.zig");
const TableType = @import("telar-core").Table;
const builtin_table_module = @import("telar-core").builtin_table;
const SignalType = @import("telar-core").Signal;
const Initialization = @import("Initialization.zig");
const observer_support = @import("observer_support.zig");
const ObserverInputObservation = @import("ObserverInputObservation.zig");
const ObserverOutputObservation = @import("ObserverOutputObservation.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const ClockType = @import("Clock.zig");
const Processing = @import("Processing.zig");
const codex_screen = @import("codex_screen.zig");
const prompt_scan = @import("prompt_scan.zig");
const Observer = @This();

gpa: std.mem.Allocator,
terminal: vt.Terminal,
stream: vt.TerminalStream,
tracker: TerminalTracker,
enabled: bool,
batches: [2]Batch = .{ .{}, .{} },
active: u1 = 0,
worker: ?u1 = null,
dropped_events: u64 = 0,
dropped_bytes: u64 = 0,
resets: u64 = 0,
failures: u64 = 0,
sample: SampleType = .{},
manifests: *const TableType = &builtin_table_module,
last_signal: ?SignalType = null,
last_signal_ms: i64 = 0,
codex_screen_lost: bool = false,

/// Initializes the disposable history emulator and its bounded event
/// buffers for one pane.
///
/// ```zig
/// try observer.init(.{ .io = io, .gpa = gpa, .cwd = cwd, .size = size });
/// ```
pub fn init(observer: *Observer, initialization: Initialization) !void {
    const io = initialization.io;
    const gpa = initialization.gpa;
    const cwd = initialization.cwd;
    const size = initialization.size;

    observer.gpa = gpa;
    observer.terminal = try .init(io, gpa, .{ .cols = size.cols, .rows = size.rows });
    errdefer observer.terminal.deinit(gpa);
    var handler = observer.terminal.vtHandler();
    handler.apc_handler.enable(.kitty, false);
    handler.apc_handler.enable(.glyph, false);
    observer.stream = .init(.{ .allocator = gpa, .handler = handler });
    errdefer observer.stream.deinit();
    try observer.stream.handler.resize(observer_support.vtResize(size));
    observer.tracker = try .init(gpa, .{
        .cwd = cwd,
        .terminal = &observer.terminal,
        .capture_output = initialization.capture_output,
    });
    observer.enabled = true;
    observer.batches = .{ .{}, .{} };
    observer.active = 0;
    observer.worker = null;
    observer.dropped_events = 0;
    observer.dropped_bytes = 0;
    observer.resets = 0;
    observer.failures = 0;
    observer.sample = .{};
    observer.manifests = initialization.manifests;
    observer.last_signal = null;
    observer.last_signal_ms = 0;
    observer.codex_screen_lost = false;
}

pub fn deinit(observer: *Observer) void {
    if (observer.worker) |index| {
        observer.batches[index].reset();
    }
    observer.worker = null;
    if (observer.enabled) {
        observer.tracker.deinit(&observer.terminal);
        observer.stream.deinit();
    }
    observer.terminal.deinit(observer.gpa);
}

/// Copies one input event into the active bounded observation batch.
///
/// ```zig
/// observer.queueInput(.{ .bytes = bytes, .shell_foreground = true, .clock = clock });
/// ```
pub fn queueInput(observer: *Observer, observation: ObserverInputObservation) void {
    const batch = observer.prepareBytes(observation.bytes) orelse return;
    const offset = batch.pushBytes(observation.bytes) orelse unreachable;
    _ = batch.pushEvent(.{ .input = .{
        .offset = offset,
        .len = @intCast(observation.bytes.len),
        .shell_foreground = observation.shell_foreground,
        .clock = observation.clock,
    } });
}

/// Copies one output event into the active bounded observation batch.
///
/// ```zig
/// observer.queueOutput(.{ .bytes = bytes, .shell_foreground = foreground, .clock = clock });
/// ```
pub fn queueOutput(observer: *Observer, observation: ObserverOutputObservation) void {
    const batch = observer.prepareBytes(observation.bytes) orelse return;
    const offset = batch.pushBytes(observation.bytes) orelse unreachable;
    _ = batch.pushEvent(.{ .output = .{
        .offset = offset,
        .len = @intCast(observation.bytes.len),
        .shell_foreground = observation.shell_foreground,
        .clock = observation.clock,
    } });
}

pub fn queueResize(observer: *Observer, size: TerminalSizeType) void {
    observer.pushControl(.{ .resize = size });
}

pub fn queueShellExit(observer: *Observer, clock: ClockType, exit_code: i32) void {
    observer.pushControl(.{ .shell_exit = .{ .clock = clock, .exit_code = exit_code } });
}

pub fn queueInterrupt(observer: *Observer, clock: ClockType) void {
    observer.pushControl(.{ .interrupt = clock });
}

pub fn hasPending(observer: *const Observer) bool {
    return observer.worker == null and observer.batches[observer.active].event_count != 0;
}

pub fn currentCwd(observer: *const Observer) []const u8 {
    if (!observer.enabled) {
        return "";
    }
    return observer.tracker.currentCwd();
}

pub fn seal(observer: *Observer) bool {
    if (!observer.hasPending()) {
        return false;
    }
    const sealed = observer.active;
    observer.active ^= 1;
    std.debug.assert(observer.batches[observer.active].event_count == 0);
    observer.worker = sealed;
    return true;
}

pub fn finishSealed(observer: *Observer) void {
    const index = observer.worker orelse unreachable;
    observer.batches[index].reset();
    observer.worker = null;
}

/// Replays one sealed batch through the history emulator and emits complete
/// commands to a statically dispatched sink exposing `emit(Command)`.
///
/// ```zig
/// observer.processSealed(.{ .cwd = cwd, .current_size = size, .stats = stats }, &sink);
/// ```
pub fn processSealed(observer: *Observer, processing: Processing, sink: anytype) void {
    const cwd = processing.cwd;
    const current_size = processing.current_size;
    const stats = processing.stats;

    const index = observer.worker orelse return;
    const batch = &observer.batches[index];
    var latest_clock: ?ClockType = null;
    if (batch.reset_before) {
        const reset_cwd = cwd orelse if (observer.enabled)
            observer.tracker.currentCwd()
        else
            "";
        observer.resetState(reset_cwd, current_size) catch {
            observer.failures +|= 1;
            stats.failed = true;
            return;
        };
        observer.resets +|= 1;
        stats.reset = true;
    } else if (!observer.enabled) {
        stats.failed = true;
        return;
    } else if (cwd) |path| {
        observer.tracker.updateCwd(path);
    }

    for (batch.events[0..batch.event_count]) |event| switch (event) {
        .input => |input| {
            const start: usize = input.offset;
            stats.input_bytes +|= observer.tracker.observeInput(.{
                .terminal = &observer.terminal,
                .bytes = batch.bytes[start..][0..input.len],
                .shell_foreground = input.shell_foreground,
                .clock = input.clock,
            }, sink);
        },
        .output => |output| {
            const start: usize = output.offset;
            latest_clock = output.clock;
            observer.observeOutput(.{
                .bytes = batch.bytes[start..][0..output.len],
                .clock = output.clock,
                .shell_foreground = output.shell_foreground,
            }, sink);
        },
        .resize => |size| observer.stream.handler.resize(observer_support.vtResize(size)) catch {
            observer.failures +|= 1;
            stats.failed = true;
        },
        .shell_exit => |exit| observer.tracker.shellExited(.{
            .clock = exit.clock,
            .exit_code = exit.exit_code,
        }, sink),
        .interrupt => |clock| observer.tracker.interrupt(clock, sink),
    };
    // Input, resize, and a worker's delivery time cannot make an old
    // screen newer than a lifecycle report. Nor is a partial VT frame a
    // completion: Codex temporarily erases its status while repainting.
    const clock = latest_clock orelse return;
    if (!observer.stream.ground() or observer.terminal.modes.get(.synchronized_output)) {
        return;
    }

    observer.sample.capture(&observer.terminal);
    const phrase_signal = observer.sample.signal(observer.manifests);
    const codex = codex_screen.scan(&observer.terminal, observer.manifests);
    const signal = if (processing.provider == .codex or
        (processing.provider == .unknown and codex != null and codex.?.identity_confirmed))
        codex
    else if (processing.provider == .unknown and phrase_signal != null and phrase_signal.?.provider == .codex)
        null
    else
        observer_support.mergeSignals(observer.manifests, phrase_signal, prompt_scan.scanReadyPrompt(&observer.terminal));
    if (signal) |candidate| {
        if (candidate.provider == .codex) {
            if (candidate.status == .working) {
                observer.codex_screen_lost = false;
            } else if (observer.codex_screen_lost) {
                // A dropped status row must not turn an incremental
                // composer repaint into proof of completion.
                return;
            }
        }
    }

    if (observer.publishSignal(signal, clock.real_ms)) |published| {
        stats.agent_observation = .{ .signal = published, .observed_at_ms = clock.real_ms, .observed_at_ns = clock.awake_ns };
    }
}

/// Hands one screen signal to the runtime when it differs from the last
/// one handed over, or when that one is old enough to need a refresh.
/// An unchanged screen stays quiet in between, so a repainting spinner
/// does not republish the projection on every batch. Codex's ready screen
/// is reconsidered on output: the prior sample may have preceded Stop and
/// been rejected by the runtime. Input alone never refreshes this proof.
fn publishSignal(observer: *Observer, signal: ?SignalType, now_ms: ?i64) ?SignalType {
    const current = signal orelse {
        observer.last_signal = null;
        return null;
    };

    if (observer.last_signal) |previous| {
        if (std.meta.eql(previous, current) and !(current.provider == .codex and current.ready_confirmed)) {
            const clock = now_ms orelse return null;

            if (clock - observer.last_signal_ms < observer_support.signal_refresh_ms) {
                return null;
            }
        }
    }

    observer.last_signal = current;
    if (now_ms) |clock| {
        observer.last_signal_ms = clock;
    }

    return current;
}

fn observeOutput(observer: *Observer, observation: ObserverOutputObservation, sink: anytype) void {
    var offset: usize = 0;
    while (offset < observation.bytes.len) {
        const remaining = observation.bytes[offset..];
        const boundary = observer.tracker.commitBoundary(remaining);
        const slice = if (boundary) |len| remaining[0..len] else remaining;
        observer.stream.nextSlice(slice);
        if (boundary != null) {
            _ = observer.tracker.captureSubmitted(&observer.terminal) catch {
                observer.failures +|= 1;
            };
        }
        observer.tracker.observeOutput(.{
            .terminal = &observer.terminal,
            .bytes = slice,
            .clock = observation.clock,
            .shell_foreground = observation.shell_foreground,
        }, sink);
        offset += slice.len;
    }
}

fn prepareBytes(observer: *Observer, bytes: []const u8) ?*Batch {
    if (bytes.len > observer_support.batch_bytes) {
        observer.dropActive(bytes.len, 1);
        return null;
    }
    var batch = &observer.batches[observer.active];
    if (batch.event_count == batch.events.len or bytes.len > batch.bytes.len - batch.len) {
        observer.dropActive(bytes.len, 1);
        batch = &observer.batches[observer.active];
    }
    return batch;
}

fn pushControl(observer: *Observer, event: observer_support.Event) void {
    var batch = &observer.batches[observer.active];
    if (!batch.pushEvent(event)) {
        observer.dropActive(0, 1);
        batch = &observer.batches[observer.active];
        _ = batch.pushEvent(event);
    }
}

fn dropActive(observer: *Observer, incoming_bytes: usize, incoming_events: usize) void {
    const batch = &observer.batches[observer.active];
    observer.dropped_events +|= batch.event_count + incoming_events;
    observer.dropped_bytes +|= batch.len + incoming_bytes;
    batch.reset();
    batch.reset_before = true;
}

fn resetState(observer: *Observer, cwd: []const u8, size: TerminalSizeType) !void {
    observer.tracker.deinit(&observer.terminal);
    observer.stream.deinit();
    observer.enabled = false;
    observer.last_signal = null;
    observer.last_signal_ms = 0;
    observer.codex_screen_lost = true;
    observer.terminal.fullReset();
    var handler = observer.terminal.vtHandler();
    handler.apc_handler.enable(.kitty, false);
    handler.apc_handler.enable(.glyph, false);
    observer.stream = .init(.{ .allocator = observer.gpa, .handler = handler });
    errdefer observer.stream.deinit();
    try observer.stream.handler.resize(observer_support.vtResize(size));
    observer.tracker = try .init(observer.gpa, .{ .cwd = cwd, .terminal = &observer.terminal });
    observer.enabled = true;
}
