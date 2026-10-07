const std = @import("std");
const objc = @import("objc");
const native = @import("../native.zig");
const appkit = @import("appkit.zig");
const input_receiver = @import("InputReceiver.zig");
const InputReceiver = input_receiver.InputReceiver;
const ranges = @import("text_ranges.zig");
const ns_range = @import("Range.zig");
const Range = ns_range.Range;
const action = @import("../input/AccessibilityAction.zig");
const Action = action.Action;
const c = native.c;
const Id = objc.c.id;
const Sel = objc.c.SEL;
const Object = objc.Object;
const Role = enum(u32) { group = 1, button = 2, text_field = 3, label = 4, tab = 5, list = 6, list_item = 7, terminal = 8 };
const Flag = enum(u32) { enabled = 1, focused = 2, selected = 4, editable = 8, multiline = 16, modal = 32 };
const Kind = enum(u32) { accessibility = 10 };
const Phase = enum(u32) { press = 1 };

extern "c" var NSAccessibilityGroupRole: Id;
extern "c" var NSAccessibilityButtonRole: Id;
extern "c" var NSAccessibilityTextAreaRole: Id;
extern "c" var NSAccessibilityTextFieldRole: Id;
extern "c" var NSAccessibilityStaticTextRole: Id;
extern "c" var NSAccessibilityRadioButtonRole: Id;
extern "c" var NSAccessibilityListRole: Id;
extern "c" var NSAccessibilityRowRole: Id;
extern "c" var NSAccessibilityLayoutChangedNotification: Id;
extern "c" var NSAccessibilityValueChangedNotification: Id;
extern "c" var NSAccessibilitySelectedTextChangedNotification: Id;
extern "c" var NSAccessibilityFocusedUIElementChangedNotification: Id;
extern "c" fn NSAccessibilityPostNotification(element: Id, notification: Id) void;

// AppKit may retain elements after a snapshot is replaced or the window closes.
// Weak parent/bridge references and explicit retirement make such objects inert.
const Node = struct {
    bridge: Id = null,
    parent: Id = null,
    children: Id = null,
    label: Id = null,
    value: Id = null,
    semantic: c.telar_gui_accessibility_node = std.mem.zeroes(c.telar_gui_accessibility_node),
    active: bool = false,
};
const Accessibility = struct {
    view: Id = null,
    receiver: ?InputReceiver = null,
    elements: Id = null,
    roots: Id = null,
    revision: ?u64 = null,
    closed: bool = false,
};
var bridge_offset: usize = 0;
var node_offset: usize = 0;
var installed = false;

/// Register the NSAccessibilityElement methods that AppKit invokes, plus the
/// tree publisher used by the remaining native canvas. Called once before views.
pub fn install() !void {
    if (installed) {
        return;
    }

    const node_class = objc.allocateClassPair(objc.getClass("NSAccessibilityElement").?, "TelarAccessibilityNode") orelse return error.NativeClassRegistrationFailed;
    errdefer objc.disposeClassPair(node_class);
    node_offset = try appkit.addStorage(node_class, "telar_state");
    try appkit.method(node_class, "init", nodeInitialize);
    try appkit.method(node_class, "dealloc", nodeDeallocate);
    try appkit.method(node_class, "isAccessibilityElement", isElement);
    try appkit.method(node_class, "accessibilityParent", parent);
    try appkit.method(node_class, "accessibilityChildren", children);
    try appkit.method(node_class, "accessibilityLabel", label);
    try appkit.method(node_class, "accessibilityValue", value);
    try appkit.method(node_class, "isAccessibilityEnabled", enabled);
    try appkit.method(node_class, "isAccessibilityFocused", focused);
    try appkit.method(node_class, "isAccessibilitySelected", selected);
    try appkit.method(node_class, "isAccessibilityModal", modal);
    try appkit.method(node_class, "accessibilityNumberOfCharacters", characterCount);
    try appkit.method(node_class, "accessibilityRole", role);
    try appkit.method(node_class, "accessibilityFrame", frame);
    try appkit.method(node_class, "accessibilitySelectedTextRange", selectedRange);
    try appkit.method(node_class, "accessibilitySelectedText", selectedText);
    try appkit.method(node_class, "accessibilityStringForRange:", stringForRange);
    try appkit.method(node_class, "accessibilityPerformPress", press);
    try appkit.method(node_class, "accessibilityPerformIncrement", increment);
    try appkit.method(node_class, "accessibilityPerformDecrement", decrement);
    try appkit.method(node_class, "setAccessibilityFocused:", setFocused);
    try appkit.method(node_class, "setAccessibilityValue:", setValue);
    try appkit.method(node_class, "setAccessibilitySelectedTextRange:", setSelectedRange);
    try appkit.method(node_class, "isAccessibilitySelectorAllowed:", selectorAllowed);

    const class = objc.allocateClassPair(objc.getClass("NSObject").?, "TelarAccessibility") orelse return error.NativeClassRegistrationFailed;
    errdefer objc.disposeClassPair(class);
    bridge_offset = try appkit.addStorage(class, "telar_state");
    try appkit.method(class, "initWithView:receiver:", initialize);
    try appkit.method(class, "dealloc", deallocate);
    try appkit.method(class, "setTree:", setTree);
    try appkit.method(class, "children", roots);
    try appkit.method(class, "focusedElement", focusedElement);
    try appkit.method(class, "hitTest:", hitTest);
    try appkit.method(class, "stop", stop);
    objc.registerClassPair(node_class);
    objc.registerClassPair(class);
    installed = true;
}

