const std = @import("std");
const Io = std.Io;
const File = std.Io.File;

const telar = @import("telar-frontend");
const ui = telar.ui;
const term = telar.term;
const pace = telar.pace;
const platform = telar.platform;
const edit = telar.edit;
const sel = telar.select;

// herdr's task sidebar, drawn without a widget framework.
//
//   zig build ui-spike
//
// Everything visible is clickable: the tabs, the search field, the `+` and
// `ctrl+k` chips, the scope dropdown, every task row, every action chip on the
// right of a task, the scrollbar, and the key hints along the bottom.
//
// The piece worth stealing is `Hits`. The previous version worked out where a
// tab was twice - once to draw it, once to decide what a click landed on - and
// those two calculations drift the moment a label changes. Here a widget
// registers the rectangle it just drew, and a click is a lookup. Position is
// computed once, by the code that owns it.
//
// The number in the pane is cells written last frame. Clicking a task redraws
// six rows, not the screen.

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------

const bg: ui.Color = .{ .rgb = .{ 0x10, 0x10, 0x10 } };
const raised: ui.Color = .{ .rgb = .{ 0x18, 0x18, 0x18 } };
const chip_bg: ui.Color = .{ .rgb = .{ 0x33, 0x33, 0x33 } };
const white: ui.Color = .{ .rgb = .{ 0xe8, 0xe8, 0xe8 } };
const fg: ui.Color = .{ .rgb = .{ 0xb0, 0xb0, 0xb0 } };
const muted: ui.Color = .{ .rgb = .{ 0x6c, 0x6c, 0x6c } };
const faint: ui.Color = .{ .rgb = .{ 0x45, 0x45, 0x45 } };
const apricot: ui.Color = .{ .rgb = .{ 0xff, 0xc7, 0x99 } };
const mint: ui.Color = .{ .rgb = .{ 0x99, 0xff, 0xe4 } };
const red: ui.Color = .{ .rgb = .{ 0xff, 0x80, 0x80 } };

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

const Section = enum {
    needs_you,
    ready,
    running,
    background,

    fn label(s: Section) []const u8 {
        return switch (s) {
            .needs_you => "NEEDS YOU",
            .ready => "READY",
            .running => "RUNNING",
            .background => "BACKGROUND",
        };
    }

    fn color(s: Section) ui.Color {
        return switch (s) {
            .needs_you, .running => apricot,
            .ready => mint,
            .background => muted,
        };
    }
};

/// The call to action on the right of a task title.
const Chip = enum {
    decide,
    debug,
    review,
    none,

    fn glyph(c: Chip) []const u8 {
        return switch (c) {
            .decide, .review => "\u{25c6}",
            .debug => "\u{2717}",
            .none => "",
        };
    }

    fn label(c: Chip) []const u8 {
        return switch (c) {
            .decide => "decide",
            .debug => "debug",
            .review => "review",
            .none => "",
        };
    }

    fn color(c: Chip) ui.Color {
        return switch (c) {
            .decide => white,
            .debug => red,
            .review => mint,
            .none => muted,
        };
    }

    /// Only the primary action gets a filled background. More than one thing
    /// shouting at once is the same as nothing shouting.
    fn filled(c: Chip) bool {
        return c == .decide;
    }
};

const Status = enum { waiting, failed, ready, working, queued };

const Origin = enum { agent, shell, host };

const Task = struct {
    title: []const u8,
    chip: Chip,
    /// Where the work is: a repository and branch, or a machine and a path.
    place: []const u8,
    place_detail: []const u8,
    origin: Origin,
    status: Status,
    status_detail: []const u8,
    /// The tool doing the work: `claude/opus`, `shell/vitest`.
    tool: []const u8,
    /// What it is saying about itself.
    note: []const u8,
    section: Section,
};

const Tab = struct { key: u8, name: []const u8, count: u16 };

const Hint = struct { key: []const u8, label: []const u8 };

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

/// What clicking somewhere means. Deliberately phrased in terms of the model
/// and not the layout: `select_task`, never `sidebar_row_4`.
const Action = union(enum) {
    focus_search,
    new_task,
    command_palette,
    select_tab: usize,
    toggle_scope,
    select_task: usize,
    run_task_action: usize,
    scroll_to_row: u16,
    hint: usize,
    /// The modal's own controls, and the click that lands anywhere else.
    dialog_choice: usize,
    dismiss_dialog,
    /// The dialog's own body. Does nothing on purpose: with a dismiss target
    /// covering the whole screen, the frame needs something registered over it
    /// or clicking the dialog closes the dialog.
    dialog_body,
};

/// Hit testing, layers included, from the core.
///
/// One hundred and twenty eight registrations is generous for a frame; past
/// that the extras are dropped rather than allocated for on the draw path.
const Hits = ui.Hits(Action, 128);

/// What can hold the keyboard.
///
/// A separate identity from `Action` because the two answer different
/// questions: an action is what a click *does*, and this is what a key press
/// is *addressed to*. Plenty of things are one and not the other - a scrollbar
/// notch is clickable and not focusable, and the search field is focusable
/// long before it is clicked.
const FocusId = union(enum) {
    search,
    tab: usize,
    scope,
    task: usize,
    dialog_button: usize,
};

const FocusReg = ui.Focus(FocusId, 64);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const State = struct {
    tasks: []const Task,
    tabs: []const Tab,
    hints: []const Hint,

    selected_tab: usize = 0,
    selected_task: usize = 0,
    hovered: ?Action = null,
    scroll: u16 = 0,
    scope_open: bool = false,
    /// The search box. Editable whenever it holds the keyboard - there is no
    /// separate "search mode", because focus already answers that question.
    search: edit.Field(256) = .init(""),
    /// Inside a bracketed paste, so a newline is text rather than Enter.
    pasting: bool = false,
    /// Which task's dialog is open, if any.
    dialog: ?usize = null,
    /// Set by an action so the footer can show what happened. A real one would
    /// open a dialog.
    flash: []const u8 = "",

    hits: Hits = .{},
    /// Opens on the list, not in the search box: a UI whose first keystroke has
    /// to be Tab before any shortcut works is a UI that feels broken.
    focus: FocusReg = .{ .initial = .{ .task = 0 } },
    /// Where the real cursor should go this frame, set by whatever is editable.
    cursor: ?term.Screen.Position = null,

    /// The drag in progress or the one just finished.
    selection: ?sel.Range = null,
    dragging: bool = false,
    clicks: sel.ClickTracker = .{},
    /// Text waiting to go to the clipboard, and how much of it there is.
    ///
    /// Handed to the loop rather than written here: `update` has no writer and
    /// keeping it that way is what makes every interaction testable.
    clipboard: [4096]u8 = undefined,
    clipboard_len: usize = 0,

    /// The buffer the last frame drew into, for reading text back out of.
    ///
    /// A selection is over what the user can see, and what they can see is the
    /// last frame. Re-deriving it from the model would copy something subtly
    /// different from what is on screen.
    last_buffer: ?*const ui.Buffer = null,

    /// Monotonic nanoseconds, set by the loop before each batch.
    ///
    /// Time as data rather than as a call. Double click is a timing fact, and a
    /// handler that reads a clock cannot be tested without one.
    now: u64 = 0,
    list_area: ui.Rect = .{},
    total_rows: u16 = 0,

    frames: u64 = 0,
    last_frame: term.Screen.Stats = .{},
    pacing: pace.Pacer.Stats = .{},
    quit: bool = false,
};

/// One line of the scrolling list.
///
/// Flattening sections and tasks into rows before drawing is what makes
/// scrolling and the scrollbar honest: the total is known up front rather than
/// discovered halfway down the screen.
const Row = union(enum) {
    section: Section,
    /// `line` is 0, 1 or 2 within the task.
    task: struct { index: usize, line: u8 },
    blank,
};

fn buildRows(state: *const State, out: []Row) u16 {
    var len: usize = 0;
    const push = struct {
        fn call(list: []Row, n: *usize, row: Row) void {
            if (n.* < list.len) {
                list[n.*] = row;
                n.* += 1;
            }
        }
    }.call;

    for ([_]Section{ .needs_you, .ready, .running, .background }) |section| {
        var seen = false;
        for (state.tasks, 0..) |task, index| {
            if (task.section != section) {
                continue;
            }
            if (!seen) {
                push(out, &len, .{ .section = section });
                seen = true;
            }
            push(out, &len, .{ .task = .{ .index = index, .line = 0 } });
            push(out, &len, .{ .task = .{ .index = index, .line = 1 } });
            push(out, &len, .{ .task = .{ .index = index, .line = 2 } });
            push(out, &len, .blank);
        }
    }
    return @intCast(len);
}

// ---------------------------------------------------------------------------
// The view
// ---------------------------------------------------------------------------

const DrawContext = struct {
    state: *State,
    buffer: *ui.Buffer,
    area: ui.Rect,
};

fn view(state: *State, buf: *ui.Buffer) void {
    state.hits.clear();
    state.focus.beginFrame();
    // Cleared every frame: a field that stops being focused must not leave the
    // hardware cursor parked where it used to be.
    state.cursor = null;
    buf.clear(.{ .bg = bg, .fg = fg });

    const full = buf.area();
    // Wide enough for the content, everything left over is the pane. On a
    // narrow terminal the sidebar simply takes it all.
    const sidebar_width: u16 = if (full.w >= 82) @min(62, full.w - 20) else full.w;
    const sidebar, const pane = full.splitLeft(sidebar_width);

    drawSidebar(state, buf, sidebar);
    if (pane.w > 4) {
        drawPane(state, buf, pane);
    }
    if (state.dialog) |index| {
        drawDialog(.{ .state = state, .buffer = buf, .area = full }, index);
    }

    // Last of all, over whatever ended up on screen. A selection is about what
    // the user can see, so it follows the pixels rather than the model - and
    // reversing rather than painting a colour keeps it legible over every
    // background the UI uses.
    if (state.selection) |range| {
        const expanded = range.expanded(buf);
        for (0..buf.h) |y| for (0..buf.w) |x| {
            if (!expanded.contains(@intCast(x), @intCast(y))) {
                continue;
            }
            if (buf.at(@intCast(x), @intCast(y))) |cell| {
                cell.style.flags.inverse = !cell.style.flags.inverse;
            }
        };
    }
    state.last_buffer = buf;

    // After everything has registered, so it can see which layer ended up on
    // top and whether what held the keyboard last frame is still on screen.
    state.focus.endFrame();
}

