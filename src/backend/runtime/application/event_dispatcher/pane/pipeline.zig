//! Runtime-event adapters for pane output ingestion and process exit.

const std = @import("std");
const core = @import("telar-core");
const runtime_config = @import("../../../config.zig");
const pane_events = @import("../../../entrypoints/events/pane/root.zig");
const pane_mod = @import("../../../../pane/root.zig");
const pane_launcher_mod = @import("../../pane_launcher.zig");

pub const schema = core.schema;
pub const diagnostics = core.diagnostics;

pub const IngestTestGate = runtime_config.IngestTestGate;
pub const Pane = pane_mod.Pane;
pub const pane_exit_coordinator = pane_events.exit;
pub const pane_ingest_coordinator = pane_events.ingest;
pub const pane_output_pipeline = pane_events.output;
pub const PaneIngestEvent = pane_ingest_coordinator.Completion;

pub const Dependencies = @import("GenericPipelineDependencies.zig").Type;

pub const Dispatcher = @import("GenericPipelineDispatcher.zig").Type;

test {
    std.testing.refAllDecls(@This());
}
