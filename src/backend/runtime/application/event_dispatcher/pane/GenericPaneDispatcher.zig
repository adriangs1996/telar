const GenericPaneDependencies = @import("GenericPaneDependencies.zig").Type;
const GenericIoDispatcher = @import("GenericIoDispatcher.zig").Type;
const GenericProjectionDispatcher = @import("GenericProjectionDispatcher.zig").Type;
const GenericPipelineDispatcher = @import("GenericPipelineDispatcher.zig").Type;

/// Composes pane I/O, projection and output-pipeline event adapters without
/// adding runtime state or dispatch policy.
///
/// ```zig
/// const PaneEvents = Dispatcher(Application, dependencies);
/// try PaneEvents.Io.handleInputWritten(&application, event);
/// ```
pub fn Type(comptime Application: type, comptime dependencies: GenericPaneDependencies(Application)) type {
    const IoEvents = GenericIoDispatcher(Application);
    const ProjectionEvents = GenericProjectionDispatcher(Application, .{
        .schedule_description = dependencies.schedule_agent_description,
        .schedule_response = IoEvents.scheduleResponse,
    });
    const PipelineEvents = GenericPipelineDispatcher(Application, .{
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
