//! Disposable GUI registry of workspace favicons: which workspace has a
//! sprite, which still needs a lookup and the one landed image waiting to
//! be placed into the renderer's page. Bounded to the workspace list size;
//! a page rebuilt at another scale forgets every placement so the lookups
//! run again against the new cell size. Nothing here allocates on a warm
//! frame: placement copies one cell and a lookup starts at most once per
//! workspace per page.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const SpritePage = @import("../image/SpritePage.zig");
const Sprite = @import("../image/Sprite.zig");
const Entry = @import("FaviconEntry.zig");
const Landing = @import("FaviconLanding.zig");
const Want = @import("FaviconWant.zig");
const Favicons = @This();

pub const capacity = core.max_workspace_list_entries;

entries: [capacity]Entry = undefined,
count: u8 = 0,
/// The page the placements belong to, by its pixel storage.
page: ?[*]const u8 = null,
/// One landed image awaiting placement; the worker runs one lookup at a time.
landed: ?Landing = null,

/// Releases the landed image, if any, at client teardown.
/// Example: `gui.chrome.favicons.deinit(gpa);`
pub fn deinit(favicons: *Favicons, gpa: std.mem.Allocator) void {
    favicons.dropLanding(gpa);
}

/// Keeps one completed lookup until the next preparation places it.
/// Example: `gui.chrome.favicons.land(gpa, .{ .workspace = id, .image = image });`
pub fn land(favicons: *Favicons, gpa: std.mem.Allocator, landing: Landing) void {
    favicons.dropLanding(gpa);
    favicons.landed = landing;
}

/// Follows the renderer's page and places the landed image into it. A
/// different page forgets every placement.
/// Example: `favicons.refresh(gpa, &renderer.sprites.?);`
pub fn refresh(favicons: *Favicons, gpa: std.mem.Allocator, page: *SpritePage) void {
    if (favicons.page != page.pixels.ptr) {
        favicons.page = page.pixels.ptr;
        favicons.count = 0;
    }

    const landing = favicons.landed orelse return;
    defer favicons.dropLanding(gpa);
    const entry = favicons.find(landing.workspace) orelse return;
    const image = landing.image orelse {
        entry.state = .missing;
        return;
    };
    const side: u32 = image.side;
    if (side != page.cell) {
        entry.state = .wanted;
        return;
    }

    entry.sprite = page.addFavicon(.{ .pixels = image.slice(), .stride = side * 4, .width = side, .height = side }) catch |err| {
        entry.state = if (err == error.SheetFull) .full else .missing;
        return;
    };
    entry.state = .resolved;
}

/// The next workspace of the list that still needs a lookup, registering
/// new workspaces and evicting departed ones when the table is full.
/// Example: `if (favicons.next(model.workspaceListSnapshot())) |want| try request(want);`
pub fn next(favicons: *Favicons, workspaces: *const client.WorkspaceListSnapshot) ?Want {
    for (0..workspaces.count) |index| {
        const workspace = workspaces.workspaceAt(index);
        const entry = favicons.find(workspace) orelse favicons.register(workspace, workspaces) orelse continue;
        if (entry.state == .wanted) {
            return .{ .workspace = workspace, .cwd = workspaces.pathAt(index) };
        }
    }

    return null;
}

/// Marks a workspace's lookup as accepted by the controller.
/// Example: `if (started) favicons.started(want.workspace);`
pub fn started(favicons: *Favicons, workspace: core.WorkspaceId) void {
    if (favicons.find(workspace)) |entry| {
        entry.state = .pending;
    }
}

/// The placed favicon of a location; worktrees and unresolved workspaces
/// draw the generic glyph.
/// Example: `card.project_icon = favicons.sprite(agent.location.workspace);`
pub fn sprite(favicons: *const Favicons, location: core.WorkspaceLocation) ?Sprite {
    const workspace = switch (location) {
        .workspace => |id| id,
        .worktree => return null,
    };
    for (favicons.entries[0..favicons.count]) |entry| {
        if (entry.workspace == workspace) {
            return if (entry.state == .resolved) entry.sprite else null;
        }
    }

    return null;
}

pub fn stateOf(favicons: *const Favicons, workspace: core.WorkspaceId) ?Entry.State {
    for (favicons.entries[0..favicons.count]) |entry| {
        if (entry.workspace == workspace) {
            return entry.state;
        }
    }

    return null;
}

fn find(favicons: *Favicons, workspace: core.WorkspaceId) ?*Entry {
    for (favicons.entries[0..favicons.count]) |*entry| {
        if (entry.workspace == workspace) {
            return entry;
        }
    }

    return null;
}

// Entries outlive their workspace so a page cell is never placed twice;
// they leave only when the table is full and a new workspace arrives.
fn register(favicons: *Favicons, workspace: core.WorkspaceId, workspaces: *const client.WorkspaceListSnapshot) ?*Entry {
    if (favicons.count == capacity) {
        var kept: u8 = 0;
        for (favicons.entries[0..favicons.count]) |entry| {
            if (workspaces.indexOf(entry.workspace) != null) {
                favicons.entries[kept] = entry;
                kept += 1;
            }
        }

        favicons.count = kept;
        if (favicons.count == capacity) {
            return null;
        }
    }

    favicons.entries[favicons.count] = .{ .workspace = workspace };
    favicons.count += 1;
    return &favicons.entries[favicons.count - 1];
}

fn dropLanding(favicons: *Favicons, gpa: std.mem.Allocator) void {
    const landing = favicons.landed orelse return;
    if (landing.image) |image| {
        gpa.destroy(image);
    }

    favicons.landed = null;
}
