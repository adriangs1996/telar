const TestingPorts = @This();
const PanesCapture = @import("PanesCapture.zig");
const AuthorityCapture = @import("OpenPaneAuthorityCapture.zig");
const GeometryCapture = @import("OpenPaneGeometryCapture.zig");
const EventCapture = @import("OpenPaneEventCapture.zig");
panes: *PanesCapture,
authority: *AuthorityCapture,
geometry: *GeometryCapture,
events: *EventCapture,
