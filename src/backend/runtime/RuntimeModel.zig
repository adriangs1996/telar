const localsocket = @import("localsocket");
const pacing = @import("pacing");
const core = @import("telar-core");
const std = @import("std");
const ReviewJobs = @import("../change_review/Jobs.zig");
const PathIndexes = @import("../paths/PathIndexes.zig");
const ReviewService = @import("../change_review/Service.zig");
const EditorOpenState = @import("../editors/State.zig");
const event = @import("event.zig");
const Resources = @import("resources/Resources.zig");
const Options = @import("Options.zig");
const AgentDescriptionOptions = @import("AgentDescriptionOptions.zig");
const LaunchTestFault = @import("LaunchTestFault.zig");
const IngestTestGate = @import("IngestTestGate.zig");
const Store = @import("client/Store.zig");
const GenericState = @import("client/GenericState.zig").Type;
const LifecycleState = @import("lifecycle/State.zig");
const Workspaces = @import("../workspace/Workspaces.zig");
const Worktrees = @import("../workspace/Worktrees.zig");
const PaneStore = @import("../pane/PaneStore.zig");
const Attachments = @import("attachment/Attachments.zig");
const Agents = @import("../agent/Agents.zig");
const PromptBudget = @import("../agent/PromptBudget.zig");
const RestoredAgents = @import("../agent/RestoredAgents.zig");
const Watches = @import("../agent/Watches.zig");
const agent_status = @import("agent_status.zig");
const ClientLayouts = @import("ClientLayouts.zig");
const hostmetrics = @import("hostmetrics");
const Sampler = hostmetrics.Sampler;
const RuntimeMetrics = @import("observability/RuntimeMetrics.zig");
const CheckpointWriter = @import("CheckpointWriter.zig");
const AgentDisplayStorage = @import("delivery/AgentDisplayStorage.zig");
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
/// A description worker owns the single description slot, even after its
/// agent is gone.
agent_description_pending: bool = false,
/// Test seam: fails one pane launch at a selected post-spawn phase.
launch_fault: ?*LaunchTestFault = null,
/// Test seam: holds a pane's ingest actor open.
ingest_gate: ?*IngestTestGate = null,
clients: Store = .{},
/// The one accepted connection whose handshake actor is in flight.
client_admission: GenericState(localsocket.SocketChannel) = .{},
shutdown: LifecycleState = .{},
workspaces: Workspaces = .{},
worktrees: Worktrees = .{},
panes: PaneStore,
attachments: Attachments = .{},
agents: Agents = .{},
/// Prompts panes sent each other in the current window.
prompt_budget: PromptBudget = .{},
/// Titles and resumes restored from a checkpoint, waiting for their agent.
restored_agents: RestoredAgents = .{},
/// Session files watched for names an agent gives its session.
agent_watches: Watches = .{},
/// Advances when an agent appears, leaves, or changes status or title.
agent_revision: u64 = 1,
/// Advances when an agent's session reference changes; the reference names
/// the change-review owner, which `agent_revision` does not cover.
agent_session_revision: u64 = 0,
/// Orders agent projections; zero is never handed out.
agent_sequence: u64 = 0,
client_layouts: ClientLayouts = .{},
system_metrics: Sampler = .{},
system_metrics_pending: bool = false,
metrics: RuntimeMetrics,
checkpoint: CheckpointWriter = .{},
session_name_probe_in_flight: bool = false,
/// Whether a worker is looking for the linked worktree of a pane's directory.
worktree_detection_in_flight: bool = false,
review_jobs: ReviewJobs = .{},
review_service: ?*ReviewService = null,
/// The agent snapshot's revision and the input revisions it last covered.
agent_snapshot_revision: u64 = 1,
agent_snapshot_inputs: [4]u64 = @splat(0),
/// Storage the snapshot is built into, once per flush that sends it.
agent_entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined,
agent_display: [core.max_agent_snapshot_entries]AgentDisplayStorage = undefined,
/// The owner hash discovery last ran against; only safe builds keep it, to
/// check that `review_owner_inputs` covers every owner input.
review_owner_stamp: u64 = 0,
/// Advances when a pane's review owner may change without a table
/// revision: a close request, a review binding or an agent session id.
review_owner_revision: u64 = 0,
/// The pane, agent and review-owner revisions discovery last ran against.
review_owner_inputs: [4]u64 = @splat(0),
/// Discovery skipped a pane because every job slot was busy; retry it.
review_discovery_blocked: bool = false,
editor_open: EditorOpenState = .{},
/// The path picker index of each client that opened one.
path_indexes: PathIndexes = .{},
input_sequence: u64 = 0,
cell_timer: pacing.DeadlineScheduler = .{},

/// Composes the model over resources that outlive it. The caller keeps the
/// model at a stable address until `deinit` completes.
///
/// ```zig
/// try model.init(&resources, loop.selector(), options);
/// ```
pub fn init(model: *RuntimeModel, resources: *Resources, select: *std.Io.Select(event.Event), options: Options) !void {
    const io = resources.io();
    var executable_path: [std.fs.max_path_bytes]u8 = undefined;
    const executable_path_len = try std.process.executablePath(io, &executable_path);

    var review_directory: [std.fs.max_path_bytes]u8 = undefined;
    const review_path = try std.fmt.bufPrint(&review_directory, "{s}/change-reviews", .{std.fs.path.dirname(options.session_path orelse options.endpoint) orelse return error.InvalidReviewStorage});
    const review_service = try ReviewService.init(resources.gpa, review_path);
    errdefer review_service.deinit();
    model.* = .{
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
        .checkpoint = .{ .path = options.session_path, .resume_agents = options.resume_agents },
        .agent_description_options = options.agent_descriptions,
        .launch_fault = options.launch_fault,
        .ingest_gate = options.ingest_gate,
        .panes = .{
            .graphics_limits = options.graphics,
            .graphics_budget = .init(options.graphics.global_bytes),
        },
        .client_layouts = try .init(resources.gpa),
        .metrics = .{ .started_ns = core.now(io) },
    };
}

/// Releases attachment, pane, job and workspace state after every actor has
/// joined.
/// Example: `runtime.loop.cancel(); client_connection.releaseAll(model); model.deinit();`.
pub fn deinit(model: *RuntimeModel) void {
    model.attachments.deinit(model.gpa);
    model.panes.deinit();
    model.review_jobs.deinitJoined();
    model.path_indexes.deinitJoined();
    if (model.review_service) |service| {
        service.deinit();
        model.review_service = null;
    }

    model.client_layouts.deinit();
    model.workspaces.deinit(model.gpa);
    model.worktrees.deinit(model.gpa);
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
    try std.testing.expectEqual(@as(usize, 0), agent_status.snapshot(&model.agents, &entries, 0).len);
}

test "the workspace table releases allocations retained by the runtime model" {
    const model = try std.testing.allocator.create(RuntimeModel);
    defer std.testing.allocator.destroy(model);
    model.workspaces = .{};
    defer model.workspaces.deinit(std.testing.allocator);

    _ = try model.workspaces.insert(std.testing.allocator, "/tmp/telar-model-test", null);

    try std.testing.expectEqual(@as(usize, 1), model.workspaces.count);
}
