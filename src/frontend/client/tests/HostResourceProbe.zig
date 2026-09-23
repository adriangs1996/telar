//! Records host port calls while the shared client runs its real host policy.
const data = @import("model");
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const Probe = @This();

pub const Event = enum { presenter, view, sidebar };

app: *client.AttachedClient,
chrome: client.HostChrome,
presentation: client.HostPresentation,
events: [8]Event = undefined,
len: usize = 0,
failure: ?Event = null,
expected_size: ?core.TerminalSize = null,
sidebar: ?client.SidebarRendererInput = null,
committed: bool = true,

pub fn init(app: *client.AttachedClient) Probe {
    return .{
        .app = app,
        .chrome = app.chrome,
        .presentation = app.presentation,
    };
}

/// Bind at a stable address for one synchronous policy call, then restore.
/// Example: `probe.bind(); defer probe.restore();`
pub fn bind(self: *Probe) void {
    self.app.chrome.context = self;
    self.app.chrome.configure_sidebar_fn = configureSidebar;
    self.app.chrome.resize_fn = resizeView;
    self.app.chrome.region_fn = region;
    self.app.presentation.context = self;
    self.app.presentation.resize_fn = resizePresenter;
}

pub fn restore(self: *Probe) void {
    self.app.chrome = self.chrome;
    self.app.presentation = self.presentation;
}

pub fn slice(self: *const Probe) []const Event {
    return self.events[0..self.len];
}

fn record(self: *Probe, event: Event) !void {
    if (self.expected_size) |size| {
        self.committed = self.committed and std.meta.eql(size, self.app.model.host.host_size);
    }

    self.events[self.len] = event;
    self.len += 1;
    if (self.failure == event) {
        return error.HostResourceFailed;
    }
}

fn configureSidebar(context: *anyopaque, input: client.SidebarRendererInput) !void {
    const self: *Probe = @ptrCast(@alignCast(context));
    self.sidebar = input;
    self.committed = self.committed and input.support == self.app.model.host.host_capabilities.images;
    try self.record(.sidebar);
}

fn resizePresenter(context: *anyopaque, cols: u16, rows: u16) !void {
    const self: *Probe = @ptrCast(@alignCast(context));
    const size = self.app.model.host.host_size;
    self.committed = self.committed and cols == size.cols and rows == size.rows;
    try self.record(.presenter);
}

fn resizeView(context: *anyopaque, cols: u16, rows: u16) !void {
    const self: *Probe = @ptrCast(@alignCast(context));
    const size = self.app.model.host.host_size;
    self.committed = self.committed and cols == size.cols and rows == size.rows;
    try self.record(.view);
}

fn region(context: *anyopaque) data.Region {
    const self: *Probe = @ptrCast(@alignCast(context));
    return self.chrome.region();
}
