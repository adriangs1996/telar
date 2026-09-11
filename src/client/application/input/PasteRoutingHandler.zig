const PasteRoutingHandler = @This();
const Effects = @import("PasteRoutingEffects.zig");
const Authority = @import("PasteRoutingAuthority.zig");
const source_namespace = @import("paste_routing.zig");
effects: Effects,

/// Resolves one paste phase against a fixed authority snapshot and sends
/// it to at most one owner.
///
/// ```zig
/// const outcome = try handler.execute(authority, command);
/// ```
pub fn execute(handler: *PasteRoutingHandler, authority: Authority, command: source_namespace.Command) !source_namespace.Outcome {
    const owner = source_namespace.resolve(authority, command) orelse return .ignored;

    try handler.effects.route(handler.effects.context, .{
        .owner = owner,
        .command = command,
    });

    return switch (owner) {
        .prompt => .prompt_owned,
        .pane => .pane_owned,
    };
}
