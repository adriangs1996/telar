const core = @import("telar-core");
const std = @import("std");
const requests = @import("application/requests.zig");
const events = @import("application/events.zig");
const ReviewJobs = @import("../change_review/Jobs.zig");
const ReviewService = @import("../change_review/Service.zig");
const AdmittedReview = @import("../change_review/Admitted.zig");
const EditorOpenState = @import("../editors/State.zig");
const event = @import("event.zig");
const Resources = @import("resources/Resources.zig");
const Options = @import("Options.zig");
const AgentDescriptionOptions = @import("AgentDescriptionOptions.zig");
const DescriptionState = @import("application/coordinators/State.zig");
const LaunchTestFault = @import("application/LaunchTestFault.zig");
const Store = @import("client/Store.zig");
const application_namespace = @import("application/application_namespace.zig");
const LifecycleState = @import("lifecycle/State.zig");
const state_support = @import("../workspace/state_support.zig");
const GeometryLease = @import("application/GeometryLease.zig");
const WorkspaceState = @import("../workspace/State.zig");
const PaneStore = @import("../pane/PaneStore.zig");
const Tracker = @import("../agent/Tracker.zig");
const ClientLayoutStore = @import("application/Store.zig");
const Sampler = @import("observability/Sampler.zig");
const RuntimeMetrics = @import("observability/RuntimeMetrics.zig");
const CheckpointState = @import("application/State.zig");
const AgentHistoryJobs = @import("application/AgentHistoryJobs.zig");
const PaneType = @import("../pane/Pane.zig");
const Repository = @import("../workspace/Repository.zig");
const ReaderType = @import("../workspace/Reader.zig");
const LaunchRequestType = @import("application/LaunchRequest.zig");
const GenericPaneLauncher = @import("application/GenericPaneLauncher.zig").Type;
const SessionTitleType = @import("../agent/SessionTitle.zig");
const CompletionType = @import("resources/Completion.zig");
const AgentCompletion = @import("../agent/Completion.zig");
const commands = @import("../workspace/commands.zig");
const ClientKeyType = @import("../history/ClientKey.zig");
const WorkspaceChange = @import("application/WorkspaceChange.zig");
const Session = @import("client/Session.zig");
const PaneDetachedType = @import("attachment/PaneDetached.zig");
const TabRemovedType = @import("../workspace/TabRemoved.zig");
const PendingNotificationType = @import("delivery/PendingNotification.zig");
/// The authoritative state of one running runtime: singletons as fields and
/// repeating entities as tables. Physical resources stay in `Resources`.
const RuntimeModel = @This();

io: std.Io,
gpa: std.mem.Allocator,
select: *std.Io.Select(event.Event),
resources: *Resources,
inherited_environment: std.process.Environ,
socket_path: []const u8,
executable_path: [std.fs.max_path_bytes]u8 = undefined,
executable_path_len: usize,
/// `HOME` from the inherited environment, read once for cwd labels.
home: ?[]const u8 = null,
agent_description_options: ?AgentDescriptionOptions,
agent_description_state: DescriptionState = .{},
launch_fault: ?*LaunchTestFault,
clients: Store = .{},
client_admission: application_namespace.ClientAdmissionState = .{},
shutdown: LifecycleState = .{},
geometry_leases: [state_support.max_workspaces]?GeometryLease = @splat(null),
workspaces: WorkspaceState = .{},
panes: PaneStore,
agents: Tracker = .{},
client_layouts: ClientLayoutStore = .{},
system_metrics: Sampler = .{},
system_metrics_pending: bool = false,
metrics: RuntimeMetrics,
session: CheckpointState = .{},
session_name_probe_in_flight: bool = false,
agent_history_jobs: AgentHistoryJobs = .{},
review_jobs: ReviewJobs = .{},
review_service: ?*ReviewService = null,
review_admitted: [core.max_panes_per_tab]?AdmittedReview = @splat(null),
editor_open: EditorOpenState = .{},
input_sequence: u64 = 0,
cell_timer: core.DeadlineScheduler = .{},

