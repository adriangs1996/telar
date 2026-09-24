const console = @import("console");
const keyinput = @import("keyinput");

/// Builds a fixed-capacity key router for one semantic action type.
/// For example: `const InputRouter = Router(Action, limits);`.
pub fn Type(comptime Action: type, comptime limits: keyinput.RouterLimits) type {
    return keyinput.GenericRouter(Action, limits, console);
}
