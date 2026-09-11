const NativeActionHandler = @This();
const Effects = @import("NativeActionEffects.zig");
const source_namespace = @import("native_action.zig");
const Authority = @import("NativeActionAuthority.zig");
effects: Effects,

/// Retires copy mode before delivering any other native action. This
/// policy applies identically to host, Lua and plugin action sources.
///
/// ```zig
/// const control = try handler.execute(action, authority);
/// ```
pub fn execute(handler: *NativeActionHandler, value: source_namespace.Action, authority: Authority) !source_namespace.Control {
    const preserves_copy_mode = switch (value) {
        .enter_copy_mode => true,
        else => false,
    };
    if (authority.copy_mode_active and !preserves_copy_mode) {
        try handler.effects.leave_copy_mode(handler.effects.context);
    }

    return handler.effects.deliver(handler.effects.context, value);
}
