//! Immutable semantic projection and explicit presentation-owned resources for
//! one synchronous client frame.

const client_module = @import("telar-client");
const TerminalClient = @import("../TerminalClient.zig");
const Resources = @import("Resources.zig");

/// Captures the bounded revisions observed by the presenter after one client
/// event without exposing the client aggregate.
///
/// ```zig
/// try host(client).presenter.observe(observation(terminal));
/// ```
pub fn observation(terminal: *TerminalClient) client_module.Observation {
    const client = &terminal.app;

    return .{
        .model = client.model.version(),
        .geometry_revision = client.geometry().revision,
        .graphics_ingress = terminal.graphics_store.ingressVersion(),
        .attachment_ingress = terminal.view.kittyAttachments().ingressVersion(),
        .presentation_ingress = presentationIngress(terminal),
    };
}

/// Borrows one immutable semantic projection for a synchronous cell or media
/// presentation. The event loop cannot mutate it until the call returns.
///
/// ```zig
/// const current = projection(terminal);
/// ```
pub fn projection(terminal: *TerminalClient) client_module.Projection {
    const client = &terminal.app;

    return client_module.capture(&client.model, .{
        .presentation_ingress = presentationIngress(terminal),
        .status_mode = terminal.host_input.statusMode(client.model.copyModeActive()),
        .geometry = client.geometry(),
    });
}

fn presentationIngress(terminal: *const TerminalClient) client_module.PresentationIngress {
    return .{
        .view_interaction = terminal.view.interactionVersion(),
        .input_routing = terminal.host_input.presentationVersion(),
    };
}

/// Exposes only the mutable resources that presentation owns and the host
/// writer that receives its output.
///
/// ```zig
/// const target = resources(terminal);
/// ```
pub fn resources(terminal: *TerminalClient) Resources {
    return .{
        .view = &terminal.view,
        .graphics_store = &terminal.graphics_store,
        .writer = terminal.writer,
    };
}
