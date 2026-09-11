const Command = @This();
const client_model = @import("../../root.zig").model;
configuration: client_model.ConfigurationInput,
theme_locked: bool,
