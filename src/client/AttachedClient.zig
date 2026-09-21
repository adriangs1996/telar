//! One attached client's shared state: the model, the runtime transport, the
//! request lifecycle, configuration, plugins and the ports through which a
//! presentation adapter supplies its host. Adapters embed it, build it in
//! place and bind the ports before the first event.
const EditorOpening = @import("links/EditorOpening.zig");

const core = @import("telar-core");
const std = @import("std");
const OptionsType = @import("Options.zig");
const ClientInit = @import("ClientInit.zig");
const AppearanceThemesType = @import("appearance/AppearanceThemes.zig");
const max_expression_paste_bytes_module = @import("config/effects.zig").max_expression_paste_bytes;
const max_encoded_bytes = @import("input/input_namespace.zig").max_encoded_bytes;
const RuntimeTransportState = @import("connection/RuntimeTransportState.zig");
const ClientIdentityType = @import("telar-core").ClientIdentity;
const HostCapabilitiesType = @import("model/HostCapabilities.zig");
const TelemetryState = @import("resources/TelemetryState.zig");
const ClientLayoutsState = @import("resources/ClientLayoutsState.zig");
const StartupState = @import("operations/session/State.zig");
const ModelType = @import("model/Model.zig");
const HistoryType = @import("workspace/History.zig");
const GenerationType = @import("config/Generation.zig");
const RegistryType = @import("plugins/Registry.zig");
const TrustStoreType = @import("telar-core").TrustStore;
const ConfigReloadState = @import("resources/ConfigReloadState.zig");
const SoundPlaybackType = @import("agents/SoundPlayback.zig");
const DeliveryType = @import("notifications/notifications.zig").Delivery;
const CaptureResourcesType = @import("attachments/CaptureResources.zig");
const OpeningType = @import("links/Opening.zig");
const PointerType = @import("links/Pointer.zig");
const LifecycleState = @import("connection/LifecycleState.zig");
const SchedulerType = core.DeadlineScheduler;
const BarUpdatesState = @import("operations/configuration/State.zig");
const key_policy = @import("application/input/key_routing.zig");
const KeyRoutingAuthority = @import("application/input/KeyRoutingAuthority.zig");
const LeasesType = key_policy.Leases;
const RegionType = @import("workspace/Region.zig");
const default_width = @import("layout/sidebar.zig").default_width;
const SoundPortType = @import("agents/SoundPort.zig");
const HostNotifierType = @import("notifications/HostNotifier.zig");
const LinkOpenerType = @import("links/LinkOpener.zig");
const CapturePortType = @import("attachments/CapturePort.zig");
const HostClipboardType = @import("application/panes/Clipboard.zig");
const HostGraphicsType = @import("graphics/HostGraphics.zig");
const GraphicsRetentionType = @import("graphics/GraphicsRetention.zig");
const HostChromeType = @import("presentation/HostChrome.zig");
const AttachmentCatalogPortType = @import("attachments/AttachmentCatalogPort.zig");
const AttachmentShelfType = @import("attachments/AttachmentShelf.zig");
const HostPresentationType = @import("presentation/HostPresentation.zig");
const HostTimersType = @import("resources/HostTimers.zig");
const BarCommandRunnerType = @import("bars/BarCommandRunner.zig");
const PluginWorkerRunnerType = @import("plugins/PluginWorkerRunner.zig");
const PathCompletionRunnerType = @import("completion/PathCompletionRunner.zig");
const PathCompletionsStateType = @import("operations/input/PathCompletionsState.zig");
const FaviconRunnerType = @import("completion/FaviconRunner.zig");
const FaviconsStateType = @import("operations/workspaces/FaviconsState.zig");
const HostClockType = @import("resources/HostClock.zig");
const HostInputSourceType = @import("input/HostInputSource.zig");
const TransportDriverType = @import("connection/TransportDriver.zig");
const ConfigReloadWatcherType = @import("resources/ConfigReloadWatcher.zig");
const ChangeReviewSession = @import("change_review/Session.zig");
const config_reload = @import("resources/config_reload.zig");
const BarConfiguration = @import("bars/Configuration.zig");

comptime {
    std.debug.assert(max_expression_paste_bytes_module + 16 <= max_encoded_bytes);
}

