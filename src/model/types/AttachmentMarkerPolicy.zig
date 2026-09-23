pub const AttachmentMarkerPolicy = enum {
    ordered,
    stable_number,
    pasted_path,

    pub fn learnsIdentity(self: AttachmentMarkerPolicy) bool {
        return self != .ordered;
    }
};
