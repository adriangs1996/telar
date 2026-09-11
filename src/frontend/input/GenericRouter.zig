const RouterLimits = @import("telar-client").RouterLimits;
const GenericRouter = @import("telar-client").GenericRouter;
const term = @import("../presentation/screen_support.zig");

/// Builds a fixed-capacity key router for one semantic action type.
/// For example: `const InputRouter = Router(Action, .{ .max_bindings = 16, .max_keys = 4, .input_capacity = 64, .held_capacity = 32 });`.
pub fn Type(comptime Action: type, comptime limits: RouterLimits) type {
    return GenericRouter(Action, limits, term);
}