const dialog_choices = [_][]const u8{ "Approve", "Reject", "Open diff" };

/// A dialog, built entirely out of core primitives.
///
/// The two things that make it a dialog rather than a rectangle with words in
/// it are both one line each: a clip, so nothing it draws escapes its frame,
/// and a layer that swallows the whole screen, so the list behind it stops
/// answering clicks. Neither is something the dialog implements - it asks for
/// them.
fn drawDialog(context: DrawContext, index: usize) void {
    const state = context.state;
    const buf = context.buffer;
    const full = context.area;
    const w: u16 = @min(52, full.w -| 4);
    const h: u16 = 9;
    if (w < 24 or full.h < h + 2) {
        return;
    }

    const frame: ui.Rect = .{
        .x = full.x + (full.w - w) / 2,
        .y = full.y + (full.h -| h) / 2,
        .w = w,
        .h = h,
    };

    // Everything above the base layer. The whole screen is claimed so that a
    // click outside the frame dismisses instead of reaching the list, which is
    // the behaviour a user expects and the reason a modal cannot be built out
    // of z-order alone.
    state.hits.beginLayer(full);
    defer state.hits.endLayer();
    // The keyboard follows the same nesting. Opening this layer is the entire
    // reason the dialog gets the keys - no handler asks whether it is open.
    state.focus.beginLayer();
    defer state.focus.endLayer();
    state.hits.add(full, .dismiss_dialog);
    // Absorbs everything the frame covers, so only the controls drawn after it
    // do anything. Without this the dismiss target underneath answers for the
    // dialog's own background.
    state.hits.add(frame, .dialog_body);

    buf.pushClip(frame);
    defer buf.popClip();

    buf.fill(frame, .{ .glyph = " ", .style = .{ .bg = raised } });
    buf.box(frame, .{ .fg = apricot, .bg = raised }, null);
    _ = buf.writeText(frame, frame.x + 2, frame.y, " action ", .{ .fg = apricot, .bg = raised });

    const inside: ui.Rect = .{ .x = frame.x + 2, .y = frame.y + 2, .w = frame.w - 4, .h = frame.h - 4 };
    const task = state.tasks[index];
    _ = buf.writeTruncated(inside, inside.x, inside.y, task.title, inside.w, .{
        .fg = white,
        .bg = raised,
        .flags = .{ .bold = true },
    });
    _ = buf.writeTruncated(inside, inside.x, inside.y + 1, task.place, inside.w, .{ .fg = muted, .bg = raised });

    // The buttons, registered inside the layer so they beat the dismiss
    // rectangle underneath them.
    var x = inside.x;
    const y = frame.y + frame.h - 3;
    for (dialog_choices, 0..) |choice, choice_index| {
        const width = ui.measure(choice) + 4;
        if (x + width > inside.x + inside.w) {
            break;
        }
        const rect: ui.Rect = .{ .x = x, .y = y, .w = width, .h = 1 };
        const action: Action = .{ .dialog_choice = choice_index };
        state.focus.register(.{ .dialog_button = choice_index });
        const hot = isHovered(state, action) or state.focus.has(.{ .dialog_button = choice_index });
        state.hits.add(rect, action);

        buf.fill(rect, .{ .glyph = " ", .style = .{ .bg = if (hot) apricot else chip_bg } });
        _ = buf.writeText(rect, x + 2, y, choice, .{
            .fg = if (hot) bg else white,
            .bg = if (hot) apricot else chip_bg,
            .flags = .{ .bold = hot },
        });
        x += width + 1;
    }
}

fn drawSidebar(state: *State, buf: *ui.Buffer, area: ui.Rect) void {
    if (area.w < 30 or area.h < 14) {
        return;
    }
    buf.fill(area, .{ .glyph = " ", .style = .{ .bg = bg } });
    buf.box(area, .{ .fg = faint, .bg = bg }, null);

    // The title sits inside the top border, which is why it is drawn after the
    // box rather than by it.
    _ = buf.writeText(area, area.x + 2, area.y, " herdr ", .{ .fg = muted, .bg = bg });

    const inside: ui.Rect = .{ .x = area.x + 1, .y = area.y + 1, .w = area.w - 2, .h = area.h - 2 };

    var y = inside.y;
    y = drawSearch(.{ .state = state, .buffer = buf, .area = inside }, y);
    y = rule(buf, area, y);
    y = drawTabs(.{ .state = state, .buffer = buf, .area = inside }, y);
    y = rule(buf, area, y);
    y = drawScope(.{ .state = state, .buffer = buf, .area = inside }, y);
    y = rule(buf, area, y);

    const footer_y = area.y + area.h - 2;
    const rule_y = footer_y - 1;
    if (rule_y > y) {
        drawList(state, buf, .{ .x = inside.x, .y = y, .w = inside.w, .h = rule_y - y });
        _ = rule(buf, area, rule_y);
    }
    drawFooter(state, buf, .{ .x = inside.x, .y = footer_y, .w = inside.w, .h = 1 });
}

/// A divider that meets the border on both sides.
fn rule(buf: *ui.Buffer, area: ui.Rect, y: u16) u16 {
    const style: ui.Style = .{ .fg = faint, .bg = bg };
    var x = area.x + 1;
    while (x < area.x + area.w - 1) : (x += 1) _ = buf.writeText(area, x, y, "\u{2500}", style);
    _ = buf.writeText(area, area.x, y, "\u{251c}", style);
    _ = buf.writeText(area, area.x + area.w - 1, y, "\u{2524}", style);
    return y + 1;
}

fn drawSearch(context: DrawContext, y: u16) u16 {
    const state = context.state;
    const buf = context.buffer;
    const area = context.area;
    const row: ui.Rect = .{ .x = area.x, .y = y, .w = area.w, .h = 1 };
    // Registered before it is drawn, so the drawing can ask. `has` reads the
    // focus decided by the previous frame's `endFrame`, which is exactly the
    // state the user is looking at right now.
    state.focus.register(.search);
    const focused = state.focus.has(.search);
    buf.fill(row, .{ .glyph = " ", .style = .{ .bg = if (focused) raised else bg } });

    const field_bg: ui.Color = if (focused) raised else bg;
    var x = row.x + 1;
    x += buf.writeText(row, x, y, "/", .{ .fg = apricot, .bg = field_bg, .flags = .{ .bold = true } });
    x += buf.writeText(row, x, y, " ", .{ .bg = field_bg });
    // Chips first, so the field knows how much room is left rather than
    // guessing. They are laid out from the right edge inwards.
    var right = row.x + row.w - 1;
    right -= drawChipAt(.{ .state = state, .buffer = buf, .area = row }, .{ .right = right, .label = "+", .color = fg, .action = .new_task });
    right -= drawChipAt(.{ .state = state, .buffer = buf, .area = row }, .{ .right = right, .label = "ctrl+k", .color = muted, .action = .command_palette });

    // Registered before the early return below: the placeholder branch is the
    // common case, and skipping it there made the search box unclickable
    // exactly when nobody had clicked it yet.
    state.hits.add(.{ .x = row.x, .y = y, .w = row.w / 2, .h = 1 }, .focus_search);

    const width = right -| x;
    if (state.search.len == 0 and !focused) {
        _ = buf.writeTruncated(row, x, y, "search tasks\u{2026}", width, .{ .fg = faint, .bg = field_bg });
        return y + 1;
    }

    // The field decides what is visible and where the cursor lands; this only
    // paints it. Every column here comes from `view`, never from a byte count.
    const shown = state.search.view(width);
    _ = buf.writeText(row, x, y, shown.text, .{ .fg = white, .bg = field_bg });

    if (shown.selection) |range| {
        // Reversed rather than a fixed colour, so the selection reads the same
        // against whatever the field's background happens to be.
        var column = x + range[0];
        while (column < x + range[1] and column < right) : (column += 1) {
            if (buf.at(column, y)) |cell| {
                cell.style.flags.inverse = true;
            }
        }
    }

    // Ellipses for text scrolled out of sight. Without them a value longer than
    // the field looks like a value that was truncated on the way in.
    if (shown.clipped_left) {
        _ = buf.writeText(row, x, y, "\u{2039}", .{ .fg = faint, .bg = field_bg });
    }
    if (shown.clipped_right and right > x) {
        _ = buf.writeText(row, right - 1, y, "\u{203a}", .{ .fg = faint, .bg = field_bg });
    }

    // The terminal's own cursor, not a painted block: it is what a screen
    // reader follows and what an input method composes against, and it blinks
    // without us doing anything.
    if (focused) {
        state.cursor = .{ .x = x + shown.cursor, .y = y };
    }

    return y + 1;
}

/// A bordered chip whose right edge is at `right`. Returns the columns it and
/// its trailing gap consumed.
const ChipDraw = struct {
    right: u16,
    label: []const u8,
    color: ui.Color,
    action: Action,
};

fn drawChipAt(context: DrawContext, chip: ChipDraw) u16 {
    const state = context.state;
    const buf = context.buffer;
    const area = context.area;
    const width = ui.measure(chip.label) + 2;
    if (chip.right < area.x + width) {
        return 0;
    }
    const x = chip.right - width;

    const hovered = isHovered(state, chip.action);
    const fill: ui.Color = if (hovered) chip_bg else bg;

    _ = buf.writeText(area, x, area.y, "[", .{ .fg = faint, .bg = fill });
    _ = buf.writeText(area, x + 1, area.y, chip.label, .{ .fg = chip.color, .bg = fill });
    _ = buf.writeText(area, x + width - 1, area.y, "]", .{ .fg = faint, .bg = fill });

    state.hits.add(.{ .x = x, .y = area.y, .w = width, .h = 1 }, chip.action);
    return width + 1;
}

