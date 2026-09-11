const std = @import("std");
const SessionType = @import("telar-backend").Session;
const HostCapabilitiesType = @import("telar-client").HostCapabilities;
const FeedContext = @This();

io: std.Io,
session: *SessionType,
capabilities: *HostCapabilitiesType,
