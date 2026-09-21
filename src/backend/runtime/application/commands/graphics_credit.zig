//! Application command for returning graphics transfer capacity to one client
//! attachment.

pub const ReturnGraphicsCreditResult = enum {
    returned,
    pane_not_attached,
    invalid_amount,
};
