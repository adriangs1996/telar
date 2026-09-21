//! Application transaction for creating a tab and its root pane.

pub fn mapLaunchError(spawn_error: anyerror) anyerror {
    return switch (spawn_error) {
        error.PaneLimitReached => error.PaneLimitReached,
        error.UnsupportedEnvironment => error.UnsupportedEnvironment,
        else => error.PaneSpawnFailed,
    };
}