fn node(raw: Id) *Node {
    return appkit.storage(Node, raw, node_offset).*.?;
}

fn bridge(raw: Id) *Accessibility {
    return appkit.storage(Accessibility, raw, bridge_offset).*.?;
}

fn array() Object {
    return objc.getClass("NSMutableArray").?.msgSend(Object, "array", .{});
}

fn dictionary() Object {
    return objc.getClass("NSMutableDictionary").?.msgSend(Object, "dictionary", .{});
}

fn at(collection: Id, index: usize) Id {
    return Object.fromId(collection).msgSend(Id, "objectAtIndex:", .{index});
}

fn count(collection: Id) usize {
    return Object.fromId(collection).msgSend(usize, "count", .{});
}

fn key(id: u64) Id {
    return objc.getClass("NSNumber").?.msgSend(Id, "numberWithUnsignedLongLong:", .{id});
}

fn find(elements: Id, id: u64) Id {
    return Object.fromId(elements).msgSend(Id, "objectForKey:", .{key(id)});
}

fn nodeInitialize(raw: Id, _: Sel) callconv(.c) Id {
    const result = Object.fromId(raw).msgSendSuper(objc.getClass("NSAccessibilityElement").?, Id, "init", .{});
    if (result == null) {
        return null;
    }

    const state = std.heap.c_allocator.create(Node) catch {
        Object.fromId(result).release();
        return null;
    };
    state.* = .{};
    appkit.storage(Node, result, node_offset).* = state;
    return result;
}

fn nodeDeallocate(raw: Id, _: Sel) callconv(.c) void {
    if (appkit.storage(Node, raw, node_offset).*) |state| {
        appkit.objc_destroyWeak(&state.bridge);
        appkit.objc_destroyWeak(&state.parent);
        Object.fromId(state.children).release();
        Object.fromId(state.label).release();
        Object.fromId(state.value).release();
        std.heap.c_allocator.destroy(state);
        appkit.storage(Node, raw, node_offset).* = null;
    }

    Object.fromId(raw).msgSendSuper(objc.getClass("NSAccessibilityElement").?, void, "dealloc", .{});
}

fn initialize(raw: Id, _: Sel, view: Id, receiver: InputReceiver) callconv(.c) Id {
    const result = Object.fromId(raw).msgSendSuper(objc.getClass("NSObject").?, Id, "init", .{});
    if (result == null) {
        return null;
    }

    const state = std.heap.c_allocator.create(Accessibility) catch {
        Object.fromId(result).release();
        return null;
    };
    state.* = .{
        .receiver = receiver,
        .elements = dictionary().retain().value,
        .roots = array().retain().value,
    };
    _ = appkit.objc_storeWeak(&state.view, view);
    appkit.storage(Accessibility, result, bridge_offset).* = state;
    return result;
}

