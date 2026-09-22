pub const AttachmentMarkerPolicy = enum {
    ordered,
    stable_number,
    pasted_path,

    pub fn learnsIdentity(policy: AttachmentMarkerPolicy) bool {
        return policy != .ordered;
    }
};
