//! What landing one favicon completion meant for the workspace it names.
const ImageType = @import("../../completion/FaviconImage.zig");

pub const FaviconOutcome = union(enum) {
    /// The result answered no in-flight lookup and was released.
    stale,
    /// The lookup finished without a usable image.
    missing,
    /// The resized favicon, owned by the caller.
    image: *ImageType,
};
