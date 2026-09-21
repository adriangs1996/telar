//! Application policy for assigning routed host input to one client owner.

const KeyType = @import("../../input/Key.zig");
const PaneIdType = @import("telar-core").PaneId;
const GenericTable = @import("../../input/GenericTable.zig").Type;
const keybind = @import("../../input/keybind.zig");
const KeyRoutingAuthority = @import("KeyRoutingAuthority.zig");
const std = @import("std");
const chord = @import("../../input/chord.zig");

pub const Command = union(enum) {
    bytes: []const u8,
    key: KeyType,
};

pub const Owner = enum {
    ignored,
    attachment_modal,
    name_prompt,
    copy_mode,
    pane,
};

pub const PaneTarget = union(enum) {
    current,
    lease: PaneIdType,
};

pub const LeaseOwner = union(enum) {
    ignored,
    attachment_modal,
    name_prompt,
    copy_mode,
    pane: PaneIdType,
};

pub const Leases = GenericTable(LeaseOwner, keybind.max_physical_leases);

/// Returns whether the native router must bypass configured bindings for the
/// current exclusive owner.
///
/// ```zig
/// if (captures(authority)) routeDirectly();
/// ```
pub fn captures(authority: KeyRoutingAuthority) bool {
    return authority.attachment_modal_active or authority.prompt_active;
}

pub fn requestsClipboardPreview(command: Command) bool {
    return switch (command) {
        .bytes => false,
        .key => |key| key.phase == .press and key.isCtrl('v') and !key.mods.alt and !key.mods.shift,
    };
}

pub const Event = enum {
    close_modal,
    prompt,
    copy_key,
    pane,
    preview,
};

pub const Failure = enum {
    none,
    prompt,
    copy_key,
    pane,
    preview,
};

test "key routing captures only modal and prompt authority" {
    try std.testing.expect(captures(.{ .attachment_modal_active = true }));
    try std.testing.expect(captures(.{ .prompt_active = true }));
    try std.testing.expect(!captures(.{ .copy_mode_active = true }));
    try std.testing.expect(!captures(.{}));
}
