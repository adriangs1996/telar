//! Public construction contract and opt-in integration seams for a runtime.

const std = @import("std");
const core = @import("telar-core");
const engine = @import("../engine/root.zig");
const pane = @import("../pane/root.zig");
const pane_launcher = @import("application/pane_launcher.zig");
const proxy_resource = @import("resources/proxy.zig");

const Io = std.Io;

/// Process facilities selected by `main` and borrowed by one runtime instance.
pub const Dependencies = struct {
    io: Io,
    allocator: std.mem.Allocator,
};

pub const GraphicsLimits = pane.GraphicsLimits;

pub const AgentDescriptionOptions = struct {
    arguments: []const []const u8,
    timeout_ms: u32,
};

/// A headless agent engine (Pi in RPC mode) the runtime keeps alive between
/// prompts. Configuring it is an explicit privacy opt-in: prompts carry user
/// text such as the first request of an agent session.
pub const EngineOptions = engine.Options;

pub const ProxyOptions = proxy_resource.Config;

pub const Options = struct {
    endpoint: []const u8,
    graphics: GraphicsLimits = .{},
    environment: std.process.Environ,
    /// SQLite database for durable history; the default keeps it in memory.
    history_path: [:0]const u8 = ":memory:",
    /// Record-time history filtering: secrets refusal plus configured
    /// command and cwd patterns.
    history_filters: core.history_filter.Filters = .{},
    /// Keep a bounded raw output tail per command (opt-in).
    history_output_capture: bool = false,
    proxy: ?ProxyOptions = null,
    agent_descriptions: ?AgentDescriptionOptions = null,
    /// The headless agent behind features like command suggestion.
    engine: ?EngineOptions = null,
    /// Agent identification rules; the built-in table unless configured.
    agent_manifests: core.agent_manifest.Table = core.agent_manifest.builtin_table,
    /// Absolute session checkpoint path; null keeps the session volatile.
    session_path: ?[]const u8 = null,
    /// Type each restored agent's resume command into its relaunched shell.
    resume_agents: bool = true,
    /// Test seam: stops the otherwise long-lived runtime without signals.
    stop: ?*Io.Queue(u8) = null,
    /// Test seam: holds a pane's ingest actor open.
    ingest_gate: ?*IngestTestGate = null,
    /// Test seam: fails one pane launch at a selected post-spawn phase.
    launch_fault: ?*LaunchTestFault = null,
};

/// Everything required to initialize one runtime at a stable address.
pub const Initialization = struct {
    dependencies: Dependencies,
    options: Options,
};

/// Deterministic integration seam proving that PTY input remains independent
/// while a pane's bounded ingest actor is occupied. Production entrypoints do
/// not install this gate.
pub const IngestTestGate = struct {
    entered: *Io.Queue(u8),
    release: *Io.Queue(u8),
    claimed: std.atomic.Value(bool) = .init(false),

    /// Blocks only the first caller until the test releases it.
    ///
    /// ```zig
    /// try gate.wait(std.testing.io);
    /// ```
    pub fn wait(gate: *IngestTestGate, io: Io) !void {
        if (gate.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
            return;
        }

        try gate.entered.putOne(io, 0);
        _ = try gate.release.getOne(io);
    }
};

pub const LaunchTestFault = pane_launcher.LaunchTestFault;

test "the ingest gate is claimed at most once" {
    var entered_storage: [1]u8 = undefined;
    var release_storage: [1]u8 = undefined;
    var entered: Io.Queue(u8) = .init(&entered_storage);
    var release: Io.Queue(u8) = .init(&release_storage);
    var gate: IngestTestGate = .{ .entered = &entered, .release = &release };

    gate.claimed.store(true, .release);
    try gate.wait(std.testing.io);

    try std.testing.expect(gate.claimed.load(.acquire));
}
