const std = @import("std");
const objc = @import("objc");
const native = @import("../native.zig");
const appkit = @import("appkit.zig");
const input_receiver = @import("InputReceiver.zig");
const InputReceiver = input_receiver.InputReceiver;
const ranges = @import("text_ranges.zig");
const ns_range = @import("Range.zig");
const Range = ns_range.Range;
const c = native.c;
const Object = objc.Object;
const Id = objc.c.id;
const Sel = objc.c.SEL;
const none: Range = .{ .location = std.math.maxInt(isize) };
const key_capacity = 256;
const Kind = enum(u32) { text = 1, key = 3, unicode = 4, composition = 7 };
const Phase = enum(u32) { press = 1, repeat = 2, release = 3 };
const Composition = enum(u32) { update = 1, cancel = 2 };
const Modifier = enum(u32) { shift = 1, alt = 2, control = 4, command = 8 };
const Key = enum(u32) { none = 0, enter = 1, tab = 2, backspace = 3, escape = 4, up = 5, down = 6, left = 7, right = 8, home = 9, end = 10, delete = 11, page_up = 12, page_down = 13 };
const Keycode = enum(u16) { enter = 36, keypad_enter = 76, tab = 48, backspace = 51, escape = 53, up = 126, down = 125, left = 123, right = 124, home = 115, end = 119, delete = 117, page_up = 116, page_down = 121, _ };

// One AppKit view owns this native editing mirror. It never references a GUI
// adapter. Commits and physical-key leases change only after queue admission.
const TextInput = struct {
    receiver: ?InputReceiver = null,
    marked: Id = null,
    surrounding: Id = null,
    context: c.telar_gui_text_context = std.mem.zeroes(c.telar_gui_text_context),
    selection: Range = .{},
    marked_selection: Range = .{},
    marked_replacement: Range = none,
    optimistic: bool = false,
    phase: Phase = .press,
    physical: u32 = 0,
    held: [key_capacity]c.telar_gui_input = @splat(std.mem.zeroes(c.telar_gui_input)),
};
var offset: usize = 0;
/// canvas_view installs these AppKit text methods on its single NSView subclass.
/// Storage and lifetime are coordinated by that view, without a native base class.
pub fn install(class: objc.Class) !void {
    offset = try appkit.addStorage(class, "telar_text");
    try appkit.method(class, "acceptsFirstResponder", acceptsFirstResponder);
    try appkit.method(class, "setTextContext:", setTextContext);
    try appkit.method(class, "paste:", paste);
    try appkit.method(class, "keyDown:", keyDown);
    try appkit.method(class, "keyUp:", keyUp);
    try appkit.method(class, "releasePressedKeys", releasePressedKeys);
    try appkit.method(class, "resignFirstResponder", resignFirstResponder);
    try appkit.method(class, "insertText:replacementRange:", insertText);
    try appkit.method(class, "setMarkedText:selectedRange:replacementRange:", setMarkedText);
    try appkit.method(class, "unmarkText", unmarkText);
    try appkit.method(class, "hasMarkedText", hasMarkedText);
    try appkit.method(class, "markedRange", markedRange);
    try appkit.method(class, "selectedRange", selectedRange);
    try appkit.method(class, "validAttributesForMarkedText", validAttributes);
    try appkit.method(class, "attributedSubstringForProposedRange:actualRange:", attributedSubstring);
    try appkit.method(class, "characterIndexForPoint:", characterIndex);
    try appkit.method(class, "firstRectForCharacterRange:actualRange:", firstRect);
    try appkit.method(class, "doCommandBySelector:", command);
    const protocol = objc.c.objc_getProtocol("NSTextInputClient") orelse return error.ProtocolUnavailable;
    if (objc.c.class_addProtocol(class.value, protocol) == 0) {
        return error.NativeClassRegistrationFailed;
    }
}

fn state(raw: Id) *TextInput {
    return appkit.storage(TextInput, raw, offset).*.?;
}

pub fn init(raw: Id, receiver: InputReceiver) !void {
    const input = try std.heap.c_allocator.create(TextInput);
    input.* = .{
        .receiver = receiver,
        .marked = appkit.string(null, 0),
        .surrounding = appkit.string(null, 0),
    };
    appkit.storage(TextInput, raw, offset).* = input;
}

pub fn deinit(raw: Id) void {
    if (appkit.storage(TextInput, raw, offset).*) |input| {
        Object.fromId(input.marked).release();
        Object.fromId(input.surrounding).release();
        std.heap.c_allocator.destroy(input);
        appkit.storage(TextInput, raw, offset).* = null;
    }
}

