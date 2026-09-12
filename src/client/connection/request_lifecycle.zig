//! Owns one client's bounded request identities and reply correlations.

const Client = @import("../AttachedClient.zig");
const RequestIdType = @import("telar-core").RequestId;
const initial_request_id = @import("lifecycle.zig").initial_request_id;
const GroupType = @import("requests.zig").Group;
const PaneIdType = @import("telar-core").PaneId;
const Registration = @import("Registration.zig");
const ContinuationType = @import("requests.zig").Continuation;
const Delivery = @import("ConnectionDelivery.zig");
const runtime_transport = @import("../entrypoints/runtime_io.zig");
const RenameTabType = @import("telar-core").RenameTab;
const RenameWorkspaceType = @import("telar-core").RenameWorkspace;
const CreateWorkspaceType = @import("telar-core").CreateWorkspace;
const CreateTabType = @import("telar-core").CreateTab;
const ShowNotificationType = @import("telar-core").ShowNotification;
const TabLocationType = @import("telar-core").TabLocation;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const TabIdType = @import("telar-core").TabId;
const LifecycleState = @import("LifecycleState.zig");
const std = @import("std");
const TrackerType = @import("Tracker.zig");

/// Registers the fixed bootstrap continuation before its synchronous open
/// request leaves the client.
///
/// ```zig
/// const request_id = try request_lifecycle.registerInitial(client);
/// ```
pub fn registerInitial(client: *Client) !RequestIdType {
    try register(client, .{
        .request_id = initial_request_id,
        .continuation = .{ .initial_open = .{} },
    });

    return initial_request_id;
}

/// Allocates one identity from this client's request lifecycle.
///
/// ```zig
/// const request_id = try request_lifecycle.nextId(client);
/// ```
pub fn nextId(client: *Client) !RequestIdType {
    return client.request_lifecycle.nextId();
}

/// Preflights one correlation slot and the identities required by an
/// operation and its synchronous recovery path.
///
/// ```zig
/// try request_lifecycle.ensureCanStart(client, 2);
/// ```
pub fn ensureCanStart(client: *const Client, id_count: u64) !void {
    try client.request_lifecycle.ensureCanStart(id_count);
}

/// Reports whether this client has any response correlation in flight.
///
/// ```zig
/// if (request_lifecycle.busy(client)) {
///     return;
/// }
/// ```
pub fn busy(client: *const Client) bool {
    return !client.request_lifecycle.tracker.isEmpty();
}

/// Reports whether a semantic request group already has a continuation.
///
/// ```zig
/// if (request_lifecycle.has(client, .tab_snapshot)) {
///     return;
/// }
/// ```
pub fn has(client: *const Client, group: GroupType) bool {
    return client.request_lifecycle.tracker.has(group);
}

/// Reports whether one pane already owns a continuation in a request group.
///
/// ```zig
/// if (request_lifecycle.hasPane(client, .attachment, pane_id)) {
///     return;
/// }
/// ```
pub fn hasPane(client: *const Client, group: GroupType, pane_id: PaneIdType) bool {
    return client.request_lifecycle.tracker.hasPane(group, pane_id);
}

/// Registers an externally assigned identity, used by bootstrap and protocol
/// contract tests.
///
/// ```zig
/// try request_lifecycle.register(client, registration);
/// ```
pub fn register(client: *Client, registration: Registration) !void {
    try client.request_lifecycle.tracker.add(registration.request_id, registration.continuation);
}

/// Consumes a known continuation exactly once.
///
/// ```zig
/// const continuation = request_lifecycle.consume(client, request_id) orelse return error.UnexpectedRequest;
/// ```
pub fn consume(client: *Client, request_id: RequestIdType) ?ContinuationType {
    return client.request_lifecycle.tracker.take(request_id);
}

/// Registers one fixed-size request and rolls its correlation back if the
/// runtime transport rejects delivery.
///
/// ```zig
/// try request_lifecycle.deliver(client, delivery);
/// ```
pub fn deliver(client: *Client, delivery: Delivery) !void {
    try register(client, delivery.registration);
    errdefer _ = consume(client, delivery.registration.request_id);
    try runtime_transport.enqueue(client, delivery.message);
}

/// Registers and copies one tab rename as one fallible delivery.
///
/// ```zig
/// try request_lifecycle.deliverRename(client, rename, continuation);
/// ```
pub fn deliverRename(client: *Client, rename: RenameTabType, continuation: ContinuationType) !void {
    try register(client, .{ .request_id = rename.request_id, .continuation = continuation });
    errdefer _ = consume(client, rename.request_id);
    try runtime_transport.enqueueRename(client, rename);
}

/// Registers and copies one workspace rename as one fallible delivery.
///
/// ```zig
/// try request_lifecycle.deliverWorkspaceRename(client, rename);
/// ```
pub fn deliverWorkspaceRename(client: *Client, rename: RenameWorkspaceType) !void {
    try register(client, .{
        .request_id = rename.request_id,
        .continuation = .{ .rename_workspace = rename.workspace },
    });
    errdefer _ = consume(client, rename.request_id);
    try runtime_transport.enqueueWorkspaceRename(client, rename);
}

