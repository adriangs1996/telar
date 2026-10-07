const std = @import("std");
const native = @import("../native.zig");
const c = native.c;
const atk = @import("atk.zig");
const HostState = @import("../HostState.zig");
const Accessibility = @This();
const capacity = c.TELAR_GUI_ACCESSIBILITY_CAPACITY;
const action_capacity = c.TELAR_ACCESSIBLE_ACTION_CAPACITY;

host: *HostState,
bridge: c.telar_accessibility = std.mem.zeroes(c.telar_accessibility),
// SAFETY: pthread_create writes worker on success; init returns only then, and earlier failures never join it.
worker: c.pthread_t = undefined,
// SAFETY: pthread_mutex_init constructs lock before any locking or worker startup; its cleanup is registered only after success.
lock: c.pthread_mutex_t = undefined,
// SAFETY: pipe2 fills both descriptors before worker startup or closePipe registration; failure returns without reading them.
updates: [2]c_int = undefined,
// SAFETY: pipe2 fills both wake descriptors before worker startup or closePipe registration; failure returns without reading them.
actions_wake: [2]c_int = undefined,
stopping: std.atomic.Value(bool) = .init(false),
loop: *atk.MainLoop,
dirty: bool = false,
published_revision: ?u64 = null,
pending: c.struct_accessible_snapshot = std.mem.zeroes(c.struct_accessible_snapshot),
current: c.struct_accessible_snapshot = std.mem.zeroes(c.struct_accessible_snapshot),
// SAFETY: enqueue fills the action and its text before increasing action_count under lock; receive reads only queued actions.
actions: [action_capacity]c.struct_accessible_action = undefined,
action_start: usize = 0,
action_count: usize = 0,
action_admitted: bool = false,

/// Starts the AT-SPI worker with its own bounded handoff storage. Only that
/// worker accesses GObjects; the window publishes values and consumes actions.
pub fn init(host: *HostState) !*Accessibility {
    const self = try std.heap.c_allocator.create(Accessibility);
    errdefer std.heap.c_allocator.destroy(self);
    const loop = atk.g_main_loop_new(null, 0) orelse return error.AccessibilityInitializationFailed;
    errdefer atk.g_main_loop_unref(loop);
    self.* = .{ .host = host, .loop = loop };
    self.bridge.owner = self;
    if (c.pthread_mutex_init(&self.lock, null) != 0) {
        return error.AccessibilityInitializationFailed;
    }
    errdefer _ = c.pthread_mutex_destroy(&self.lock);
    if (c.pipe2(&self.updates, c.O_NONBLOCK | c.O_CLOEXEC) != 0) {
        return error.AccessibilityInitializationFailed;
    }
    errdefer closePipe(self.updates);
    if (c.pipe2(&self.actions_wake, c.O_NONBLOCK | c.O_CLOEXEC) != 0) {
        return error.AccessibilityInitializationFailed;
    }
    errdefer closePipe(self.actions_wake);
    if (c.pthread_create(&self.worker, null, run, self) != 0) {
        return error.AccessibilityInitializationFailed;
    }
    return self;
}

fn closePipe(fds: [2]c_int) void {
    for (fds) |fd| {
        _ = c.close(fd);
    }
}

fn wake(fd: c_int) void {
    while (c.write(fd, "w", 1) < 0 and c.__errno_location().* == c.EINTR) {}
}

fn drain(fd: c_int) void {
    var bytes: [64]u8 = undefined;
    while (c.read(fd, &bytes, bytes.len) > 0) {}
}

fn from(data: ?*anyopaque) *Accessibility {
    return @ptrCast(@alignCast(data.?));
}

// These two ABI entries serve GObject methods in accessible.c. They never
// enter GUI code; the worker reads its own tree and appends bounded actions.
export fn telar_accessibility_find(bridge: *c.telar_accessibility, id: u64) ?*c.AtkObject {
    if (id == 0) {
        return bridge.root;
    }
    for (bridge.objects[0..bridge.count]) |object| {
        if (c.telar_accessible_id(object) == id) {
            return object;
        }
    }
    return null;
}

export fn telar_accessibility_enqueue(bridge: *c.telar_accessibility, event: c.telar_gui_input) bool {
    const self = from(bridge.owner);
    if (event.len > c.TELAR_GUI_TEXT_CAPACITY or (event.len != 0 and (event.text == null or !std.unicode.utf8ValidateSlice(event.text[0..event.len])))) {
        return false;
    }
    _ = c.pthread_mutex_lock(&self.lock);
    defer _ = c.pthread_mutex_unlock(&self.lock);
    if (self.stopping.load(.acquire) or self.action_count == action_capacity) {
        return false;
    }
    const action = &self.actions[(self.action_start + self.action_count) % action_capacity];
    action.event = event;
    if (event.len != 0) {
        @memcpy(action.text[0..event.len], event.text[0..event.len]);
    }
    action.event.text = &action.text;
    self.action_count += 1;
    wake(self.actions_wake[1]);
    return true;
}

