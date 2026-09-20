//! Resolves delivered Markdown hits against their exact live message snapshot.
const client = @import("telar-client");
const PointerRouting = @import("../../input/PointerRouting.zig");
const std = @import("std");
const GuiClient = @import("../../GuiClient.zig");
const Target = @import("Target.zig");
const Control = @import("MessageLinkControl.zig");
const Preview = @import("../MessageLinkPreview.zig");
const Destination = @import("../MessageLinkDestination.zig");

/// Borrows only the destination range of the recorded immutable message item.
/// Example: `const text = message_links.destination(gui, control) orelse return;`
pub fn destination(gui: *const GuiClient, control: Control) ?[]const u8 {
    const owner = control.owner;
    const model = gui.app.model.activeTabModelConst() orelse return null;
    const pane = model.findConst(owner.pane_id) orelse return null;
    if (!pane.attached or pane.kind != .agent or pane.attachment_generation != owner.attachment_generation) {
        return null;
    }

    const snapshot = pane.threadItemSource(owner.item_identity) orelse return null;
    if (snapshot.pane_generation != owner.pane_generation or snapshot.revision != owner.snapshot_revision) {
        return null;
    }

    const item = snapshot.findItem(owner.item_identity) orelse return null;
    const offset: usize = switch (owner.section) {
        .body => item.text_offset,
        .metadata => item.detail_offset,
        .approval => return null,
    };
    const length: usize = switch (owner.section) {
        .body => item.text_len,
        .metadata => item.detail_len,
        .approval => return null,
    };
    const pool: []const u8 = if (owner.section == .body) snapshot.text_storage[0..snapshot.text_len] else snapshot.metadata_storage[0..snapshot.metadata_len];
    const at: usize = control.destination_offset;
    const len: usize = control.destination_len;
    if (offset > pool.len or length > pool.len - offset or at < offset or at - offset > length or len > length - (at - offset)) {
        return null;
    }

    return pool[at..][0..len];
}

/// Reuses delivered geometry; motion and invalidation require no text layout.
/// Example: `message_links.refresh(gui);`
pub fn refresh(gui: *GuiClient) void {
    const state = &gui.widgets;
    const event = gui.input.pointer.hover.event;
    const target: ?Target = if (event) |pointer| state.dispatcher.maps.presented().at(.{ pointer.x, pointer.y }) else null;
    if (!gui.focused or state.thread_selection.dragging or state.tab_drag.captured or gui.app.model.name_prompt.active() or state.dispatcher.maps.presented().modal_layer != 0 or state.composer_menu.selector != null or event == null or target == null or target.?.action != .message_link or !PointerRouting.geometryMatches(&gui.app)) {
        clear(gui);
        return;
    }

    const hit = target.?;
    const source = destination(gui, hit.action.message_link) orelse {
        clear(gui);
        return;
    };
    if (state.message_link_preview) |*previous| {
        if (std.meta.eql(previous.control, hit.action.message_link) and std.meta.eql(previous.anchor, hit.bounds)) {
            previous.pointer = .{ event.?.x, event.?.y };
            return;
        }
    }

    const decoded = Destination.init(source) catch {
        clear(gui);
        return;
    };
    state.message_link_preview = Preview{ .control = hit.action.message_link, .anchor = hit.bounds, .pointer = .{ event.?.x, event.?.y }, .destination = decoded };
    state.dispatcher.revision +%= 1;
}

/// Example: `message_links.clear(gui);`
pub fn clear(gui: *GuiClient) void {
    if (gui.widgets.message_link_preview != null) {
        gui.widgets.message_link_preview = null;
        gui.widgets.dispatcher.revision +%= 1;
    }
}

/// Opens only a still-current local destination after a completed click.
/// Example: `try message_links.open(gui, control);`
pub fn open(gui: *GuiClient, control: Control) !void {
    if (!PointerRouting.geometryMatches(&gui.app) or gui.app.model.name_prompt.active() or gui.widgets.composer_menu.selector != null) {
        return;
    }

    const source = destination(gui, control) orelse return;
    const decoded = Destination.init(source) catch return;
    const text = decoded.text();
    if (!std.mem.startsWith(u8, text, "/") and !std.ascii.startsWithIgnoreCase(text, "file:")) {
        return;
    }

    const path = client.FilePath.fromDestination(text) catch |err| {
        try client.controllers.notifications.publishNow(&gui.app, .{ .level = .warning, .title = "Could not open link", .message = @errorName(err) });
        return;
    };
    _ = try client.controllers.link_openings.openMessageFile(&gui.app, control.owner.pane_id, path);
    clear(gui);
}
