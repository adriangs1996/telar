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
const LaunchTestFault = @import("LaunchTestFault.zig");
const IngestTestGate = @import("IngestTestGate.zig");
const Store = @import("client/Store.zig");
const GenericState = @import("client/GenericState.zig").Type;
const LifecycleState = @import("lifecycle/State.zig");
const Workspaces = @import("../workspace/Workspaces.zig");
const PaneStore = @import("../pane/PaneStore.zig");
const Tracker = @import("../agent/Tracker.zig");
const ClientLayouts = @import("ClientLayouts.zig");
const Sampler = @import("observability/Sampler.zig");
const RuntimeMetrics = @import("observability/RuntimeMetrics.zig");
const CheckpointWriter = @import("CheckpointWriter.zig");
const AgentHistoryJobs = @import("AgentHistoryJobs.zig");
const ClientKey = @import("../history/ClientKey.zig");
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
client_admission: GenericState(core.SocketChannel) = .{},
shutdown: LifecycleState = .{},
workspaces: Workspaces = .{},
panes: PaneStore,
agents: Tracker = .{},
client_layouts: ClientLayouts = .{},
system_metrics: Sampler = .{},
system_metrics_pending: bool = false,
metrics: RuntimeMetrics,
checkpoint: CheckpointWriter = .{},
session_name_probe_in_flight: bool = false,
agent_history_jobs: AgentHistoryJobs = .{},
review_jobs: ReviewJobs = .{},
review_service: ?*ReviewService = null,
review_admitted: [PaneStore.capacity]?AdmittedReview = @splat(null),
/// The agent snapshot's revision and the input revisions it last covered.
agent_snapshot_revision: u64 = 1,
agent_snapshot_inputs: [4]u64 = @splat(0),
/// Storage the snapshot is built into, once per flush that sends it.
agent_entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined,
agent_display: [core.max_agent_snapshot_entries]AgentDisplayStorage = undefined,
/// The pane and owner state change-review discovery last ran against.
review_owner_stamp: u64 = 0,
/// Discovery skipped a pane because every job slot was busy; retry it.
review_discovery_blocked: bool = false,
editor_open: EditorOpenState = .{},
input_sequence: u64 = 0,
cell_timer: core.DeadlineScheduler = .{},

/// Composes the model over resources that outlive it. The caller keeps the
/// model at a stable address until `deinit` completes.
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

/// Releases pane, job and workspace state after every actor has joined.
/// Example: `runtime.loop.cancel(); client_connection.releaseAll(model); model.deinit();`.
pub fn deinit(self: *RuntimeModel) void {
    self.panes.deinit();
    self.agent_history_jobs.deinitJoined();
    self.review_jobs.deinitJoined();
    if (self.review_service) |service| {
        service.deinit();
        self.review_service = null;
    }

    self.client_layouts.deinit();
    self.workspaces.deinit(self.gpa);
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

test "the workspace table releases allocations retained by the runtime model" {
    const model = try std.testing.allocator.create(RuntimeModel);
    defer std.testing.allocator.destroy(model);
    model.workspaces = .{};
    defer model.workspaces.deinit(std.testing.allocator);

    _ = try model.workspaces.insert(std.testing.allocator, "/tmp/telar-model-test", null);

    try std.testing.expectEqual(@as(usize, 1), model.workspaces.count);
}
