const Job = @import("Job.zig");

busy: bool = false,
// SAFETY: link_opening fills job before setting busy and dispatching the worker; completion requires that active job.
job: Job = undefined,
