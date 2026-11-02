# Daily C++ client adoption

## Current phase

The agreed order is Preview26, graphics and attachments, native blur, then a
full-client performance comparison with the Zig GUI. Preview26 and the scoped
graphics fixes are complete. Native blur is implemented in the later Preview27;
the comparative benchmark is running on Personal. Equal-or-better performance
has not been established.

The client supports terminal input, Unicode/IME, panes/tabs/workspaces, agents and
tasks, History, SSH machines, clipboard, images/attachments, Lua reload and custom
plugins/bars/panels/picks. This describes implemented behavior, not exhaustive
acceptance of every native state.

Run a local build with `out/telar-gui`. Separately packaged macOS candidates live
under ignored `out-adoption/` when available. Close the candidate and reopen the
installed Telar app to return; keep the runtime running. Do not migrate active
sessions or replace installations as part of testing.

## Deferred work

Additional terminal/IME/History/activity improvements, limit-title naming, broader
accessibility, palette/notification changes, exhaustive visual matrices, physical
system sleep and general framework shutdown-retention triage are outside this
phase. They do not block its delivery. Direct memory, security or data-loss faults
in the graphics or benchmark flow still require correction.

Do not resume the older backlog automatically after the agreed phase. Complete
parity and removal of Telar's Zig code remain separate later stages.

## Verification output

Keep benchmark and diagnostic output outside the versioned source tree. Report
results with the candidate version, workload and endpoint, including failed runs
and known limits. Do not commit captures, logs, source snapshots or generated
validation manifests.
