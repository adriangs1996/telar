//! Public namespace for client-owned Lua configuration.

const config_model = @import("model.zig");
const default_bindings = @import("default_bindings.zig");
const generation = @import("generation.zig");
const loader = @import("loader.zig");
const vm = @import("vm.zig");

pub const api_version = generation.api_version;
pub const default_memory_limit = config_model.default_memory_limit;
pub const default_load_instruction_limit = config_model.default_load_instruction_limit;
pub const default_callback_instruction_limit = vm.default_callback_instruction_limit;
pub const default_callback_deadline_ns = vm.default_callback_deadline_ns;
pub const hook_instruction_interval = vm.hook_instruction_interval;
pub const max_bindings = config_model.max_bindings;
pub const max_binding_keys = config_model.max_binding_keys;
pub const max_binding_suffix_keys = generation.max_binding_suffix_keys;
pub const max_callbacks = generation.max_callbacks;
pub const max_callback_effects = config_model.max_callback_effects;
pub const max_expression_keys = config_model.max_expression_keys;
pub const max_expression_paste_bytes = config_model.max_expression_paste_bytes;
pub const max_config_bytes = generation.max_config_bytes;
pub const max_local_modules = generation.max_local_modules;
pub const max_plugins = config_model.max_plugins;
pub const max_plugin_path_bytes = config_model.max_plugin_path_bytes;
pub const max_profile_name_bytes = generation.max_profile_name_bytes;
pub const max_history_path_bytes = config_model.max_history_path_bytes;
pub const max_proxy_path_bytes = config_model.max_proxy_path_bytes;
pub const max_proxy_intercept_hosts = config_model.max_proxy_intercept_hosts;
pub const max_proxy_intercept_host_bytes = config_model.max_proxy_intercept_host_bytes;
pub const max_proxy_intercept_bytes = config_model.max_proxy_intercept_bytes;
pub const max_agent_description_command_args = config_model.max_agent_description_command_args;
pub const max_agent_description_command_bytes = config_model.max_agent_description_command_bytes;
pub const max_bar_callbacks = config_model.max_bar_callbacks;
pub const min_agent_description_timeout_ms = config_model.min_agent_description_timeout_ms;
pub const max_agent_description_timeout_ms = config_model.max_agent_description_timeout_ms;
pub const default_binding_count = default_bindings.count;
pub const default_binding_max_keys = default_bindings.max_keys;
pub const DefaultBinding = default_bindings.Binding;
pub const loadDefaultBindings = default_bindings.load;
pub const resolveBindings = default_bindings.resolve;
pub const validateKeymap = default_bindings.validate;

pub const ConfiguredBinding = config_model.ConfiguredBinding;
pub const Diagnostic = config_model.Diagnostic;
pub const Snapshot = config_model.Snapshot;
pub const PluginSpec = config_model.PluginSpec;
pub const RuntimeSnapshot = config_model.RuntimeSnapshot;
pub const AgentDescriptionCommand = config_model.AgentDescriptionCommand;
pub const CommandSpec = config_model.CommandSpec;
pub const SoundConfig = config_model.SoundConfig;
pub const BarCallbackContext = config_model.BarCallbackContext;
pub const BarTime = config_model.BarTime;
pub const BarMetrics = config_model.BarMetrics;
pub const BarInvocation = config_model.BarInvocation;
pub const CallbackContext = config_model.CallbackContext;
pub const EffectBatch = config_model.EffectBatch;
pub const InputKeys = config_model.InputKeys;
pub const InputPaste = config_model.InputPaste;
pub const InputDecision = config_model.InputDecision;
pub const Limits = config_model.Limits;
pub const Meter = vm.Meter;
pub const Vm = vm.Vm;
pub const Generation = generation.Generation;
pub const defaultPath = loader.defaultPath;

test {
    _ = generation;
    _ = loader;
    _ = vm;
}
