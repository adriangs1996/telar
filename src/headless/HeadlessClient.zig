//! The headless client (docs/flows/headless-client.md): the shared client
//! with an adapter that has no window. It takes semantic input from stdin,
//! presents and acknowledges every frame the moment it is ready, records
//! host requests instead of performing them, and answers `--client`
//! commands through the shared client code. Tests and tools use it where a
//! window cannot run.
const keyinput = @import("keyinput");
const mailbox = @import("mailbox");
const pacing = @import("pacing");
const core = @import("telar-core");
const data = @import("model");
const std = @import("std");
const client = @import("telar-client");
const HeadlessOptions = @import("HeadlessOptions.zig");
const Trace = @import("Trace.zig");
const input_protocol = @import("input_protocol.zig");
const dump = @import("dump.zig");
const InputLine = @import("InputLine.zig").InputLine;
const HeadlessClient = @This();

pub const Event = union(enum) {
    client: client.Message,
    /// One stdin line, or why none could be read.
    input: anyerror!InputLine,
};

pub const Inbox = mailbox.GenericInbox(Event);

/// Queue slots the runtime outbox keeps free before another line is read,
/// so input never outruns the runtime.
const minimum_outbox_slots = 4;
/// Exit status when the link failed for a reason retrying cannot fix.
const link_failed_status: u8 = 1;
/// Pixels one cell stands for in the fixed host facts.
const cell_width_px = 8;
const cell_height_px = 16;

gpa: std.mem.Allocator,
io: std.Io,
app: client.Client,
inbox: Inbox,
router: client.key_router.Type,
binding_revision: u64 = 0,
trace: Trace,
options: HeadlessOptions,
stdin_buffer: [2 * input_protocol.max_line_bytes]u8 = undefined,
stdin: std.Io.File.Reader = undefined,
reading: bool = false,
/// Whether `ready` went to stdout, once input was first admitted.
announced: bool = false,

/// Adopts the client's options and binds every port before any event.
///
/// ```zig
/// const headless = try HeadlessClient.init(params, options);
/// defer headless.deinit();
/// ```
pub fn init(params: client.ClientInit, options: HeadlessOptions) !*HeadlessClient {
    const router = try client.key_router.build(.{
        .prefix = params.options.prefix,
        .bindings = params.options.bindings,
        .sequence_timeout_ns = params.options.input_sequence_timeout_ns,
    });

    const self = try params.gpa.create(HeadlessClient);
    errdefer params.gpa.destroy(self);

    self.* = .{
        .gpa = params.gpa,
        .io = params.io,
        .app = undefined,
        .inbox = .init(params.io, .{}),
        .router = router,
        .trace = try Trace.init(params.gpa),
        .options = options,
    };
    errdefer self.trace.deinit(params.gpa);

    try client.Client.init(&self.app, params);
    self.app.graphics = no_graphics;
    self.app.chrome = .{
        .context = self,
        .pointer_fn = noPointer,
        .inspection_scroll_limit_fn = noScrollLimit,
    };
    self.app.host_input_source = .{
        .context = self,
        .route_prompt_bytes_fn = noPromptBytes,
    };
    self.stdin = std.Io.File.stdin().readerStreaming(params.io, &self.stdin_buffer);
    return self;
}

/// Joins every worker before the client they report to goes away.
///
/// ```zig
/// headless.deinit();
/// ```
pub fn deinit(self: *HeadlessClient) void {
    const gpa = self.gpa;
    self.inbox.deinit();
    if (self.app.presentation.active) |flight| {
        _ = self.app.presentation.complete(flight.token, .cancelled);
    }

    self.app.deinit();
    self.trace.deinit(gpa);
    gpa.destroy(self);
}

/// Connects to the machine, then serves events until the runtime ends the
/// client, stdin ends or a `quit` line arrives, and writes the exit trace
/// and dump.
///
/// ```zig
/// const status = try headless.run();
/// ```
pub fn run(self: *HeadlessClient) !u8 {
    try self.start();
    const status = while (true) {
        try self.inbox.wait();
        if (try self.update()) |value| {
            break value;
        }

        // Only a person retries a failed link, and this client has none;
        // it leaves with the failure in its dump instead of waiting forever.
        if (self.app.model.runtime_link.phase == .failed) {
            break link_failed_status;
        }
    };

    try self.writeReports();
    return status;
}