/// Composes the model over resources that outlive it. The caller keeps the
/// model at a stable address until `deinitModel` completes.
///
/// ```zig
/// try model.init(&resources, loop.selector(), options);
/// ```
pub fn init(self: *RuntimeModel, resources: *Resources, select: *std.Io.Select(event.Event), options: Options) !void {
    const io = resources.io();
    var executable_path: [std.fs.max_path_bytes]u8 = undefined;
    const executable_path_len = try std.process.executablePath(io, &executable_path);

    var review_directory: [std.fs.max_path_bytes]u8 = undefined;
    const review_path = try std.fmt.bufPrint(&review_directory, "{s}/change-reviews", .{std.fs.path.dirname(options.session_path orelse options.endpoint) orelse return error.InvalidReviewStorage});
    const review_service = try ReviewService.init(resources.gpa, review_path);
    errdefer review_service.deinit();
    self.* = .{
        .review_service = review_service,
        .io = io,
        .gpa = resources.gpa,
        .select = select,
        .resources = resources,
        .inherited_environment = options.environment,
        .socket_path = options.endpoint,
        .executable_path = executable_path,
        .executable_path_len = executable_path_len,
        .home = options.environment.getPosix("HOME"),
        .session = .{ .path = options.session_path, .resume_agents = options.resume_agents },
        .agent_description_options = options.agent_descriptions,
        .launch_fault = options.launch_fault,
        .panes = .{
            .graphics_limits = options.graphics,
            .graphics_budget = .init(options.graphics.global_bytes),
        },
        .client_layouts = try .init(resources.gpa),
        .metrics = .{ .started_ns = core.now(io) },
    };
}

/// Unblocks client actors without releasing the connections they borrow.
/// Example: `model.stopClientConnections(); runtime.loop.cancel();`.
pub fn stopClientConnections(self: *RuntimeModel) void {
    for (self.clients.items) |slot| {
        if (slot) |session| {
            session.connection.shutdown(self.io);
        }
    }

    if (self.client_admission.pendingConnection()) |pending| {
        pending.shutdown(self.io);
    }
}

/// Releases connection storage after every client actor has joined.
/// Example: `runtime.loop.cancel(); model.deinitClients();`.
pub fn deinitClients(self: *RuntimeModel) void {
    if (self.client_admission.isPending()) {
        var pending = self.client_admission.takePending();
        pending.deinit(self.io);
    }

    for (self.clients.items) |slot| {
        if (slot) |session| {
            session.read_pending = false;
            session.send_pending = false;
            session.search_scheduled = false;
        }
    }

    self.clients.deinit(self.io, self.gpa);
}

/// Persists the final state after the previous checkpoint writer has joined.
/// Example: `runtime.loop.cancel(); model.persistSession();`.
pub fn persistSession(self: *RuntimeModel) void {
    self.session.discardJoinedWrite();
    application_namespace.SessionCheckpoint.writeNow(self);
}

/// Releases pane and workspace state after their actors have joined.
/// Example: `model.deinitClients(); model.deinitModel();`.
pub fn deinitModel(self: *RuntimeModel) void {
    self.panes.deinit();
    self.agent_history_jobs.deinitJoined();
    self.review_jobs.deinitJoined();
    if (self.review_service) |service| {
        service.deinit();
        self.review_service = null;
    }

    self.client_layouts.deinit();
    application_namespace.deinitWorkspaces(self);
}

/// Reaps lifecycle work that became collectible after an actor completed.
///
/// ```zig
/// model.collect();
/// ```
pub fn collect(model: *RuntimeModel) void {
    model.collectFinished();
}

/// Revokes the proxy credential associated with a pane, when enabled.
///
/// ```zig
/// model.revokePaneCredential(pane);
/// ```
pub fn revokePaneCredential(model: *RuntimeModel, pane: *PaneType) void {
    if (model.resources.proxy.capability()) |proxy| {
        proxy.revokePane(pane.key());
    }
}

/// Opens the repository used by one request-scoped workspace operation.
///
/// ```zig
/// var workspaces = model.workspaceRepository();
/// ```
pub fn workspaceRepository(model: *RuntimeModel) Repository {
    return Repository.init(&model.workspaces, model.gpa);
}

/// Returns a read-only view of the current workspace projection.
///
/// ```zig
/// const workspaces = model.workspaceReader();
/// ```
pub fn workspaceReader(model: *const RuntimeModel) ReaderType {
    return ReaderType.init(&model.workspaces);
}

