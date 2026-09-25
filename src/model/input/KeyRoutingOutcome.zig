const key_routing = @import("key_routing.zig");
const Outcome = @This();

owner: KeyRoutingOwner,
delivered: bool = false,
lease_overflow: bool = false,

const KeyRoutingOwner = enum {
    ignored,
    attachment_modal,
    name_prompt,
    copy_mode,
    pane,
};
