const Application = @import("Application.zig");
const Session = @import("../client/Session.zig");
const Repository = @import("../../workspace/Repository.zig");

application: *Application,
session: *Session,
workspaces: Repository,
