//! One attached client's shared state: the model, the runtime transport, the
//! request lifecycle, configuration, plugins and the ports through which a
//! presentation adapter supplies its host. Adapters embed it, build it in
//! place and bind the ports before the first event.
const sidebar_animation = @import("../notifications/sidebar_animation.zig");
const localsocket = @import("localsocket");
const pacing = @import("pacing");
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const bar_updates = @import("../config/bar_updates.zig");
const client_tests = @import("client_tests.zig");

const Options = @import("../Options.zig");
const ClientInit = @import("../ClientInit.zig");
const RuntimeTransportState = @import("../connection/RuntimeTransportState.zig");
const ConnectReport = @import("../connection/ConnectReport.zig");
const Forward = @import("../machines/Forward.zig");
const RuntimeConnection = @import("../machines/RuntimeConnection.zig");
const runtime_link = @import("../connection/runtime_link.zig");
const machine_profiles = @import("../machines/machine_profiles.zig");
const Machines = @import("../machines/Machines.zig");
const TelemetryState = @import("../resources/TelemetryState.zig");
const Generation = @import("../config/Generation.zig");
const Snapshot = @import("../config/Snapshot.zig");
const Registry = @import("../plugins/Registry.zig");
const ConfigReloadState = @import("../resources/ConfigReloadState.zig");
const GraphicsRetention = @import("../graphics/GraphicsRetention.zig");
const HostChrome = @import("../presentation/HostChrome.zig");
const AttachmentShelf = @import("../attachments/AttachmentShelf.zig");
const PresentationLifecycle = @import("../presentation/LifecycleState.zig");
const Job = @import("Job.zig").Job;
const BackgroundJob = @import("BackgroundJob.zig").BackgroundJob;
const job_runner = @import("job_runner.zig");
const Message = @import("Message.zig").Message;
const HostInputSource = @import("../input/HostInputSource.zig");
const RouterConfig = @import("../input/RouterConfig.zig");
const agent_sound = @import("../agents/agent_sound.zig");
const prompt_paths = @import("../completion/prompt_paths.zig");
const config_adoption = @import("../config/config_adoption.zig");
const runtime_io = @import("../connection/runtime_io.zig");
const link_opening = @import("../links/link_opening.zig");
const notifications = @import("../notifications/notifications.zig");
const plugin_actions = @import("../plugins/plugin_actions.zig");
const client_telemetry = @import("../resources/client_telemetry.zig");

/// Jobs one event can start: most kinds keep at most one in flight, and
/// system notices arrive in short bursts.
const max_queued_jobs = 32;

comptime {
    std.debug.assert(data.effects.max_expression_paste_bytes + 16 <= data.input_limits.max_encoded_bytes);
}

const Client = @This();

