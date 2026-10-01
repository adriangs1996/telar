//! Disposable GUI registry of workspace favicons: which workspace has a
//! sprite, which still needs a lookup and the one landed image waiting to
//! be placed into the renderer's page. Bounded to the workspace list size;
//! a page rebuilt at another ratio forgets every placement so the lookups
//! run again against the new cell sizes. An entry keeps its page slot while
//! its workspace is away, so one that returns needs no second lookup; it
//! gives the slot back when the table or the page needs room for a listed
//! workspace. Nothing here allocates on a warm frame: placement copies one
//! slot and a lookup starts at most once per workspace per page.
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const SpritePage = @import("../image/SpritePage.zig");
const Sprite = @import("../image/Sprite.zig");
const SpriteSize = @import("../image/SpriteSize.zig").SpriteSize;
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
/// The workspace list revision whose departed workspaces were last
/// reclaimed: an entry the full page turned away tries again only once the
/// list has changed, never on every frame.
reclaimed_revision: u64 = 0,

/// Releases the landed image, if any, at client teardown.
/// Example: `gui.chrome.favicons.deinit(gpa);`
pub fn deinit(self: *Favicons, gpa: std.mem.Allocator) void {
    self.dropLanding(gpa);
}

/// Keeps one completed lookup until the next preparation places it.
/// Example: `gui.chrome.favicons.land(gpa, .{ .workspace = id, .image = image });`
pub fn land(self: *Favicons, gpa: std.mem.Allocator, landing: Landing) void {
    self.dropLanding(gpa);
    self.landed = landing;
}

/// Follows the renderer's page and places the landed image into it. A
/// different page forgets every placement. A full page first takes back
/// the slots of workspaces no longer listed; when every slot still belongs
/// to a listed workspace the entry keeps the glyph and the reach of
/// `gui.favicons.max_favicons` comes back for the window to report.
/// Example: `if (favicons.refresh(gpa, page, &model.workspace_list_snapshot)) |reach| client.limit_reached.report(app, reach);`
pub fn refresh(self: *Favicons, gpa: std.mem.Allocator, page: *SpritePage, workspaces: *const data.WorkspaceListSnapshot) ?core.LimitReach {
    if (self.page != page.pixels.ptr) {
        self.page = page.pixels.ptr;
        self.count = 0;
    }

    const landing = self.landed orelse return null;
    defer self.dropLanding(gpa);
    const entry = self.find(landing.workspace) orelse return null;
    const image = landing.image orelse {
        entry.state = .missing;
        return null;
    };
    var images: SpritePage.Images = undefined;
    for (SpriteSize.all, &images, 0..) |size, *view, index| {
        const side: u32 = image.sides[index];
        if (side != page.cell(size)) {
            entry.state = .wanted;
            return null;
        }

        view.* = .{ .pixels = image.slice(index), .stride = side * 4, .width = side, .height = side };
    }

    if (page.faviconRoom() == 0) {
        self.reclaim(page, workspaces);
    }

    // Reclaiming compacts the table, so the entry is found again.
    const placed = self.find(landing.workspace) orelse return null;
    placed.slot = page.addFavicon(images) catch |err| {
        if (err != error.SheetFull) {
            placed.state = .missing;
            return null;
        }

        placed.state = .full;
        return .{
            .limit = SpritePage.favicons_limit,
            .requested = @as(u64, SpritePage.max_favicons) + 1,
        };
    };
    placed.state = .resolved;
    return null;
}

/// The next workspace of the list that still needs a lookup, registering
/// new workspaces and evicting departed ones, whose page slots are
/// released, when the table is full.
/// Example: `if (favicons.next(page, &model.workspace_list_snapshot)) |want| try request(want);`
pub fn next(self: *Favicons, page: *SpritePage, workspaces: *const data.WorkspaceListSnapshot) ?Want {
    for (0..workspaces.count) |index| {
        const workspace = workspaces.workspaceAt(index);
        var entry = self.find(workspace) orelse self.register(page, workspace, workspaces) orelse continue;
        if (entry.state == .full and workspaces.revision != self.reclaimed_revision) {
            self.reclaim(page, workspaces);
            entry = self.find(workspace) orelse continue;
        }

        if (entry.state == .wanted) {
            return .{
                .workspace = workspace,
                .cwd = workspaces.pathAt(index),
            };
        }
    }

    return null;
}

/// Marks a workspace's lookup as accepted by the controller.
/// Example: `if (started) favicons.started(want.workspace);`
pub fn started(self: *Favicons, workspace: core.WorkspaceId) void {
    if (self.find(workspace)) |entry| {
        entry.state = .pending;
    }
}

/// The placed favicon of a location at one size; worktrees and unresolved
/// workspaces draw the generic glyph.
/// Example: `card.project_icon = favicons.sprite(agent.location.workspace, .small);`
pub fn sprite(self: *const Favicons, location: core.WorkspaceLocation, size: SpriteSize) ?Sprite {
    const workspace = switch (location) {
        .workspace => |id| id,
        .worktree => return null,
    };
    for (self.entries[0..self.count]) |entry| {
        if (entry.workspace == workspace) {
            if (entry.state != .resolved) {
                return null;
            }

            return .{
                .index = entry.slot,
                .size = size,
            };
        }
    }

    return null;
}

pub fn stateOf(self: *const Favicons, workspace: core.WorkspaceId) ?Entry.State {
    for (self.entries[0..self.count]) |entry| {
        if (entry.workspace == workspace) {
            return entry.state;
        }
    }

    return null;
}

fn find(self: *Favicons, workspace: core.WorkspaceId) ?*Entry {
    for (self.entries[0..self.count]) |*entry| {
        if (entry.workspace == workspace) {
            return entry;
        }
    }

    return null;
}

// Entries outlive their workspace so one that returns keeps its cell; they
// leave only when the table is full and a new workspace arrives.
fn register(self: *Favicons, page: *SpritePage, workspace: core.WorkspaceId, workspaces: *const data.WorkspaceListSnapshot) ?*Entry {
    if (self.count == capacity) {
        self.reclaim(page, workspaces);
        if (self.count == capacity) {
            return null;
        }
    }

    self.entries[self.count] = .{ .workspace = workspace };
    self.count += 1;
    return &self.entries[self.count - 1];
}

// Drops the entries of workspaces no longer listed and releases their page
// slots. A free slot lets entries the full page turned away look up again.
fn reclaim(self: *Favicons, page: *SpritePage, workspaces: *const data.WorkspaceListSnapshot) void {
    self.reclaimed_revision = workspaces.revision;
    var kept: u8 = 0;
    var released = false;
    for (self.entries[0..self.count]) |entry| {
        if (workspaces.indexOf(entry.workspace) != null) {
            self.entries[kept] = entry;
            kept += 1;
            continue;
        }

        if (entry.state == .resolved) {
            page.removeFavicon(entry.slot);
            released = true;
        }
    }

    self.count = kept;
    if (!released and page.faviconRoom() == 0) {
        return;
    }

    for (self.entries[0..self.count]) |*entry| {
        if (entry.state == .full) {
            entry.state = .wanted;
        }
    }
}

fn dropLanding(self: *Favicons, gpa: std.mem.Allocator) void {
    const landing = self.landed orelse return;
    if (landing.image) |image| {
        gpa.destroy(image);
    }

    self.landed = null;
}