fn drawTabs(context: DrawContext, y: u16) u16 {
    const state = context.state;
    const buf = context.buffer;
    const area = context.area;
    const row: ui.Rect = .{ .x = area.x, .y = y, .w = area.w, .h = 1 };
    const underline: ui.Rect = .{ .x = area.x, .y = y + 1, .w = area.w, .h = 1 };
    buf.fill(row, .{ .glyph = " ", .style = .{ .bg = bg } });
    buf.fill(underline, .{ .glyph = " ", .style = .{ .bg = bg } });

    var x = row.x + 1;
    for (state.tabs, 0..) |tab, index| {
        const active = index == state.selected_tab;
        const hovered = isHovered(state, .{ .select_tab = index });
        const color: ui.Color = if (active) white else if (hovered) fg else muted;
        const start = x;

        var key_buf: [8]u8 = undefined;
        const key_text = std.fmt.bufPrint(&key_buf, "[{d}]", .{tab.key}) catch "[?]";
        x += buf.writeText(row, x, y, key_text, .{ .fg = color, .bg = bg, .flags = .{ .bold = active } });
        x += buf.writeText(row, x, y, " ", .{ .bg = bg });
        x += buf.writeText(row, x, y, tab.name, .{ .fg = color, .bg = bg, .flags = .{ .bold = active } });
        x += buf.writeText(row, x, y, " ", .{ .bg = bg });

        var count_buf: [8]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{tab.count}) catch "";
        x += buf.writeText(row, x, y, count_text, .{
            .fg = if (active) apricot else faint,
            .bg = bg,
        });

        if (active) {
            var u = start;
            while (u < x) : (u += 1) _ = buf.writeText(underline, u, y + 1, "\u{2501}", .{ .fg = apricot, .bg = bg });
        }

        // Two rows tall, so the underline is part of the target.
        state.hits.add(.{ .x = start, .y = y, .w = x - start, .h = 2 }, .{ .select_tab = index });
        state.focus.register(.{ .tab = index });
        x += 2;
    }
    return y + 2;
}

fn drawScope(context: DrawContext, y: u16) u16 {
    const state = context.state;
    const buf = context.buffer;
    const area = context.area;
    const row: ui.Rect = .{ .x = area.x, .y = y, .w = area.w, .h = 1 };
    const hovered = isHovered(state, .toggle_scope);
    const row_bg: ui.Color = if (hovered) raised else bg;
    buf.fill(row, .{ .glyph = " ", .style = .{ .bg = row_bg } });

    var x = row.x + 1;
    x += buf.writeText(row, x, y, if (state.scope_open) "\u{25b4}" else "\u{25be}", .{ .fg = muted, .bg = row_bg });
    x += buf.writeText(row, x, y, " ", .{ .bg = row_bg });
    _ = buf.writeText(row, x, y, "all scopes", .{ .fg = fg, .bg = row_bg });

    var count_buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&count_buf, "{d} tasks ", .{state.tasks.len}) catch "";
    _ = buf.writeRight(row, y, text, .{ .fg = muted, .bg = row_bg });

    state.hits.add(row, .toggle_scope);
    state.focus.register(.scope);
    return y + 1;
}

fn drawList(state: *State, buf: *ui.Buffer, area: ui.Rect) void {
    buf.fill(area, .{ .glyph = " ", .style = .{ .bg = bg } });
    state.list_area = area;

    var rows: [256]Row = undefined;
    const total = buildRows(state, &rows);
    state.total_rows = total;

    // The scrollbar owns the last column, so the content is one narrower.
    const content: ui.Rect = .{ .x = area.x, .y = area.y, .w = area.w -| 1, .h = area.h };

    var line: u16 = 0;
    while (line < area.h) : (line += 1) {
        const index = state.scroll + line;
        if (index >= total) {
            break;
        }
        const y = area.y + line;
        switch (rows[index]) {
            .blank => {},
            .section => |section| drawSectionHeader(.{ .state = state, .buffer = buf, .area = content }, y, section),
            .task => |t| drawTaskLine(.{ .state = state, .buffer = buf, .area = content }, .{ .y = y, .index = t.index, .line = t.line }),
        }
    }

    drawScrollbar(.{ .state = state, .buffer = buf, .area = .{ .x = area.x + area.w - 1, .y = area.y, .w = 1, .h = area.h } }, total);
}

fn drawSectionHeader(context: DrawContext, y: u16, section: Section) void {
    const state = context.state;
    const buf = context.buffer;
    const area = context.area;
    const row: ui.Rect = .{ .x = area.x, .y = y, .w = area.w, .h = 1 };

    var x = row.x + 1;
    x += buf.writeText(row, x, y, section.label(), .{ .fg = section.color(), .bg = bg, .flags = .{ .bold = true } });
    x += 1;

    var count: u16 = 0;
    for (state.tasks) |task| {
        if (task.section == section) {
            count += 1;
        }
    }
    var count_buf: [8]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{count}) catch "";

    // The rule runs from the end of the label to just before the count.
    const rule_end = row.x + row.w -| ui.measure(count_text) -| 2;
    while (x < rule_end) : (x += 1) _ = buf.writeText(row, x, y, "\u{2500}", .{ .fg = faint, .bg = bg });

    _ = buf.writeRight(.{ .x = row.x, .y = y, .w = row.w -| 1, .h = 1 }, y, count_text, .{
        .fg = muted,
        .bg = bg,
    });
}

const TaskLine = struct {
    y: u16,
    index: usize,
    line: u8,
};

fn drawTaskLine(context: DrawContext, position: TaskLine) void {
    const state = context.state;
    const buf = context.buffer;
    const area = context.area;
    const y = position.y;
    const index = position.index;
    const line = position.line;
    const task = state.tasks[index];
    const selected = index == state.selected_task;
    const hovered = isHovered(state, .{ .select_task = index }) or isHovered(state, .{ .run_task_action = index });
    const row_bg: ui.Color = if (selected)
        .{ .rgb = .{ 0x1e, 0x1e, 0x1e } }
    else if (hovered)
        raised
    else
        bg;

    const row: ui.Rect = .{ .x = area.x, .y = y, .w = area.w, .h = 1 };
    buf.fill(row, .{ .glyph = " ", .style = .{ .bg = row_bg } });

    // The selection marker is a bar in the gutter rather than a reversed row:
    // reversing would fight every colour the row is trying to use.
    //
    // Focus is drawn as a *different* bar, because it is a different fact. A
    // row can be selected while a dialog holds the keyboard, and a UI that
    // draws one marker for both tells the user the keys will go somewhere they
    // will not.
    if (selected) {
        const has_keys = state.focus.has(.{ .task = index });
        _ = buf.writeText(row, row.x, y, if (has_keys) "\u{2503}" else "\u{2502}", .{
            .fg = if (has_keys) apricot else faint,
            .bg = row_bg,
        });
    }

    const body: ui.Rect = .{ .x = row.x + 2, .y = y, .w = row.w -| 3, .h = 1 };
    if (body.w == 0) {
        return;
    }

    switch (line) {
        0 => {
            // The chip is placed first so the title knows what room is left.
            const chip_width = if (task.chip == .none) 0 else drawTaskChip(.{ .state = state, .buffer = buf, .area = body }, index, task.chip);
            _ = buf.writeTruncated(body, body.x, y, task.title, body.w -| chip_width -| 1, .{
                .fg = white,
                .bg = row_bg,
                .flags = .{ .bold = true },
            });
        },
        1 => {
            const icon: []const u8 = if (task.origin == .host) "\u{2302}" else "\u{2387}";
            var x = body.x;
            x += buf.writeText(body, x, y, icon, .{ .fg = faint, .bg = row_bg });
            x += buf.writeText(body, x, y, " ", .{ .bg = row_bg });
            x += buf.writeText(body, x, y, task.place, .{ .fg = muted, .bg = row_bg });
            x += buf.writeText(body, x, y, " \u{00b7} ", .{ .fg = faint, .bg = row_bg });

            const status_width = drawStatus(buf, .{ .area = body, .y = y, .task = task, .background = row_bg });
            _ = buf.writeTruncated(body, x, y, task.place_detail, body.x + body.w -| x -| status_width -| 1, .{
                .fg = muted,
                .bg = row_bg,
            });
        },
        else => {
            const agent = task.origin == .agent;
            var x = body.x;
            x += buf.writeText(body, x, y, if (agent) "\u{2733}" else "$", .{
                .fg = if (agent) apricot else muted,
                .bg = row_bg,
            });
            x += buf.writeText(body, x, y, " ", .{ .bg = row_bg });
            x += buf.writeText(body, x, y, task.tool, .{
                .fg = if (agent) apricot else fg,
                .bg = row_bg,
            });
            x += buf.writeText(body, x, y, " \u{00b7} ", .{ .fg = faint, .bg = row_bg });
            _ = buf.writeTruncated(body, x, y, task.note, body.x + body.w -| x, .{ .fg = faint, .bg = row_bg });
        },
    }

    state.hits.add(row, .{ .select_task = index });
    // Once per task, not once per line: a task occupies four rows and
    // registering each of them would make Tab visit the same task four times.
    if (line == 0) {
        state.focus.register(.{ .task = index });
    }
    // Registered after the row, so the chip drawn on line 0 wins the overlap.
    if (line == 0 and task.chip != .none) {
        const width = chipWidth(task.chip);
        if (width <= body.w) {
            state.hits.add(
                .{ .x = body.x + body.w - width, .y = y, .w = width, .h = 1 },
                .{ .run_task_action = index },
            );
        }
    }
}

fn chipWidth(chip: Chip) u16 {
    return ui.measure(chip.glyph()) + 1 + ui.measure(chip.label()) + 2;
}

fn drawTaskChip(context: DrawContext, index: usize, chip: Chip) u16 {
    const state = context.state;
    const buf = context.buffer;
    const area = context.area;
    const width = chipWidth(chip);
    if (width > area.w) {
        return 0;
    }

    const x = area.x + area.w - width;
    const hovered = isHovered(state, .{ .run_task_action = index });
    const fill: ui.Color = if (chip.filled() or hovered) chip_bg else bg;

    const rect: ui.Rect = .{ .x = x, .y = area.y, .w = width, .h = 1 };
    buf.fill(rect, .{ .glyph = " ", .style = .{ .bg = fill } });

    var cursor = x + 1;
    cursor += buf.writeText(rect, cursor, area.y, chip.glyph(), .{
        .fg = if (chip.filled()) apricot else chip.color(),
        .bg = fill,
    });
    cursor += buf.writeText(rect, cursor, area.y, " ", .{ .bg = fill });
    _ = buf.writeText(rect, cursor, area.y, chip.label(), .{
        .fg = chip.color(),
        .bg = fill,
        .flags = .{ .bold = hovered },
    });
    return width;
}

const StatusDraw = struct {
    area: ui.Rect,
    y: u16,
    task: Task,
    background: ui.Color,
};