io: std.Io,
gpa: std.mem.Allocator,
runtime_transport: RuntimeTransportState,
options: Options,
client_identity: core.ClientIdentity,
telemetry: TelemetryState,
model: data.ClientModel,
lua_generation: ?*Generation,
plugin_registry: ?*Registry,
trust_store: ?*core.TrustStore,
/// Whether this client frees the configuration above. A window's other
/// machines share its client's configuration and follow its reloads.
owns_configuration: bool = true,
reload: ConfigReloadState,
/// Transient: the alternate flag of the list submission being finished.
list_submission_alternate: bool = false,
/// Interactive jobs procedures started during the current event. The
/// adapter drains it after every event, runs each job off the event loop and
/// delivers its completion message; a job it cannot start finishes through
/// `failJob`.
to_workers: core.GenericRing(Job, max_queued_jobs) = .{},
/// Background jobs procedures started during the current event, drained
/// like `to_workers`; one the adapter cannot start finishes through
/// `failBackgroundJob`. Each slot holds a request copy of kilobytes, so the
/// interactive queue stays a few cache lines.
to_background: core.GenericRing(BackgroundJob, max_queued_jobs) = .{},
/// The running plugin action's result. Its worker writes it before posting
/// the completion that tells `plugin_actions.completePluginAction` to read
/// it; it stays out of `Message`, which every event copies.
plugin_result: data.WorkerResult = undefined,
/// Host ports, bound by the adapter before the first event.
graphics: GraphicsRetention = undefined,
chrome: HostChrome = undefined,
/// Bound only by hosts that draw attachment previews.
attachments: ?AttachmentShelf = null,
/// The one presentation in flight and what the host last delivered, shared
/// by every adapter.
presentation: PresentationLifecycle = .{},
host_input_source: HostInputSource = undefined,
/// What every session sends first; the adapter stores it before the link
/// starts.
bootstrap: ?data.RuntimeBootstrap = null,
/// The socket a connection job produced; `runtime_transport` borrows it.
channel: localsocket.SocketChannel = undefined,
channel_owned: bool = false,
/// The SSH forward carrying `channel` to a remote machine.
forward: ?Forward = null,
/// Written by the connection worker before its completion.
connect_result: RuntimeConnection = undefined,
connect_report: ConnectReport = .{},
/// A connection job is running; its result lands in `connect_result`.
connect_pending: bool = false,
/// The target changed while a job ran; its result is closed and a new
/// attempt starts.
connect_outdated: bool = false,
/// A connection that landed while the previous socket was still in use
/// waits in `connect_result` until that socket closes.
connect_parked: bool = false,
/// The text of the machine change being written; one change at a time.
machine_edit_label: [core.MachineProfile.max_label_bytes]u8 = undefined,
machine_edit_value: [core.ssh_destination.max_bytes]u8 = undefined,
machine_edit_pending: bool = false,
/// The destination the running connection job reads. It is written only
/// when no job runs, so a machine renamed meanwhile never changes it.
connect_destination: [core.ssh_destination.max_bytes]u8 = undefined,
/// The wait before connecting again to a lost runtime.
runtime_retry: pacing.DeadlineScheduler = .{},
connected_at_ns: u64 = 0,
/// A remote machine's home and login shell for the first pane, copied
/// from its discovery because the forward that holds them can stop.
launch_cwd: [std.fs.max_path_bytes]u8 = undefined,
launch_shell: [std.fs.max_path_bytes]u8 = undefined,
launch_arguments: [1][]const u8 = undefined,
/// Whether the window shows this client's machine. A hidden client keeps
/// metadata only: it defers its first pane and leaves its workspace.
presented: bool = true,
/// The first pane a hidden client did not open yet, and the layout the
/// runtime restored for it.
open_deferred: bool = false,
deferred_layout: ?data.SavedLayout = null,
/// The workspace a hidden client left, reopened when it is shown again.
left_workspace: ?core.WorkspaceId = null,
/// Leaving waits for requests in flight to finish.
leave_pending: bool = false,
/// The machines of the window this client belongs to, for the palette's
/// machine mode; null in a host that holds one machine.
machines: ?*const Machines = null,

