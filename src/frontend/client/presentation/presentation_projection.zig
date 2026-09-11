//! Immutable semantic projection and explicit presentation-owned resources for
//! one synchronous client frame.

const presenter = @import("Presenter.zig");

const Client = @import("../Client.zig");

/// Captures the bounded revisions observed by the presenter after one client
/// event without exposing the client aggregate.
///
/// ```zig
/// try client.presenter.observe(observation(client));
/// ```
pub fn observation(client: *Client) presenter.Observation {
    return .{
        .model = client.model.version(),
        .geometry_revision = client.geometry().revision,
        .graphics_ingress = client.graphics_store.ingressVersion(),
        .attachment_ingress = client.view.kittyAttachments().ingressVersion(),
        .presentation_ingress = presentationIngress(client),
    };
}

/// Borrows one immutable semantic projection for a synchronous cell or media
/// presentation. The event loop cannot mutate it until the call returns.
///
/// ```zig
/// const current = projection(client);
/// ```
pub fn projection(client: *const Client) presenter.Projection {
    return @import("telar-client").presentation.capture(&client.model, .{
        .presentation_ingress = presentationIngress(client),
        .status_mode = client.host_input.statusMode(client.model.copyModeActive()),
        .geometry = client.geometry(),
    });
}

fn presentationIngress(client: *const Client) presenter.PresentationIngress {
    return .{
        .view_interaction = client.view.interactionVersion(),
        .input_routing = client.host_input.presentationVersion(),
    };
}

/// Exposes only the mutable resources that presentation owns and the host
/// writer that receives its output.
///
/// ```zig
/// const target = resources(client);
/// ```
pub fn resources(client: *Client) presenter.Resources {
    return .{
        .view = &client.view,
        .graphics_store = &client.graphics_store,
        .writer = client.writer,
    };
}
