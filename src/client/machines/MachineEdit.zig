//! One change to `machines.json`, as `telar machine` and the window's
//! machine picker both make it. The slices are borrowed until the change is
//! applied.
const core = @import("telar-core");
const MachineEdit = @This();

pub const Kind = enum {
    add,
    remove,
    rename,
    enable,
    disable,
    place_telar,
    record_login,
};

kind: Kind,
/// The machine's label; the new machine's label for `add`.
label: []const u8,
/// The new label for `rename`, the destination for `add`, the absolute
/// telar path for `place_telar`, unused otherwise.
value: []const u8 = "",
/// The new machine's color, for `add` only.
color: ?[]const u8 = null,
/// Whether windows connect to the new machine, for `add` only.
enabled: bool = true,
/// The agent and how its login stood, for `record_login` only.
login_agent: core.MachineProfile.LoginAgent = .claude,
login: core.AgentLogin = .pending,