fn deallocate(raw: Id, selector: Sel) callconv(.c) void {
    if (appkit.storage(Accessibility, raw, bridge_offset).*) |state| {
        stop(raw, selector);
        appkit.objc_destroyWeak(&state.view);
        Object.fromId(state.roots).release();
        Object.fromId(state.elements).release();
        std.heap.c_allocator.destroy(state);
        appkit.storage(Accessibility, raw, bridge_offset).* = null;
    }

    Object.fromId(raw).msgSendSuper(objc.getClass("NSObject").?, void, "dealloc", .{});
}

fn hasFlag(state: *const Node, flag: Flag) bool {
    return state.semantic.flags & @intFromEnum(flag) != 0;
}

fn isElement(raw: Id, _: Sel) callconv(.c) bool {
    return node(raw).active;
}

fn parent(raw: Id, _: Sel) callconv(.c) Id {
    return appkit.objc_loadWeak(&node(raw).parent);
}

fn children(raw: Id, _: Sel) callconv(.c) Id {
    return node(raw).children;
}

fn label(raw: Id, _: Sel) callconv(.c) Id {
    return node(raw).label;
}

fn value(raw: Id, _: Sel) callconv(.c) Id {
    const state = node(raw);
    return if (state.semantic.role == @intFromEnum(Role.tab)) objc.getClass("NSNumber").?.msgSend(Id, "numberWithBool:", .{hasFlag(state, .selected)}) else state.value;
}

fn enabled(raw: Id, _: Sel) callconv(.c) bool {
    return node(raw).active and hasFlag(node(raw), .enabled);
}

fn focused(raw: Id, _: Sel) callconv(.c) bool {
    return node(raw).active and hasFlag(node(raw), .focused);
}

fn selected(raw: Id, _: Sel) callconv(.c) bool {
    return hasFlag(node(raw), .selected);
}

fn modal(raw: Id, _: Sel) callconv(.c) bool {
    return hasFlag(node(raw), .modal);
}

fn characterCount(raw: Id, _: Sel) callconv(.c) isize {
    return @intCast(appkit.length(node(raw).value));
}

fn role(raw: Id, _: Sel) callconv(.c) Id {
    const state = node(raw);
    return switch (std.enums.fromInt(Role, state.semantic.role) orelse .group) {
        .button => NSAccessibilityButtonRole,
        .text_field => if (hasFlag(state, .multiline)) NSAccessibilityTextAreaRole else NSAccessibilityTextFieldRole,
        .label => NSAccessibilityStaticTextRole,
        .tab => NSAccessibilityRadioButtonRole,
        .list => NSAccessibilityListRole,
        .list_item => NSAccessibilityRowRole,
        .terminal => NSAccessibilityTextAreaRole,
        .group => NSAccessibilityGroupRole,
    };
}

fn frame(raw: Id, _: Sel) callconv(.c) appkit.c.CGRect {
    const state = node(raw);
    const owner = appkit.objc_loadWeak(&state.bridge);
    if (owner == null or !state.active) {
        return std.mem.zeroes(appkit.c.CGRect);
    }

    const view = Object.fromId(appkit.objc_loadWeak(&bridge(owner).view));
    if (view.value == null) {
        return std.mem.zeroes(appkit.c.CGRect);
    }

    const semantic = state.semantic;
    const rect = ranges.contentRect(view.value, semantic.x, semantic.y, semantic.width, semantic.height);
    const window_rect = view.msgSend(appkit.c.CGRect, "convertRect:toView:", .{ rect, @as(Id, null) });
    return view.msgSend(Object, "window", .{}).msgSend(appkit.c.CGRect, "convertRectToScreen:", .{window_rect});
}

fn selectedRange(raw: Id, _: Sel) callconv(.c) Range {
    const state = node(raw);
    return ranges.utf16Range(state.value, state.semantic.selection_start, state.semantic.selection_end);
}