const HostUpdate = @import("model/HostUpdate.zig");
const HostCommit = @import("model/HostCommit.zig");
const HostCapabilityObservation = @import("model/types.zig").HostCapabilityObservation;
const server_messages = @import("entrypoints/server_messages.zig");
const RuntimeOutboundMessage = @import("connection/outbox_support.zig").Message;
const RuntimeMessage = @import("connection/RuntimeMessage.zig");
const pane_graphics = @import("operations/panes/pane_graphics.zig");
const MultiplexerModel = @import("workspace/MultiplexerModel.zig");
const multiplexer = @import("workspace/multiplexer.zig");
const Tab = @import("workspace/Tab.zig");
const requests = @import("connection/request_lifecycle.zig");

const AttachedClient = @This();

io: std.Io,
gpa: std.mem.Allocator,
runtime_transport: RuntimeTransportState,
options: OptionsType,
client_identity: ClientIdentityType,
telemetry: TelemetryState,
client_layouts: ClientLayoutsState = .{},
startup: StartupState = .{},
model: ModelType,
navigation_history: HistoryType = .{},
lua_generation: ?*GenerationType,
plugin_registry: ?*RegistryType,
trust_store: ?*TrustStoreType,
reload: ConfigReloadState,
sound_playback: SoundPlaybackType,
notification_delivery: DeliveryType = .telar,
/// Whether the history palette lists automation-submitted commands too.
history_show_agent_commands: bool = false,
/// Whether Enter in the history palette runs the command instead of only
/// pasting it; shift+enter always does the opposite.
history_enter_runs: bool = false,
/// Whether the palette uses trigram substring matching instead of the
/// default fuzzy subsequence matching.
history_match_fts: bool = false,
/// Transient: the alternate flag of the list submission being finished.
list_submission_alternate: bool = false,
appearance_themes: AppearanceThemesType = .{},
clipboard_capture_resources: CaptureResourcesType = .{},
link_opening: OpeningType = .{},
link_pointer: PointerType = .{},
request_lifecycle: LifecycleState = .{},
change_review: ChangeReviewSession = .{},
sidebar_animation_scheduler: SchedulerType = .{},
notification_scheduler: SchedulerType = .{},
bar_updates: BarUpdatesState = .{},
path_completions: PathCompletionsStateType = .{},
favicons: FaviconsStateType = .{},
/// Application key leases, owned by routing rather than by the host reader.
input_leases: LeasesType = .{},
/// Host ports, bound by the adapter before the first event.
sound_port: SoundPortType = undefined,
notifier: HostNotifierType = undefined,
link_opener: LinkOpenerType = undefined,
editor_open: EditorOpening = .{},
capture_port: CapturePortType = undefined,
host_clipboard: HostClipboardType = undefined,
host_graphics: HostGraphicsType = undefined,
graphics: GraphicsRetentionType = undefined,
chrome: HostChromeType = undefined,
attachment_catalog: AttachmentCatalogPortType = undefined,
attachment_shelf: AttachmentShelfType = undefined,
presentation: HostPresentationType = undefined,
timers: HostTimersType = undefined,
bar_runner: BarCommandRunnerType = undefined,
plugin_runner: PluginWorkerRunnerType = undefined,
path_completion_runner: PathCompletionRunnerType = undefined,
/// Bound only by adapters that draw sprites; unset means no favicon lookups.
favicon_runner: ?FaviconRunnerType = null,
clock: HostClockType = undefined,
host_input_source: HostInputSourceType = undefined,
transport_driver: TransportDriverType = undefined,
config_watcher: ConfigReloadWatcherType = undefined,

