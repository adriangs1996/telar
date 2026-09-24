const keyinput = @import("keyinput");
const data = @import("model");
const client = @import("telar-client");

// No escape decoder is instantiated: AppKit and Wayland supply semantic keys.
pub const Type = keyinput.GenericRouter(data.actions.Action, .{
    .max_bindings = data.config_values.max_bindings,
    .max_keys = data.config_values.max_binding_keys,
    .input_capacity = 1,
    .held_capacity = 128,
    .max_physical_leases = data.keybind.max_physical_leases,
    .escape_timeout_ns = data.keybind.default_escape_timeout_ns,
    .sequence_timeout_ns = data.keybind.default_sequence_timeout_ns,
}, struct {});

/// Example: `const router = try build(config);`
pub fn build(config: client.RouterConfig) !Type {
    const resolved = try client.default_bindings.resolve(config.prefix, config.bindings);
    var router = try Type.initWithPrefix(resolved.slice(), config.prefix);
    router.escape_timeout_ns = config.escape_timeout_ns;
    router.sequence_timeout_ns = config.sequence_timeout_ns;
    return router;
}
