const Executions = @import("../execution/Executions.zig");
const localsocket = @import("localsocket");
const pacing = @import("pacing");
const EngineRuntime = @import("resources/EngineRuntime.zig");
const EngineReply = EngineRuntime.Service.Response;
const core = @import("telar-core");
const std = @import("std");
const PathIndexes = @import("../paths/PathIndexes.zig");
const EditorOpenState = @import("../editors/State.zig");
const event = @import("event.zig");
const Resources = @import("resources/Resources.zig");
const Options = @import("Options.zig");
const AgentDescriptionOptions = @import("AgentDescriptionOptions.zig");
const Store = @import("client/Store.zig");
const GenericHandshakes = @import("client/GenericHandshakes.zig").Type;
const store_support = @import("client/store_support.zig");
const LifecycleState = @import("lifecycle/State.zig");
const Workspaces = @import("../workspace/Workspaces.zig");
const Worktrees = @import("../workspace/Worktrees.zig");
const PaneStore = @import("../pane/PaneStore.zig");
const Attachments = @import("attachment/Attachments.zig");
const Agents = @import("../agent/Agents.zig");
const PromptBudget = @import("../agent/PromptBudget.zig");
const RestoredAgents = @import("../agent/RestoredAgents.zig");
const Watches = @import("../agent/Watches.zig");
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
// SAFETY: RuntimeModel.init supplies the executablePath output and its length; consumers use only that prefix.
executable_path: [std.fs.max_path_bytes]u8 = undefined,
executable_path_len: usize,
/// `HOME` from the inherited environment, read once for cwd labels.
home: ?[]const u8 = null,
agent_description_options: ?AgentDescriptionOptions,
/// A description worker owns the single description slot, even after its
/// agent is gone.
agent_description_pending: bool = false,
clients: Store = .{},
/// Hook reports parked so far, which orders their answers.
parked_reports: u64 = 0,
/// Accepted connections whose handshake actors are in flight.
client_admission: GenericHandshakes(localsocket.SocketChannel, store_support.max_pending_handshakes) = .{},
shutdown: LifecycleState = .{},
workspaces: Workspaces = .{},
executions: Executions = .{},
administration_workspace: core.WorkspaceId = .invalid,
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
/// Orders agent projections; zero is never handed out.
agent_sequence: u64 = 0,
client_layouts: ClientLayouts = .{},
system_metrics: Sampler = .{},
system_metrics_pending: bool = false,
metrics: RuntimeMetrics,
/// The limits the runtime reached; `limit_reached.report` writes it.
limit_reaches: core.LimitReaches = .{},
/// The limits clients reported, apart so a client never evicts, silences
/// or renames a runtime row.
client_limit_reaches: core.LimitReaches = .{},
/// Client reports refused because a connection sent too many in a second.
refused_limit_reports: u64 = 0,
checkpoint: CheckpointWriter = .{},
session_name_probe_in_flight: bool = false,
/// Whether a worker is looking for the linked worktree of a pane's directory.
worktree_detection_in_flight: bool = false,
/// The agent snapshot's revision and the input revisions it last covered.
agent_snapshot_revision: u64 = 1,
agent_snapshot_inputs: [4]u64 = @splat(0),
/// Storage the snapshot is built into, once per flush that sends it.
// SAFETY: agent_snapshot.project fills entries before returning their bounded slice to client delivery.
agent_entries: [core.max_agent_snapshot_entries]core.AgentSnapshotEntry = undefined,
// SAFETY: agent_snapshot.project fills each borrowed display string before publishing it in a snapshot entry.
agent_display: [core.max_agent_snapshot_entries]AgentDisplayStorage = undefined,
editor_open: EditorOpenState = .{},
/// The path picker index of each client that opened one.
path_indexes: PathIndexes = .{},
/// Where a `pane_text` reply's text is dumped while it is encoded: one
/// read at a time, on the loop, instead of on the stack of every reply.
// SAFETY: Pane text projection writes into this scratch buffer before synchronous encoding of the returned slice.
pane_text: [core.max_pane_text_bytes]u8 = undefined,
input_sequence: u64 = 0,
cell_timer: pacing.DeadlineScheduler = .{},
/// The engine reply an `engine_response` event announces; its actor writes
/// it and only the loop reads it once the event arrives.
// SAFETY: sources.receiveEngineReply assigns the response before publishing completion; the loop reads it only after successful completion.
engine_reply: EngineReply = undefined,

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

    model.* = .{
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
    for (model.executions.id, 0..) |id, slot| {
        if (id != 0) {
            model.executions.remove(model.gpa, slot);
        }
    }

    model.attachments.deinit(model.gpa);
    model.panes.deinit();
    model.path_indexes.deinitJoined();

    model.client_layouts.deinit();
    model.workspaces.deinit(model.gpa);
    model.worktrees.deinit(model.gpa);
}
