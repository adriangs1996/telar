//! What a tab shows as its name: the canonical label, or the focused
//! foreground application when the label is empty. The GUI strip shows a
//! richer caption for the same tab: the agent's session title, or the focused
//! directory beside the application.
const core = @import("telar-core");
const std = @import("std");
const ClientModel = @import("../state/ClientModel.zig");
const icons = @import("../layout/icons.zig");
const tab_layout = @import("tab_layout.zig");
const pane_support = @import("../panes/pane_support.zig");

/// Bytes a caption can need: a directory name, the separator and an
/// application name. Session titles are borrowed, never copied.
pub const caption_bytes = core.max_tab_label_bytes;

const caption_separator = " \u{00b7} ";

comptime {
    std.debug.assert(pane_support.max_cwd_name_bytes + caption_separator.len + core.max_foreground_name_bytes <= caption_bytes);
}

/// What the GUI tab strip calls a tab. A manual label wins. An automatic tab
/// names the agent in its focused pane by session title once that title is no
/// longer a placeholder; otherwise it names the focused directory beside the
/// foreground application, so two shells in different projects differ.
/// Example: `var storage: [tab_label.caption_bytes]u8 = undefined; const shown = tab_label.caption(model, slot, &storage);`
pub fn caption(model: *const ClientModel, slot: usize, storage: *[caption_bytes]u8) []const u8 {
    if (!automatic(model, slot)) {
        return model.tabs.canonicalLabel(slot);
    }

    const application = applicationName(model, slot);
    const pane = tab_layout.focusedPaneConst(model, slot) orelse return application;
    if (sessionTitle(model, slot, pane.id)) |title| {
        return title;
    }

    const directory = pane.cwdName();
    if (directory.len == 0) {
        return application;
    }

    return std.fmt.bufPrint(storage, "{s}{s}{s}", .{ directory, caption_separator, application }) catch application;
}

/// Example: `const title = tab_label.text(model, slot);`
pub fn text(model: *const ClientModel, slot: usize) []const u8 {
    if (!automatic(model, slot)) {
        return model.tabs.canonicalLabel(slot);
    }

    return applicationName(model, slot);
}

/// Artwork for the focused application of any tab, renamed or not, so every
/// tab in the GUI strip carries a mark.
/// Example: `const mark = tab_label.mark(model, slot);`
pub fn mark(model: *const ClientModel, slot: usize) icons.Icon {
    return icons.Icon.forApplication(applicationName(model, slot));
}

/// Artwork for a tab that follows its foreground application.
/// Example: `if (tab_label.icon(model, slot)) |icon| draw(icon);`
pub fn icon(model: *const ClientModel, slot: usize) ?icons.Icon {
    if (!automatic(model, slot)) {
        return null;
    }

    return icons.Icon.forApplication(applicationName(model, slot));
}

/// Example: `if (tab_label.automatic(model, slot)) followForeground();`
pub fn automatic(model: *const ClientModel, slot: usize) bool {
    return model.tabs.label_len[slot] == 0;
}

/// Refreshes foreground names using this client's focus before panes
/// attach, and reports whether the visible label changed.
/// Example: `_ = tab_label.applyForegroundSnapshot(model, slot, names, saved_focus);`
pub fn applyForegroundSnapshot(model: *ClientModel, slot: usize, names: []const core.PaneForeground, saved_focus: ?core.PaneId) bool {
    if (names.len == 0) {
        return false;
    }

    var previous: [core.max_tab_label_bytes]u8 = undefined;
    const previous_text = text(model, slot);
    @memcpy(previous[0..previous_text.len], previous_text);
    const previous_len = previous_text.len;
    const layout = &model.tabs.layout[slot];
    const focused = if (model.tabs.snapshot_loaded[slot]) layout.focused() else saved_focus orelse layout.focused();
    var selected = names[0];
    for (names) |name| {
        if (focused != null and focused.? == name.pane_id) {
            selected = name;
        }
    }

    model.tabs.foreground_pane[slot] = selected.pane_id;
    model.tabs.setForegroundName(slot, selected.name);
    return !std.mem.eql(u8, previous[0..previous_len], text(model, slot));
}

/// Updates a detached tab's selected foreground and reports whether its
/// automatic label changed.
/// Example: `_ = tab_label.applyForegroundReport(model, slot, report);`
pub fn applyForegroundReport(model: *ClientModel, slot: usize, report: core.PaneForeground) bool {
    if (report.pane_id != model.tabs.foreground_pane[slot] or std.mem.eql(u8, report.name, model.tabs.foregroundName(slot))) {
        return false;
    }

    model.tabs.setForegroundName(slot, report.name);
    return automatic(model, slot);
}

fn sessionTitle(model: *const ClientModel, slot: usize, pane_id: core.PaneId) ?[]const u8 {
    const location = model.tabs.location[slot];
    for (model.agent_snapshot.slice()) |*agent| {
        if (agent.key.pane_id != pane_id or !std.meta.eql(agent.location, location)) {
            continue;
        }

        if (agent.title_state == .placeholder or agent.sessionTitle().len == 0) {
            return null;
        }

        return agent.sessionTitle();
    }

    return null;
}

fn applicationName(model: *const ClientModel, slot: usize) []const u8 {
    if (tab_layout.focusedPaneConst(model, slot)) |pane| {
        if (pane.foregroundName().len != 0) {
            return pane.foregroundName();
        }

        if (pane.id != model.tabs.foreground_pane[slot]) {
            return "shell";
        }
    }

    const name = model.tabs.foregroundName(slot);
    return if (name.len == 0) "shell" else name;
}