fn drawStatus(buf: *ui.Buffer, draw: StatusDraw) u16 {
    const area = draw.area;
    const y = draw.y;
    const task = draw.task;
    const row_bg = draw.background;
    const word: []const u8 = switch (task.status) {
        .waiting => "waiting",
        .failed => "failed",
        .ready => "ready",
        .working => "working",
        .queued => "queued",
    };
    const color: ui.Color = switch (task.status) {
        .waiting, .working => apricot,
        .failed => red,
        .ready => mint,
        .queued => muted,
    };

    const prefix: u16 = if (task.status == .working) 2 else 0;
    const detail: u16 = if (task.status_detail.len == 0) 0 else ui.measure(task.status_detail) + 3;
    const width = prefix + ui.measure(word) + detail + 1;
    if (width > area.w) {
        return 0;
    }

    var x = area.x + area.w - width;
    if (task.status == .working) {
        x += buf.writeText(area, x, y, "\u{2237} ", .{ .fg = color, .bg = row_bg });
    }
    x += buf.writeText(area, x, y, word, .{ .fg = color, .bg = row_bg, .flags = .{ .bold = true } });
    if (task.status_detail.len > 0) {
        x += buf.writeText(area, x, y, " \u{00b7} ", .{ .fg = faint, .bg = row_bg });
        _ = buf.writeText(area, x, y, task.status_detail, .{
            .fg = if (task.status == .failed) red else muted,
            .bg = row_bg,
        });
    }
    return width;
}

fn drawScrollbar(context: DrawContext, total: u16) void {
    const state = context.state;
    const buf = context.buffer;
    const area = context.area;
    if (total <= area.h or area.h == 0) {
        return;
    }

    // Thumb size is proportional to how much is visible, with a floor of one
    // row so a very long list still leaves something to grab.
    const thumb = @max(1, area.h * area.h / total);
    const travel = area.h - thumb;
    const max_scroll = total - area.h;
    const offset: u16 = if (max_scroll == 0) 0 else @intCast(@as(u32, state.scroll) * travel / max_scroll);

    var line: u16 = 0;
    while (line < area.h) : (line += 1) {
        const on_thumb = line >= offset and line < offset + thumb;
        _ = buf.writeText(area, area.x, area.y + line, if (on_thumb) "\u{2588}" else "\u{2502}", .{
            .fg = if (on_thumb) muted else faint,
            .bg = bg,
        });
        // Clicking anywhere on the track jumps there, which is what a mouse
        // user expects and costs one registration per row.
        const target: u16 = @intCast(@as(u32, line) * max_scroll / area.h);
        state.hits.add(.{ .x = area.x, .y = area.y + line, .w = 1, .h = 1 }, .{ .scroll_to_row = target });
    }
}

fn drawFooter(state: *State, buf: *ui.Buffer, area: ui.Rect) void {
    buf.fill(area, .{ .glyph = " ", .style = .{ .bg = bg } });

    if (state.flash.len > 0) {
        _ = buf.writeTruncated(area, area.x + 1, area.y, state.flash, area.w -| 4, .{
            .fg = mint,
            .bg = bg,
            .flags = .{ .bold = true },
        });
    } else {
        var x = area.x + 1;
        for (state.hints, 0..) |hint, index| {
            const hovered = isHovered(state, .{ .hint = index });
            const start = x;
            x += buf.writeText(area, x, area.y, hint.key, .{ .fg = apricot, .bg = bg, .flags = .{ .bold = true } });
            x += buf.writeText(area, x, area.y, " ", .{ .bg = bg });
            x += buf.writeText(area, x, area.y, hint.label, .{
                .fg = if (hovered) white else muted,
                .bg = bg,
            });
            state.hits.add(.{ .x = start, .y = area.y, .w = x - start, .h = 1 }, .{ .hint = index });
            x += 2;
        }
    }
    _ = buf.writeRight(.{ .x = area.x, .y = area.y, .w = area.w -| 1, .h = 1 }, area.y, "^g", .{
        .fg = faint,
        .bg = bg,
    });
}

fn drawPane(state: *const State, buf: *ui.Buffer, area: ui.Rect) void {
    buf.fill(area, .{ .glyph = " ", .style = .{ .bg = bg } });
    const inner = area.inner(2);
    if (inner.w == 0 or inner.h == 0) {
        return;
    }

    const task = state.tasks[state.selected_task];
    var y = inner.y;
    _ = buf.writeTruncated(inner, inner.x, y, task.title, inner.w, .{ .fg = white, .bg = bg, .flags = .{ .bold = true } });
    y += 2;

    const lines = [_][]const u8{
        "A pane is a vt.Terminal screen; drawing it is a copy,",
        "one cell of theirs into one cell of ours.",
        "",
        "Click a tab, a task, an action chip, the scope row,",
        "the scrollbar, or a key hint along the bottom.",
        "",
        "Each of those registered its own rectangle while it",
        "drew. Nothing works out a position twice.",
    };
    for (lines) |line| {
        if (y >= inner.y + inner.h) {
            break;
        }
        _ = buf.writeTruncated(inner, inner.x, y, line, inner.w, .{ .fg = muted, .bg = bg });
        y += 1;
    }

    var stats: [128]u8 = undefined;
    // `absorbed` is events that rode along on someone else's frame and
    // `dropped` is events a newer one made redundant. Both are frames that a
    // redraw-per-event loop would have drawn and this one did not.
    const text = std.fmt.bufPrint(
        &stats,
        "frame {d}  \u{00b7}  {d} cells  \u{00b7}  {d} bytes  \u{00b7}  {d} absorbed  \u{00b7}  {d} dropped",
        .{
            state.frames,
            state.last_frame.cells,
            state.last_frame.bytes,
            state.pacing.absorbed,
            state.pacing.dropped,
        },
    ) catch "";
    if (area.h >= 3) {
        _ = buf.writeTruncated(inner, inner.x, area.y + area.h - 2, text, inner.w, .{ .fg = faint, .bg = bg });
    }
}

fn isHovered(state: *const State, action: Action) bool {
    const hovered = state.hovered orelse return false;
    return std.meta.eql(hovered, action);
}

// ---------------------------------------------------------------------------
// Update
// ---------------------------------------------------------------------------

fn apply(state: *State, action: Action) void {
    state.flash = "";
    // A click moves the keyboard. Leaving focus behind is how a user clicks a
    // row, presses Enter, and watches a different row run.
    switch (action) {
        .focus_search => state.focus.set(.search),
        .toggle_scope => state.focus.set(.scope),
        .select_tab => |index| state.focus.set(.{ .tab = index }),
        .select_task, .run_task_action => |index| state.focus.set(.{ .task = index }),
        .dialog_choice => |index| state.focus.set(.{ .dialog_button = index }),
        else => {},
    }
    switch (action) {
        .focus_search => {},
        .new_task => state.flash = "new task\u{2026}",
        .command_palette => state.flash = "command palette\u{2026}",
        .select_tab => |index| state.selected_tab = index,
        .toggle_scope => state.scope_open = !state.scope_open,
        .select_task => |index| state.selected_task = index,
        .run_task_action => |index| {
            state.selected_task = index;
            state.dialog = index;
        },
        .dialog_choice => |index| {
            state.flash = dialog_choices[index];
            state.dialog = null;
        },
        .dismiss_dialog => state.dialog = null,
        .dialog_body => {},
        .scroll_to_row => |row| state.scroll = row,
        .hint => |index| state.flash = state.hints[index].label,
    }
}

fn update(state: *State, event: term.Event) void {
    switch (event) {
        .incomplete => {},
        .terminal_response => {},
        .paste_start => state.pasting = true,
        .paste_end => state.pasting = false,
        .key => |key| handleKey(state, key),
        .mouse => |mouse| {
            state.hovered = state.hits.at(mouse.x, mouse.y);
            if (handleSelection(state, mouse)) {
                return;
            }
            switch (mouse.kind) {
                .press => if (state.hits.at(mouse.x, mouse.y)) |action| apply(state, action),
                // Scrolling is aimed by the pointer, not by the keyboard, so
                // it reaches the list even while a dialog holds focus - but
                // not while one covers the list, because the layer swallows it.
                .scroll_down => if (state.hits.at(mouse.x, mouse.y) != null or state.dialog == null) scrollBy(state, 3),
                .scroll_up => if (state.hits.at(mouse.x, mouse.y) != null or state.dialog == null) scrollBy(state, -3),
                else => {},
            }
        },
    }
}

/// Turns a drag into a selection, and a release into a copy.
///
/// Returns whether the event was a selection gesture, in which case it is not
/// also a click on whatever was underneath. That is the crux: a press is
/// ambiguous until it either moves or does not, so a press over a control acts
/// on the control and a press over inert text starts a drag.
///
/// The whole feature exists because we took something away. Asking the terminal
/// for mouse reporting stops it interpreting a drag as selection, so a user who
/// could always drag to copy suddenly cannot, and learns to hold Shift to
/// bypass a program that broke it.
fn handleSelection(state: *State, mouse: term.Event.Mouse) bool {
    const at: sel.Point = .{ .x = mouse.x, .y = mouse.y };

    switch (mouse.kind) {
        .press => {
            const granularity = state.clicks.press(at, state.now);
            // A single click on a control belongs to the control. A double or
            // triple click is unambiguously a selection gesture, even over one.
            if (granularity == .character and state.hits.at(mouse.x, mouse.y) != null) {
                state.selection = null;
                return false;
            }
            state.dragging = true;
            state.selection = .{ .anchor = at, .head = at, .granularity = granularity };
            // A word or line selection is complete the moment it is made;
            // nobody drags before releasing a double click.
            if (granularity != .character) {
                copySelection(state);
            }
            return true;
        },
        .drag => {
            if (!state.dragging) {
                return false;
            }
            if (state.selection) |*range| {
                range.head = at;
            }
            return true;
        },
        .release => {
            if (!state.dragging) {
                return false;
            }
            state.dragging = false;
            copySelection(state);
            return true;
        },
        else => return false,
    }
}

/// Renders the selection to text and parks it for the loop to send.
fn copySelection(state: *State) void {
    state.clipboard_len = 0;
    const range = state.selection orelse return;
    if (range.isEmpty()) {
        state.selection = null;
        return;
    }
    // The buffer the last frame drew is what the user is looking at and what
    // they think they selected.
    const source = state.last_buffer orelse return;
    const copied = sel.text(source, range.expanded(source), &state.clipboard);
    state.clipboard_len = copied.len;
    if (copied.len > 0) {
        state.flash = "copied";
    }
}

