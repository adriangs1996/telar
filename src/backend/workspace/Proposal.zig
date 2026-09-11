const Repository = @import("Repository.zig");
const WorkspaceType = @import("Workspace.zig");
const TabLocationType = @import("telar-core").TabLocation;
const std = @import("std");
const raw_module = @import("telar-core").raw;
const repository_support = @import("repository_support.zig");
const state_mod = @import("state_support.zig");
/// Repository-owned aggregate candidate that remains invisible until commit.
const Proposal = @This();

repository: *Repository,
workspace: ?WorkspaceType,
proposed_location: TabLocationType,

/// Returns the stable identity reserved by this proposal.
///
/// ```zig
/// const location = proposal.location();
/// ```
pub fn location(proposal: *const Proposal) TabLocationType {
    std.debug.assert(proposal.workspace != null);
    return proposal.proposed_location;
}

/// Returns the proposal-owned workspace path until commit or rollback.
///
/// ```zig
/// const path = proposal.path();
/// ```
pub fn path(proposal: *const Proposal) []const u8 {
    return proposal.workspace.?.pathSlice();
}

/// Returns the canonical proposal-owned workspace name.
///
/// ```zig
/// const name = proposal.name();
/// ```
pub fn name(proposal: *const Proposal) []const u8 {
    return proposal.workspace.?.name();
}

/// Transfers the aggregate into repository state and advances identities
/// and list revision exactly once.
///
/// ```zig
/// const location = proposal.commit();
/// ```
pub fn commit(proposal: *Proposal) TabLocationType {
    const repository = proposal.repository;
    std.debug.assert(proposal.workspace != null);
    std.debug.assert(raw_module(repository_support.workspaceId(proposal.proposed_location.workspace).?) == repository.state.next_workspace_id);
    std.debug.assert(raw_module(proposal.proposed_location.tab_id) == repository.state.next_tab_id);
    std.debug.assert(repository.state.count < repository.state.items.len);

    for (&repository.state.items) |*slot| {
        if (slot.* != null) {
            continue;
        }

        slot.* = proposal.workspace.?;
        proposal.workspace = null;
        repository.state.count += 1;
        repository.state.next_workspace_id += 1;
        repository.state.next_tab_id += 1;
        state_mod.advanceRevision(repository.state);
        return proposal.proposed_location;
    }

    unreachable;
}

/// Releases an uncommitted aggregate. Calling it after commit is a no-op,
/// which makes it safe in a transaction defer.
///
/// ```zig
/// defer proposal.rollback();
/// ```
pub fn rollback(proposal: *Proposal) void {
    const workspace = if (proposal.workspace) |*value| value else return;
    workspace.deinit(proposal.repository.gpa);
    proposal.workspace = null;
}
