const data = @import("model");
const composer_menu = @import("composer_menu.zig");
const event_module = @import("../../input/event.zig");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const GuiAdapter = @import("../../GuiAdapter.zig");
const Target = @import("Target.zig");
const Route = @import("Route.zig");
const Id = @import("Id.zig");
const ComposerSelector = @import("ComposerSelector.zig");

/// Revalidates draft and catalog identities before using delivered suggestions.
/// Example: `completions.refresh(gui);`
pub fn refresh(gui: *GuiAdapter) void {
    const state = &gui.widgets.completions;
    const tab = gui.app.model.tabs.activeSlot() orelse return;
    const target = gui.widgets.dispatcher.focusedTarget();
    if (gui.app.model.name_prompt.active() or gui.widgets.composer_menu.selector != null or gui.widgets.preedit.owner != null or target == null or target.?.action != .composer) {
        state.open = false;
        return;
    }

    const pane_id = target.?.action.composer;
    if (gui.app.model.panes.findInConst(gui.app.model.tabs.location[tab].tab_id, pane_id) == null) {
        return;
    }

    const thread = client.ThreadView.capture(&gui.app.model, null, pane_id) orelse return;
    if (thread.focused) {
        state.update(thread);
    } else {
        state.open = false;
    }
}

/// Completion rows never take the IME target away from the composer.
/// Example: `if (try completions.route(gui, event, decision)) return true;`
pub fn route(gui: *GuiAdapter, event: event_module.Event, decision: Route) !bool {
    const state = &gui.widgets.completions;
    if (!state.open) {
        return decision.target != null and decision.target.?.action == .composer_completion;
    }
    if (event == .key and event.key.target_id != 0) {
        const id: Id = .{ .target_id = event.key.target_id, .generation = event.key.generation };
        if (decision.target == null or !decision.target.?.id.eql(id)) {
            return true;
        }
    }

    if (event == .key and decision.target != null and decision.target.?.action == .composer) {
        if (event.key.phase == .release) {
            return false;
        }

        switch (event.key.code) {
            .up, .down => {
                state.move(event.key.code == .down);
                gui.widgets.dispatcher.revision +%= 1;
                return true;
            },
            .enter, .tab => {
                if (event.key.mods.shift or event.key.mods.ctrl or event.key.mods.alt or event.key.mods.super) {
                    return false;
                }
                if (state.count == 0) {
                    return true;
                }

                try choose(gui, state.selected, event.key.code == .enter);
                if (event.key.physical) |physical| {
                    _ = gui.widgets.dispatcher.keys.acquire(physical, .discarded);
                }
                return true;
            },
            else => {},
        }
    }
    if (event == .key and event.key.code == .escape and event.key.phase != .release and decision.target != null and decision.target.?.action == .composer) {
        state.dismiss();
        restoreEditor(gui);
        gui.widgets.dispatcher.revision +%= 1;
        return true;
    }
    if (event == .pointer or event == .scroll) {
        const target = decision.target;
        const over_menu = target != null and (target.?.action == .composer_completion or target.?.action == .custom and target.?.action.custom == 0x4343);
        if (over_menu and (event == .scroll or event.pointer.kind == .scroll_up or event.pointer.kind == .scroll_down)) {
            state.move(if (event == .scroll) event.scroll.delta_y > 0 else event.pointer.kind == .scroll_down);
            gui.widgets.dispatcher.revision +%= 1;
            return true;
        }
        if (event == .pointer and target != null and target.?.action == .composer_completion) {
            if (!eligible(gui, target.?)) {
                return true;
            }
            if (event.pointer.kind == .move) {
                state.selected = target.?.action.composer_completion.index;
                gui.widgets.dispatcher.revision +%= 1;
            } else if (event.pointer.kind == .release and event.pointer.button == .left and target.?.contains(.{ event.pointer.x, event.pointer.y })) {
                try choose(gui, target.?.action.composer_completion.index, true);
            }

            return true;
        }
    }

    return false;
}