/// The window calls this after native dispatch. A queued worker action remains
/// reserved until copied into HostState; pressure retries without spinning poll.
pub fn receive(self: *Accessibility) void {
    for (0..action_capacity) |_| {
        if (c.pthread_mutex_trylock(&self.lock) != 0) {
            return;
        }
        if (self.action_admitted) {
            self.action_start = (self.action_start + 1) % action_capacity;
            self.action_count -= 1;
            self.action_admitted = false;
        }
        if (self.action_count == 0) {
            drain(self.actions_wake[0]);
            _ = c.pthread_mutex_unlock(&self.lock);
            return;
        }
        const event = self.actions[self.action_start].event;
        _ = c.pthread_mutex_unlock(&self.lock);
        if (!self.host.receive(event)) {
            drain(self.actions_wake[0]);
            return;
        }
        self.action_admitted = true;
    }
}

pub fn valid(tree: c.telar_gui_accessibility_tree) bool {
    if (tree.count > capacity or (tree.count != 0 and tree.nodes == null)) {
        return false;
    }
    for ((if (tree.count == 0) &[_]c.telar_gui_accessibility_node{} else tree.nodes[0..tree.count]), 0..) |node, index| {
        if (node.id == 0 or node.label_len > c.TELAR_ACCESSIBLE_LABEL_CAPACITY or node.value_len > c.TELAR_GUI_TEXT_CAPACITY) {
            return false;
        }
        if ((node.label_len != 0 and (node.label == null or !std.unicode.utf8ValidateSlice(node.label[0..node.label_len]))) or (node.value_len != 0 and (node.value == null or !std.unicode.utf8ValidateSlice(node.value[0..node.value_len])))) {
            return false;
        }
        if (!std.math.isFinite(node.x) or !std.math.isFinite(node.y) or !std.math.isFinite(node.width) or !std.math.isFinite(node.height) or node.width < 0 or node.height < 0) {
            return false;
        }
        if (node.selection_start > node.value_len or node.selection_end > node.value_len) {
            return false;
        }
        for ([_]u32{ node.selection_start, node.selection_end }) |offset| {
            if (offset < node.value_len and node.value[offset] & 0xc0 == 0x80) {
                return false;
            }
        }
        var parent_found = node.parent_id == 0;
        for (tree.nodes[0..index]) |previous| {
            if (previous.id == node.id) {
                return false;
            }
            parent_found = parent_found or previous.id == node.parent_id;
        }
        if (!parent_found) {
            return false;
        }
    }
    return true;
}

/// Publish the newest revision without waiting for the worker. The worker wakes
/// the window after consuming a snapshot, so a busy handoff is retried once idle.
pub fn publish(self: *Accessibility) void {
    const tree = self.host.tree;
    if (self.published_revision == tree.revision or !valid(tree) or c.pthread_mutex_trylock(&self.lock) != 0) {
        return;
    }
    self.pending.count = tree.count;
    self.pending.revision = tree.revision;
    for ((if (tree.count == 0) &[_]c.telar_gui_accessibility_node{} else tree.nodes[0..tree.count]), 0..) |node, index| {
        const destination = &self.pending.nodes[index];
        destination.value = node;
        if (node.label_len != 0) {
            @memcpy(@as([*]u8, @ptrCast(&destination.label))[0..node.label_len], node.label[0..node.label_len]);
        }
        destination.label[node.label_len] = 0;
        if (node.value_len != 0) {
            @memcpy(@as([*]u8, @ptrCast(&destination.text))[0..node.value_len], node.value[0..node.value_len]);
        }
        destination.text[node.value_len] = 0;
    }
    self.dirty = true;
    self.published_revision = tree.revision;
    _ = c.pthread_mutex_unlock(&self.lock);
    wake(self.updates[1]);
}