/// Starts a pane and returns only after the runtime can observe both its
/// output and exit. Client attachment and response delivery happen later.
/// ```zig
/// const pane = try model.launchPane(request);
/// ```
pub fn launchPane(model: *RuntimeModel, request: LaunchRequestType) !*PaneType {
    var launcher: GenericPaneLauncher(event.Event) = .{
        .io = model.io,
        .gpa = model.gpa,
        .select = model.select,
        .history_service = model.resources.history.service(),
        .review_service = model.review_service,
        .inherited_environment = model.inherited_environment,
        .socket_path = model.socket_path,
        .executable_path = model.executable_path[0..model.executable_path_len],
        .manifests = &model.resources.agent_manifests,
        .proxy = model.resources.proxy.capability(),
        .panes = &model.panes,
        .launch_fault = model.launch_fault,
        .terminal_colors = model.workspaceTerminalColors(request.location.workspace),
    };
    const fresh = try launcher.launch(request);
    model.agents.touch();
    model.noteSessionChange();
    return fresh;
}

/// Queues bytes for a restored pane's child and starts the input write.
/// The bytes are a runtime-built resume command, never client input.
///
/// ```zig
/// try model.queueRestoredInput(pane, "claude --resume <id>\r");
/// ```
pub fn queueRestoredInput(model: *RuntimeModel, pane: *PaneType, bytes: []const u8) !void {
    if (std.mem.indexOfScalar(u8, bytes, '\r') != null) {
        pane.noteInjectedSubmission();
    }

    _ = pane.queuePtyInput(bytes);
    try events.panes.Io.scheduleInput(model, pane);
}

/// Hands a checkpointed title to the agent that will resume in a restored
/// pane and records it for the pane's new history session, so the sidebar
/// and the history palette show the resumed session under its old name.
///
/// ```zig
/// model.restoreAgentTitle(pane, title);
/// ```
pub fn restoreAgentTitle(model: *RuntimeModel, pane: *const PaneType, title: SessionTitleType) void {
    if (!model.agents.restoreTitle(pane.key(), title)) {
        return;
    }

    _ = model.resources.history.service().setSessionTitle(model.io, .{
        .id = pane.history_session_id,
        .title = title.slice(),
        .source = title.source,
        .state = .ready,
    });
}

/// Marks the restorable session shape as changed so the next maintenance
/// tick persists it.
///
/// ```zig
/// model.noteSessionChange();
/// ```
pub fn noteSessionChange(model: *RuntimeModel) void {
    application_namespace.SessionCheckpoint.noteChange(model);
}

/// Rebuilds the model from the checkpoint file. Runs once at startup,
/// before clients are accepted.
///
/// ```zig
/// model.restoreSession();
/// ```
pub fn restoreSession(model: *RuntimeModel) void {
    application_namespace.SessionCheckpoint.restore(model);
}

/// Starts a checkpoint write when one is due.
///
/// ```zig
/// try model.flushSessionCheckpoint();
/// ```
pub fn flushSessionCheckpoint(model: *RuntimeModel) !void {
    try application_namespace.SessionCheckpoint.flushIfDue(model);
}

/// Starts one git probe for the stalest due workspace.
///
/// ```zig
/// model.tickGitStatus();
/// ```
pub fn tickGitStatus(model: *RuntimeModel) void {
    application_namespace.GitObserver.tick(model);
}

/// Applies one git probe result.
///
/// ```zig
/// model.gitStatusCompleted(completion);
/// ```
pub fn gitStatusCompleted(model: *RuntimeModel, completion: CompletionType) void {
    application_namespace.GitObserver.handleCompletion(model, completion);
}

/// Starts one session-file probe for the stalest due agent.
///
/// ```zig
/// model.tickSessionNames();
/// ```
pub fn tickSessionNames(model: *RuntimeModel) void {
    application_namespace.SessionNameObserver.tick(model);
}

/// Applies one session-file probe result.
///
/// ```zig
/// model.sessionNameCompleted(completion);
/// ```
pub fn sessionNameCompleted(model: *RuntimeModel, completion: AgentCompletion) void {
    application_namespace.SessionNameObserver.handleCompletion(model, completion);
}

/// Completes the in-flight checkpoint write.
///
/// ```zig
/// model.sessionCheckpointWritten(result);
/// ```
pub fn sessionCheckpointWritten(model: *RuntimeModel, result: anyerror!void) void {
    application_namespace.SessionCheckpoint.handleWritten(model, result);
}

