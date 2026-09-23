const core = @import("telar-core");
const std = @import("std");
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
const SessionTitleType = @import("../agent/SessionTitle.zig");
const CompletionType = @import("resources/Completion.zig");
const AgentCompletion = @import("../agent/Completion.zig");
const commands = @import("../workspace/commands.zig");
const ClientKeyType = @import("../history/ClientKey.zig");
const Session = @import("client/Session.zig");
const client_control = @import("client_control.zig");
const geometry_lease = @import("geometry_lease.zig");
const pane_input = @import("pane_input.zig");
const tab_removal = @import("tab_removal.zig");
/// The authoritative state of one running runtime: singletons as fields and
/// repeating entities as tables. Physical resources stay in `Resources`.
const RuntimeModel = @This();

const GeometryLease = struct {
    workspace: core.WorkspaceLocation,
    owner: ClientKeyType,
};

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
                tab_removal.announce(model, removed);
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
        client_control.abandon(model, key);
        session.closing = true;
        session.connection.shutdown(model.io);
        session.attachments.deinit();
        session.delivery.close();
        geometry_lease.releaseAll(model, key);
    }
    model.finalizeClient(key);
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
            geometry_lease.release(model, session.key, workspace);
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

/// Publishes due cells from current owners; the timer borrows no attachment.
/// Example: `try model.cellPublicationDue(result);`.
pub fn cellPublicationDue(model: *RuntimeModel, result: anyerror!void) !void {
    try model.cell_timer.complete(result);
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
    const model = try std.testing.allocator.create(RuntimeModel);
    defer std.testing.allocator.destroy(model);
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
    const model = try std.testing.allocator.create(RuntimeModel);
    defer std.testing.allocator.destroy(model);
    model.workspaces = .{};
    model.gpa = std.testing.allocator;
    var repository = model.workspaceRepository();
    defer repository.deinit();

    _ = try repository.ensure("/tmp/telar-model-test");

    try std.testing.expectEqual(@as(usize, 1), model.workspaces.count);
}
