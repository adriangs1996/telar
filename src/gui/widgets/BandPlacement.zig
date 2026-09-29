/// Which of the band controls that share one action a hit is. The interaction
/// registry keys a control by its action and placement, so two controls that
/// open the same thing in one frame keep their own identity, hover and focus.
pub const BandPlacement = enum(u8) {
    /// The only control for its action: every band control but the ones below.
    primary,
    /// The sidebar switcher's `+N`, which opens the machine picker the top
    /// bar's machine segment opens too.
    machine_fold,
};