/// Reaps panes whose child exited and which no actor still borrows, then
/// closes tabs that ran out of panes. Spans three stores, which is why it
/// lives on the model rather than on any one of them.
fn collectFinished(model: *RuntimeModel) void {
    const store = &model.panes;
    var workspaces = model.workspaceRepository();

    if (store.exited_count == 0) {
        return;
    }

    for (&store.items) |*slot| {
        const pane = slot.* orelse continue;

        if (!pane.readyToDestroy()) {
            continue;
        }

        for (&model.clients.items) |*client_slot| {
            const client = client_slot.* orelse continue;
            if (client.attachments.find(pane.id) != null) {
                break;
            }
        } else {
            const location = pane.location;
            store.index.remove(core.raw(pane.id));
            store.exited_count -= 1;
            slot.* = null;
            store.count -= 1;

            if (!model.agents.remove(pane.key())) {
                model.agents.touch();
            }

            model.revokePaneCredential(pane);
            pane.destroy();
            model.noteSessionChange();

            if (!store.hasAt(location) and workspaces.reader().contains(location)) {
                const removed = commands.removeTab(&workspaces, location).?;
                model.publishLifecycleTabRemoved(removed);
            }

            model.completeEmptyWorkspaceDepartures(location.workspace);
        }
    }
}

/// Starts idempotent client teardown and removes it after actor claims end.
///
/// ```zig
/// model.dropClient(client);
/// ```
pub fn dropClient(model: *RuntimeModel, key: ClientKeyType) void {
    const session = model.clients.resolve(key) orelse return;
    if (!session.closing) {
        model.failClientCommandsFor(key);
        model.failPaneFocusesFor(key);
        session.closing = true;
        session.connection.shutdown(model.io);
        session.attachments.deinit();
        session.delivery.close();
        model.releaseGeometry(key);
    }
    model.finalizeClient(key);
}

fn failClientCommandsFor(self: *RuntimeModel, key: ClientKeyType) void {
    for (self.clients.items) |slot| {
        const requester = slot orelse continue;
        const pending = requester.pending_client_command orelse continue;
        if (!std.meta.eql(pending.target, key)) {
            continue;
        }

        requester.pending_client_command = null;
        requester.delivery.responses.push(.{ .request_failed = .{
            .request_id = pending.request_id,
            .code = .invalid_request,
            .message = "target client disconnected before confirming the operation",
        } }) catch {
            self.dropClient(requester.key);
        };
    }
}

fn failPaneFocusesFor(model: *RuntimeModel, key: ClientKeyType) void {
    for (&model.clients.items) |*slot| {
        const requester = slot.* orelse continue;
        const pending = requester.pending_pane_focus orelse continue;

        if (!std.meta.eql(pending.target, key)) {
            continue;
        }

        requester.releaseFocus();
        requester.delivery.responses.push(.{ .request_failed = .{
            .request_id = pending.request_id,
            .code = .invalid_request,
            .message = "focus client disconnected",
        } }) catch {
            model.dropClient(requester.key);
            continue;
        };
        requester.delivery.close_after_reply = true;
    }
}

/// Removes a closing client after its read, write and search slots retire.
///
/// ```zig
/// model.finalizeClient(client);
/// ```
pub fn finalizeClient(model: *RuntimeModel, key: ClientKeyType) void {
    const session = model.clients.resolve(key) orelse return;

    if (!session.closing or session.read_pending or session.send_pending or session.search_scheduled) {
        return;
    }

    _ = model.clients.remove(.{ .io = model.io, .gpa = model.gpa }, key);
}

/// Acquires or verifies the workspace geometry lease for one client.
///
/// ```zig
/// if (!model.holdsGeometry(client, workspace)) return error.GeometryUnavailable;
/// ```
pub fn holdsGeometry(model: *RuntimeModel, key: ClientKeyType, workspace: core.WorkspaceLocation) bool {
    for (&model.geometry_leases) |*slot| {
        const lease = slot.* orelse continue;

        if (!std.meta.eql(lease.workspace, workspace)) {
            continue;
        }

        return std.meta.eql(lease.owner, key);
    }

    for (&model.geometry_leases) |*slot| {
        if (slot.* != null) {
            continue;
        }

        slot.* = .{ .workspace = workspace, .owner = key };
        model.applyWorkspaceTerminalColors(workspace, key);
        return true;
    }

    return false;
}

/// Queries authority without acquiring an unowned workspace.
/// Example: `const owner = model.geometryOwner(workspace) orelse return;`.
pub fn geometryOwner(model: *const RuntimeModel, workspace: core.WorkspaceLocation) ?ClientKeyType {
    for (model.geometry_leases) |slot| {
        const lease = slot orelse continue;
        if (std.meta.eql(lease.workspace, workspace)) {
            return lease.owner;
        }
    }

    return null;
}

pub fn workspaceTerminalColors(model: *RuntimeModel, workspace: core.WorkspaceLocation) core.TerminalColors {
    const owner = model.geometryOwner(workspace) orelse return .{};
    const session = model.clients.resolve(owner) orelse return .{};
    return session.terminal_colors;
}

