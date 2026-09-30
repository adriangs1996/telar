const core = @import("telar-core");
const std = @import("std");
const vt = @import("ghostty-vt");
const cmdcapture = @import("cmdcapture");
const TerminalTracker = cmdcapture.TerminalTracker;
const Sample = @import("Sample.zig");
const Initialization = @import("Initialization.zig");
const observer_support = @import("observer_support.zig");
const ObserverInputObservation = @import("ObserverInputObservation.zig");
const ObserverOutputObservation = @import("ObserverOutputObservation.zig");
const Clock = cmdcapture.Clock;
const Processing = @import("Processing.zig");
const codex_screen = @import("codex_screen.zig");
const cursor_screen = @import("cursor_screen.zig");
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
sample: Sample = .{},
manifests: *const core.Table = &core.builtin_table,
last_signal: ?core.Signal = null,
last_signal_ms: i64 = 0,
composer_lost: bool = false,

/// Initializes the disposable history emulator and its bounded event
/// buffers for one pane.
///
/// ```zig
/// try observer.init(.{ .io = io, .gpa = gpa, .cwd = cwd, .size = size });
/// ```
pub fn init(self: *Observer, initialization: Initialization) !void {
    const io = initialization.io;
    const gpa = initialization.gpa;
    const cwd = initialization.cwd;
    const size = initialization.size;

    self.gpa = gpa;
    self.terminal = try .init(io, gpa, .{ .cols = size.cols, .rows = size.rows });
    errdefer self.terminal.deinit(gpa);
    var handler = self.terminal.vtHandler();
    handler.apc_handler.enable(.kitty, false);
    handler.apc_handler.enable(.glyph, false);
    self.stream = .init(.{ .allocator = gpa, .handler = handler });
    errdefer self.stream.deinit();
    try self.stream.handler.resize(observer_support.vtResize(size));
    self.tracker = try .init(gpa, .{
        .cwd = cwd,
        .terminal = &self.terminal,
        .capture_output = initialization.capture_output,
    });
    self.enabled = true;
    self.batches = .{ .{}, .{} };
    self.active = 0;
    self.worker = null;
    self.dropped_events = 0;
    self.dropped_bytes = 0;
    self.resets = 0;
    self.failures = 0;
    self.sample = .{};
    self.manifests = initialization.manifests;
    self.last_signal = null;
    self.last_signal_ms = 0;
    self.composer_lost = false;
}

pub fn deinit(self: *Observer) void {
    if (self.worker) |index| {
        self.batches[index].reset();
    }
    self.worker = null;
    if (self.enabled) {
        self.tracker.deinit(&self.terminal);
        self.stream.deinit();
    }
    self.terminal.deinit(self.gpa);
}

