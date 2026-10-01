const core = @import("telar-core");
identity: [32]u8,
next_comment: u64,
/// Bytes of the reported diff the edition left out; absent in files written
/// before editions kept a prefix of a diff past `max_patch_bytes`.
omitted_patch_bytes: u32 = 0,
snapshot: core.ChangeReviewSnapshotView,
