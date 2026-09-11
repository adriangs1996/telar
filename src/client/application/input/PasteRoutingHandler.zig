const PasteRoutingEffects = @import("PasteRoutingEffects.zig");
const PasteRoutingAuthority = @import("PasteRoutingAuthority.zig");
const paste_routing = @import("paste_routing.zig");
const PasteRoutingHandler = @This();

effects: PasteRoutingEffects,

/// Resolves one paste phase against a fixed authority snapshot and sends
/// it to at most one owner.
///
/// ```zig
/// const outcome = try handler.execute(authority, command);
/// ```
pub fn execute(handler: *PasteRoutingHandler, authority: PasteRoutingAuthority, command: paste_routing.Command) !paste_routing.Outcome {
    const owner = paste_routing.resolve(authority, command) orelse return .ignored;

    try handler.effects.route(handler.effects.context, .{
        .owner = owner,
        .command = command,
    });

    return switch (owner) {
        .prompt => .prompt_owned,
        .pane => .pane_owned,
    };
}