fn selectedText(raw: Id, selector: Sel) callconv(.c) Id {
    const selection = selectedRange(raw, selector);
    if (selection.location == std.math.maxInt(isize)) {
        return appkit.autorelease(appkit.string(null, 0));
    }

    return Object.fromId(node(raw).value).msgSend(Id, "substringWithRange:", .{selection});
}

fn stringForRange(raw: Id, _: Sel, selection: Range) callconv(.c) Id {
    const text = node(raw).value;
    const length = appkit.length(text);
    if (selection.location > length or selection.length > length - selection.location) {
        return null;
    }

    return Object.fromId(text).msgSend(Id, "substringWithRange:", .{selection});
}

// AppKit actions target the exact delivered node generation and text revision.
// Removed nodes remain callable if held by assistive software, but admit nothing.
fn dispatch(raw: Id, requested: Action, text: Id, selection: Range) bool {
    const state = node(raw);
    const owner = appkit.objc_loadWeak(&state.bridge);
    if (!state.active or !hasFlag(state, .enabled) or state.semantic.actions & @intFromEnum(requested) == 0 or owner == null) {
        return false;
    }

    const publisher = bridge(owner);
    if (publisher.closed) {
        return false;
    }

    var event = std.mem.zeroInit(c.telar_gui_input, .{
        .kind = @intFromEnum(Kind.accessibility),
        .code = @intFromEnum(requested),
        .phase = @intFromEnum(Phase.press),
        .target_id = state.semantic.id,
        .generation = state.semantic.generation,
        .revision = state.semantic.text_revision,
        .text = Object.fromId(text).msgSend([*c]const u8, "bytes", .{}),
        .len = appkit.length(text),
    });
    if (requested == .set_selection and !ranges.utf8Range(state.value, selection, &event.selection_start, &event.selection_end)) {
        return false;
    }

    return appkit.send(publisher.receiver, event);
}

fn press(raw: Id, _: Sel) callconv(.c) bool {
    return dispatch(raw, .press, null, .{});
}

fn increment(raw: Id, _: Sel) callconv(.c) bool {
    return dispatch(raw, .increment, null, .{});
}

fn decrement(raw: Id, _: Sel) callconv(.c) bool {
    return dispatch(raw, .decrement, null, .{});
}

fn setFocused(raw: Id, _: Sel, focus: bool) callconv(.c) void {
    if (focus) {
        _ = dispatch(raw, .focus, null, .{});
    }
}

fn setValue(raw: Id, _: Sel, text: Id) callconv(.c) void {
    if (!Object.fromId(text).msgSend(bool, "isKindOfClass:", .{objc.getClass("NSString").?}) or appkit.byteLength(text) > c.TELAR_GUI_TEXT_CAPACITY) {
        return;
    }

    const bytes = appkit.bytes(text);
    if (bytes.value != null) {
        _ = dispatch(raw, .set_value, bytes.value, .{});
    }
}

fn setSelectedRange(raw: Id, _: Sel, selection: Range) callconv(.c) void {
    _ = dispatch(raw, .set_selection, null, selection);
}

fn selectorAllowed(raw: Id, _: Sel, selector: Sel) callconv(.c) bool {
    const names = .{ "accessibilityPerformPress", "setAccessibilityFocused:", "setAccessibilityValue:", "setAccessibilitySelectedTextRange:", "accessibilityPerformIncrement", "accessibilityPerformDecrement" };
    const actions = [_]Action{ .press, .focus, .set_value, .set_selection, .increment, .decrement };
    inline for (names, actions) |name, allowed| {
        if (selector == objc.sel(name).value) {
            return node(raw).semantic.actions & @intFromEnum(allowed) != 0;
        }
    }

    return Object.fromId(raw).msgSendSuper(objc.getClass("NSAccessibilityElement").?, bool, "isAccessibilitySelectorAllowed:", .{selector});
}

