//! Application policy for assigning routed host input to one client owner.

const GenericTable = @import("../../input/GenericTable.zig").Type;
const keybind = @import("../../input/keybind.zig");
const KeyRoutingAuthority = @import("KeyRoutingAuthority.zig");
const std = @import("std");

pub const Command = @import("../../types/KeyRoutingCommand.zig").KeyRoutingCommand;

pub const Owner = @import("../../types/KeyRoutingOwner.zig").KeyRoutingOwner;

pub const PaneTarget = @import("../../types/KeyRoutingPaneTarget.zig").KeyRoutingPaneTarget;

pub const LeaseOwner = @import("../../types/KeyRoutingLeaseOwner.zig").KeyRoutingLeaseOwner;

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

pub const Event = @import("../../types/KeyRoutingEvent.zig").KeyRoutingEvent;

pub const Failure = @import("../../types/KeyRoutingFailure.zig").KeyRoutingFailure;

test "key routing captures only modal and prompt authority" {
    try std.testing.expect(captures(
        .{
            .attachment_modal_active = true,
        },
    ));
    try std.testing.expect(captures(
        .{
            .prompt_active = true,
        },
    ));
    try std.testing.expect(!captures(
        .{
            .copy_mode_active = true,
        },
    ));
    try std.testing.expect(!captures(
        .{},
    ));
}
