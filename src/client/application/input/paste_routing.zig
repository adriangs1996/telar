//! Application policy for assigning each streamed paste phase to one owner.

const PasteRoutingAuthority = @import("PasteRoutingAuthority.zig");

pub const Command = union(enum) {
    start,
    /// Borrowed only for the synchronous routing effect.
    content: []const u8,
    finish,
};

pub const Owner = enum {
    prompt,
    pane,
};

pub const Outcome = enum {
    ignored,
    prompt_owned,
    pane_owned,
};

pub fn resolve(authority: PasteRoutingAuthority, command: Command) ?Owner {
    return switch (command) {
        .start => if (authority.attachment_modal_active)
            null
        else if (authority.prompt_active)
            .prompt
        else if (authority.copy_mode_active)
            null
        else
            .pane,
        .content, .finish => if (authority.pane_paste_active)
            .pane
        else if (authority.prompt_pasting)
            .prompt
        else
            null,
    };
}