/// Builds the shared state in its final address. The model is megabytes, so
/// nothing here passes it by value. Ports remain unbound.
///
/// ```zig
/// try Client.init(&terminal.app, .{ .gpa = gpa, .io = io, .connection = connection, .host_size = size, .options = options });
/// ```
pub fn init(self: *Client, params: ClientInit) !void {
    const gpa = params.gpa;
    var capabilities: data.HostCapabilities = .{
        .window_width_px = params.window_width_px,
        .window_height_px = params.window_height_px,
    };

    var host_size = params.host_size;
    const cell_size = capabilities.cellSize(host_size.cols, host_size.rows);
    host_size.cell_width_px = cell_size.width;
    host_size.cell_height_px = cell_size.height;
    try host_size.validate();
    const configuration_generation = if (params.options.lua_generation) |generation|
        generation.number
    else
        0;
    const snapshot: ?*const Snapshot = if (params.options.lua_generation) |generation| &generation.snapshot else null;
    // The client owns these from here on; `options` keeps no second pointer
    // that a reload could leave dangling.
    var options = params.options;
    options.lua_generation = null;
    options.plugin_registry = null;
    options.trust_store = null;
    var runtime_transport_state = try RuntimeTransportState.init(gpa, params.connection);
    errdefer runtime_transport_state.deinit(gpa);

    self.* = .{
        .io = params.io,
        .gpa = gpa,
        .runtime_transport = runtime_transport_state,
        .options = options,
        .client_identity = params.client_identity,
        .telemetry = .init(params.io, params.options.endpoint),
        .model = undefined,
        .lua_generation = params.options.lua_generation,
        .plugin_registry = params.options.plugin_registry,
        .trust_store = params.options.trust_store,
        .reload = .{ .mtime_ns = params.options.config_mtime_ns },
    };

    self.model.initInto(gpa, .{
        .pane_gaps = params.options.pane_gaps,
        .configuration_generation = configuration_generation,
        .bars = params.options.bars,
        .host_size = host_size,
        .host_capabilities = capabilities,
        .sidebar_width = data.sidebar.default_width,
        .config = if (snapshot) |value| config_adoption.configFrom(value) else .{},
        .theme = params.options.theme,
        .icon_theme = params.options.icon_theme,
        .window_title = if (snapshot) |value| value.windowTitle() else "",
    });
    errdefer self.model.deinit();
    if (params.connection != null) {
        self.model.runtime_link.phase = .connected;
        self.model.runtime_link.sessions = 1;
    }

    self.model.sound_playback = .init(params.options.sound);
    try self.model.history_palette.prepare(gpa);
    try self.model.to_runtime.reservePayloads(gpa);
    _ = data.sidebar.setVisible(&self.model, params.options.sidebar_visible);
    try client_telemetry.start(self);
}

/// The key bindings of the live configuration, borrowed from its
/// generation until the next adoption.
/// Example: `const router = try buildRouter(client.routerConfig());`
pub fn routerConfig(self: *const Client) RouterConfig {
    if (self.lua_generation) |generation| {
        const snapshot = &generation.snapshot;
        return .{
            .prefix = snapshot.prefix,
            .bindings = snapshot.bindingSlice(),
            .sequence_timeout_ns = snapshot.input_sequence_timeout_ns,
        };
    }

    return .{
        .prefix = self.options.prefix,
        .bindings = self.options.bindings,
        .sequence_timeout_ns = self.options.input_sequence_timeout_ns,
    };
}

/// Returns the grid the active tab's panes share.
/// Example: `const region = client.geometry();`.
pub fn geometry(self: *const Client) data.Region {
    return data.workbench.region(&self.model);
}

/// Releases shared state. The adapter cancels its tasks and frees its own
/// resources first; nothing here may still be borrowed by a worker.
///
/// ```zig
/// terminal.app.deinit();
/// ```
pub fn deinit(self: *Client) void {
    const gpa = self.gpa;
    self.telemetry.deinit(self.io);
    self.reload.deinit(gpa);
    if (self.owns_configuration) {
        if (self.lua_generation) |generation| {
            generation.deinit();
        }

        if (self.plugin_registry) |registry| {
            gpa.destroy(registry);
        }

        if (self.trust_store) |store| {
            gpa.destroy(store);
        }
    }

    self.model.deinit();
    self.runtime_transport.deinit(gpa);
    if (self.channel_owned) {
        self.channel.deinit(self.io);
    }

    if (self.forward) |*forward| {
        forward.stop(self.io);
    }

    if (self.connect_parked) {
        self.connect_result.close(self.io);
    }
}

