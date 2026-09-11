const PanesCapture = @import("PanesCapture.zig");
const OpenPaneAuthorityCapture = @import("OpenPaneAuthorityCapture.zig");
const OpenPaneGeometryCapture = @import("OpenPaneGeometryCapture.zig");
const OpenPaneEventCapture = @import("OpenPaneEventCapture.zig");
const TestingPorts = @This();

panes: *PanesCapture,
authority: *OpenPaneAuthorityCapture,
geometry: *OpenPaneGeometryCapture,
events: *OpenPaneEventCapture,
