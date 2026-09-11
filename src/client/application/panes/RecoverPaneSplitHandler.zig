const ModelType = @import("../../model/Model.zig");
const RectType = @import("telar-core").Rect;
const RecoveryEffects = @import("RecoveryEffects.zig");
const PaneSplitType = @import("../../model/PaneSplit.zig");
const split_pane = @import("split_pane.zig");
const RecoverPaneSplitHandler = @This();

model: *ModelType,
area: RectType,
effects: RecoveryEffects,

/// Restores only the exact active target that was provisionally resized.
/// Inactive targets need no resize; retired state is reported as stale.
///
/// ```zig
/// const status = try handler.execute(split);
/// ```
pub fn execute(handler: *RecoverPaneSplitHandler, split: PaneSplitType) !split_pane.RecoveryStatus {
    return switch (handler.model.recoverPaneSplit(.{ .split = split, .area = handler.area })) {
        .resize => |resize| recovery: {
            try handler.effects.resize(handler.effects.context, resize);
            break :recovery .restored;
        },
        .not_required => .not_required,
        .stale => .stale,
    };
}