pub fn stop(raw: Id) void {
    const input = appkit.storage(TextInput, raw, offset).* orelse return;
    input.receiver = null;
    clearMarked(input);
    appkit.replace(&input.surrounding, appkit.string(null, 0));
    input.context = std.mem.zeroes(c.telar_gui_text_context);
    input.held = @splat(std.mem.zeroes(c.telar_gui_input));
}

fn acceptsFirstResponder(_: Id, _: Sel) callconv(.c) bool {
    return true;
}

// The canvas calls this for text and pointer events. Never publish optimistic text
// after rejection: AppKit must continue seeing the last admitted transaction.
pub fn receive(raw: Id, event: c.telar_gui_input) bool {
    const input = state(raw);
    if (input.receiver == null) {
        return false;
    }

    if (!appkit.send(input.receiver, event)) {
        appkit.NSBeep();
        return false;
    }

    return true;
}

fn send(raw: Id, event: c.telar_gui_input) bool {
    return Object.fromId(raw).msgSend(bool, "sendInput:", .{event});
}

fn clearMarked(input: *TextInput) void {
    appkit.replace(&input.marked, appkit.string(null, 0));
    input.marked_replacement = none;
}

// Window snapshot publication is separate from native dispatch. AppKit can
// query this owned mirror synchronously without reentering the client loop.
fn setTextContext(raw: Id, _: Sel, next: c.telar_gui_text_context) callconv(.c) void {
    if (next.len > c.TELAR_GUI_TEXT_CAPACITY or (next.len != 0 and next.text == null) or
        !std.math.isFinite(next.x) or !std.math.isFinite(next.y) or !std.math.isFinite(next.width) or !std.math.isFinite(next.height))
    {
        return;
    }

    const input = state(raw);
    const changed_owner = next.target_id != input.context.target_id or next.generation != input.context.generation or next.enabled != input.context.enabled;
    if (changed_owner or (next.enabled != 0 and next.composition_active == 0 and appkit.length(input.marked) != 0)) {
        clearMarked(input);
        Object.fromId(raw).msgSend(Object, "inputContext", .{}).msgSend(void, "discardMarkedText", .{});
    }

    if (!changed_owner and next.revision == input.context.revision and !input.optimistic) {
        input.context.x = next.x;
        input.context.y = next.y;
        input.context.width = next.width;
        input.context.height = next.height;
        return;
    }

    const text = appkit.string(next.text, next.len);
    const selected = ranges.utf16Range(text, next.selection_start, next.selection_end);
    if (text == null or (next.enabled != 0 and selected.location == none.location)) {
        Object.fromId(text).release();
        return;
    }

    appkit.replace(&input.surrounding, text);
    input.selection = if (selected.location == none.location) .{} else selected;
    input.context = next;
    input.context.text = null;
    input.optimistic = false;
    if (appkit.length(input.marked) != 0 and !within(input.marked_replacement, appkit.length(text))) {
        clearMarked(input);
    }

    Object.fromId(raw).msgSend(Object, "inputContext", .{}).msgSend(void, "invalidateCharacterCoordinates", .{});
}

fn within(value: Range, length: usize) bool {
    return value.location <= length and value.length <= length - value.location;
}

// AppKit ranges include provisional text; semantic replacements refer to the
// committed document. Collapse intersections with preedit back to its original span.
fn committedRange(input: *const TextInput, value: Range) Range {
    if (value.location == none.location) {
        return value;
    }

    const marked_length = appkit.length(input.marked);
    const has_mark = marked_length != 0 and input.marked_replacement.location != none.location;
    const length = appkit.length(input.surrounding);
    const document_length = if (has_mark) length - input.marked_replacement.length + marked_length else length;
    if (!within(value, document_length)) {
        return none;
    }

    if (!has_mark) {
        return value;
    }

    const mark_start = input.marked_replacement.location;
    const mark_end = mark_start + marked_length;
    var first = value.location;
    var last = value.location + value.length;
    if (first > mark_start) {
        first = if (first >= mark_end) first - marked_length + input.marked_replacement.length else mark_start;
    }

    if (last > mark_start) {
        last = if (last >= mark_end) last - marked_length + input.marked_replacement.length else mark_start + input.marked_replacement.length;
    }

    return .{ .location = first, .length = last - first };
}