fn reconcile(self: *Accessibility) void {
    const previous = self.bridge.objects;
    const previous_count = self.bridge.count;
    var replacement: [capacity]?*c.AtkObject = @splat(null);
    var retained: [capacity]bool = @splat(false);
    var topology_changed = previous_count != self.current.count;
    for (self.current.nodes[0..self.current.count], 0..) |node, index| {
        if (topology_changed) {
            break;
        }
        topology_changed = !c.telar_accessible_matches(previous[index], &node.value) or c.telar_accessible_id(atk.atk_object_get_parent(previous[index])) != node.value.parent_id;
    }
    if (topology_changed) {
        var count = atk.atk_object_get_n_accessible_children(self.bridge.root);
        while (count > 0) {
            count -= 1;
            const child = atk.atk_object_ref_accessible_child(self.bridge.root, count);
            atk.g_signal_emit_by_name(self.bridge.root, "children-changed::remove", count, child, @as(?*anyopaque, null));
            atk.g_object_unref(child);
        }
    }
    for (self.current.nodes[0..self.current.count], 0..) |*node, index| {
        node.value.label = @ptrCast(&node.label);
        node.value.value = @ptrCast(&node.text);
        for (previous[0..previous_count], 0..) |object, old| {
            if (!retained[old] and c.telar_accessible_matches(object, &node.value)) {
                replacement[index] = object;
                retained[old] = true;
                break;
            }
        }
        if (replacement[index] == null) {
            replacement[index] = c.telar_accessible_new(&self.bridge, &node.value);
        }
    }
    self.bridge.objects = replacement;
    self.bridge.count = self.current.count;
    for (previous[0..previous_count], 0..) |object, index| {
        if (!retained[index]) {
            c.telar_accessible_detach(object);
            atk.g_object_unref(object);
        }
    }
    for (self.bridge.objects[0..self.bridge.count], 0..) |object, index| {
        c.telar_accessible_update(object, &self.current.nodes[index].value);
    }
    if (topology_changed) {
        const count = atk.atk_object_get_n_accessible_children(self.bridge.root);
        var index: c_int = 0;
        while (index < count) : (index += 1) {
            const child = atk.atk_object_ref_accessible_child(self.bridge.root, index);
            atk.g_signal_emit_by_name(self.bridge.root, "children-changed::add", index, child, @as(?*anyopaque, null));
            atk.g_object_unref(child);
        }
    }
    atk.g_signal_emit_by_name(self.bridge.root, "visible-data-changed");
}

fn updated(fd: c_int, _: c_int, data: ?*anyopaque) callconv(.c) c_int {
    const self = from(data);
    drain(fd);
    if (self.stopping.load(.acquire)) {
        atk.g_main_loop_quit(self.loop);
        return atk.source_continue;
    }
    _ = c.pthread_mutex_lock(&self.lock);
    const dirty = self.dirty;
    if (dirty) {
        self.current = self.pending;
    }
    self.dirty = false;
    _ = c.pthread_mutex_unlock(&self.lock);
    if (dirty) {
        self.reconcile();
    }
    wake(self.actions_wake[1]);
    return atk.source_continue;
}

fn run(data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const self = from(data);
    self.bridge.root = c.telar_accessible_new(&self.bridge, null);
    const initialized = c.telar_accessible_start(&self.bridge);
    const source = atk.g_unix_fd_source_new(self.updates[0], c.POLLIN);
    atk.g_source_set_callback(source, @ptrCast(&updated), self, null);
    _ = atk.g_source_attach(source, null);
    if (!self.stopping.load(.acquire)) {
        atk.g_main_loop_run(self.loop);
    }
    atk.g_source_destroy(source);
    atk.g_source_unref(source);
    if (initialized) {
        atk.atk_bridge_adaptor_cleanup();
    }
    // Empty the visible tree before synchronous GObject retirement notifications.
    const retired = self.bridge.objects;
    const count = self.bridge.count;
    self.bridge.objects = @splat(null);
    self.bridge.count = 0;
    for (retired[0..count]) |object| {
        c.telar_accessible_detach(object);
        atk.g_object_unref(object);
    }
    c.telar_accessible_detach(self.bridge.root);
    atk.g_object_unref(self.bridge.root);
    self.bridge.root = null;
    c.telar_accessible_stop();
    return null;
}

pub fn deinit(self: *Accessibility) void {
    self.stopping.store(true, .release);
    wake(self.updates[1]);
    _ = c.pthread_join(self.worker, null);
    atk.g_main_loop_unref(self.loop);
    closePipe(self.updates);
    closePipe(self.actions_wake);
    _ = c.pthread_mutex_destroy(&self.lock);
    std.heap.c_allocator.destroy(self);
}

extern "c" fn telar_test_accessible_interfaces(bridge: *c.telar_accessibility) void;
extern "c" fn telar_test_accessible_retired(object: ?*c.AtkObject) void;
extern "c" fn g_object_ref(object: ?*anyopaque) ?*anyopaque;
