const LifecycleState = @import("LifecycleState.zig");
const Frame = @import("Frame.zig");
const ProjectionType = @import("Projection.zig");
const lifecycle_module = @import("lifecycle.zig");
const ObservationType = @import("Observation.zig");
const headless = @import("headless.zig");
const GeometryType = @import("Geometry.zig");
const DeliveryType = @import("PresentationDelivery.zig");
const Adapter = @This();

state: LifecycleState = .{},
frame: Frame = .{},
busy: bool = false,
fail_preparation: bool = false,

/// Copies one bounded projection synchronously, then holds it until complete.
/// Busy attempts coalesce observations without overwriting the in-flight frame.
/// Example: `const token = try adapter.prepare(projection) orelse return;`.
pub fn prepare(adapter: *Adapter, projection: ProjectionType) !?lifecycle_module.Token {
    const observation: ObservationType = .{
        .model = projection.version,
        .presentation_ingress = projection.presentation_ingress,
        .geometry_revision = projection.geometry.revision,
    };
    _ = adapter.state.observe(observation);
    if (adapter.busy or adapter.state.active != null) {
        return error.PresentationBusy;
    }

    if (!adapter.state.needsPreparation()) {
        return null;
    }

    if (adapter.fail_preparation) {
        return error.HeadlessPreparationFailed;
    }

    var count: usize = 0;
    if (projection.model) |model| {
        for (&model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            const len = pane.buffer.cells.len;
            if (len > headless.cell_capacity - count) {
                return error.HeadlessCellBudgetExceeded;
            }

            count += len;
        }
    }

    adapter.frame.cell_count = 0;
    adapter.frame.pane_count = 0;
    adapter.frame.version = projection.version;
    adapter.frame.geometry = GeometryType.capture(projection);
    adapter.frame.focused = null;
    if (projection.model) |model| {
        adapter.frame.focused = model.layout.focused();
        for (&model.panes) |*slot| {
            const pane = if (slot.*) |*value| value else continue;
            const start = adapter.frame.cell_count;
            const len = pane.buffer.cells.len;
            @memcpy(adapter.frame.cells[start..][0..len], pane.buffer.cells);
            adapter.frame.cell_count += len;
            adapter.frame.panes[adapter.frame.pane_count] = .{
                .id = pane.id,
                .start = start,
                .len = len,
                .cursor = pane.cursor,
                .mouse = pane.mouse,
                .input_modes = pane.input_modes,
                .pointer_shape = pane.pointer_shape,
                .scroll = pane.scroll,
            };
            adapter.frame.pane_count += 1;
        }
    }

    return try adapter.state.begin(.{
        .observation = observation,
        .commit = if (projection.model) |model| model.presentationCommit() else .{},
        .geometry = adapter.frame.geometry,
    });
}

/// Reports completion only after all consumers stop borrowing frame storage.
/// Failed and cancelled work releases its slot without retiring model damage.
/// Example: `const delivery = adapter.complete(token, .delivered) orelse return;`.
pub fn complete(adapter: *Adapter, token: lifecycle_module.Token, outcome: lifecycle_module.Outcome) ?DeliveryType {
    return adapter.state.complete(token, outcome);
}
