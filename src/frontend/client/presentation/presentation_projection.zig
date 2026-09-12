//! Immutable semantic projection and explicit presentation-owned resources for
//! one synchronous client frame.

const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const host_const = TerminalClient.ofConst;
const Client = @import("telar-client").AttachedClient;
const ObservationType = @import("telar-client").Observation;
const ProjectionType = @import("telar-client").Projection;
const capture_module = @import("telar-client").capture;
const PresentationIngressType = @import("telar-client").PresentationIngress;
const ResourcesType = @import("Resources.zig");

/// Captures the bounded revisions observed by the presenter after one client
/// event without exposing the client aggregate.
///
/// ```zig
/// try host(client).presenter.observe(observation(client));
/// ```
pub fn observation(client: *Client) ObservationType {
    return .{
        .model = client.model.version(),
        .geometry_revision = client.geometry().revision,
        .graphics_ingress = host(client).graphics_store.ingressVersion(),
        .attachment_ingress = host(client).view.kittyAttachments().ingressVersion(),
        .presentation_ingress = presentationIngress(client),
    };
}

/// Borrows one immutable semantic projection for a synchronous cell or media
/// presentation. The event loop cannot mutate it until the call returns.
///
/// ```zig
/// const current = projection(client);
/// ```
pub fn projection(client: *const Client) ProjectionType {
    return capture_module(&client.model, .{
        .presentation_ingress = presentationIngress(client),
        .status_mode = host_const(client).host_input.statusMode(client.model.copyModeActive()),
        .geometry = client.geometry(),
    });
}

fn presentationIngress(client: *const Client) PresentationIngressType {
    return .{
        .view_interaction = host_const(client).view.interactionVersion(),
        .input_routing = host_const(client).host_input.presentationVersion(),
    };
}

/// Exposes only the mutable resources that presentation owns and the host
/// writer that receives its output.
///
/// ```zig
/// const target = resources(client);
/// ```
pub fn resources(client: *Client) ResourcesType {
    return .{
        .view = &host(client).view,
        .graphics_store = &host(client).graphics_store,
        .writer = host(client).writer,
    };
}