/// Copies one input event into the active bounded observation batch.
///
/// ```zig
/// observer.queueInput(.{ .bytes = bytes, .shell_foreground = true, .clock = clock });
/// ```
pub fn queueInput(self: *Observer, observation: ObserverInputObservation) void {
    const batch = self.prepareBytes(observation.bytes) orelse return;
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
pub fn queueOutput(self: *Observer, observation: ObserverOutputObservation) void {
    const batch = self.prepareBytes(observation.bytes) orelse return;
    const offset = batch.pushBytes(observation.bytes) orelse unreachable;
    _ = batch.pushEvent(.{ .output = .{
        .offset = offset,
        .len = @intCast(observation.bytes.len),
        .shell_foreground = observation.shell_foreground,
        .clock = observation.clock,
    } });
}

pub fn queueResize(self: *Observer, size: core.TerminalSize) void {
    self.pushControl(.{ .resize = size });
}

pub fn queueShellExit(self: *Observer, clock: Clock, exit_code: i32) void {
    self.pushControl(.{ .shell_exit = .{ .clock = clock, .exit_code = exit_code } });
}

pub fn hasPending(self: *const Observer) bool {
    return self.worker == null and self.batches[self.active].event_count != 0;
}

pub fn currentCwd(self: *const Observer) []const u8 {
    if (!self.enabled) {
        return "";
    }
    return self.tracker.currentCwd();
}

pub fn seal(self: *Observer) bool {
    if (!self.hasPending()) {
        return false;
    }
    const sealed = self.active;
    self.active ^= 1;
    std.debug.assert(self.batches[self.active].event_count == 0);
    self.worker = sealed;
    return true;
}

/// Seals the active batch even when it holds nothing, so an observation can
/// identify the pane's process without output to replay. False while a
/// worker still holds a batch.
///
/// ```zig
/// if (observer.sealForProbe()) startWorker();
/// ```
pub fn sealForProbe(self: *Observer) bool {
    if (self.worker != null) {
        return false;
    }

    const sealed = self.active;
    self.active ^= 1;
    std.debug.assert(self.batches[self.active].event_count == 0);
    self.worker = sealed;
    return true;
}

pub fn finishSealed(self: *Observer) void {
    const index = self.worker orelse unreachable;
    self.batches[index].reset();
    self.worker = null;
}

/// Replays one sealed batch through the history emulator and emits complete
/// commands to a statically dispatched sink exposing `emit(Command)`.
///
/// ```zig
/// observer.processSealed(.{ .cwd = cwd, .current_size = size, .stats = stats }, &sink);
/// ```
pub fn processSealed(self: *Observer, processing: Processing, sink: anytype) void {
    const cwd = processing.cwd;
    const current_size = processing.current_size;
    const stats = processing.stats;

    const index = self.worker orelse return;
    const batch = &self.batches[index];
    defer stats.shell_markers = self.enabled and self.tracker.aux.markers_ready;
    var latest_clock: ?Clock = null;
    if (batch.reset_before) {
        const reset_cwd = cwd orelse if (self.enabled)
            self.tracker.currentCwd()
        else
            "";
        self.resetState(reset_cwd, current_size) catch {
            self.failures +|= 1;
            stats.failed = true;
            return;
        };
        self.resets +|= 1;
        stats.reset = true;
    } else if (!self.enabled) {
        stats.failed = true;
        return;
    } else if (cwd) |path| {
        self.tracker.updateCwd(path);
    }

    for (batch.events[0..batch.event_count]) |event| switch (event) {
        .input => |input| {
            const start: usize = input.offset;
            stats.input_bytes +|= self.tracker.observeInput(.{
                .terminal = &self.terminal,
                .bytes = batch.bytes[start..][0..input.len],
                .shell_foreground = input.shell_foreground,
                .clock = input.clock,
            }, sink);
        },
        .output => |output| {
            const start: usize = output.offset;
            latest_clock = output.clock;
            self.observeOutput(.{
                .bytes = batch.bytes[start..][0..output.len],
                .clock = output.clock,
                .shell_foreground = output.shell_foreground,
            }, sink);
        },
        .resize => |size| self.stream.handler.resize(observer_support.vtResize(size)) catch {
            self.failures +|= 1;
            stats.failed = true;
        },
        .shell_exit => |exit| self.tracker.shellExited(.{
            .clock = exit.clock,
            .exit_code = exit.exit_code,
        }, sink),
    };
    // Input, resize, and a worker's delivery time cannot make an old
    // screen newer than a lifecycle report. Nor is a partial VT frame a
    // completion: Codex temporarily erases its status while repainting.
    const clock = latest_clock orelse return;
    if (!self.stream.ground() or self.terminal.modes.get(.synchronized_output)) {
        return;
    }

    self.sample.capture(&self.terminal);
    const phrase_signal = self.sample.signal(self.manifests);
    const codex = codex_screen.scan(&self.terminal, self.manifests);
    const signal = if (processing.provider == .codex or
        (processing.provider == .unknown and codex != null and codex.?.identity_confirmed))
        codex
    else if (processing.provider == .unknown and phrase_signal != null and phrase_signal.?.provider == .codex)
        null
    else if (processing.provider == .cursor)
        observer_support.mergeCursorSignals(phrase_signal, cursor_screen.scan(&self.terminal))
    else
        observer_support.mergeSignals(self.manifests, phrase_signal, prompt_scan.scanReadyPrompt(&self.terminal));
    if (signal) |candidate| {
        if (candidate.provider == .codex or candidate.provider == .cursor) {
            if (candidate.status == .working) {
                self.composer_lost = false;
            } else if (self.composer_lost) {
                // A dropped status row must not turn an incremental
                // composer repaint into proof of completion.
                return;
            }
        }
    }

    if (self.publishSignal(signal, clock.real_ms)) |published| {
        stats.agent_observation = .{ .signal = published, .observed_at_ms = clock.real_ms, .observed_at_ns = clock.awake_ns };
    }
}

/// Hands one screen signal to the runtime when it differs from the last
/// one handed over, or when that one is old enough to need a refresh.
/// An unchanged screen stays quiet in between, so a repainting spinner
/// does not republish the projection on every batch. Codex's ready screen
/// is reconsidered on output: the prior sample may have preceded Stop and
/// been rejected by the runtime. Input alone never refreshes this proof.
fn publishSignal(self: *Observer, signal: ?core.Signal, now_ms: ?i64) ?core.Signal {
    const current = signal orelse {
        self.last_signal = null;
        return null;
    };

    if (self.last_signal) |previous| {
        if (std.meta.eql(previous, current) and !(current.provider == .codex and current.ready_confirmed)) {
            const clock = now_ms orelse return null;

            if (clock - self.last_signal_ms < observer_support.signal_refresh_ms) {
                return null;
            }
        }
    }

    self.last_signal = current;
    if (now_ms) |clock| {
        self.last_signal_ms = clock;
    }

    return current;
}

fn observeOutput(self: *Observer, observation: ObserverOutputObservation, sink: anytype) void {
    var offset: usize = 0;
    while (offset < observation.bytes.len) {
        const remaining = observation.bytes[offset..];
        const boundary = self.tracker.commitBoundary(remaining);
        const slice = if (boundary) |len| remaining[0..len] else remaining;
        self.stream.nextSlice(slice);
        if (boundary != null) {
            _ = self.tracker.captureSubmitted(&self.terminal) catch {
                self.failures +|= 1;
            };
        }
        self.tracker.observeOutput(.{
            .terminal = &self.terminal,
            .bytes = slice,
            .clock = observation.clock,
            .shell_foreground = observation.shell_foreground,
        }, sink);
        offset += slice.len;
    }
}

fn prepareBytes(self: *Observer, bytes: []const u8) ?*Batch {
    if (bytes.len > observer_support.batch_bytes) {
        self.dropActive(bytes.len, 1);
        return null;
    }
    var batch = &self.batches[self.active];
    if (batch.event_count == batch.events.len or bytes.len > batch.bytes.len - batch.len) {
        self.dropActive(bytes.len, 1);
        batch = &self.batches[self.active];
    }
    return batch;
}

fn pushControl(self: *Observer, event: observer_support.Event) void {
    var batch = &self.batches[self.active];
    if (!batch.pushEvent(event)) {
        self.dropActive(0, 1);
        batch = &self.batches[self.active];
        _ = batch.pushEvent(event);
    }
}

fn dropActive(self: *Observer, incoming_bytes: usize, incoming_events: usize) void {
    const batch = &self.batches[self.active];
    self.dropped_events +|= batch.event_count + incoming_events;
    self.dropped_bytes +|= batch.len + incoming_bytes;
    batch.reset();
    batch.reset_before = true;
}

fn resetState(self: *Observer, cwd: []const u8, size: core.TerminalSize) !void {
    self.tracker.deinit(&self.terminal);
    self.stream.deinit();
    self.enabled = false;
    self.last_signal = null;
    self.last_signal_ms = 0;
    self.composer_lost = true;
    self.terminal.fullReset();
    var handler = self.terminal.vtHandler();
    handler.apc_handler.enable(.kitty, false);
    handler.apc_handler.enable(.glyph, false);
    self.stream = .init(.{ .allocator = self.gpa, .handler = handler });
    errdefer self.stream.deinit();
    try self.stream.handler.resize(observer_support.vtResize(size));
    self.tracker = try .init(self.gpa, .{ .cwd = cwd, .terminal = &self.terminal });
    self.enabled = true;
}

const Batch = struct {
    bytes: [observer_support.batch_bytes]u8 = undefined,
    len: usize = 0,
    events: [observer_support.batch_events]observer_support.Event = undefined,
    event_count: usize = 0,
    reset_before: bool = false,

    pub fn reset(self: *Batch) void {
        self.len = 0;
        self.event_count = 0;
        self.reset_before = false;
    }

    pub fn pushBytes(self: *Batch, bytes: []const u8) ?u32 {
        if (self.event_count == self.events.len or bytes.len > self.bytes.len - self.len) {
            return null;
        }
        const offset = self.len;
        @memcpy(self.bytes[offset..][0..bytes.len], bytes);
        self.len += bytes.len;
        return @intCast(offset);
    }

    pub fn pushEvent(self: *Batch, event: observer_support.Event) bool {
        if (self.event_count == self.events.len) {
            return false;
        }
        self.events[self.event_count] = event;
        self.event_count += 1;
        return true;
    }
};
