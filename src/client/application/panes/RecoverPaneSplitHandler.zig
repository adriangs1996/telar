const RecoverPaneSplitHandler = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("split_pane.zig");
const RecoveryEffects = @import("RecoveryEffects.zig");
model: *client_model.Model,
area: source_namespace.ui.Rect,
effects: RecoveryEffects,

/// Restores only the exact active target that was provisionally resized.
/// Inactive targets need no resize; retired state is reported as stale.
///
/// ```zig
/// const status = try handler.execute(split);
/// ```
pub fn execute(handler: *RecoverPaneSplitHandler, split: source_namespace.PaneSplit) !source_namespace.RecoveryStatus {
    return switch (handler.model.recoverPaneSplit(.{ .split = split, .area = handler.area })) {
        .resize => |resize| recovery: {
            try handler.effects.resize(handler.effects.context, resize);
            break :recovery .restored;
        },
        .not_required => .not_required,
        .stale => .stale,
    };
}
