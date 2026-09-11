const ExportedType = @import("Exported.zig");
const std = @import("std");
const Record = @import("Record.zig");
const max_client_layout_clients_module = @import("telar-core").max_client_layout_clients;
const max_client_layout_tabs_module = @import("telar-core").max_client_layout_tabs;
const ClientTabLayoutType = @import("telar-core").ClientTabLayout;
const encodeClientLayoutUpdate_module = @import("telar-core").encodeClientLayoutUpdate;
const Update = @import("Update.zig");
const client_layout_store = @import("client_layout_store.zig");
const StoredTab = @import("StoredTab.zig");
const SnapshotQuery = @import("SnapshotQuery.zig");
const SnapshotStorage = @import("SnapshotStorage.zig");
const ClientLayoutSnapshotType = @import("telar-core").ClientLayoutSnapshot;
const ClientIdentityType = @import("telar-core").ClientIdentity;
const Store = @This();

gpa: ?std.mem.Allocator = null,
records: []Record = &.{},
clock: u64 = 0,

/// Preallocates every bounded record before the runtime loop starts.
///
/// ```zig
/// var store = try Store.init(gpa);
/// defer store.deinit();
/// ```
pub fn init(gpa: std.mem.Allocator) !Store {
    const records = try gpa.alloc(Record, max_client_layout_clients_module);
    for (records) |*record| {
        record.* = .{};
    }

    return .{ .gpa = gpa, .records = records };
}

/// Releases the preallocated terminal-record array.
///
/// ```zig
/// store.deinit();
/// ```
pub fn deinit(store: *Store) void {
    const gpa = store.gpa orelse return;
    gpa.free(store.records);
    store.* = .{};
}

pub const Exported = @import("Exported.zig");

/// Encodes the record at `index` as one `update_client_layout` request so
/// a checkpoint can replay it through `replace` on restore. Empty slots
/// yield null.
///
/// ```zig
/// var index: usize = 0;
/// while (index < store.capacity()) : (index += 1) {
///     const exported = try store.exportRecord(index, &buffer) orelse continue;
/// }
/// ```
pub fn exportRecord(store: *const Store, index: usize, buffer: []u8) !?ExportedType {
    const record = &store.records[index];
    if (record.identity == .invalid) {
        return null;
    }

    var tabs: [max_client_layout_tabs_module]ClientTabLayoutType = undefined;
    for (record.tabs[0..record.tab_count], 0..) |*tab, position| {
        tabs[position] = tab.schemaLayout();
    }

    return .{
        .identity = record.identity,
        .last_used = record.last_used,
        .payload = try encodeClientLayoutUpdate_module(buffer, .{
            .sidebar_visible = record.sidebar_visible,
            .sidebar_width = record.sidebar_width,
            .workspace_list_collapsed = record.workspace_list_collapsed,
            .active_tab = record.active_tab,
            .tabs = tabs[0..record.tab_count],
        }),
    };
}

pub fn capacity(store: *const Store) usize {
    return store.records.len;
}

/// Merges one terminal's current workspace into its retained snapshot
/// after checking every pane against authoritative runtime state.
///
/// ```zig
/// try store.replace(update);
/// ```
pub fn replace(store: *Store, update: Update) !void {
    if (update.identity == .invalid) {
        return error.InvalidClientIdentity;
    }

    var valid_count: usize = 0;
    var active_valid = false;
    var tabs = update.layout.tabs();
    while (try tabs.next()) |tab| {
        if (!client_layout_store.tabIsCurrent(tab, update.sources)) {
            if (std.meta.eql(tab.location, update.layout.active_tab)) {
                return;
            }

            continue;
        }

        valid_count += 1;
        active_valid = active_valid or std.meta.eql(tab.location, update.layout.active_tab);
    }

    if (!active_valid or valid_count == 0) {
        return;
    }

    const record = try store.acquire(update.identity);
    client_layout_store.prune(record, update.sources);
    record.sidebar_visible = update.layout.sidebar_visible;
    record.sidebar_width = update.layout.sidebar_width;
    record.workspace_list_collapsed = update.layout.workspace_list_collapsed;
    record.active_tab = update.layout.active_tab;
    tabs = update.layout.tabs();
    while (try tabs.next()) |tab| {
        if (!client_layout_store.tabIsCurrent(tab, update.sources)) {
            continue;
        }

        if (tab.workspace_active) {
            client_layout_store.clearWorkspaceActive(record, tab.location.workspace);
        }

        const stored = try StoredTab.copy(tab);
        if (client_layout_store.findTab(record, tab.location)) |index| {
            record.tabs[index] = stored;
        } else {
            std.debug.assert(record.tab_count < record.tabs.len);
            record.tabs[record.tab_count] = stored;
            record.tab_count += 1;
        }
    }
}

/// Returns a current runtime-filtered snapshot, or an explicit empty
/// result when this terminal has no safe state to restore.
///
/// ```zig
/// const snapshot = store.snapshot(query, &storage);
/// ```
pub fn snapshot(store: *Store, query: SnapshotQuery, storage: *SnapshotStorage) ClientLayoutSnapshotType {
    const record = store.find(query.identity) orelse return .{ .restored = false };
    store.touch(record);
    var tab_count: usize = 0;
    var active_valid = false;
    for (record.tabs[0..record.tab_count]) |*tab| {
        const layout = tab.schemaLayout();
        if (!client_layout_store.typedTabIsCurrent(layout, query.sources)) {
            continue;
        }

        storage.tabs[tab_count] = layout;
        tab_count += 1;
        active_valid = active_valid or std.meta.eql(tab.location, record.active_tab);
    }
    return .{
        .restored = true,
        .sidebar_visible = record.sidebar_visible,
        .sidebar_width = record.sidebar_width,
        .workspace_list_collapsed = record.workspace_list_collapsed,
        .active_tab = if (active_valid) record.active_tab else null,
        .tabs = storage.tabs[0..tab_count],
    };
}

fn acquire(store: *Store, identity: ClientIdentityType) !*Record {
    if (store.find(identity)) |record| {
        store.touch(record);
        return record;
    }

    if (store.gpa == null) {
        return error.ClientLayoutStoreUninitialized;
    }

    var selected: ?usize = null;
    var oldest: u64 = std.math.maxInt(u64);
    for (store.records, 0..) |*record, index| {
        if (record.identity == .invalid) {
            selected = index;
            break;
        }
        if (record.last_used < oldest) {
            oldest = record.last_used;
            selected = index;
        }
    }

    const index = selected orelse unreachable;
    const record = &store.records[index];
    record.* = .{
        .identity = identity,
    };
    store.touch(record);
    return record;
}

fn find(store: *Store, identity: ClientIdentityType) ?*Record {
    for (store.records) |*record| {
        if (record.identity == identity) {
            return record;
        }
    }

    return null;
}

fn touch(store: *Store, record: *Record) void {
    store.clock +%= 1;
    if (store.clock == 0) {
        store.clock = 1;
    }

    record.last_used = store.clock;
}