/// Registers and copies one workspace creation as one fallible delivery.
///
/// ```zig
/// try request_lifecycle.deliverCreateWorkspace(client, request);
/// ```
pub fn deliverCreateWorkspace(client: *Client, request: CreateWorkspaceType) !void {
    try register(client, .{
        .request_id = request.request_id,
        .continuation = .{ .create_workspace = request.size },
    });
    errdefer _ = consume(client, request.request_id);
    try runtime_transport.enqueueCreateWorkspace(client, request);
}

/// Registers and copies one tab creation as one fallible delivery.
///
/// ```zig
/// try request_lifecycle.deliverCreateTab(client, request);
/// ```
pub fn deliverCreateTab(client: *Client, request: CreateTabType) !void {
    try register(client, .{
        .request_id = request.request_id,
        .continuation = .{ .create_tab = .{
            .workspace = request.workspace,
            .size = request.size,
        } },
    });
    errdefer _ = consume(client, request.request_id);
    try runtime_transport.enqueueCreateTab(client, request);
}

/// Registers and copies one host notification request as one fallible
/// delivery.
///
/// ```zig
/// try request_lifecycle.deliverNotification(client, request);
/// ```
pub fn deliverNotification(client: *Client, request: ShowNotificationType) !void {
    try register(client, .{
        .request_id = request.request_id,
        .continuation = .notification,
    });
    errdefer _ = consume(client, request.request_id);
    try runtime_transport.enqueueNotification(client, request);
}

/// Requests one canonical tab snapshot and records its exact target.
///
/// ```zig
/// try request_lifecycle.requestTabSnapshot(client, location);
/// ```
pub fn requestTabSnapshot(client: *Client, location: TabLocationType) !void {
    const request_id = try nextId(client);
    try deliver(client, .{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .tab_snapshot = location },
        },
        .message = .{ .request_tab_snapshot = .{
            .request_id = request_id,
            .location = location,
        } },
    });
}

/// Requests one canonical workspace snapshot and records its exact target.
///
/// ```zig
/// try request_lifecycle.requestWorkspaceSnapshot(client, workspace);
/// ```
pub fn requestWorkspaceSnapshot(client: *Client, workspace: WorkspaceLocationType) !void {
    const request_id = try nextId(client);
    try deliver(client, .{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .workspace_snapshot = workspace },
        },
        .message = .{ .request_workspace_snapshot = .{
            .request_id = request_id,
            .workspace = workspace,
        } },
    });
}

/// Marks every non-split continuation for one removed tab as stale.
///
/// ```zig
/// request_lifecycle.ignoreTab(client, tab_id);
/// ```
pub fn ignoreTab(client: *Client, tab_id: TabIdType) void {
    client.request_lifecycle.tracker.ignoreTab(tab_id);
}

/// Marks every non-split continuation for one retired pane as stale.
///
/// ```zig
/// request_lifecycle.ignorePane(client, pane_id);
/// ```
pub fn ignorePane(client: *Client, pane_id: PaneIdType) void {
    client.request_lifecycle.tracker.ignorePane(pane_id);
}

/// Marks only one matching pane attachment as stale.
///
/// ```zig
/// _ = request_lifecycle.ignoreAttachment(client, pane_id);
/// ```
pub fn ignoreAttachment(client: *Client, pane_id: PaneIdType) bool {
    return client.request_lifecycle.tracker.ignoreAttachment(pane_id);
}

/// Completes the matching close continuation when pane exit is authoritative.
///
/// ```zig
/// _ = request_lifecycle.completePaneClose(client, pane_id);
/// ```
pub fn completePaneClose(client: *Client, pane_id: PaneIdType) bool {
    return client.request_lifecycle.tracker.completePaneClose(pane_id);
}

test "request identities never reach the reserved zero or maximum values" {
    var state: LifecycleState = .{};
    try std.testing.expectEqual(@as(RequestIdType, @enumFromInt(2)), try state.nextId());

    state.next_request_id = std.math.maxInt(u64) - 1;
    try std.testing.expectEqual(
        @as(RequestIdType, @enumFromInt(std.math.maxInt(u64) - 1)),
        try state.nextId(),
    );
    try std.testing.expectError(error.RequestIdExhausted, state.nextId());

    state.next_request_id = 0;
    try std.testing.expectError(error.RequestIdExhausted, state.nextId());
}

test "request preflight preserves identities needed by synchronous recovery" {
    var state: LifecycleState = .{ .next_request_id = std.math.maxInt(u64) - 1 };

    try state.ensureCanStart(1);
    try std.testing.expectError(error.RequestIdExhausted, state.ensureCanStart(2));
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, state.next_request_id);
}

test "request identity allocation stops before correlation overflow" {
    var state: LifecycleState = .{};
    for (0..TrackerType.capacity) |index| {
        try state.tracker.add(@enumFromInt(index + 20), .notification);
    }
    const next_request_id = state.next_request_id;

    try std.testing.expectError(error.TooManyPendingRequests, state.nextId());
    try std.testing.expectEqual(next_request_id, state.next_request_id);
}