/// Updates only workspaces already controlled by this exact generation.
/// Example: `model.refreshTerminalColors(session.key);`.
pub fn refreshTerminalColors(model: *RuntimeModel, key: ClientKeyType) void {
    for (model.geometry_leases) |slot| {
        const lease = slot orelse continue;
        if (std.meta.eql(lease.owner, key)) {
            model.applyWorkspaceTerminalColors(lease.workspace, key);
        }
    }
}

fn applyWorkspaceTerminalColors(model: *RuntimeModel, workspace: core.WorkspaceLocation, key: ClientKeyType) void {
    const session = model.clients.resolve(key) orelse return;
    for (model.panes.items) |slot| {
        const pane = slot orelse continue;
        if (std.meta.eql(pane.location.workspace, workspace)) {
            pane.setTerminalColors(session.terminal_colors);
        }
    }
}

fn releaseGeometry(model: *RuntimeModel, key: ClientKeyType) void {
    for (&model.geometry_leases) |*slot| {
        const lease = slot.* orelse continue;

        if (!std.meta.eql(lease.owner, key)) {
            continue;
        }

        slot.* = null;
        // The lease is free but the runtime does not know any surviving
        // client's size. Resync the observers so one re-offers its
        // geometry and takes the lease over; without this the pane keeps
        // the departed client's size until an unrelated resize.
        model.notifyWorkspaceChanged(key, lease.workspace);
    }
}

/// Releases a client's lease for one workspace and requests observer resync.
///
/// ```zig
/// model.releaseGeometryFor(client, workspace);
/// ```
pub fn releaseGeometryFor(model: *RuntimeModel, key: ClientKeyType, workspace: core.WorkspaceLocation) void {
    for (&model.geometry_leases) |*slot| {
        const lease = slot.* orelse continue;
        if (std.meta.eql(lease.owner, key) and std.meta.eql(lease.workspace, workspace)) {
            slot.* = null;
            model.notifyWorkspaceChanged(key, workspace);
        }
    }
}

/// Queues resynchronization for observers other than the mutation origin.
///
/// ```zig
/// model.notifyWorkspaceChanged(origin, workspace);
/// ```
pub fn notifyWorkspaceChanged(model: *RuntimeModel, origin: ClientKeyType, workspace: core.WorkspaceLocation) void {
    model.notifyWorkspaceChange(.{ .origin = origin, .workspace = workspace });
}

/// Queues resynchronization after a workspace disappears.
///
/// ```zig
/// model.notifyWorkspaceClosed(change);
/// ```
pub fn notifyWorkspaceClosed(model: *RuntimeModel, change: WorkspaceChange) void {
    model.notifyWorkspaceChange(change);
}

fn notifyWorkspaceChange(model: *RuntimeModel, change: WorkspaceChange) void {
    for (&model.clients.items) |*slot| {
        const session = slot.* orelse continue;

        if (std.meta.eql(session.key, change.origin) or !session.active()) {
            continue;
        }

        if (session.attachments.observes(change.workspace)) {
            session.delivery.responses.resync_workspace = change.workspace;
            session.delivery.responses.resync_previous_workspace = change.previous_workspace;
        }
    }
}

/// Detaches one pane and completes any resulting workspace departure.
///
/// ```zig
/// const detached = model.detachSessionPane(session, pane_id);
/// ```
pub fn detachSessionPane(model: *RuntimeModel, session: *Session, pane_id: core.PaneId) ?PaneDetachedType {
    const detached = session.attachments.detach(pane_id) orelse return null;
    model.completeSessionWorkspaceDeparture(session, detached);
    return detached;
}

fn completeSessionWorkspaceDeparture(model: *RuntimeModel, session: *Session, detached: PaneDetachedType) void {
    if (!detached.last_attachment) {
        return;
    }

    const left_workspace = session.attachments.leaveWorkspace(detached.workspace);
    std.debug.assert(left_workspace);

    if (!left_workspace) {
        return;
    }

    model.releaseGeometryFor(session.key, detached.workspace);
}

/// Completes departures deferred by `pane_exited` only after every pane
/// that can still publish lifecycle changes for the workspace is reaped.
fn completeEmptyWorkspaceDepartures(model: *RuntimeModel, workspace: core.WorkspaceLocation) void {
    if (model.hasPendingExitedPane(workspace)) {
        return;
    }

    for (&model.clients.items) |*slot| {
        const session = slot.* orelse continue;

        if (session.attachments.len() != 0 or !session.attachments.observes(workspace)) {
            continue;
        }

        const left_workspace = session.attachments.leaveWorkspace(workspace);
        std.debug.assert(left_workspace);

        if (left_workspace) {
            model.releaseGeometryFor(session.key, workspace);
        }
    }
}