fn inputDocument(input: *const TextInput) Id {
    if (appkit.length(input.marked) == 0 or input.marked_replacement.location == none.location) {
        return input.surrounding;
    }

    return Object.fromId(input.surrounding).msgSend(Id, "stringByReplacingCharactersInRange:withString:", .{ input.marked_replacement, input.marked });
}

fn eventFor(input: *const TextInput, kind: Kind) c.telar_gui_input {
    return std.mem.zeroInit(c.telar_gui_input, .{
        .kind = @intFromEnum(kind),
        .phase = @intFromEnum(Phase.press),
        .target_id = if (input.context.enabled != 0) input.context.target_id else 0,
        .generation = input.context.generation,
        .replacement_start = c.TELAR_GUI_RANGE_NONE,
        .replacement_end = c.TELAR_GUI_RANGE_NONE,
    });
}

fn character(text: Id, index: usize) u16 {
    return Object.fromId(text).msgSend(u16, "characterAtIndex:", .{index});
}

fn sendText(raw: Id, text: Id, replacement: Range) void {
    if (appkit.byteLength(text) > c.TELAR_GUI_CLIPBOARD_CAPACITY) {
        return;
    }

    const data = appkit.bytes(text);
    if (data.value == null) {
        return;
    }

    const input = state(raw);
    const length = appkit.length(text);
    const scalar = length == 1 or (length == 2 and std.unicode.utf16IsHighSurrogate(character(text, 0)) and std.unicode.utf16IsLowSurrogate(character(text, 1)));
    const physical = if (scalar and appkit.length(input.marked) == 0) input.physical else 0;
    var event = eventFor(input, .text);
    event.phase = @intFromEnum(if (physical != 0) input.phase else Phase.press);
    event.physical = physical;
    event.text = data.msgSend([*c]const u8, "bytes", .{});
    event.len = appkit.length(data.value);
    const committed = committedRange(input, replacement);
    if (replacement.location != none.location and committed.location == none.location) {
        return;
    }

    if (committed.location != none.location and !ranges.utf8Range(input.surrounding, committed, &event.replacement_start, &event.replacement_end)) {
        return;
    }

    if (!send(raw, event)) {
        return;
    }

    if (physical != 0 and physical <= key_capacity) {
        var held = eventFor(input, .unicode);
        // SAFETY: A nonzero physical key requires scalar; a two-unit scalar was checked for a high surrogate followed by a low surrogate above.
        held.code = if (length == 1) character(text, 0) else std.unicode.utf16DecodeSurrogatePair(&.{ character(text, 0), character(text, 1) }) catch unreachable;
        held.physical = physical;
        input.held[physical - 1] = held;
    }

    input.optimistic = input.context.enabled != 0;
    const replace = if (committed.location != none.location) committed else if (appkit.length(input.marked) != 0) input.marked_replacement else input.selection;
    const surrounding_length = appkit.length(input.surrounding);
    if (input.context.enabled != 0 and within(replace, surrounding_length) and surrounding_length - replace.length + length <= c.TELAR_GUI_TEXT_CAPACITY) {
        const updated = Object.fromId(input.surrounding).msgSend(Object, "stringByReplacingCharactersInRange:withString:", .{ replace, text }).retain();
        appkit.replace(&input.surrounding, updated.value);
        input.selection = .{ .location = replace.location + length };
    }

    clearMarked(input);
}

fn paste(raw: Id, _: Sel, _: Id) callconv(.c) void {
    var event = eventFor(state(raw), .unicode);
    event.code = 'v';
    event.mods = @intFromEnum(Modifier.command);
    _ = send(raw, event);
}

fn keyDown(raw: Id, _: Sel, native_event: Id) callconv(.c) void {
    const event = Object.fromId(native_event);
    const input = state(raw);
    if (input.receiver == null) {
        return;
    }

    input.phase = if (event.msgSend(bool, "isARepeat", .{})) .repeat else .press;
    const key = event.msgSend(u16, "keyCode", .{});
    input.physical = if (key < key_capacity) @as(u32, key) + 1 else 0;
    defer {
        input.physical = 0;
        input.phase = .press;
    }

    routeKey(raw, event, key);
}

fn interpret(raw: Id, event: Object) void {
    const events = objc.getClass("NSArray").?.msgSend(Object, "arrayWithObject:", .{event});
    Object.fromId(raw).msgSend(void, "interpretKeyEvents:", .{events});
}