fn start(self: *HeadlessClient) !void {
    const app = &self.app;
    var capabilities = app.model.host.host_capabilities;
    capabilities.images = .unsupported;
    capabilities.pointer_pixels = .unsupported;
    capabilities.window_width_px = @as(u32, self.options.cols) * cell_width_px;
    capabilities.window_height_px = @as(u32, self.options.rows) * cell_height_px;
    _ = try client.host_resize.applyHostUpdate(app, .{
        .size = hostSize(self.options.cols, self.options.rows),
        .capabilities = capabilities,
    });

    app.model.startup.phase = .opening;
    app.bootstrap = .{
        .graphics_shared = false,
        .client_identity = app.client_identity,
        .terminal_colors = capabilities.terminal_colors,
    };
    try client.runtime_link.start(app);
    try client.config_adoption.scheduleConfigReload(app);
    try client.bar_updates.synchronizeBars(app);
    try self.deliverEffects();
    try self.readWhenAdmitted();
}

// One bounded turn: the admitted events, then one presentation.
fn update(self: *HeadlessClient) !?u8 {
    var turn = try self.inbox.begin();
    defer self.inbox.end();

    while (try self.inbox.next(&turn)) |event| {
        const status = try self.dispatch(event);
        try self.deliverEffects();
        if (status) |value| {
            return value;
        }
    }

    if (turn.processed != 0) {
        try client.client_layout.synchronizeClientLayout(&self.app.model);
    }

    try self.present();
    try self.deliverEffects();
    try self.readWhenAdmitted();
    return null;
}

fn dispatch(self: *HeadlessClient, event: Event) !?u8 {
    switch (event) {
        .client => |message| {
            const status = try self.app.update(message);
            if (message == .server) {
                client.client_startup.finish(&self.app.model);
            }

            return status;
        },
        .input => |result| {
            self.reading = false;
            const line = result catch |err| switch (err) {
                error.EndOfStream => return 0,
                else => {
                    std.log.scoped(.headless).warn("stdin line refused: {s}", .{@errorName(err)});
                    return null;
                },
            };

            return self.take(line);
        },
    }
}

fn take(self: *HeadlessClient, line: InputLine) !?u8 {
    // The echo trace's chain starts where a host key arrives; only lines a
    // window would have received as keys count.
    if (line == .key or line == .text) {
        core.mark(self.io, .host_read);
        core.mark(self.io, .client_input);
    }

    const now_ns = pacing.clock.monotonic(self.io);
    const pane = self.focusedPane();
    switch (line) {
        .key => |key| {
            self.trace.record(.{ .kind = .input, .t_ns = now_ns, .pane = pane }, "key");
            if (try self.press(key, now_ns) == .stop) {
                return 0;
            }
        },
        .text => |*text| {
            self.trace.record(.{ .kind = .input, .t_ns = now_ns, .pane = pane }, "text");
            var characters = (try std.unicode.Utf8View.init(text.slice())).iterator();
            while (characters.nextCodepointSlice()) |character| {
                if (try self.press(.{ .code = .{ .char = keyinput.Char.init(character) } }, now_ns) == .stop) {
                    return 0;
                }
            }
        },
        .resize => |size| {
            self.trace.record(.{ .kind = .input, .t_ns = now_ns, .pane = pane }, "resize");
            var capabilities = self.app.model.host.host_capabilities;
            capabilities.window_width_px = @as(u32, size.cols) * cell_width_px;
            capabilities.window_height_px = @as(u32, size.rows) * cell_height_px;
            _ = try client.host_resize.applyHostUpdate(&self.app, .{
                .size = hostSize(size.cols, size.rows),
                .capabilities = capabilities,
            });
        },
        .mark => |*label| self.trace.record(.{ .kind = .mark, .t_ns = now_ns }, label.slice()),
        .notification_activate => {
            self.trace.record(.{ .kind = .input, .t_ns = now_ns, .pane = pane }, "notification");
            const center = &self.app.model.notification_center;
            if (center.count != 0) {
                _ = try client.notifications.activateNotificationNow(&self.app, center.itemAt(center.count - 1).?.id);
            }
        },
        .quit => return 0,
    }

    return null;
}

// The pane input goes to, recorded so a trace reader can find its echo
// among other panes' frames; 0 without one.
fn focusedPane(self: *const HeadlessClient) u64 {
    const model = &self.app.model;
    const slot = model.tabs.activeSlot() orelse return 0;
    const pane = data.tab_layout.focusedPaneConst(model, slot) orelse return 0;
    return @intFromEnum(pane.id);
}

// A press through the keymap, as a terminal delivers keys: without a
// release, which would end prefix mode before its second key. A binding
// such as detach may end the client.
fn press(self: *HeadlessClient, key: keyinput.Key, now_ns: u64) !keyinput.Control {
    const decision = self.router.routeEvent(.{
        .key = key,
        .now_ns = now_ns,
    }, .{
        .captures_keys = data.key_routing.captures(client.key_routing.keyRoutingAuthority(&self.app)),
        .repeat_policy = null,
    });

    return self.decide(decision);
}

