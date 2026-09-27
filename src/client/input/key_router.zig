//! The keymap router a client without a terminal uses: the native window and
//! the headless client both receive semantic keys, so no escape decoder is
//! instantiated.
const keyinput = @import("keyinput");
const data = @import("model");
const RouterConfig = @import("RouterConfig.zig");
const default_bindings = @import("../config/default_bindings.zig");

pub const Type = keyinput.GenericRouter(data.actions.Action, .{
    .max_bindings = data.config_values.max_bindings,
    .max_keys = data.config_values.max_binding_keys,
    .input_capacity = 1,
    .held_capacity = 128,
    .max_physical_leases = data.keybind.max_physical_leases,
    .escape_timeout_ns = data.keybind.default_escape_timeout_ns,
    .sequence_timeout_ns = data.keybind.default_sequence_timeout_ns,
}, struct {});

/// Builds the router for one configuration's prefix and bindings.
///
/// ```zig
/// const router = try key_router.build(app.routerConfig());
/// ```
pub fn build(config: RouterConfig) !Type {
    const resolved = try default_bindings.resolve(config.prefix, config.bindings);
    var router = try Type.initWithPrefix(resolved.slice(), config.prefix);
    router.escape_timeout_ns = config.escape_timeout_ns;
    router.sequence_timeout_ns = config.sequence_timeout_ns;
    return router;
}