fn routeKey(raw: Id, event: Object, key: u16) void {
    const input = state(raw);
    const flags = event.msgSend(usize, "modifierFlags", .{});
    const mods = appkit.modifiers(flags);

    const shortcut = @intFromEnum(Modifier.command) | @intFromEnum(Modifier.control);
    if (mods & shortcut == shortcut) {
        const lowered = event.msgSend(Object, "charactersIgnoringModifiers", .{}).msgSend(Id, "lowercaseString", .{});
        if (appkit.length(lowered) == 1 and character(lowered, 0) == 'f') {
            if (input.phase != .repeat) {
                Object.fromId(raw).msgSend(Object, "window", .{}).msgSend(void, "toggleFullScreen:", .{@as(Id, null)});
            }

            return;
        }
    }

    if (appkit.length(input.marked) != 0 and mods & shortcut == 0) {
        input.physical = 0;
        interpret(raw, event);
        return;
    }

    const code: Key = switch (@as(Keycode, @enumFromInt(key))) {
        .enter, .keypad_enter => .enter,
        inline .tab, .backspace, .escape, .up, .down, .left, .right, .home, .end, .delete, .page_up, .page_down => |value| @field(Key, @tagName(value)),
        _ => .none,
    };
    var delivered = eventFor(input, if (code != .none) .key else .unicode);
    delivered.code = @intFromEnum(code);
    delivered.mods = mods;
    delivered.phase = @intFromEnum(input.phase);
    delivered.physical = input.physical;
    if (code == .none) {
        if (mods & (@intFromEnum(Modifier.alt) | shortcut) == 0) {
            interpret(raw, event);
            return;
        }

        const characters = event.msgSend(Object, "charactersIgnoringModifiers", .{});
        if (appkit.length(characters.value) != 1) {
            return;
        }

        delivered.code = character(characters.value, 0);
    }

    if (send(raw, delivered) and delivered.physical != 0) {
        input.held[delivered.physical - 1] = delivered;
    }
}

fn keyUp(raw: Id, _: Sel, native_event: Id) callconv(.c) void {
    const key = Object.fromId(native_event).msgSend(u16, "keyCode", .{});
    const input = state(raw);
    if (key >= key_capacity or input.held[key].physical == 0) {
        return;
    }

    var event = input.held[key];
    event.phase = @intFromEnum(Phase.release);
    if (send(raw, event)) {
        input.held[key] = std.mem.zeroes(c.telar_gui_input);
    }
}

pub fn releasePressedKeys(raw: Id, _: Sel) callconv(.c) void {
    for (&state(raw).held) |*held| {
        if (held.physical != 0) {
            var event = held.*;
            event.phase = @intFromEnum(Phase.release);
            _ = send(raw, event);
            held.* = std.mem.zeroes(c.telar_gui_input);
        }
    }
}

fn resignFirstResponder(raw: Id, selector: Sel) callconv(.c) bool {
    releasePressedKeys(raw, selector);
    return Object.fromId(raw).msgSendSuper(objc.getClass("NSView").?, bool, "resignFirstResponder", .{});
}

fn plainText(value: Id) Id {
    const object = Object.fromId(value);
    return if (object.msgSend(bool, "isKindOfClass:", .{objc.getClass("NSAttributedString").?})) object.msgSend(Id, "string", .{}) else value;
}

fn insertText(raw: Id, _: Sel, value: Id, replacement: Range) callconv(.c) void {
    sendText(raw, plainText(value), replacement);
}

// AppKit calls this during IME composition. Publish the semantic update first;
// only accepted input may replace the provisional document queried by AppKit.
fn setMarkedText(raw: Id, _: Sel, value: Id, selection: Range, replacement: Range) callconv(.c) void {
    const text = plainText(value);
    if (appkit.byteLength(text) > c.TELAR_GUI_TEXT_CAPACITY) {
        return;
    }

    const data = appkit.bytes(text);
    if (data.value == null) {
        return;
    }

    if (appkit.length(data.value) == 0) {
        cancelMarked(raw);
        return;
    }

    const input = state(raw);
    var event = eventFor(input, .composition);
    event.code = @intFromEnum(Composition.update);
    event.text = data.msgSend([*c]const u8, "bytes", .{});
    event.len = appkit.length(data.value);
    if (!ranges.utf8Range(text, selection, &event.selection_start, &event.selection_end)) {
        return;
    }

    const committed = committedRange(input, replacement);
    if (replacement.location != none.location and committed.location == none.location) {
        return;
    }

    if (committed.location != none.location and !ranges.utf8Range(input.surrounding, committed, &event.replacement_start, &event.replacement_end)) {
        return;
    }

    // Terminal content has no editable context, but still needs a provisional
    // native buffer until the IME commits its composed text.
    if (input.context.enabled != 0 and !send(raw, event)) {
        return;
    }

    if (committed.location != none.location) {
        input.marked_replacement = committed;
    } else if (appkit.length(input.marked) == 0) {
        input.marked_replacement = input.selection;
    }

    appkit.replace(&input.marked, Object.fromId(text).msgSend(Id, "copy", .{}));
    input.marked_selection = selection;
}