/// Example: `if (completions.eligible(gui, target)) activate();`
pub fn eligible(gui: *const GuiAdapter, target: Target) bool {
    const choice = target.action.composer_completion;
    const state = &gui.widgets.completions;
    const pane = gui.app.model.agentPane(choice.pane_id) orelse return false;
    return state.open and state.pane_id == choice.pane_id and state.generation == choice.generation and pane.attachment_generation == target.id.generation and pane.composer_revision == state.revision and choice.index < state.count;
}

/// Example: `try completions.activate(gui, target);`
pub fn activate(gui: *GuiAdapter, target: Target) !void {
    refresh(gui);
    if (eligible(gui, target)) {
        try choose(gui, target.action.composer_completion.index, true);
    }
}

fn choose(gui: *GuiAdapter, index: u8, execute: bool) !void {
    const state = &gui.widgets.completions;
    const pane_id = state.pane_id orelse return;
    const pane = gui.app.model.agentPane(pane_id) orelse return;
    if (!state.open or index >= state.count or pane.composer_revision != state.revision) {
        return;
    }

    const entry = state.entries[index];
    var buffer: [192]u8 = undefined;
    const text = switch (entry) {
        .command => |kind| try std.fmt.bufPrint(&buffer, "/{s} ", .{@tagName(kind)}),
        .skill => |skill| blk: {
            const snapshot = pane.agent_thread orelse return;
            if (snapshot.skills.revision != state.catalog_revision or skill >= snapshot.skills.count) {
                return;
            }

            break :blk try std.fmt.bufPrint(&buffer, "${s} ", .{snapshot.skills.entries[skill].name(&snapshot.skills)});
        },
    };
    _ = data.agent_panes.editComposer(&gui.app.model, 
        pane_id,
        .{
            .replace_range = .{
                .range = .{
                    state.start,
                    state.end,
                },
                .text = text,
            },
        },
    );
    state.dismiss();
    restoreEditor(gui);
    gui.widgets.dispatcher.revision +%= 1;
    if (execute and entry == .command and entry.command != .rename) {
        try submit(gui, pane_id);
    }
}

/// Executes local selectors or submits conversation commands to runtime authority.
/// Example: `try completions.submit(gui, pane_id);`
pub fn submit(gui: *GuiAdapter, pane_id: core.PaneId) !void {
    const pane = gui.app.model.agentPane(pane_id) orelse return;
    if (gui.widgets.pastingImage(pane_id)) {
        return;
    }

    if (if (pane.composerImages().count == 0) core.AgentCommand.parse(pane.composerSlice()) else null) |action| {
        if (action.argument.len == 0) {
            switch (action.kind) {
                .skills => {
                    _ = data.agent_panes.editComposer(&gui.app.model, 
                        pane_id,
                        .{
                            .replace_range = .{
                                .range = .{
                                    0,
                                    @intCast(pane.composerSlice().len),
                                },
                                .text = "$",
                            },
                        },
                    );
                    return;
                },
                .model, .permissions => {
                    const kind: @FieldType(ComposerSelector, "kind") = if (action.kind == .model) .model else .access;
                    for (gui.widgets.dispatcher.maps.presented().targets[0..gui.widgets.dispatcher.maps.presented().len]) |target| {
                        if (target.action == .composer_selector and target.action.composer_selector.pane_id == pane_id and target.action.composer_selector.kind == kind) {
                            if (!composer_menu.eligible(gui, target)) {
                                return;
                            }

                            _ = data.agent_panes.editComposer(&gui.app.model, 
                                pane_id,
                                .{
                                    .replace_range = .{
                                        .range = .{
                                            0,
                                            @intCast(pane.composerSlice().len),
                                        },
                                        .text = "",
                                    },
                                },
                            );
                            gui.widgets.completions.dismiss();
                            try composer_menu.activate(gui, target);
                            return;
                        }
                    }

                    return;
                },
                else => {},
            }
        }
    }

    try client.agent_control.submitAgentPrompt(&gui.app.model, pane_id);
}

fn restoreEditor(gui: *GuiAdapter) void {
    const pane_id = gui.widgets.completions.pane_id orelse return;
    for (gui.widgets.dispatcher.maps.presented().targets[0..gui.widgets.dispatcher.maps.presented().len]) |target| {
        if (target.action == .composer and target.action.composer == pane_id) {
            _ = gui.widgets.dispatcher.focus(target.id);
            return;
        }
    }
}