fn decide(self: *HeadlessClient, decision: client.key_router.Type.Decision) !keyinput.Control {
    switch (decision) {
        .forward => |value| _ = try client.key_routing.routeKeyInput(&self.app, .{ .key = value }),
        .replay => |value| {
            for (value.held_keys[0..value.held_key_len]) |held| {
                _ = try client.key_routing.routeKeyInput(&self.app, .{ .key = held });
            }

            if (value.current_key) |current| {
                _ = try client.key_routing.routeKeyInput(&self.app, .{ .key = current });
            }
        },
        .action => |request| {
            const control = try client.actions.executeAction(&self.app, request.value, .binding);
            if (control == .continue_routing) {
                self.router.actionCompleted(request, client.repeatPolicy(request.value, client.actions.repeatPane(&self.app)));
            }

            return control;
        },
        .pending, .discard => {},
    }

    return .continue_routing;
}

// Presents the active tab's pending frames the moment they are ready and
// acknowledges them, as a window does once its frame is on screen.
fn present(self: *HeadlessClient) !void {
    const app = &self.app;
    const model = &app.model;
    const region = data.workbench.region(model);
    const ingress: client.PresentationIngress = .{ .input_routing = self.binding_revision };
    const observed: client.Observation = .{
        .model = model.version(),
        .geometry_revision = region.revision,
        .presentation_ingress = ingress,
    };

    _ = app.presentation.observe(observed);
    if (app.presentation.active != null or !app.presentation.needsPreparation()) {
        return;
    }

    core.mark(self.io, .compose_start);
    const projected = client.capture(model, .{
        .geometry = region,
        .presentation_ingress = ingress,
    });
    const token = try app.presentation.begin(.{
        .observation = observed,
        .commit = if (model.tabs.activeSlot()) |slot| data.presentation_delivery.capture(model, slot) else .{},
        .geometry = client.Geometry.capture(projected),
    });

    // There is no host to write to; the frame counts as flushed once it is
    // presented.
    core.mark(self.io, .host_flush_start);
    const delivery = app.presentation.complete(token, .delivered) orelse return;
    core.mark(self.io, .host_flush_done);
    const now_ns = pacing.clock.monotonic(self.io);
    for (delivery.commit.slice()) |pane| {
        // A pane with no pending frame was only drawn again.
        if (pane.frame_id == 0) {
            continue;
        }

        self.trace.record(.{
            .kind = .frame,
            .t_ns = now_ns,
            .pane = @intFromEnum(pane.pane_id),
            .frame = pane.frame_id,
        }, "");
    }

    try client.presentation_delivery.apply(model, delivery.commit);
}

// Host requests are recorded, never performed: there is no clipboard,
// notification centre or window to hand them to.
fn deliverEffects(self: *HeadlessClient) !void {
    while (true) {
        const effects = &self.app.model.to_host;
        _ = effects.takePlacementInvalidation();
        effects.resume_input = false;
        effects.pane_input = null;
        if (effects.rebind_input) {
            effects.rebind_input = false;
            self.router = try client.key_router.build(self.app.routerConfig());
            self.binding_revision +%= 1;
        }

        while (effects.pop()) |effect| {
            const now_ns = pacing.clock.monotonic(self.io);
            self.trace.record(.{ .kind = .effect, .t_ns = now_ns }, @tagName(effect));
            switch (effect) {
                .capture => |request| try client.clipboard_capture.completeClipboardCapture(&self.app, .{
                    .execution_id = @enumFromInt(request.sequence),
                    .result = error.NativeServiceUnavailable,
                }),
                .clipboard, .machine => {},
            }
        }

        try self.startJobs();
        if (self.app.model.to_host.count == 0) {
            return;
        }
    }
}

fn startJobs(self: *HeadlessClient) !void {
    const app = &self.app;
    try app.flush();
    while (true) {
        if (app.to_workers.pop()) |job| {
            self.inbox.start(.client, .{ client.job_runner.run, .{ self.io, job } }) catch |err| {
                try app.failJob(job, err);
                try app.flush();
            };
        } else if (app.to_background.pop()) |job| {
            if (recordedInstead(job)) |completion| {
                self.trace.record(
                    .{
                        .kind = .effect,
                        .t_ns = pacing.clock.monotonic(self.io),
                    },
                    @tagName(job),
                );
                const status = try app.update(completion);
                std.debug.assert(status == null);
                try app.flush();
                continue;
            }

            self.inbox.start(.client, .{ client.job_runner.runBackground, .{ self.io, self.gpa, job } }) catch |err| {
                try app.failBackgroundJob(job, err);
                try app.flush();
            };
        } else {
            return;
        }
    }
}