/// Builds the shared state in its final address. The model is megabytes, so
/// nothing here passes it by value. Ports remain unbound.
///
/// ```zig
/// try AttachedClient.init(&terminal.app, .{ .gpa = gpa, .io = io, .connection = connection, .host_size = size, .options = options });
/// ```
pub fn init(client: *AttachedClient, params: ClientInit) !void {
    const gpa = params.gpa;
    var capabilities: HostCapabilitiesType = .{
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
    var runtime_transport_state = try RuntimeTransportState.init(gpa, params.connection);
    errdefer runtime_transport_state.deinit(gpa);

    client.* = .{
        .io = params.io,
        .gpa = gpa,
        .runtime_transport = runtime_transport_state,
        .options = params.options,
        .client_identity = params.client_identity,
        .telemetry = .init(params.io, params.options.endpoint),
        .model = undefined,
        .lua_generation = params.options.lua_generation,
        .plugin_registry = params.options.plugin_registry,
        .trust_store = params.options.trust_store,
        .reload = .{ .mtime_ns = params.options.config_mtime_ns },
        .sound_playback = .init(params.options.sound),
    };
    client.model.initInto(gpa, .{
        .pane_gaps = params.options.pane_gaps,
        .configuration_generation = configuration_generation,
        .bars = params.options.bars,
        .host_size = host_size,
        .host_capabilities = capabilities,
        .sidebar_width = default_width,
    });
    errdefer client.model.deinit();
    try client.model.history_palette.prepare(gpa);
    _ = client.model.setSidebarVisible(params.options.sidebar_visible);
}

/// Returns the workbench grid the adapter currently publishes.
/// Example: `const region = client.geometry();`.
pub fn geometry(client: *const AttachedClient) RegionType {
    return client.chrome.region();
}

/// Releases shared state. The adapter cancels its tasks and frees its own
/// resources first; nothing here may still be borrowed by a worker.
///
/// ```zig
/// terminal.app.deinit();
/// ```
pub fn deinit(client: *AttachedClient) void {
    const gpa = client.gpa;
    client.telemetry.deinit(client.io);
    client.reload.deinit(gpa);
    client.clipboard_capture_resources.deinit(gpa);
    if (client.lua_generation) |generation| {
        generation.deinit();
    }
    if (client.plugin_registry) |registry| {
        gpa.destroy(registry);
    }
    if (client.trust_store) |store| {
        gpa.destroy(store);
    }
    client.model.deinit();
    client.runtime_transport.deinit(gpa);
}

/// Uses the current generation so editor changes take effect after reload.
/// Example: `const executable = client.editorExecutable();`
pub fn editorExecutable(self: *const AttachedClient) []const u8 {
    if (self.lua_generation) |generation| {
        return generation.snapshot.resolveEditor(self.options.editor);
    }

    return self.options.editor;
}

/// Owns a routed response until its asynchronous send completes. Example: `try self.sendRuntimeClientCompletion(reply);`
pub fn sendRuntimeClientCompletion(self: *AttachedClient, reply: core.ClientCommand) !void {
    try self.runtime_transport.outbox.pushClientCompletion(reply);
    try self.startRuntimeSend();
}

/// Copies one fixed-size message and starts its write when idle.
/// Example: `try self.sendRuntime(.{ .detach_pane = detach });`
pub fn sendRuntime(self: *AttachedClient, message: RuntimeOutboundMessage) !void {
    try self.runtime_transport.outbox.push(message);
    try self.startRuntimeSend();
}

/// Copies bounded pane input and starts its write when idle.
///
/// ```zig
/// try self.sendRuntimeInput(.{ .pane_id = pane_id, .bytes = bytes });
/// ```
pub fn sendRuntimeInput(self: *AttachedClient, input: core.PaneInput) !void {
    if (input.bytes.len > max_encoded_bytes) {
        try self.runtime_transport.outbox.pushInputBatch(input.pane_id, input.bytes);
    } else {
        try self.runtime_transport.outbox.pushInput(input.pane_id, input.bytes);
    }

    try self.startRuntimeSend();
}

/// Copies one tab rename and starts its write when idle.
///
/// ```zig
/// try self.sendRuntimeRename(rename);
/// ```
pub fn sendRuntimeRename(self: *AttachedClient, rename: core.RenameTab) !void {
    try self.runtime_transport.outbox.pushRename(rename);
    try self.startRuntimeSend();
}

/// Copies one workspace rename and starts its write when idle.
///
/// ```zig
/// try self.sendRuntimeWorkspaceRename(rename);
/// ```
pub fn sendRuntimeWorkspaceRename(self: *AttachedClient, rename: core.RenameWorkspace) !void {
    try self.runtime_transport.outbox.pushWorkspaceRename(rename);
    try self.startRuntimeSend();
}

/// Copies one workspace creation and starts its write when idle.
///
/// ```zig
/// try self.sendRuntimeCreateWorkspace(request);
/// ```
pub fn sendRuntimeCreateWorkspace(self: *AttachedClient, request: core.CreateWorkspace) !void {
    try self.runtime_transport.outbox.pushCreateWorkspace(request);
    try self.startRuntimeSend();
}

/// Copies one tab creation and starts its write when idle.
///
/// ```zig
/// try self.sendRuntimeCreateTab(request);
/// ```
pub fn sendRuntimeCreateTab(self: *AttachedClient, request: core.CreateTab) !void {
    try self.runtime_transport.outbox.pushCreateTab(request);
    try self.startRuntimeSend();
}

/// Copies a prompt into its outbound slot before the editor can change it.
/// Example: `try self.sendRuntimeAgentPrompt(request);`
pub fn sendRuntimeAgentPrompt(self: *AttachedClient, request: core.AgentPrompt) !void {
    try self.runtime_transport.outbox.pushAgentPrompt(request);
    try self.startRuntimeSend();
}

/// Copies a page cursor before its reading window can change.
/// Example: `try self.sendRuntimeAgentHistory(request);`
pub fn sendRuntimeAgentHistory(self: *AttachedClient, request: core.QueryAgentHistory) !void {
    try self.runtime_transport.outbox.pushAgentHistory(request);
    try self.startRuntimeSend();
}

/// Pins a query to copied provider session bytes before the view can change.
/// Example: `try self.sendRuntimeChangeReviewQuery(query);`
pub fn sendRuntimeChangeReviewQuery(self: *AttachedClient, query: core.QueryChangeReview) !void {
    try self.runtime_transport.outbox.pushChangeReviewQuery(query);
    try self.startRuntimeSend();
}

/// Copies comment and path bytes before the originating editor can mutate them.
/// Example: `try self.sendRuntimeChangeReviewCommand(request);`
pub fn sendRuntimeChangeReviewCommand(self: *AttachedClient, request: core.ChangeReviewCommand) !void {
    try self.runtime_transport.outbox.pushChangeReviewCommand(request);
    try self.startRuntimeSend();
}

/// Copies one notification request and starts its write when idle.
///
/// ```zig
/// try self.sendRuntimeNotification(request);
/// ```
pub fn sendRuntimeNotification(self: *AttachedClient, request: core.ShowNotification) !void {
    try self.runtime_transport.outbox.pushNotification(request);
    try self.startRuntimeSend();
}

/// Copies and coalesces one complete reconnectable client layout.
///
/// ```zig
/// try self.sendRuntimeClientLayout(update);
/// ```
pub fn sendRuntimeClientLayout(self: *AttachedClient, update: core.ClientLayoutUpdate) !void {
    try self.runtime_transport.outbox.pushClientLayout(update);
    try self.startRuntimeSend();
}

/// Starts the receive loop before sending the queued bootstrap.
/// Example: `try client.startRuntimeIo();`
pub fn startRuntimeIo(self: *AttachedClient) !void {
    try self.startRuntimeRead();
    try self.startRuntimeSend();
}

/// Reserves a receive buffer and releases it if the driver rejects the read.
/// Example: `try client.startRuntimeRead();`
pub fn startRuntimeRead(self: *AttachedClient) !void {
    const transport = &self.runtime_transport;
    if (!transport.beginRead()) {
        return;
    }

    self.transport_driver.startRead(transport) catch |err| {
        transport.cancelRead();

        return err;
    };
}

/// Keeps queued data owned by the transport if scheduling fails.
fn startRuntimeSend(self: *AttachedClient) !void {
    const transport = &self.runtime_transport;
    const payload = try transport.prepareSend() orelse return;

    self.transport_driver.startSend(transport, payload) catch |err| {
        transport.cancelSend();

        return err;
    };
}

/// Releases one runtime read, dispatches its bounded message and rearms only
/// while the client remains alive.
///
/// ```zig
/// if (try self.receiveRuntime(result)) |status| return status;
/// ```
pub fn receiveRuntime(self: *AttachedClient, result: anyerror!*const RuntimeMessage) !?u8 {
    core.mark(self.io, .client_frame);
    const received = try self.runtime_transport.completeRead(result);
    self.telemetry.recordMessage(received);
    const status = try server_messages.handleServerMessage(self, received.message);

    if (status) |exit_status| {
        return exit_status;
    }

    self.queueGraphicsCredits();
    try self.startRuntimeSend();
    try self.startRuntimeRead();

    return null;
}

/// Releases one runtime write, pumps its successor and resumes host input when
/// one queue slot becomes available.
///
/// ```zig
/// try self.completeRuntimeSend(result);
/// ```
pub fn completeRuntimeSend(self: *AttachedClient, result: anyerror!void) !void {
    try self.runtime_transport.outbox.finishSend(result);
    self.queueGraphicsCredits();
    try self.startRuntimeSend();
    try self.host_input_source.resumeRead();
}

/// Returns available graphics credits and starts their delivery.
/// Example: `try client.flushGraphicsCredits();`
pub fn flushGraphicsCredits(self: *AttachedClient) !void {
    self.queueGraphicsCredits();
    try self.startRuntimeSend();
}

/// Transfers only credits admitted by the outbox; saturation preserves the rest.
fn queueGraphicsCredits(self: *AttachedClient) void {
    while (self.graphics.peekCredit()) |credit| {
        self.runtime_transport.outbox.push(
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

/// Commits validated geometry before touching resources. Delivery failure keeps
/// the committed state; the caller ends the client session.
/// Example: `_ = try self.applyHostUpdate(update);`
pub fn applyHostUpdate(self: *AttachedClient, update: HostUpdate) !?HostCommit {
    const commit = try self.model.reconcileHost(update) orelse return null;

    try self.deliverHostCommit(commit);

    return commit;
}

/// Applies a semantic terminal response through the same resource policy.
/// Example: `_ = try self.observeHostCapability(observation);`
pub fn observeHostCapability(self: *AttachedClient, observation: HostCapabilityObservation) !?HostCommit {
    const commit = try self.model.observeHostCapability(observation) orelse return null;

    try self.deliverHostCommit(commit);

    return commit;
}

/// Resolves geometry when a probe settles a complete set of capabilities.
/// Example: `_ = try self.reconcileHostCapabilities(capabilities);`
pub fn reconcileHostCapabilities(self: *AttachedClient, capabilities: HostCapabilitiesType) !?HostCommit {
    var size = self.model.hostSize();
    const cell_size = capabilities.cellSize(size.cols, size.rows);
    size.cell_width_px = cell_size.width;
    size.cell_height_px = cell_size.height;

    return self.applyHostUpdate(
        .{
            .size = size,
            .capabilities = capabilities,
        },
    );
}

/// Delivers a current commit, stopping at the first failed resource operation.
fn deliverHostCommit(self: *AttachedClient, commit: HostCommit) !void {
    try validateHostCommit(&self.model, commit);

    if (commit.capabilities) |change| {
        if (!std.meta.eql(change.previous.terminal_colors, change.current.terminal_colors) and
            (self.startup.phase == .opening or self.startup.phase == .active))
        {
            try self.sendRuntime(
                .{
                    .configure_terminal_colors = change.current.terminal_colors,
                },
            );
        }

        if (change.previous.appearance != change.current.appearance and !self.options.theme_locked) {
            const theme = switch (change.current.appearance) {
                .unknown => null,
                .light => self.appearance_themes.light,
                .dark => self.appearance_themes.dark,
            };

            if (theme) |value| {
                self.chrome.setTheme(value);
            }
        }

        if (change.previous.images != change.current.images) {
            pane_graphics.syncFallbacks(&self.model, self.graphics);

            const size = self.model.hostSize();
            try self.chrome.configureSidebar(
                .{
                    .support = change.current.images,
                    .cell_width = size.cell_width_px,
                    .cell_height = size.cell_height_px,
                },
            );
            self.host_graphics.invalidatePlacements();
        }
    }

    if (commit.resize) |resize| {
        if (resize.grid_changed) {
            try self.presentation.resize(resize.current.cols, resize.current.rows);
            try self.chrome.resize(resize.current.cols, resize.current.rows);
        }

        if (resize.cell_size_changed) {
            try self.chrome.configureSidebar(
                .{
                    .support = self.model.hostCapabilities().images,
                    .cell_width = resize.current.cell_width_px,
                    .cell_height = resize.current.cell_height_px,
                },
            );
        }

        self.host_graphics.invalidatePlacements();
        if (self.model.workspace.active()) |tab| {
            const area = self.geometry().area;
            try self.resizeAttachedPanes(&tab.model, area);

            if (tab.snapshot_loaded) {
                try self.attachVisiblePanes(tab, area);
            }
        }
    }
}

/// Offers sizes for attached visible panes, reserving space for the attachment shelf.
/// Example: `try self.resizeAttachedPanes(&tab.model, area);`
pub fn resizeAttachedPanes(self: *AttachedClient, model: *MultiplexerModel, area: core.Rect) !void {
    var layout = model.layoutSnapshot(area).*;
    _ = layout.reserveBelowPane(self.attachment_shelf.reservation());
    var panes = model.paneIterator();

    while (panes.next()) |pane| {
        if (!pane.attached) {
            continue;
        }

        const view = layout.find(pane.id) orelse continue;
        var size = multiplexer.rectSize(view.content) orelse continue;
        size.cell_width_px = model.cell_width_px;
        size.cell_height_px = model.cell_height_px;
        try self.sendRuntime(
            .{
                .pane_resize = .{
                    .pane_id = pane.id,
                    .size = size,
                },
            },
        );
    }
}

/// Connects visible detached panes after canonical membership is loaded.
/// Pending attachments are coalesced; failed delivery rolls back its correlation.
/// Example: `if (tab.snapshot_loaded) { try self.attachVisiblePanes(tab, area); }`
pub fn attachVisiblePanes(self: *AttachedClient, tab: *Tab, area: core.Rect) !void {
    std.debug.assert(tab.snapshot_loaded);
    var panes = tab.model.paneIterator();

    while (panes.next()) |pane| {
        if (pane.attached or self.request_lifecycle.tracker.hasPane(.attachment, pane.id)) {
            continue;
        }

        const size = tab.model.contentSize(pane.id, area) orelse continue;
        const request_id = try self.request_lifecycle.nextId();
        try requests.deliver(
            self,
            .{
                .registration = .{
                    .request_id = request_id,
                    .continuation = .{
                        .attach_pane = .{
                            .pane_id = pane.id,
                            .location = tab.location,
                        },
                    },
                },
                .message = .{
                    .open_pane = .{
                        .request_id = request_id,
                        .target = .{
                            .pane = pane.id,
                        },
                        .size = size,
                        .launch = null,
                    },
                },
            },
        );
    }
}

fn validateHostCommit(model: *const ModelType, commit: HostCommit) !void {
    if (commit.capabilities == null and commit.resize == null) {
        return error.EmptyHostCommit;
    }

    const version = model.version();

    if (commit.capabilities) |change| {
        if (!std.meta.eql(model.hostCapabilities(), change.current) or
            version.host_capabilities != change.host_capabilities_revision)
        {
            return error.StaleHostCommit;
        }
    }

    if (commit.resize) |resize| {
        if (!std.meta.eql(model.hostSize(), resize.current) or version.host != resize.host_revision) {
            return error.StaleHostCommit;
        }
    }
}

/// Selects the live configuration resources before scheduling their next watch.
/// No configured file means no watch; incomplete ownership is an explicit error.
/// Example: `try client.scheduleConfigReload();`
pub fn scheduleConfigReload(self: *AttachedClient) !void {
    const path = self.options.config_path orelse return;
    const trust_path = self.options.trust_path orelse return error.ConfigurationNotLoaded;
    const generation = self.lua_generation orelse return error.ConfigurationNotLoaded;
    const registry = self.plugin_registry orelse return error.ConfigurationNotLoaded;

    try config_reload.schedule(
        &self.reload,
        .{
            .io = self.io,
            .gpa = self.gpa,
            .watcher = self.config_watcher,
            .path = path,
            .profile = self.options.profile,
            .trust_path = trust_path,
            .current_generation = generation,
            .current_registry = registry,
        },
    );
}

/// Borrows bar sources only when Lua and the model agree on their generation.
/// Example: `const configuration = client.barConfiguration() orelse return;`
pub fn barConfiguration(self: *const AttachedClient) ?*const BarConfiguration {
    const generation = self.lua_generation orelse return null;

    if (generation.number != self.model.configurationGeneration()) {
        return null;
    }

    return &generation.snapshot.bars;
}

/// Replaces bar deadlines from the active configuration and rearms their timer.
/// Example: `try client.synchronizeBars();`
pub fn synchronizeBars(self: *AttachedClient) !void {
    self.bar_updates.synchronize(
        .{
            .generation = if (self.lua_generation) |generation| generation.number else self.model.configurationGeneration(),
            .configuration = self.barConfiguration(),
            .now_ns = core.monotonic(self.io),
        },
    );

    try self.bar_updates.rearm(self.io, self.timers);
}

/// Snapshot the current exclusive keyboard owners without exposing client state.
/// Example: `const captures_keys = key_policy.captures(self.keyRoutingAuthority());`
pub fn keyRoutingAuthority(self: *const AttachedClient) KeyRoutingAuthority {
    return .{
        .attachment_modal_active = self.attachment_shelf.modalActive(),
        .prompt_active = self.model.name_prompt.active(),
        .copy_mode_active = self.model.copyModeActive(),
    };
}

/// An exclusive owner or unavailable pane prevents held-action repetition.
/// Re-read after executing an action because it may change focus or modes.
/// Example: `const policy = repeatPolicy(action, self.repeatPane());`
pub fn repeatPane(self: *const AttachedClient) ?core.PaneId {
    const authority = self.keyRoutingAuthority();
    if (key_policy.captures(authority) or authority.copy_mode_active) {
        return null;
    }

    const model = self.model.activeTabModelConst() orelse return null;
    const pane = model.focusedPaneConst() orelse return null;
    return if (pane.attached) pane.id else null;
}

test "host resources reject empty and stale commits before calling ports" {
    const app = try std.testing.allocator.create(AttachedClient);
    defer std.testing.allocator.destroy(app);
    // Only the model is initialized: invalid commits must never reach a host port.
    app.model.initInto(
        std.testing.allocator,
        .{
            .pane_gaps = false,
            .host_size = .{
                .cols = 80,
                .rows = 24,
            },
        },
    );
    defer app.model.deinit();

    const stale_capabilities = (try app.model.observeHostCapability(
        .{
            .images = .supported,
        },
    )).?;
    _ = try app.model.observeHostCapability(
        .{
            .pointer_pixels = .supported,
        },
    );
    const stale_size = (try app.model.reconcileHost(
        .{
            .capabilities = app.model.hostCapabilities(),
            .size = .{
                .cols = 100,
                .rows = 30,
            },
        },
    )).?;
    _ = try app.model.reconcileHost(
        .{
            .capabilities = app.model.hostCapabilities(),
            .size = .{
                .cols = 101,
                .rows = 30,
            },
        },
    );

    try std.testing.expectError(error.EmptyHostCommit, app.deliverHostCommit(
        .{
            .capabilities = null,
            .resize = null,
        },
    ));
    try std.testing.expectError(error.StaleHostCommit, app.deliverHostCommit(stale_capabilities));
    try std.testing.expectError(error.StaleHostCommit, app.deliverHostCommit(stale_size));
}

test "transport scheduling releases rejected reservations and retries queued frames in order" {
    const Driver = struct {
        reject: bool = true,
        reads: usize = 0,
        sends: usize = 0,
        payload: []const u8 = &.{},

        fn read(raw: *anyopaque, state: *RuntimeTransportState) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reads += 1;
            try std.testing.expect(state.receive_pending);

            if (self.reject) {
                return error.DriverBusy;
            }
        }

        fn send(raw: *anyopaque, state: *RuntimeTransportState, payload: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.sends += 1;
            self.payload = payload;
            try std.testing.expect(state.outbox.inFlight());

            if (self.reject) {
                return error.DriverBusy;
            }
        }
    };

    var capture: Driver = .{};
    const driver: TransportDriverType = .{
        .context = &capture,
        .start_read_fn = Driver.read,
        .start_send_fn = Driver.send,
    };
    var send_buffer: [64]u8 = undefined;
    const app = try std.testing.allocator.create(AttachedClient);
    defer std.testing.allocator.destroy(app);
    app.transport_driver = driver;
    const state = &app.runtime_transport;
    state.* = .{
        .connection = undefined,
        .send_buffer = &send_buffer,
        .receive_buffer = &.{},
        .read_buffer = &.{},
    };

    try std.testing.expectError(error.DriverBusy, app.startRuntimeRead());
    try std.testing.expect(!state.receive_pending);
    capture.reject = false;
    try app.startRuntimeRead();
    try app.startRuntimeRead();
    try std.testing.expectEqual(@as(usize, 2), capture.reads);
    try std.testing.expectError(error.ReadFailed, state.completeRead(error.ReadFailed));
    try std.testing.expect(!state.receive_pending);
    try app.startRuntimeRead();
    try std.testing.expectEqual(@as(usize, 3), capture.reads);
    state.cancelRead();

    try app.startRuntimeSend();
    try std.testing.expectEqual(@as(usize, 0), capture.sends);
    try state.outbox.push(
        .{
            .detach_pane = .{
                .pane_id = @enumFromInt(1),
            },
        },
    );
    try state.outbox.push(
        .{
            .detach_pane = .{
                .pane_id = @enumFromInt(2),
            },
        },
    );
    capture.reject = true;
    try std.testing.expectError(error.DriverBusy, app.startRuntimeSend());
    try std.testing.expect(!state.outbox.inFlight());
    try std.testing.expectEqual(@as(u8, 2), state.outbox.len);
    const first = send_buffer;
    const first_len = capture.payload.len;
    capture.reject = false;
    try app.startRuntimeSend();
    try std.testing.expectEqualSlices(
        u8,
        first[0..first_len],
        capture.payload,
    );
    try app.startRuntimeSend();
    try std.testing.expectEqual(@as(usize, 2), capture.sends);
    try state.outbox.finishSend({});
    try app.startRuntimeSend();
    try std.testing.expectEqual(@as(usize, 3), capture.sends);
    try std.testing.expect(!std.mem.eql(
        u8,
        first[0..first_len],
        capture.payload,
    ));
    try state.outbox.finishSend({});
    try std.testing.expectEqual(@as(u8, 0), state.outbox.len);
}

test "enqueue retains copied input after rejected scheduling and preserves order on retry" {
    const Driver = struct {
        reject: bool = true,
        sends: usize = 0,
        payload: []const u8 = &.{},

        fn read(_: *anyopaque, _: *RuntimeTransportState) !void {
            return error.UnexpectedRead;
        }

        fn send(raw: *anyopaque, _: *RuntimeTransportState, payload: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.sends += 1;

            if (self.reject) {
                return error.DriverBusy;
            }

            self.payload = payload;
        }
    };

    var capture: Driver = .{};
    const driver: TransportDriverType = .{
        .context = &capture,
        .start_read_fn = Driver.read,
        .start_send_fn = Driver.send,
    };
    var send_buffer: [max_encoded_bytes + 64]u8 = undefined;
    const app = try std.testing.allocator.create(AttachedClient);
    defer std.testing.allocator.destroy(app);
    app.transport_driver = driver;
    const state = &app.runtime_transport;
    state.* = .{
        .connection = undefined,
        .send_buffer = &send_buffer,
        .receive_buffer = &.{},
        .read_buffer = &.{},
    };
    const pane: core.PaneId = @enumFromInt(1);
    var source = [_]u8{
        'x',
    } ** (max_encoded_bytes + 1);

    try std.testing.expectError(error.DriverBusy, app.sendRuntimeInput(
        .{
            .pane_id = pane,
            .bytes = &source,
        },
    ));
    try std.testing.expectEqual(@as(u8, 2), state.outbox.len);
    try std.testing.expect(!state.outbox.inFlight());
    @memset(&source, 'y');
    capture.reject = false;

    try app.sendRuntime(
        .{
            .detach_pane = .{
                .pane_id = pane,
            },
        },
    );
    const first = try core.decodeClient(capture.payload);
    try std.testing.expect(first == .pane_input);
    try std.testing.expectEqual(pane, first.pane_input.pane_id);
    try std.testing.expectEqualStrings("x" ** max_encoded_bytes, first.pane_input.bytes);
    try state.outbox.finishSend({});
    try app.startRuntimeSend();
    const second = try core.decodeClient(capture.payload);
    try std.testing.expect(second == .pane_input);
    try std.testing.expectEqualStrings("x", second.pane_input.bytes);
    try state.outbox.finishSend({});
    try app.startRuntimeSend();
    const third = try core.decodeClient(capture.payload);
    try std.testing.expect(third == .detach_pane);
    try std.testing.expectEqual(pane, third.detach_pane.pane_id);
    try state.outbox.finishSend({});
    try std.testing.expectEqual(@as(u8, 0), state.outbox.len);

    while (state.outbox.hasCapacity()) {
        try state.outbox.push(
            .{
                .detach_pane = .{
                    .pane_id = pane,
                },
            },
        );
    }

    const sends = capture.sends;
    try std.testing.expectError(error.ClientOutboxFull, app.sendRuntime(
        .{
            .detach_pane = .{
                .pane_id = pane,
            },
        },
    ));
    try std.testing.expectEqual(sends, capture.sends);
    try std.testing.expect(!state.outbox.inFlight());
}
