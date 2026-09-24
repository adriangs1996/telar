const keyinput = @import("keyinput");
const term = @import("../presentation/screen_support.zig");

/// Builds a fixed-capacity key router for one semantic action type.
/// For example: `const InputRouter = Router(Action, limits);`.
pub fn Type(comptime Action: type, comptime limits: keyinput.RouterLimits) type {
    return keyinput.GenericRouter(Action, limits, term);
}
