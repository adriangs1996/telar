const ConfigType = @import("Config.zig");
const CredentialGateType = @import("CredentialGate.zig");
const InitOptions = @This();

config: ConfigType,
gate: CredentialGateType,
