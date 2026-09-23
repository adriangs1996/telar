const data = @import("model");
const LifecycleState = @import("LifecycleState.zig");
const Frame = @import("Frame.zig");
const Projection = @import("Projection.zig");
const lifecycle_module = @import("lifecycle.zig");
const Observation = @import("Observation.zig");
const headless = @import("headless.zig");
const Geometry = @import("Geometry.zig");
const PresentationDelivery = @import("PresentationDelivery.zig");
const Adapter = @This();

/// The client's presentation lifecycle, borrowed.
state: *LifecycleState,
frame: Frame = .{},
busy: bool = false,
fail_preparation: bool = false,

/// Copies one bounded projection synchronously, then holds it until complete.
/// Busy attempts coalesce observations without overwriting the in-flight frame.
/// Example: `const token = try adapter.prepare(projection) orelse return;`.
pub fn prepare(self: *Adapter, projection: Projection) !?lifecycle_module.Token {
    const observation: Observation = .{
        .model = projection.version,
        .presentation_ingress = projection.presentation_ingress,
        .geometry_revision = projection.geometry.revision,
    };
    _ = self.state.observe(observation);
    if (self.busy or self.state.active != null) {
        return error.PresentationBusy;
    }

    if (!self.state.needsPreparation()) {
        return null;
    }

    if (self.fail_preparation) {
        return error.HeadlessPreparationFailed;
    }

    var count: usize = 0;
    const model = projection.model;
    if (projection.tab) |slot| {
        var panes = model.panes.iterateConst(model.tabs.location[slot].tab_id);
        while (panes.next()) |pane| {
            const len = pane.buffer.cells.len;
            if (len > headless.cell_capacity - count) {
                return error.HeadlessCellBudgetExceeded;
            }

            count += len;
        }
    }

    self.frame.cell_count = 0;
    self.frame.pane_count = 0;
    self.frame.version = projection.version;
    self.frame.geometry = Geometry.capture(projection);
    self.frame.focused = null;
    if (projection.tab) |slot| {
        self.frame.focused = model.tabs.layout[slot].focused();
        var panes = model.panes.iterateConst(model.tabs.location[slot].tab_id);
        while (panes.next()) |pane| {
            const start = self.frame.cell_count;
            const len = pane.buffer.cells.len;
            @memcpy(self.frame.cells[start..][0..len], pane.buffer.cells);
            self.frame.cell_count += len;
            self.frame.panes[self.frame.pane_count] = .{
                .id = pane.id,
                .start = start,
                .len = len,
                .cursor = pane.cursor,
                .mouse = pane.mouse,
                .input_modes = pane.input_modes,
                .pointer_shape = pane.pointer_shape,
                .scroll = pane.scroll,
            };
            self.frame.pane_count += 1;
        }
    }

    return try self.state.begin(.{
        .observation = observation,
        .commit = if (projection.tab) |slot| data.presentation_delivery.capture(model, slot) else .{},
        .geometry = self.frame.geometry,
    });
}

/// Reports completion only after all consumers stop borrowing frame storage.
/// Failed and cancelled work releases its slot without retiring model damage.
/// Example: `const delivery = adapter.complete(token, .delivered) orelse return;`.
pub fn complete(self: *Adapter, token: lifecycle_module.Token, outcome: lifecycle_module.Outcome) ?PresentationDelivery {
    return self.state.complete(token, outcome);
}