fn hasPendingExitedPane(model: *const RuntimeModel, workspace: core.WorkspaceLocation) bool {
    for (model.panes.items) |slot| {
        const pane = slot orelse continue;

        if (pane.exit != null and std.meta.eql(pane.location.workspace, workspace)) {
            return true;
        }
    }

    return false;
}

/// Delivers an automatic tab-removal fact to every client that still
/// observes its workspace. Queue saturation records snapshot recovery.
fn publishLifecycleTabRemoved(model: *RuntimeModel, removed: TabRemovedType) void {
    for (&model.clients.items) |*client_slot| {
        const client = client_slot.* orelse continue;

        if (!client.active() or !client.attachments.observes(removed.location.workspace)) {
            continue;
        }

        client.delivery.responses.pushOrDrop(.{ .tab_closed = .{
            .request_id = .none,
            .location = removed.location,
            .workspace_closed = removed.workspace_removed,
            .previous_workspace = removed.previous_workspace,
        } });
    }
}

/// Publishes a notification to active UI sessions and returns the number queued.
///
/// ```zig
/// const recipients = model.publishNotification(notification);
/// ```
pub fn publishNotification(model: *RuntimeModel, notification: core.Notification) u8 {
    const pending = PendingNotificationType.init(notification);
    var delivered: u8 = 0;

    for (&model.clients.items) |*slot| {
        const recipient = slot.* orelse continue;

        if (!recipient.active() or recipient.role != .ui) {
            continue;
        }

        if (recipient.delivery.responses.pushNotification(pending)) {
            delivered += 1;
        }
    }

    return delivered;
}

/// Queues an agent sound for every active UI client.
///
/// ```zig
/// model.publishAgentSound(notification);
/// ```
pub fn publishAgentSound(model: *RuntimeModel, notification: core.AgentSoundNotification) void {
    for (&model.clients.items) |*slot| {
        const recipient = slot.* orelse continue;

        if (!recipient.active() or recipient.role != .ui) {
            continue;
        }

        _ = recipient.delivery.responses.pushAgentSound(notification);
    }
}

/// Publishes due cells from current owners; the timer borrows no attachment.
/// Example: `try model.cellPublicationDue(result);`.
pub fn cellPublicationDue(model: *RuntimeModel, result: anyerror!void) !void {
    try model.cell_timer.complete(result);
}

/// Routes a decoded client message through a request-scoped dispatcher.
///
/// ```zig
/// try model.dispatchClientMessage(session, message);
/// ```
pub fn dispatchClientMessage(model: *RuntimeModel, session: *Session, message: core.ClientMessage) !void {
    return requests.dispatch(model, session, message);
}

const GraphicsLimits = @import("../media/GraphicsLimits.zig");

test "runtime model tables start empty with configured graphics limits" {
    const graphics_limits: GraphicsLimits = .{
        .pane_bytes = 1024,
        .global_bytes = 4096,
        .images_per_pane = 2,
        .placements_per_pane = 2,
        .payload_bytes = 256,
        .chunks_per_image = 4,
    };
    var model: RuntimeModel = undefined;
    model.workspaces = .{};
    model.agents = .{};
    model.panes = .{
        .graphics_limits = graphics_limits,
        .graphics_budget = .init(graphics_limits.global_bytes),
    };
    defer model.panes.deinit();

    try std.testing.expectEqual(@as(usize, 0), model.workspaces.count);
    try std.testing.expectEqual(@as(usize, 0), model.panes.count);
    try std.testing.expectEqual(graphics_limits.global_bytes, model.panes.graphics_budget.limit);
    try std.testing.expectEqualDeep(graphics_limits, model.panes.graphics_limits);

    var entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined;
    try std.testing.expectEqual(@as(usize, 0), model.agents.snapshot(&entries, 0).len);
}

test "workspace repository releases allocations retained by the runtime model" {
    var model: RuntimeModel = undefined;
    model.workspaces = .{};
    model.gpa = std.testing.allocator;
    var repository = model.workspaceRepository();
    defer repository.deinit();

    _ = try repository.ensure("/tmp/telar-model-test");

    try std.testing.expectEqual(@as(usize, 1), model.workspaces.count);
}
