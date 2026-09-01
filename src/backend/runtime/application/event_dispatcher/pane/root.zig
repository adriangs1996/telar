//! Composition root for pane runtime-event adapters.

const std = @import("std");
const pane_io = @import("io.zig");
const pane_pipeline = @import("pipeline.zig");
const pane_projection = @import("projection.zig");

/// Declares cross-capability work requested by pane event handling.
///
/// ```zig
/// const dependencies: Dependencies(Application) = .{ ... };
/// ```
pub fn Dependencies(comptime Application: type) type {
    return struct {
        schedule_agent_description: *const fn (*Application) void,
    };
}

/// Composes pane I/O, projection and output-pipeline event adapters without
/// adding runtime state or dispatch policy.
///
/// ```zig
/// const PaneEvents = Dispatcher(Application, dependencies);
/// try PaneEvents.Io.handleInputWritten(&application, event);
/// ```
pub fn Dispatcher(comptime Application: type, comptime dependencies: Dependencies(Application)) type {
    const IoEvents = pane_io.Dispatcher(Application);
    const ProjectionEvents = pane_projection.Dispatcher(Application, .{
        .schedule_description = dependencies.schedule_agent_description,
        .schedule_response = IoEvents.scheduleResponse,
    });
    const PipelineEvents = pane_pipeline.Dispatcher(Application, .{
        .schedule_observation = ProjectionEvents.scheduleObservation,
        .schedule_media = ProjectionEvents.scheduleMedia,
        .schedule_response = IoEvents.scheduleResponse,
    });

    return struct {
        pub const Io = IoEvents;
        pub const Pipeline = PipelineEvents;
        pub const Projection = ProjectionEvents;
    };
}

test {
    std.testing.refAllDecls(@This());
}