/// Routes a key by asking who has the keyboard.
///
/// The version this replaced tested `state.dialog != null` at the top of six
/// branches. That works for one overlay; the second one turns every branch
/// into a chain that has to be repeated identically, and the first branch
/// anybody forgets becomes a key that does something invisible.
///
/// Here the only question is what is focused, and nothing in this function
/// knows a dialog exists.
fn handleKey(state: *State, key: term.Event.Key) void {
    // A paste is text by definition, so it goes to whatever is editable and
    // nothing else looks at it. This is the check that stops three pasted lines
    // becoming three commands.
    if (state.pasting) {
        if (state.focus.has(.search)) {
            pasteInto(state, key);
        }
        return;
    }

    switch (key.code) {
        .tab => return state.focus.next(),
        .back_tab => return state.focus.prev(),
        .escape => {
            if (state.dialog != null) {
                state.dialog = null;
            } else if (state.focus.has(.search) and state.search.len > 0) {
                state.search.setText("");
            } else {
                state.flash = "";
            }
            return;
        },
        else => {},
    }
    if (key.isCtrl('c')) {
        state.quit = true;
        return;
    }

    switch (state.focus.focused() orelse .search) {
        .dialog_button => |index| dialogKey(state, key, index),
        .task => |index| taskKey(state, key, index),
        .tab => |index| tabKey(state, key, index),
        .search => searchKey(state, key),
        .scope => chromeKey(state, key),
    }
}

/// The search box, which is the only thing here that owns its keys outright.
///
/// A focused field has to be greedy: every printable character belongs to it,
/// and so do the arrows, Home, End and Backspace. The bindings that are global
/// everywhere else - "q" to quit, a digit to switch tab - would otherwise make
/// it impossible to search for a task called "q1".
fn searchKey(state: *State, key: term.Event.Key) void {
    const field = &state.search;
    const extend = key.mods.shift;

    if (key.isCtrl('a')) {
        return field.selectAll();
    }
    if (key.isCtrl('u')) {
        return field.setText("");
    }

    switch (key.code) {
        .char => |c| {
            if (key.mods.ctrl) {
                return;
            }
            field.insert(c.slice());
        },
        .backspace => field.backspace(),
        .delete => field.delete(),
        .left => if (key.mods.ctrl or key.mods.alt) field.moveWordLeft(extend) else field.moveLeft(extend),
        .right => if (key.mods.ctrl or key.mods.alt) field.moveWordRight(extend) else field.moveRight(extend),
        .home => field.home(extend),
        .end => field.end(extend),
        // Leaving the field is how you get back to the list without a mouse.
        .down, .enter => {
            state.focus.next();
            state.flash = if (field.len > 0) "search\u{2026}" else "";
        },
        .up => state.focus.prev(),
        else => {},
    }
}

fn pasteInto(state: *State, key: term.Event.Key) void {
    switch (key.code) {
        .char => |c| state.search.insert(c.slice()),
        // A newline in a *paste* is a character, and this field is one line, so
        // it becomes a space rather than either a command or a lost line break.
        .enter => state.search.insert(" "),
        .tab => state.search.insert("\t"),
        else => {},
    }
}

fn dialogKey(state: *State, key: term.Event.Key, index: usize) void {
    switch (key.code) {
        .enter => apply(state, .{ .dialog_choice = index }),
        .left, .up => state.focus.prev(),
        .right, .down => state.focus.next(),
        .char => |c| {
            // First letter activates, the way a dialog has behaved since CUA.
            for (dialog_choices, 0..) |choice, choice_index| {
                if (c.len == 1 and std.ascii.toLower(c.bytes[0]) == std.ascii.toLower(choice[0])) {
                    apply(state, .{ .dialog_choice = choice_index });
                    return;
                }
            }
        },
        else => {},
    }
}

fn taskKey(state: *State, key: term.Event.Key, index: usize) void {
    switch (key.code) {
        .enter => apply(state, .{ .run_task_action = index }),
        .up => moveFocusedTask(state, -1),
        .down => moveFocusedTask(state, 1),
        .left, .right => switchTab(state, key),
        .char => |c| globalChar(state, c),
        else => {},
    }
}

fn tabKey(state: *State, key: term.Event.Key, index: usize) void {
    switch (key.code) {
        .enter => apply(state, .{ .select_tab = index }),
        .left, .right => switchTab(state, key),
        .char => |c| globalChar(state, c),
        else => {},
    }
}

fn chromeKey(state: *State, key: term.Event.Key) void {
    switch (key.code) {
        .enter => apply(state, .toggle_scope),
        .up => moveFocusedTask(state, -1),
        .down => moveFocusedTask(state, 1),
        .left, .right => switchTab(state, key),
        .char => |c| globalChar(state, c),
        else => {},
    }
}

fn switchTab(state: *State, key: term.Event.Key) void {
    if (key.code == .left) {
        state.selected_tab -|= 1;
    } else {
        state.selected_tab = @min(state.selected_tab + 1, state.tabs.len - 1);
    }
}

/// Moves the selection and takes the keyboard with it.
///
/// Selection and focus were separate ideas until this function: the arrows
/// moved a highlight while the keyboard stayed where it was, so Enter ran the
/// action of a task the user was no longer looking at.
fn moveFocusedTask(state: *State, delta: i8) void {
    moveSelection(state, delta);
    state.focus.set(.{ .task = state.selected_task });
}

fn globalChar(state: *State, c: term.Event.Char) void {
    if (c.eql("q")) {
        state.quit = true;
        return;
    }
    for (state.tabs, 0..) |tab, index| {
        if (c.len == 1 and c.bytes[0] == '0' + tab.key) {
            state.selected_tab = index;
        }
    }
    for (state.hints, 0..) |hint, index| {
        if (c.eql(hint.key)) {
            apply(state, .{ .hint = index });
        }
    }
}

fn moveSelection(state: *State, delta: i8) void {
    if (delta < 0) {
        state.selected_task -|= 1;
    } else {
        state.selected_task = @min(state.selected_task + 1, state.tasks.len - 1);
    }
    // Keep the selection on screen. Four rows per task plus a header per
    // section, approximated rather than measured; the list is short and a
    // spike does not need to be exact about it.
    const approximate: u16 = @as(u16, @intCast(state.selected_task)) * 4;
    if (approximate < state.scroll) {
        state.scroll = approximate;
    }
    if (state.list_area.h > 0 and approximate + 4 > state.scroll + state.list_area.h) {
        state.scroll = approximate + 4 -| state.list_area.h;
    }
}

fn scrollBy(state: *State, delta: i8) void {
    const max_scroll = state.total_rows -| state.list_area.h;
    if (delta < 0) {
        state.scroll -|= @intCast(-delta);
    } else {
        state.scroll = @min(state.scroll + @as(u16, @intCast(delta)), max_scroll);
    }
}

// ---------------------------------------------------------------------------
// Running it
// ---------------------------------------------------------------------------

const Message = union(enum) {
    input: term.Event,
    resize,

    /// Which messages a later one makes redundant.
    ///
    /// Returning null means "must be delivered". That is the answer for every
    /// key and every button, because the information in one is not contained
    /// in the next: dropping a superseded keystroke is a swallowed character.
    /// Motion and resize are the opposite - they report a position, and the
    /// newest report is the whole truth.
    fn coalesceKey(m: Message) ?u32 {
        return switch (m) {
            .resize => 1,
            .input => |event| switch (event) {
                .mouse => |mouse| switch (mouse.kind) {
                    // Hover depends on where the pointer is, not on the path
                    // it took to get there. A drag across a pane is one
                    // hundred reports of a position that is already stale.
                    .move, .drag => 2,
                    // A click is an event, not a position.
                    .press, .release, .scroll_up, .scroll_down => null,
                },
                // Paste brackets must never be folded away: dropping a
                // `paste_end` leaves the field swallowing every key that
                // follows, and dropping a `paste_start` turns a pasted newline
                // back into Enter.
                .key, .terminal_response, .incomplete, .paste_start, .paste_end => null,
            },
        };
    }
};

fn inputActor(io: Io, queue: *Io.Queue(Message)) Io.Cancelable!void {
    // The buffering lives in `term` because getting it wrong is silent: the
    // version this replaced took whatever fit and discarded the rest of the
    // read, so a keystroke arriving while the mouse was moving simply never
    // happened. See `term.Input`.
    var input: term.Input(1024) = .{};
    const stdin = File.stdin();

    while (true) {
        var chunk: [512]u8 = undefined;
        // `readStreaming` rather than a buffered `Io.Reader`: a terminal is a
        // character device with no length and no seek, and the reader
        // abstraction wants both.
        const n = stdin.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return,
        };
        if (n == 0) {
            return;
        }

        var offset: usize = 0;
        while (offset < n) {
            offset += input.push(chunk[offset..n]);
            while (input.next()) |event| {
                queue.putOne(io, .{ .input = event }) catch |err| switch (err) {
                    error.Canceled => |e| return e,
                    error.Closed => return,
                };
            }
        }
    }
}

