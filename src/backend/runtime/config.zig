//! Public construction contract and opt-in integration seams for a runtime.

const std = @import("std");
const core = @import("telar-core");
const engine = @import("../engine/root.zig");
const pane = @import("../pane/root.zig");
const pane_launcher = @import("application/pane_launcher.zig");
const plugins = @import("../plugins/root.zig");
const proxy_resource = @import("resources/proxy.zig");

pub const Io = std.Io;

pub const Dependencies = @import("Dependencies.zig");

pub const GraphicsLimits = pane.GraphicsLimits;

pub const AgentDescriptionOptions = @import("AgentDescriptionOptions.zig");

/// A headless agent engine (Pi in RPC mode) the runtime keeps alive between
/// prompts. Configuring it is an explicit privacy opt-in: prompts carry user
/// text such as the first request of an agent session.
pub const EngineOptions = engine.Options;

pub const ProxyOptions = proxy_resource.Config;
pub const PluginSpec = plugins.Spec;

pub const Options = @import("Options.zig");

pub const Initialization = @import("Initialization.zig");

pub const IngestTestGate = @import("IngestTestGate.zig");

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
