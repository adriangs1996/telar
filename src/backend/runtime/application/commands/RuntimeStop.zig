const RuntimeStop = @This();
const shutdown_mod = @import("../../lifecycle/root.zig").shutdown_authority;
requester: shutdown_mod.ClientKey,
