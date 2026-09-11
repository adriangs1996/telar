const NativeActionEffects = @import("NativeActionEffects.zig");
const action = @import("../../input/action.zig");
const NativeActionAuthority = @import("NativeActionAuthority.zig");
const action_routing = @import("action_routing.zig");
const NativeActionHandler = @This();

effects: NativeActionEffects,

/// Retires copy mode before delivering any other native action. This
/// policy applies identically to host, Lua and plugin action sources.
///
/// ```zig
/// const control = try handler.execute(action, authority);
/// ```
pub fn execute(handler: *NativeActionHandler, value: action.Action, authority: NativeActionAuthority) !action_routing.Control {
    const preserves_copy_mode = switch (value) {
        .enter_copy_mode => true,
        else => false,
    };
    if (authority.copy_mode_active and !preserves_copy_mode) {
        try handler.effects.leave_copy_mode(handler.effects.context);
    }

    return handler.effects.deliver(handler.effects.context, value);
}