/// Turns resizes into messages.
///
/// The waiting is the platform's problem - a signal on Unix, a timer on
/// Windows - and this side of it is the same either way.
fn resizeActor(io: Io, watcher: *platform.ResizeWatcher, queue: *Io.Queue(Message)) Io.Cancelable!void {
    while (true) {
        try watcher.wait(io);
        queue.putOne(io, .resize) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.Closed => return,
        };
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var tty = platform.Tty.open() catch |err| {
        std.debug.print("this needs a terminal: {s}\n", .{@errorName(err)});
        return err;
    };
    defer tty.deinit();

    var out_buf: [512 * 1024]u8 = undefined;
    var out = File.stdout().writer(io, &out_buf);
    const w = &out.interface;

    try w.writeAll(platform.enter_sequence);
    try w.flush();
    defer {
        w.writeAll(platform.leave_sequence) catch {};
        w.flush() catch {};
    }

    const start_size = tty.size();
    var screen = try term.Screen.init(gpa, start_size.cols, start_size.rows);
    defer screen.deinit();

    var state = demoState();

    var watcher = try platform.ResizeWatcher.init(&tty);
    defer watcher.deinit();

    var queue_buf: [64]Message = undefined;
    var queue: Io.Queue(Message) = .init(&queue_buf);

    var tasks: Io.Group = .init;
    defer tasks.cancel(io);
    try tasks.concurrent(io, inputActor, .{ io, &queue });
    try tasks.concurrent(io, resizeActor, .{ io, &watcher, &queue });

    var pacer: pace.Pacer = .{};
    var batch: [64]Message = undefined;

    // Drawn twice before the first flush, and the second one is not waste.
    //
    // Focus is decided by `endFrame`, after everything has registered, so the
    // very first pass draws with no focus at all - no ring, no cursor. Frames
    // only happen on events, so that state would persist on screen until the
    // user pressed something, and an opening screen that looks inert is worse
    // than one extra pass through a pure function.
    view(&state, screen.buffer());
    view(&state, screen.buffer());
    screen.cursor = state.cursor;
    state.last_frame = try screen.flush(w);
    state.frames += 1;
    pacer.record(monotonic(io), null, 1);

    while (!state.quit) {
        // Blocks for the first message and returns everything queued behind
        // it in the same call. One syscall's worth of events, not one event.
        var n = queue.get(io, &batch, 1) catch break;
        var absorbed: usize = 0;
        var scheduled_deadline: ?u64 = null;

        // Keep folding and applying until the frame budget opens up. Messages
        // that arrive during the wait join this frame instead of earning one
        // of their own, which is the entire point.
        while (true) {
            const before = n;
            n = pace.coalesce(Message, batch[0..n], Message.coalesceKey);
            pacer.noteDropped(before - n);
            absorbed += n;

            state.now = monotonic(io);
            for (batch[0..n]) |message| switch (message) {
                .input => |event| update(&state, event),
                .resize => {
                    const now = tty.size();
                    try screen.resize(now.cols, now.rows);
                    // The emulator has no idea the destination moved, so the
                    // next frame cannot rely on dirty flags.
                    screen.invalidate();
                },
            };

            // Checked before sleeping, not after: a user who pressed quit
            // should not wait out a frame budget to see the shell again.
            if (state.quit) {
                break;
            }

            const deadline = pacer.waitUntil(monotonic(io)) orelse break;
            pacer.noteThrottled();
            scheduled_deadline = deadline;
            const timestamp = Io.Timestamp.fromNanoseconds(@intCast(deadline)).withClock(.awake);
            timestamp.wait(io) catch break;

            // Whatever arrived while we waited. `min` zero so this never
            // blocks - an empty queue after the wait means draw now.
            n = queue.get(io, &batch, 0) catch break;
            if (n == 0) {
                break;
            }
        }
        if (state.quit) {
            break;
        }

        state.pacing = pacer.stats;
        view(&state, screen.buffer());
        // Whatever drew a field this frame decided where the hardware cursor
        // belongs; nothing else in the loop knows a field exists.
        screen.cursor = state.cursor;
        try sendClipboard(&state, w);
        state.last_frame = try screen.flush(w);
        state.frames += 1;
        pacer.record(monotonic(io), scheduled_deadline, absorbed);
    }

    // On stderr and after the alternate screen is gone, so it lands in the
    // shell rather than in a frame. The ratio of events to frames is the only
    // number that says whether the pacing did anything.
    std.debug.print(
        "frames={d} absorbed={d} dropped={d} throttled={d}\n",
        .{ pacer.stats.drawn, pacer.stats.absorbed, pacer.stats.dropped, pacer.stats.throttled },
    );
}

/// Sends whatever the last interaction put on the clipboard.
///
/// In the loop and not in `update` for two reasons: the handlers stay free of a
/// writer, which is what makes every one of them testable without a terminal;
/// and the sequence lands next to the frame it belongs to rather than
/// interleaved with the diff.
fn sendClipboard(state: *State, w: *Io.Writer) !void {
    if (state.clipboard_len == 0) {
        return;
    }
    const payload = state.clipboard[0..state.clipboard_len];
    state.clipboard_len = 0;

    term.writeClipboard(w, payload) catch |err| switch (err) {
        // Nothing to recover: the terminal would have ignored it. Saying so
        // beats a copy that quietly did nothing.
        error.TooLarge => state.flash = "too much to copy",
        else => |e| return e,
    };
    try w.flush();
}