fn validTree(tree: c.telar_gui_accessibility_tree) bool {
    if (tree.count > c.TELAR_GUI_ACCESSIBILITY_CAPACITY or (tree.count != 0 and tree.nodes == null)) {
        return false;
    }

    var index: usize = 0;
    while (index < tree.count) : (index += 1) {
        const semantic = tree.nodes[index];
        if (semantic.id == 0 or std.enums.fromInt(Role, semantic.role) == null or semantic.label_len > c.TELAR_GUI_TEXT_CAPACITY or semantic.value_len > c.TELAR_GUI_TEXT_CAPACITY or
            (semantic.label_len != 0 and semantic.label == null) or (semantic.value_len != 0 and semantic.value == null) or
            !std.math.isFinite(semantic.x) or !std.math.isFinite(semantic.y) or !std.math.isFinite(semantic.width) or !std.math.isFinite(semantic.height) or semantic.width < 0 or semantic.height < 0)
        {
            return false;
        }

        for (tree.nodes[0..index]) |previous| {
            if (previous.id == semantic.id) {
                return false;
            }
        }

        var parent_id = semantic.parent_id;
        var depth: usize = 0;
        while (parent_id != 0) : (depth += 1) {
            if (depth >= tree.count or parent_id == semantic.id) {
                return false;
            }

            var found = false;
            for (tree.nodes[0..tree.count]) |candidate| {
                if (candidate.id == parent_id) {
                    parent_id = candidate.parent_id;
                    found = true;
                    break;
                }
            }

            if (!found) {
                return false;
            }
        }
    }

    return true;
}

// Build and validate the bounded native mirror before changing visible nodes.
// Strings and hierarchy are owned; no pointers into the borrowed snapshot survive.
fn setTree(raw: Id, selector: Sel, tree: c.telar_gui_accessibility_tree) callconv(.c) void {
    const state = bridge(raw);
    if (state.closed or (state.revision == tree.revision and tree.count == count(state.elements)) or !validTree(tree)) {
        return;
    }

    const labels = array();
    const values = array();
    const replacement = dictionary();
    var index: usize = 0;
    while (index < tree.count) : (index += 1) {
        const semantic = tree.nodes[index];
        const label_text = appkit.string(semantic.label, semantic.label_len);
        defer Object.fromId(label_text).release();
        const value_text = appkit.string(semantic.value, semantic.value_len);
        defer Object.fromId(value_text).release();
        if (label_text == null or value_text == null) {
            return;
        }

        labels.msgSend(void, "addObject:", .{label_text});
        values.msgSend(void, "addObject:", .{value_text});
        var element = find(state.elements, semantic.id);
        if (element == null or node(element).semantic.generation != semantic.generation) {
            element = appkit.autorelease(objc.getClass("TelarAccessibilityNode").?.msgSend(Id, "new", .{}));
            if (element == null) {
                return;
            }
        }

        replacement.msgSend(void, "setObject:forKey:", .{ element, key(semantic.id) });
    }

    const previous_focus = Object.fromId(focusedElement(raw, selector)).retain();
    defer previous_focus.release();
    const changed_values = array();
    const changed_selections = array();
    const view = appkit.objc_loadWeak(&state.view);
    index = 0;
    while (index < tree.count) : (index += 1) {
        var semantic = tree.nodes[index];
        const element = find(replacement.value, semantic.id);
        const current = node(element);
        if (current.active) {
            if (!Object.fromId(current.value).msgSend(bool, "isEqualToString:", .{at(values.value, index)}) or (current.semantic.flags ^ semantic.flags) & @intFromEnum(Flag.selected) != 0) {
                changed_values.msgSend(void, "addObject:", .{element});
            }

            if (current.semantic.selection_start != semantic.selection_start or current.semantic.selection_end != semantic.selection_end) {
                changed_selections.msgSend(void, "addObject:", .{element});
            }
        }

        _ = appkit.objc_storeWeak(&current.bridge, raw);
        current.active = true;
        appkit.replace(&current.label, Object.fromId(at(labels.value, index)).retain().value);
        appkit.replace(&current.value, Object.fromId(at(values.value, index)).retain().value);
        semantic.label = null;
        semantic.value = null;
        current.semantic = semantic;
        appkit.replace(&current.children, array().retain().value);
    }

    const top = array();
    index = 0;
    while (index < tree.count) : (index += 1) {
        const element = find(replacement.value, tree.nodes[index].id);
        const current = node(element);
        const parent_element = find(replacement.value, current.semantic.parent_id);
        _ = appkit.objc_storeWeak(&current.parent, if (parent_element != null) parent_element else view);
        const semantic = current.semantic;
        var rect = ranges.contentRect(view, semantic.x, semantic.y, semantic.width, semantic.height);
        if (parent_element != null) {
            const parent_node = node(parent_element);
            const parent_semantic = parent_node.semantic;
            const parent_rect = ranges.contentRect(view, parent_semantic.x, parent_semantic.y, parent_semantic.width, parent_semantic.height);
            rect.origin.x -= parent_rect.origin.x;
            rect.origin.y -= parent_rect.origin.y;
            Object.fromId(parent_node.children).msgSend(void, "addObject:", .{element});
        } else {
            top.msgSend(void, "addObject:", .{element});
        }

        Object.fromId(element).msgSend(void, "setAccessibilityFrameInParentSpace:", .{rect});
    }

    const previous = Object.fromId(state.elements).msgSend(Id, "allValues", .{});
    for (0..count(previous)) |slot| {
        const element = at(previous, slot);
        if (find(replacement.value, node(element).semantic.id) != element) {
            retire(element);
        }
    }

    appkit.replace(&state.elements, replacement.retain().value);
    appkit.replace(&state.roots, top.retain().value);
    state.revision = tree.revision;
    NSAccessibilityPostNotification(view, NSAccessibilityLayoutChangedNotification);
    for (0..count(changed_values.value)) |slot| {
        NSAccessibilityPostNotification(at(changed_values.value, slot), NSAccessibilityValueChangedNotification);
    }

    for (0..count(changed_selections.value)) |slot| {
        NSAccessibilityPostNotification(at(changed_selections.value, slot), NSAccessibilitySelectedTextChangedNotification);
    }

    const focus = focusedElement(raw, selector);
    if (focus != null and focus != previous_focus.value) {
        NSAccessibilityPostNotification(focus, NSAccessibilityFocusedUIElementChangedNotification);
    }
}

