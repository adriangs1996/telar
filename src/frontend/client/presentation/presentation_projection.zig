//! Immutable semantic projection and explicit presentation-owned resources for
//! one synchronous client frame.

const client_module = @import("telar-client");
const TerminalClient = @import("../TerminalClient.zig");
const ResourcesType = @import("Resources.zig");

/// Captures the bounded revisions observed by the presenter after one client
/// event without exposing the client aggregate.
///
/// ```zig
/// try host(client).presenter.observe(observation(client));
/// ```
pub fn observation(client: *client_module.AttachedClient) client_module.Observation {
    return .{
        .model = client.model.version(),
        .geometry_revision = client.geometry().revision,
        .graphics_ingress = TerminalClient.of(client).graphics_store.ingressVersion(),
        .attachment_ingress = TerminalClient.of(client).view.kittyAttachments().ingressVersion(),
        .presentation_ingress = presentationIngress(client),
    };
}

/// Borrows one immutable semantic projection for a synchronous cell or media
/// presentation. The event loop cannot mutate it until the call returns.
///
/// ```zig
/// const current = projection(client);
/// ```
pub fn projection(client: *const client_module.AttachedClient) client_module.Projection {
    return client_module.capture(&client.model, .{
        .presentation_ingress = presentationIngress(client),
        .status_mode = TerminalClient.ofConst(client).host_input.statusMode(client.model.copyModeActive()),
        .geometry = client.geometry(),
    });
}

fn presentationIngress(client: *const client_module.AttachedClient) client_module.PresentationIngress {
    return .{
        .view_interaction = TerminalClient.ofConst(client).view.interactionVersion(),
        .input_routing = TerminalClient.ofConst(client).host_input.presentationVersion(),
    };
}

/// Exposes only the mutable resources that presentation owns and the host
/// writer that receives its output.
///
/// ```zig
/// const target = resources(client);
/// ```
pub fn resources(client: *client_module.AttachedClient) ResourcesType {
    return .{
        .view = &TerminalClient.of(client).view,
        .graphics_store = &TerminalClient.of(client).graphics_store,
        .writer = TerminalClient.of(client).writer,
    };
}