/// Monotonic nanoseconds.
///
/// `awake` is this std's monotonic clock: it never steps backwards and it
/// excludes time the machine spent suspended. Not `real`, because a wall clock
/// jumps when NTP corrects it, and a frame scheduler reading one will either
/// stall for the length of the correction or free-run straight through it.
fn monotonic(io: Io) u64 {
    return @intCast(Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
}

fn demoState() State {
    return .{
        .tasks = &.{
            .{
                .title = "Fix auth token refresh",
                .chip = .decide,
                .place = "guruwalk/api",
                .place_detail = "fix-auth-refresh",
                .origin = .agent,
                .status = .waiting,
                .status_detail = "",
                .tool = "claude/opus",
                .note = "agent asks about token reuse \u{2026}",
                .section = .needs_you,
            },
            .{
                .title = "Run test suite on main",
                .chip = .debug,
                .place = "guruwalk/api",
                .place_detail = "main",
                .origin = .shell,
                .status = .failed,
                .status_detail = "2m ago",
                .tool = "shell/vitest",
                .note = "3 failures \u{00b7} checkpoint C7",
                .section = .needs_you,
            },
            .{
                .title = "Rewrite booking flow copy",
                .chip = .review,
                .place = "guruwalk/web",
                .place_detail = "booking-flow-copy",
                .origin = .agent,
                .status = .ready,
                .status_detail = "8m ago",
                .tool = "claude/sonnet",
                .note = "+3 files \u{00b7} tests passed \u{00b7} unreviewed",
                .section = .ready,
            },
            .{
                .title = "Analyze disk usage",
                .chip = .review,
                .place = "localhost",
                .place_detail = "/Users",
                .origin = .host,
                .status = .ready,
                .status_detail = "21m ago",
                .tool = "shell/du",
                .note = "47 GB reclaimable \u{00b7} report ready",
                .section = .ready,
            },
            .{
                .title = "Deploy preview build",
                .chip = .none,
                .place = "guruwalk/web",
                .place_detail = "deploy-preview",
                .origin = .shell,
                .status = .working,
                .status_detail = "for 4m",
                .tool = "shell/pnpm",
                .note = "build step 4/7",
                .section = .running,
            },
            .{
                .title = "Nightly database backup",
                .chip = .none,
                .place = "guruwalk/infra",
                .place_detail = "cron",
                .origin = .shell,
                .status = .queued,
                .status_detail = "in 3h",
                .tool = "shell/pg_dump",
                .note = "last run ok \u{00b7} 1.2 GB",
                .section = .background,
            },
        },
        .tabs = &.{
            .{ .key = 1, .name = "inbox", .count = 6 },
            .{ .key = 2, .name = "tasks", .count = 7 },
            .{ .key = 3, .name = "reviews", .count = 2 },
        },
        .hints = &.{
            .{ .key = "\u{21b5}", .label = "decide" },
            .{ .key = "a", .label = "agent" },
            .{ .key = "e", .label = "edit" },
            .{ .key = "s", .label = "shell" },
            .{ .key = "r", .label = "review" },
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Finds the first point whose registered action satisfies `match`.
fn findHit(state: *const State, comptime match: fn (Action) bool) ?struct { x: u16, y: u16 } {
    for (state.hits.registered()) |hit| {
        if (match(hit.action)) {
            return .{ .x = hit.rect.x, .y = hit.rect.y };
        }
    }
    return null;
}

test "everything the sidebar draws as clickable is registered" {
    // A widget that draws a control and forgets to register it shows up here as
    // a missing variant. That is the failure this exists to catch.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);

    var seen_tab = false;
    var seen_task = false;
    var seen_chip = false;
    var seen_hint = false;
    var seen_scope = false;
    var seen_new = false;
    var seen_palette = false;
    var seen_search = false;

    for (state.hits.registered()) |hit| {
        switch (hit.action) {
            .select_tab => seen_tab = true,
            .select_task => seen_task = true,
            .run_task_action => seen_chip = true,
            .hint => seen_hint = true,
            .toggle_scope => seen_scope = true,
            .new_task => seen_new = true,
            .command_palette => seen_palette = true,
            .focus_search => seen_search = true,
            .scroll_to_row, .dialog_choice, .dismiss_dialog, .dialog_body => {},
        }
    }
    try testing.expect(seen_tab and seen_task and seen_chip and seen_hint);
    try testing.expect(seen_scope and seen_new and seen_palette and seen_search);
}

test "an action chip takes the click, not the task row beneath it" {
    // Both cover the same cells. The chip registers later, so it has to win, or
    // the primary action of every task is unreachable with a mouse.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);

    const point = findHit(&state, struct {
        fn match(a: Action) bool {
            return a == .run_task_action and a.run_task_action == 0;
        }
    }.match) orelse return error.ChipNotFound;

    const resolved = state.hits.at(point.x + 1, point.y) orelse return error.NoHit;
    try testing.expectEqual(@as(usize, 0), resolved.run_task_action);

    update(&state, .{ .mouse = .{ .x = point.x + 1, .y = point.y, .kind = .press } });
    // The chip's action now opens the dialog for that task. Same claim as
    // before - the chip won the click, not the row - stated against what the
    // action currently does.
    try testing.expectEqual(@as(?usize, 0), state.dialog);
}

test "clicking a task row selects it without running its action" {
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);

    const point = findHit(&state, struct {
        fn match(a: Action) bool {
            return a == .select_task and a.select_task == 3;
        }
    }.match) orelse return error.RowNotFound;

    update(&state, .{ .mouse = .{ .x = point.x + 3, .y = point.y, .kind = .press } });
    try testing.expectEqual(@as(usize, 3), state.selected_task);
    try testing.expectEqualStrings("", state.flash);
}

test "clicking a tab selects it" {
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);

    const point = findHit(&state, struct {
        fn match(a: Action) bool {
            return a == .select_tab and a.select_tab == 2;
        }
    }.match) orelse return error.TabNotFound;

    update(&state, .{ .mouse = .{ .x = point.x, .y = point.y, .kind = .press } });
    try testing.expectEqual(@as(usize, 2), state.selected_tab);
}

test "the scope row toggles and the chips flash" {
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);

    const scope = findHit(&state, struct {
        fn match(a: Action) bool {
            return a == .toggle_scope;
        }
    }.match) orelse return error.ScopeNotFound;
    update(&state, .{ .mouse = .{ .x = scope.x + 1, .y = scope.y, .kind = .press } });
    try testing.expect(state.scope_open);

    view(&state, &buf);
    const plus = findHit(&state, struct {
        fn match(a: Action) bool {
            return a == .new_task;
        }
    }.match) orelse return error.PlusNotFound;
    update(&state, .{ .mouse = .{ .x = plus.x, .y = plus.y, .kind = .press } });
    try testing.expect(std.mem.startsWith(u8, state.flash, "new task"));
}

test "the scrollbar only appears when the list overflows" {
    const gpa = testing.allocator;
    var state = demoState();

    for ([_]struct { h: u16, expect: bool }{
        .{ .h = 60, .expect = false },
        .{ .h = 20, .expect = true },
    }) |case| {
        var buf = try ui.Buffer.init(gpa, 100, case.h);
        defer buf.deinit();
        view(&state, &buf);

        var found = false;
        for (state.hits.registered()) |hit| {
            if (hit.action == .scroll_to_row) {
                found = true;
            }
        }
        try testing.expectEqual(case.expect, found);
    }
}

test "hit testing is rebuilt every frame rather than accumulated" {
    // Stale rectangles are the failure mode of keeping them: the list scrolls
    // and the clicks do not follow.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    const first = state.hits.len;
    view(&state, &buf);
    try testing.expectEqual(first, state.hits.len);
}

test "narrow and short terminals draw without writing outside the buffer" {
    const gpa = testing.allocator;
    var state = demoState();
    for ([_][2]u16{
        .{ 1, 1 },    .{ 10, 4 },  .{ 29, 13 },
        .{ 30, 14 },  .{ 62, 20 }, .{ 100, 40 },
        .{ 200, 60 },
    }) |size| {
        var buf = try ui.Buffer.init(gpa, size[0], size[1]);
        defer buf.deinit();
        view(&state, &buf);
    }
}

// ---------------------------------------------------------------------------
// The dialog, which is the test of the layering
// ---------------------------------------------------------------------------

/// Tabs until the keyboard reaches a task row.
///
/// The search field now owns its keys, so a down arrow leaves the field rather
/// than moving the selection behind it. Tests that are about tasks have to get
/// there the way a user would.
fn focusFirstTask(state: *State, buf: *ui.Buffer) usize {
    for (0..32) |_| {
        if (state.focus.focused()) |id| {
            if (id == .task) {
                return id.task;
            }
        }
        update(state, .{ .key = .plain(.tab) });
        view(state, buf);
    }
    return 0;
}

/// Opens the dialog for task zero and returns the frame it drew into.
fn openDialog(state: *State, buf: *ui.Buffer) ui.Rect {
    apply(state, .{ .run_task_action = 0 });
    view(state, buf);
    for (state.hits.registered()) |entry| {
        if (entry.action == .dialog_body) {
            return entry.rect;
        }
    }
    return .{};
}

test "a click on the dialog's blank interior does not reach the list behind it" {
    // The bug this whole layer mechanism exists to prevent. A dialog opens over
    // the task list, the user clicks its empty background, and a row underneath
    // selects. Drawing order cannot fix it: by the time the row is asked, the
    // wrong answer has already been given.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    // Something under the dialog that would answer if the layer let it.
    const before = state.selected_task;

    const frame = openDialog(&state, &buf);
    try testing.expect(!frame.isEmpty());

    // A point inside the frame but on none of its controls.
    const x = frame.x + frame.w - 2;
    const y = frame.y + 1;
    update(&state, .{ .mouse = .{ .x = x, .y = y, .kind = .press } });

    try testing.expectEqual(before, state.selected_task);
    // And the dialog is still open: a click on its own body is not a dismiss.
    try testing.expectEqual(@as(?usize, 0), state.dialog);
}

test "a click outside the dialog dismisses it" {
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    const frame = openDialog(&state, &buf);

    update(&state, .{ .mouse = .{ .x = frame.x -| 3, .y = frame.y, .kind = .press } });
    try testing.expectEqual(@as(?usize, null), state.dialog);
}

test "the dialog's buttons beat the dismiss rectangle under them" {
    // The dismiss target covers the whole screen, including the buttons. They
    // register after it in the same layer, so they win - the same last-wins rule
    // that makes a chip beat its row, one layer up.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    _ = openDialog(&state, &buf);

    var found = false;
    for (state.hits.registered()) |entry| {
        if (entry.action == .dialog_choice and entry.action.dialog_choice == 1) {
            update(&state, .{ .mouse = .{ .x = entry.rect.x + 1, .y = entry.rect.y, .kind = .press } });
            found = true;
            break;
        }
    }
    try testing.expect(found);
    try testing.expectEqualStrings("Reject", state.flash);
    try testing.expectEqual(@as(?usize, null), state.dialog);
}

test "the dialog holds the keyboard while it is open" {
    // Without this, "q" quits the program from under an open dialog and the
    // arrows move a selection nobody can see.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    const selected = state.selected_task;
    _ = openDialog(&state, &buf);

    // "q" quits the program at the top level. Addressed to a dialog it matches
    // no button initial, so it does nothing at all - and crucially does not
    // reach the binding underneath.
    update(&state, .{ .key = .plain(.{ .char = .init("q") }) });
    try testing.expect(!state.quit);
    try testing.expectEqual(@as(?usize, 0), state.dialog);

    // Arrows move between the dialog's buttons, not the list behind it.
    update(&state, .{ .key = .plain(.down) });
    try testing.expectEqual(selected, state.selected_task);

    // Escape belongs to whatever is on top.
    update(&state, .{ .key = .plain(.escape) });
    try testing.expectEqual(@as(?usize, null), state.dialog);
}

test "nothing the dialog draws escapes its frame" {
    // The clip, from the client's side: the same state rendered with the
    // dialog open and closed, comparing the columns that flank it.
    //
    // Not the whole screen. Opening the dialog legitimately changes things
    // elsewhere now - it moves the keyboard, so the selection bar in the
    // gutter switches from the focused glyph to the unfocused one. Comparing
    // everything would fail on that and say nothing about clipping.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    const frame = openDialog(&state, &buf);
    try testing.expect(!frame.isEmpty());
    try testing.expect(frame.x >= 2);

    var with: [40][100]ui.Cell = undefined;
    for (0..buf.h) |y| for (0..buf.w) |x| {
        with[y][x] = (buf.at(@intCast(x), @intCast(y)) orelse unreachable).*;
    };

    state.dialog = null;
    view(&state, &buf);

    var checked: usize = 0;
    var y = frame.y;
    while (y < frame.y + frame.h) : (y += 1) {
        for ([_]u16{ frame.x - 2, frame.x - 1, frame.x + frame.w, frame.x + frame.w + 1 }) |x| {
            if (x >= buf.w) {
                continue;
            }
            const without = (buf.at(x, y) orelse unreachable).*;
            try testing.expect(with[y][x].eqlPublic(&without));
            checked += 1;
        }
    }
    // A test that compared nothing would pass too.
    try testing.expect(checked >= frame.h * 2);
}

test "the dialog takes the keyboard by opening a layer, not by being asked" {
    // Nothing in `handleKey` mentions dialogs. If this passes, the routing came
    // from where the controls were registered.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    try testing.expect(state.focus.focused().? != .dialog_button);

    _ = openDialog(&state, &buf);
    try testing.expectEqual(@as(usize, 0), state.focus.focused().?.dialog_button);
}

test "tab cannot leave the dialog" {
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    _ = openDialog(&state, &buf);

    // More presses than the dialog has buttons, so it wraps rather than
    // walking out into the list nobody can reach.
    for (0..8) |_| {
        update(&state, .{ .key = .plain(.tab) });
        try testing.expect(state.focus.focused().? == .dialog_button);
    }
}

test "dismissing the dialog returns the keyboard to where it was" {
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);

    _ = focusFirstTask(&state, &buf);
    update(&state, .{ .key = .plain(.down) });
    view(&state, &buf);
    const before = state.focus.focused().?;

    // Opened with Enter, on the focused row - which is how a user opens it.
    // The helper opens task zero regardless of focus, and moving the keyboard
    // to the task whose dialog you opened is correct behaviour, so using it
    // here would be testing the helper.
    update(&state, .{ .key = .plain(.enter) });
    view(&state, &buf);
    try testing.expect(state.dialog != null);

    update(&state, .{ .key = .plain(.escape) });
    view(&state, &buf);

    // Not reset to the top of the sidebar. Back to the row the user left.
    try testing.expectEqual(before, state.focus.focused().?);
}

test "enter runs the focused task, not the one the mouse last touched" {
    // Selection and focus used to drift apart: the arrows moved a highlight
    // while the keyboard stayed put, so Enter ran a task the user was no longer
    // looking at.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    _ = focusFirstTask(&state, &buf);
    update(&state, .{ .key = .plain(.down) });
    view(&state, &buf);

    const focused = state.focus.focused().?.task;
    try testing.expectEqual(state.selected_task, focused);

    update(&state, .{ .key = .plain(.enter) });
    try testing.expectEqual(@as(?usize, focused), state.dialog);
}

test "clicking a control moves the keyboard to it" {
    // Leaving focus behind is how a user clicks a row, presses Enter, and
    // watches a different row run.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);

    const point = findHit(&state, struct {
        fn match(a: Action) bool {
            return a == .select_task and a.select_task == 1;
        }
    }.match) orelse return error.RowNotFound;

    update(&state, .{ .mouse = .{ .x = point.x, .y = point.y, .kind = .press } });
    view(&state, &buf);
    try testing.expectEqual(@as(usize, 1), state.focus.focused().?.task);
}

test "focus survives a frame where the focused row scrolled away" {
    // The registry repairs this rather than stranding the keyboard on a row
    // that is no longer drawn - which looks like a UI that stopped responding.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    state.focus.set(.{ .task = state.tasks.len - 1 });

    // A frame where that task is not drawn at all.
    var only_first = [_]Task{state.tasks[0]};
    state.tasks = &only_first;
    state.selected_task = 0;
    view(&state, &buf);

    const now = state.focus.focused() orelse return error.KeyboardStranded;
    switch (now) {
        .task => |index| try testing.expect(index < only_first.len),
        else => {},
    }
    // And a key still lands somewhere.
    update(&state, .{ .key = .plain(.enter) });
}

