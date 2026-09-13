const client = @import("telar-client");

// No escape decoder is instantiated: AppKit and Wayland supply semantic keys.
pub const Type = client.GenericRouter(client.Action, .{
    .max_bindings = client.config_model.max_bindings,
    .max_keys = client.config_model.max_binding_keys,
    .input_capacity = 1,
    .held_capacity = 128,
}, struct {});

/// Example: `const router = try build(config);`
pub fn build(config: client.RouterConfig) !Type {
    const resolved = try client.default_bindings.resolve(config.prefix, config.bindings);
    var router = try Type.initWithPrefix(resolved.slice(), config.prefix);
    router.escape_timeout_ns = config.escape_timeout_ns;
    router.sequence_timeout_ns = config.sequence_timeout_ns;
    return router;
}
