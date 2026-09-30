//! Path picker: a client asks for the paths under a root that match a query.
//! The loop only copies requests and starts workers; one build worker per
//! client fills the index while one query worker at a time ranks what it
//! has published, so every keystroke gets an answer without waiting for
//! the walk. See `docs/flows/path-picker.md`.

const core = @import("telar-core");
const client_connection = @import("client_connection.zig");
const client_request = @import("client_request.zig");
const path_index_build = @import("../paths/path_index_build.zig");
const ClientKey = @import("../history/ClientKey.zig");
const PathIndex = @import("../paths/PathIndex.zig");
const PathQuery = @import("../paths/PathQuery.zig");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const PathIndexes = @import("../paths/PathIndexes.zig");
const limit_reached = @import("limit_reached.zig");

/// Records the client's newest query and starts whatever worker it needs.
///
/// ```zig
/// .find_paths => |request| path_picker.request(model, session, request),
/// ```
pub fn request(model: *RuntimeModel, session: *Session, find: core.FindPaths) !void {
    const index = model.path_indexes.find(session.key) orelse model.path_indexes.add(model.gpa, session.key) catch |err| switch (err) {
        error.PathPickerBusy => {
            limit_reached.report(model, .{
                .limit = PathIndexes.capacity_limit,
                .requested = PathIndexes.capacity + 1,
            });
            return client_request.fail(
                session,
                find.request_id,
                .resource_limit,
                "every path picker slot is busy",
            );
        },
        error.OutOfMemory => return client_request.fail(
            session,
            find.request_id,
            .resource_limit,
            "path index memory is unavailable",
        ),
    };

    model.path_indexes.touch(index);
    index.want(find.root, find.refresh);
    index.wanted = .init(find);
    index.pending = true;
    advance(model, index);
}

/// Takes a finished build and answers a query that saw it half done.
///
/// ```zig
/// .path_index_built => |index| path_picker.finishBuild(model, index),
/// ```
pub fn finishBuild(model: *RuntimeModel, index: *PathIndex) void {
    index.building = false;
    if (index.truncation()) |limit| {
        limit_reached.report(model, .{ .limit = limit });
    }

    if (index.abandoned) {
        releaseIdle(model, index);
        return;
    }

    if (index.answered_partial) {
        index.pending = true;
    }

    advance(model, index);
}

/// Delivers one query's reply to the client that asked.
///
/// ```zig
/// .paths_found => |query| path_picker.finishQuery(model, query),
/// ```
pub fn finishQuery(model: *RuntimeModel, query: *PathQuery) void {
    const index = query.index;
    index.querying = false;
    if (index.abandoned) {
        query.destroy();
        releaseIdle(model, index);
        return;
    }

    index.answered_partial = !query.complete;
    if (!query.complete and index.complete.load(.acquire) and !index.rebuild) {
        index.pending = true;
    }

    deliver(model, query);
    advance(model, index);
}

/// Forgets a departing client's index; a worker still holding it frees it
/// when it finishes. Example: `path_picker.release(model, key);`
pub fn release(model: *RuntimeModel, client: ClientKey) void {
    const index = model.path_indexes.find(client) orelse return;
    index.abandoned = true;
    index.cancelled.store(true, .release);
    releaseIdle(model, index);
}

fn releaseIdle(model: *RuntimeModel, index: *PathIndex) void {
    if (index.building or index.querying) {
        return;
    }

    model.path_indexes.remove(index);
}

fn deliver(model: *RuntimeModel, query: *PathQuery) void {
    const session = model.clients.resolve(query.client) orelse {
        query.destroy();
        return;
    };

    if (!session.active()) {
        query.destroy();
        return;
    }

    if (query.failure == .unreadable) {
        defer query.destroy();
        client_request.fail(
            session,
            query.query.request_id,
            .permission_denied,
            "the directory cannot be read",
        ) catch {
            client_connection.drop(model, query.client);
        };
        return;
    }

    session.delivery.responses.push(.{ .path_results = query }) catch {
        client_connection.drop(model, query.client);
    };
}

/// Starts a build when the root changed and no worker holds the index,
/// then a query when one is wanted and none runs.
fn advance(model: *RuntimeModel, index: *PathIndex) void {
    if (index.rebuild) {
        if (index.building or index.querying) {
            index.cancelled.store(true, .release);
            return;
        }

        index.reset();
        index.building = true;
        model.select.concurrent(
            .path_index_built,
            path_index_build.run,
            .{ index, model.io, model.inherited_environment },
        ) catch {
            index.building = false;
            failWanted(
                model,
                index,
                "the path index cannot start",
            );
            return;
        };
    }

    if (!index.pending or index.querying) {
        return;
    }

    const query = PathQuery.create(model.gpa, index) catch {
        failWanted(
            model,
            index,
            "path query memory is unavailable",
        );
        return;
    };

    index.pending = false;
    index.querying = true;
    model.select.concurrent(
        .paths_found,
        PathQuery.run,
        .{ query, model.io },
    ) catch {
        index.querying = false;
        query.destroy();
        failWanted(
            model,
            index,
            "the path query cannot start",
        );
    };
}

fn failWanted(model: *RuntimeModel, index: *PathIndex, message: []const u8) void {
    index.pending = false;
    const session = model.clients.resolve(index.client) orelse return;
    client_request.fail(
        session,
        index.wanted.request_id,
        .resource_limit,
        message,
    ) catch {
        client_connection.drop(model, index.client);
    };
}
