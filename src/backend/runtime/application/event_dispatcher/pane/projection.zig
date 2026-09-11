//! Runtime-event adapters for pane observation and media projections.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../../../attachment/root.zig");
const client_store = @import("../../../client/root.zig").store;
const pane_events = @import("../../../entrypoints/events/pane/root.zig");
const history = @import("../../../../history/root.zig");
const media_mod = @import("../../../../media/root.zig");
const pane_mod = @import("../../../../pane/root.zig");
const agent_process = @import("../../../../process/root.zig");

pub const schema = core.schema;
pub const diagnostics = core.diagnostics;

pub const AttachmentStore = attachment_mod.AttachmentStore;
pub const Pane = pane_mod.Pane;
pub const enforceGraphicsQuotas = attachment_mod.enforceGraphicsQuotas;
pub const max_clients = client_store.max_clients;
pub const media_projection = pane_events.media_projection;
pub const pane_media_coordinator = pane_events.media;
pub const pane_observation_coordinator = pane_events.observation;
pub const PaneMediaEvent = pane_media_coordinator.Completion;
pub const PaneObservationEvent = pane_observation_coordinator.Completion;

pub const Dependencies = @import("GenericProjectionDependencies.zig").Type;

pub const Dispatcher = @import("GenericProjectionDispatcher.zig").Type;

test {
    std.testing.refAllDecls(@This());
}