fn unmarkText(raw: Id, _: Sel) callconv(.c) void {
    const text = state(raw).marked;
    if (appkit.length(text) != 0) {
        _ = Object.fromId(text).retain();
        defer Object.fromId(text).release();
        sendText(raw, text, none);
    }
}

fn cancelMarked(raw: Id) void {
    const input = state(raw);
    if (appkit.length(input.marked) == 0) {
        return;
    }

    var event = eventFor(input, .composition);
    event.code = @intFromEnum(Composition.cancel);
    if (input.context.enabled != 0 and !send(raw, event)) {
        return;
    }

    clearMarked(input);
}

fn hasMarkedText(raw: Id, _: Sel) callconv(.c) bool {
    return appkit.length(state(raw).marked) != 0;
}

fn markedRange(raw: Id, _: Sel) callconv(.c) Range {
    const input = state(raw);
    const length = appkit.length(input.marked);
    return if (length != 0) .{ .location = input.marked_replacement.location, .length = length } else none;
}

fn selectedRange(raw: Id, _: Sel) callconv(.c) Range {
    const input = state(raw);
    return if (appkit.length(input.marked) != 0) .{ .location = input.marked_replacement.location + input.marked_selection.location, .length = input.marked_selection.length } else input.selection;
}

fn validAttributes(_: Id, _: Sel) callconv(.c) Id {
    return objc.getClass("NSArray").?.msgSend(Id, "array", .{});
}

fn attributedSubstring(raw: Id, _: Sel, requested: Range, actual: ?*Range) callconv(.c) Id {
    const document = inputDocument(state(raw));
    const length = appkit.length(document);
    if (requested.location == none.location or requested.location > length) {
        return null;
    }

    const selected: Range = .{ .location = requested.location, .length = @min(requested.length, length - requested.location) };
    if (actual) |output| {
        output.* = selected;
    }

    const text = Object.fromId(document).msgSend(Id, "substringWithRange:", .{selected});
    return appkit.autorelease(objc.getClass("NSAttributedString").?.msgSend(Object, "alloc", .{}).msgSend(Id, "initWithString:", .{text}));
}

fn characterIndex(raw: Id, selector: Sel, point: appkit.c.CGPoint) callconv(.c) usize {
    const selected = selectedRange(raw, selector);
    const caret = firstRect(raw, selector, selected, null);
    const margin = 2;
    return if (point.x >= caret.origin.x - margin and point.x < caret.origin.x + caret.size.width + margin and point.y >= caret.origin.y - margin and point.y < caret.origin.y + caret.size.height + margin) selected.location else none.location;
}

fn firstRect(raw: Id, selector: Sel, _: Range, actual: ?*Range) callconv(.c) appkit.c.CGRect {
    if (actual) |output| {
        output.* = selectedRange(raw, selector);
    }

    const context = state(raw).context;
    const caret = if (context.enabled != 0) ranges.contentRect(raw, context.x, context.y, context.width, context.height) else appkit.c.CGRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1, .height = 16 } };
    const view = Object.fromId(raw);
    const window_rect = view.msgSend(appkit.c.CGRect, "convertRect:toView:", .{ caret, @as(Id, null) });
    return view.msgSend(Object, "window", .{}).msgSend(appkit.c.CGRect, "convertRectToScreen:", .{window_rect});
}

fn command(raw: Id, _: Sel, selector: Sel) callconv(.c) void {
    const input = state(raw);
    if (selector == objc.sel("cancelOperation:").value and appkit.length(input.marked) != 0) {
        cancelMarked(raw);
        return;
    }

    const selectors = .{ "insertNewline:", "insertTab:", "deleteBackward:", "cancelOperation:", "moveUp:", "moveDown:", "moveLeft:", "moveRight:" };
    const codes = [_]Key{ .enter, .tab, .backspace, .escape, .up, .down, .left, .right };
    inline for (selectors, codes) |name, code| {
        if (selector == objc.sel(name).value) {
            var event = eventFor(input, .key);
            event.code = @intFromEnum(code);
            _ = send(raw, event);
            return;
        }
    }
}