/// The completion of a host job the headless client records instead of
/// running: opening a link, playing a sound, posting a desktop notice. There
/// is no window to hand them to, so none of them may reach `open`,
/// `xdg-open` or a sound player (docs/flows/headless-client.md, "No window,
/// no host"). Null for a job that runs as in a window.
///
/// ```zig
/// if (recordedInstead(job)) |completion| _ = try app.update(completion);
/// ```
fn recordedInstead(job: client.BackgroundJob) ?client.Message {
    return switch (job) {
        .link => .{ .link_opened = {} },
        .sound => .{ .sound_played = {} },
        .system_notification => .{ .notified = {} },
        .bar_command, .plugin, .path_completion, .config_watch, .runtime_connect, .machine_edit => null,
    };
}

test "links, sounds and desktop notices complete without running anything" {
    const link = try data.LinkTarget.init("https://auth.openai.com/codex/device");
    const opened = recordedInstead(.{ .link = link }) orelse return error.TestExpectedRecorded;
    try opened.link_opened;

    const played = recordedInstead(.{ .sound = .ready }) orelse return error.TestExpectedRecorded;
    try played.sound_played;

    const notified = recordedInstead(.{ .system_notification = .{} }) orelse return error.TestExpectedRecorded;
    try notified.notified;
}

// Reads the next line once the startup lets input through and the runtime
// outbox has room for what it may send.
fn readWhenAdmitted(self: *HeadlessClient) !void {
    const model = &self.app.model;
    if (self.reading or model.startup.holdsInput() or model.to_runtime.availableCapacity() < minimum_outbox_slots) {
        return;
    }

    self.reading = true;
    errdefer self.reading = false;
    try self.inbox.start(.input, .{ readLine, .{&self.stdin} });

    // Tools wait for this line before they send what they measure.
    if (!self.announced) {
        self.announced = true;
        try std.Io.File.stdout().writeStreamingAll(self.io, "ready\n");
    }
}

fn readLine(reader: *std.Io.File.Reader) anyerror!InputLine {
    const line = try reader.interface.takeDelimiter('\n') orelse return error.EndOfStream;
    return input_protocol.parse(line);
}

fn writeReports(self: *HeadlessClient) !void {
    if (self.options.trace_path) |path| {
        try self.writeFile(path, .trace);
    }

    if (self.options.dump_path) |path| {
        try self.writeFile(path, .dump);
    }
}

const Report = enum { trace, dump };

fn writeFile(self: *HeadlessClient, path: []const u8, report: Report) !void {
    const file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
    defer file.close(self.io);

    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writerStreaming(self.io, &buffer);
    switch (report) {
        .trace => try self.trace.writeJson(&writer.interface),
        .dump => try dump.write(&writer.interface, &self.app.model),
    }

    try writer.interface.flush();
}

fn hostSize(cols: u16, rows: u16) core.TerminalSize {
    return .{
        .cols = cols,
        .rows = rows,
        .cell_width_px = cell_width_px,
        .cell_height_px = cell_height_px,
    };
}

fn noPointer(_: *anyopaque, _: keyinput.Mouse) client.ViewInteractionCommand {
    return .{};
}

fn noScrollLimit(_: *anyopaque) ?u32 {
    return null;
}

fn noPromptBytes(_: *anyopaque, _: []const u8) anyerror!void {}

/// The headless client keeps no images; graphics commands are accepted and
/// dropped, and no pane shows any.
const no_graphics: client.GraphicsRetention = .{
    .context = undefined,
    .apply_fn = NoGraphics.apply,
    .clear_pane_fn = NoGraphics.clearPane,
    .set_pane_visible_fn = NoGraphics.setPaneVisible,
    .pane_visible_fn = NoGraphics.paneVisible,
    .has_pane_graphics_fn = NoGraphics.paneVisible,
    .ingress_version_fn = NoGraphics.ingressVersion,
    .peek_credit_fn = NoGraphics.peekCredit,
    .consume_credit_fn = NoGraphics.consumeCredit,
};

const NoGraphics = struct {
    fn apply(_: *anyopaque, _: data.PaneGraphicsCommand) !void {}

    fn clearPane(_: *anyopaque, _: core.PaneId) void {}

    fn setPaneVisible(_: *anyopaque, _: core.PaneId, _: bool) !void {}

    fn paneVisible(_: *anyopaque, _: core.PaneId) bool {
        return false;
    }

    fn ingressVersion(_: *anyopaque) u64 {
        return 0;
    }

    fn peekCredit(_: *anyopaque) ?client.GraphicsCredit {
        return null;
    }

    fn consumeCredit(_: *anyopaque, _: client.GraphicsCredit) void {}
};