fn roots(raw: Id, _: Sel) callconv(.c) Id {
    return bridge(raw).roots;
}

fn focusedElement(raw: Id, _: Sel) callconv(.c) Id {
    const elements = Object.fromId(bridge(raw).elements).msgSend(Id, "allValues", .{});
    for (0..count(elements)) |index| {
        const element = at(elements, index);
        if (node(element).active and hasFlag(node(element), .focused)) {
            return element;
        }
    }

    return null;
}

fn nodeAt(raw: Id, point: appkit.c.CGPoint) Id {
    if (!node(raw).active) {
        return null;
    }

    const rect = frame(raw, objc.sel("accessibilityFrame").value);
    if (point.x < rect.origin.x or point.y < rect.origin.y or point.x >= rect.origin.x + rect.size.width or point.y >= rect.origin.y + rect.size.height) {
        return null;
    }

    const descendants = node(raw).children;
    var index = count(descendants);
    while (index != 0) {
        index -= 1;
        const found = nodeAt(at(descendants, index), point);
        if (found != null) {
            return found;
        }
    }

    return raw;
}

fn hitTest(raw: Id, _: Sel, point: appkit.c.CGPoint) callconv(.c) Id {
    const top = bridge(raw).roots;
    var index = count(top);
    while (index != 0) {
        index -= 1;
        const found = nodeAt(at(top, index), point);
        if (found != null) {
            return found;
        }
    }

    return null;
}

fn retire(raw: Id) void {
    const state = node(raw);
    state.active = false;
    _ = appkit.objc_storeWeak(&state.bridge, null);
    _ = appkit.objc_storeWeak(&state.parent, null);
    appkit.replace(&state.children, null);
}

fn stop(raw: Id, _: Sel) callconv(.c) void {
    const state = bridge(raw);
    state.closed = true;
    const elements = Object.fromId(state.elements).msgSend(Id, "allValues", .{});
    for (0..count(elements)) |index| {
        retire(at(elements, index));
    }

    appkit.replace(&state.elements, null);
    appkit.replace(&state.roots, null);
    state.receiver = null;
    _ = appkit.objc_storeWeak(&state.view, null);
}