/// Handles one client event an adapter delivered and returns an exit
/// status when the client must stop.
///
/// ```zig
/// if (try app.update(message)) |status| return status;
/// ```
pub fn update(self: *Client, message: Message) !?u8 {
    const path = core.enter(message.path());
    defer path.restore();

    switch (message) {
        .server => |result| return runtime_io.receiveRuntime(self, result),
        .sent => |result| try runtime_io.completeRuntimeSend(self, result),
        .sidebar_animation_tick => |result| _ = try sidebar_animation.completeSidebarAnimationTick(self, result),
        .notification_tick => |result| _ = try notifications.completeNotificationTick(self, result),
        .bar_tick => |result| try bar_updates.handleTick(self, result),
        .bar_command => |completion| try bar_updates.completeCommand(self, completion),
        .plugin_result => |completion| {
            if (try plugin_actions.completePluginAction(self, completion)) {
                return 0;
            }
        },
        .path_completion => |completion| try prompt_paths.completePathCompletion(self, completion),
        .link_opened => |result| try link_opening.completeLinkOpening(self, result),
        .sound_played => |result| try agent_sound.completeAgentSound(self, result),
        .notified => |result| result catch {},
        .config_reload => |result| _ = try config_adoption.completeConfigReload(self, result),
        .runtime_connected => |result| try runtime_link.finishConnect(self, result),
        .runtime_retry_tick => |result| try runtime_link.retry(self, result),
        .machine_edited => |result| try machine_profiles.finish(self, result),
        .telemetry_tick => |result| try client_telemetry.finishTick(self, result),
        .telemetry_written => |result| client_telemetry.finishWrite(self, result),
    }

    return null;
}

/// Finishes a job the adapter could not start as if its worker had failed
/// with `err`, so its completion releases whatever starting it reserved.
///
/// ```zig
/// inbox.start(.client, .{ job_runner.run, .{ io, job } }) catch |err| try client.failJob(job, err);
/// ```
pub fn failJob(self: *Client, job: Job, err: anyerror) !void {
    const status = try self.update(job_runner.failed(job, err));
    std.debug.assert(status == null);
}

/// Finishes a background job the adapter could not start, as `failJob`.
///
/// ```zig
/// inbox.start(.client, .{ job_runner.runBackground, .{ io, gpa, job } }) catch |err| try client.failBackgroundJob(job, err);
/// ```
pub fn failBackgroundJob(self: *Client, job: BackgroundJob, err: anyerror) !void {
    const status = try self.update(job_runner.failedBackground(job, err));
    std.debug.assert(status == null);
}

/// Moves the graphics credits the host released into `model.to_runtime` and
/// starts writing the queue when no write is in flight. Procedures only push;
/// the adapter calls this once after every event, so a burst of messages
/// leaves in as few writes as the transport allows. Scheduling failure keeps
/// the queued data owned by the transport.
///
/// ```zig
/// try client.flush();
/// ```
pub fn flush(self: *Client) !void {
    const transport = &self.runtime_transport;
    if (transport.connection == null) {
        // Nothing reaches a runtime this client is not connected to; a new
        // session starts from its bootstrap.
        self.model.to_runtime.discardQueued();
        return;
    }

    self.queueGraphicsCredits();
    const payload = try self.model.to_runtime.beginSend(transport.send_buffer) orelse return;

    self.to_workers.push(.{ .runtime_send = .{ .state = transport, .bytes = payload } }) catch |err| {
        self.model.to_runtime.sendFailed();

        return err;
    };
}

/// Transfers only credits admitted by the outbox; saturation preserves the rest.
fn queueGraphicsCredits(self: *Client) void {
    while (self.graphics.peekCredit()) |credit| {
        self.model.to_runtime.push(
            .{
                .graphics_credit = .{
                    .pane_id = credit.pane_id,
                    .bytes = @intCast(credit.bytes),
                },
            },
        ) catch break;
        self.graphics.consumeCredit(credit);
    }
}

test "transport scheduling releases rejected reservations and retries queued frames in order" {
    try client_tests.retryTransportScheduling(flush);
}

test "enqueue retains copied input after rejected scheduling and preserves order on retry" {
    try client_tests.retainQueuedInput(flush);
}
