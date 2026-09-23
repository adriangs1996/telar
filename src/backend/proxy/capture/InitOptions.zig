const Config = @import("Config.zig");
const CredentialGate = @import("../CredentialGate.zig");
const InitOptions = @This();

config: Config,
gate: CredentialGate,
