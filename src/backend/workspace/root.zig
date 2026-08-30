//! Public namespace for runtime-owned workspace state and behavior.
//!
//! `RuntimeModel` owns `State`. Callers use `Repository` for collection access
//! and the command functions below for aggregate mutations.

const commands = @import("commands.zig");
const events = @import("events.zig");
const repository = @import("repository.zig");
const state = @import("state.zig");
const workspace = @import("workspace.zig");

pub const State = state.State;
pub const Repository = repository.Repository;
pub const Reader = repository.Reader;
pub const Ensured = repository.Ensured;
pub const Insert = repository.Insert;
pub const WorkspaceProposal = repository.Proposal;
pub const DescriptorSnapshot = repository.DescriptorSnapshot;
pub const TabCreated = events.TabCreated;
pub const TabRemoved = events.TabRemoved;
pub const TabRenamed = events.TabRenamed;
pub const TabMoved = events.TabMoved;
pub const WorkspaceRenamed = events.WorkspaceRenamed;
pub const WorkspaceCreated = events.WorkspaceCreated;

pub const max_workspaces = state.max_workspaces;
pub const max_tabs_per_workspace = workspace.max_tabs_per_workspace;

pub const renameWorkspace = commands.renameWorkspace;
pub const moveTab = commands.moveTab;
pub const removeTab = commands.removeTab;

test {
    _ = @import("commands.zig");
    _ = @import("events.zig");
    _ = @import("repository.zig");
    _ = @import("state.zig");
    _ = @import("workspace.zig");
}