test "every focusable variant is registered by a drawn frame" {
    // The same exhaustiveness idea as the hit registry: a control that can hold
    // the keyboard but is never registered is unreachable with Tab, and no
    // other test would notice.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    _ = openDialog(&state, &buf);

    var seen_search = false;
    var seen_tab = false;
    var seen_scope = false;
    var seen_task = false;
    var seen_button = false;
    for (state.focus.entries[0..state.focus.len]) |entry| switch (entry.id) {
        .search => seen_search = true,
        .tab => seen_tab = true,
        .scope => seen_scope = true,
        .task => seen_task = true,
        .dialog_button => seen_button = true,
    };
    try testing.expect(seen_search and seen_tab and seen_scope);
    try testing.expect(seen_task and seen_button);
}

// ---------------------------------------------------------------------------
// The search field
// ---------------------------------------------------------------------------

/// Puts the keyboard in the search box, the way a click would.
///
/// Needed now that the application opens on the list: a test about a field has
/// to reach the field first, same as a user.
fn focusSearch(state: *State, buf: *ui.Buffer) void {
    apply(state, .focus_search);
    view(state, buf);
}

fn typeInto(state: *State, buf: *ui.Buffer, text: []const u8) void {
    var it: ui.GraphemeIterator = .{ .bytes = text };
    while (it.next()) |cluster| {
        update(state, .{ .key = .plain(.{ .char = .init(cluster.bytes) }) });
    }
    view(state, buf);
}

test "the focused field is greedy with printable keys" {
    // "q" quits everywhere else. Inside a field it is a letter, or you cannot
    // search for a task called "q1".
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    focusSearch(&state, &buf);
    try testing.expect(state.focus.has(.search));

    typeInto(&state, &buf, "q1");
    try testing.expect(!state.quit);
    try testing.expectEqualStrings("q1", state.search.text());
}

test "a field that does not hold the keyboard does not eat keys" {
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    view(&state, &buf);
    try testing.expect(!state.focus.has(.search));

    typeInto(&state, &buf, "q");
    try testing.expect(state.quit);
    try testing.expectEqualStrings("", state.search.text());
}

test "the real cursor is placed on the field and nowhere else" {
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    focusSearch(&state, &buf);
    const at = state.cursor orelse return error.NoCursor;

    typeInto(&state, &buf, "abc");
    const moved = state.cursor orelse return error.NoCursor;
    try testing.expectEqual(at.y, moved.y);
    try testing.expectEqual(at.x + 3, moved.x);

    // Focus elsewhere: the hardware cursor must not stay parked on a field
    // nobody is typing into.
    _ = focusFirstTask(&state, &buf);
    try testing.expectEqual(@as(?term.Screen.Position, null), state.cursor);
}

test "a pasted newline is text, not Enter" {
    // The whole reason bracketed paste exists. Three pasted lines running three
    // commands is the classic annoyance; in an agent runtime it is worse.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    focusSearch(&state, &buf);

    update(&state, .paste_start);
    typeInto(&state, &buf, "one");
    update(&state, .{ .key = .plain(.enter) });
    typeInto(&state, &buf, "two");
    update(&state, .paste_end);
    view(&state, &buf);

    // Still in the field, and the newline became a space rather than leaving it.
    try testing.expect(state.focus.has(.search));
    try testing.expectEqualStrings("one two", state.search.text());
}

test "a paste does not trigger the bindings its characters would" {
    // "q" inside a paste is a letter even when the field does not have focus
    // yet in the user's mind - pasting must never run a command.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    focusSearch(&state, &buf);

    update(&state, .paste_start);
    typeInto(&state, &buf, "q");
    update(&state, .paste_end);
    try testing.expect(!state.quit);
    try testing.expectEqualStrings("q", state.search.text());
}

test "shift and arrows build a selection the field reports back" {
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    focusSearch(&state, &buf);
    typeInto(&state, &buf, "hola");

    update(&state, .{ .key = .{ .code = .left, .mods = .{ .shift = true } } });
    update(&state, .{ .key = .{ .code = .left, .mods = .{ .shift = true } } });
    try testing.expectEqualStrings("la", state.search.selected());

    // And typing replaces it.
    typeInto(&state, &buf, "y");
    try testing.expectEqualStrings("hoy", state.search.text());
}

test "ctrl and arrows move by word" {
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    focusSearch(&state, &buf);
    typeInto(&state, &buf, "git commit");

    update(&state, .{ .key = .{ .code = .left, .mods = .{ .ctrl = true } } });
    try testing.expectEqualStrings("commit", state.search.text()[state.search.head..]);
}

test "escape clears the field before it reaches anything else" {
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    focusSearch(&state, &buf);
    typeInto(&state, &buf, "hola");

    update(&state, .{ .key = .plain(.escape) });
    try testing.expectEqualStrings("", state.search.text());
    // Still focused: escape emptied the field, it did not leave it.
    try testing.expect(state.focus.has(.search));
}

// ---------------------------------------------------------------------------
// Selecting to copy
// ---------------------------------------------------------------------------

fn mouseAt(x: u16, y: u16, kind: term.Event.Mouse.Kind) term.Event {
    return .{ .mouse = .{ .x = x, .y = y, .kind = kind } };
}

/// A point over the sidebar's text rather than over any control.
fn inertPoint(state: *const State, buf: *const ui.Buffer) ?sel.Point {
    var y: u16 = 0;
    while (y < buf.h) : (y += 1) {
        var x: u16 = 0;
        while (x < buf.w) : (x += 1) {
            if (state.hits.at(x, y) != null) {
                continue;
            }
            const cell = buf.cells[@as(usize, y) * @as(usize, buf.w) + @as(usize, x)];
            if (cell.text().len > 0 and cell.text()[0] != ' ') {
                return .{ .x = x, .y = y };
            }
        }
    }
    return null;
}

test "a drag over inert text selects and copies it" {
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    view(&state, &buf);

    const from = inertPoint(&state, &buf) orelse return error.NothingInert;
    update(&state, mouseAt(from.x, from.y, .press));
    update(&state, mouseAt(from.x + 6, from.y, .drag));
    update(&state, mouseAt(from.x + 6, from.y, .release));

    try testing.expect(state.selection != null);
    try testing.expect(state.clipboard_len > 0);
    try testing.expectEqualStrings("copied", state.flash);
}

test "a single click on a control is a click, not a selection" {
    // The crux of the gesture: a press is ambiguous until it moves. Treating
    // every press as the start of a drag would make the whole UI unclickable.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);

    const point = findHit(&state, struct {
        fn match(a: Action) bool {
            return a == .select_task and a.select_task == 1;
        }
    }.match) orelse return error.RowNotFound;

    update(&state, mouseAt(point.x, point.y, .press));
    try testing.expectEqual(@as(?sel.Range, null), state.selection);
    try testing.expectEqual(@as(usize, 1), state.selected_task);
}

test "a double click selects a word even over a control" {
    // A second click is unambiguous. Refusing it over a task row would mean the
    // one place worth copying from - the task title - is the one place you
    // cannot.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    view(&state, &buf);

    const point = findHit(&state, struct {
        fn match(a: Action) bool {
            return a == .select_task and a.select_task == 0;
        }
    }.match) orelse return error.RowNotFound;

    state.now = 0;
    update(&state, mouseAt(point.x + 4, point.y, .press));
    state.now = 100 * std.time.ns_per_ms;
    update(&state, mouseAt(point.x + 4, point.y, .press));

    const range = state.selection orelse return error.NoSelection;
    try testing.expectEqual(sel.Granularity.word, range.granularity);
    try testing.expect(state.clipboard_len > 0);
}

test "two slow clicks are two clicks" {
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    view(&state, &buf);

    const from = inertPoint(&state, &buf) orelse return error.NothingInert;
    state.now = 0;
    update(&state, mouseAt(from.x, from.y, .press));
    update(&state, mouseAt(from.x, from.y, .release));
    state.now = 5 * std.time.ns_per_s;
    update(&state, mouseAt(from.x, from.y, .press));

    const range = state.selection orelse return error.NoSelection;
    try testing.expectEqual(sel.Granularity.character, range.granularity);
}

test "a drag that never moved copies nothing" {
    // A click on empty space is not a request to copy an empty string, and
    // sending one would clear whatever the user had on their clipboard.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    view(&state, &buf);

    const from = inertPoint(&state, &buf) orelse return error.NothingInert;
    update(&state, mouseAt(from.x, from.y, .press));
    update(&state, mouseAt(from.x, from.y, .release));
    try testing.expectEqual(@as(usize, 0), state.clipboard_len);
}

test "what is highlighted is what is copied" {
    // Two code paths, one answer. A selection that paints wider than it copies
    // is exactly the sort of thing a user notices and cannot describe.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    view(&state, &buf);

    const from = inertPoint(&state, &buf) orelse return error.NothingInert;
    update(&state, mouseAt(from.x, from.y, .press));
    update(&state, mouseAt(from.x + 8, from.y, .drag));
    update(&state, mouseAt(from.x + 8, from.y, .release));
    const copied = state.clipboard[0..state.clipboard_len];

    view(&state, &buf);
    var inverted: usize = 0;
    for (0..buf.h) |y| for (0..buf.w) |x| {
        const cell = buf.at(@intCast(x), @intCast(y)) orelse continue;
        if (cell.style.flags.inverse) {
            inverted += 1;
        }
    };
    try testing.expectEqual(@as(usize, 9), inverted);
    try testing.expect(copied.len > 0);
}

test "a copy leaves no trailing padding" {
    // The most recognisable symptom of text copied out of a terminal: a block
    // of spaces pasted along with it, because a screen row is always full.
    const gpa = testing.allocator;
    var buf = try ui.Buffer.init(gpa, 100, 40);
    defer buf.deinit();

    var state = demoState();
    view(&state, &buf);
    view(&state, &buf);

    const from = inertPoint(&state, &buf) orelse return error.NothingInert;
    state.now = 0;
    update(&state, mouseAt(from.x, from.y, .press));
    state.now = 100 * std.time.ns_per_ms;
    update(&state, mouseAt(from.x, from.y, .press));
    state.now = 200 * std.time.ns_per_ms;
    update(&state, mouseAt(from.x, from.y, .press));

    const copied = state.clipboard[0..state.clipboard_len];
    try testing.expect(copied.len > 0);
    try testing.expect(!std.mem.endsWith(u8, copied, " "));
}
