# Personal GUI C++ handoff

The Personal agent finished at `089a07dcd6cd719f80c56625652afacb87060635`.
Merge `36adb7d4f7be59c79323396db4fd8ac54142f48d` brings that result into
`feat/desktop-lua-ui`, preserving the local source relocation and other unfinished work.
Preview26, scoped graphics/attachments and native blur are delivered. The Release
benchmark failed performance acceptance. Full parity and Zig retirement remain open.

For optimization or another performance comparison, start with
[OPTIMIZATION.md](../services/gui-cpp/OPTIMIZATION.md). It identifies the measured
candidate, surviving local runners, rejected experiments and the next checks.
[PARITY.md](../services/gui-cpp/PARITY.md) owns the final metric table and limits;
[DAILY_DRIVER.md](../services/gui-cpp/DAILY_DRIVER.md) describes launching Preview27.

## Personal access

Machine label: `Personal`. Task branch: `gui-cpp-parity-personal-20261029`.
Task worktree:
`/Users/adriangonzalez/sandbox/telar-worktrees/gui-cpp-parity-personal-20261029`.
The separate main checkout on Personal is not this task's source tree.

Raw results and frozen applications survive in ignored
`services/gui-cpp/out-dependencies/adoption-benchmark-1` within the task.
All measurement archives were removed from the source tree, preserving Git history,
real tests, fixtures and tools. Keep future generated output in ignored `out*/`.

Personal cleanup on 2026-11-02 removed 33 GUI build directories, 25 obsolete
preview bundles, temporary outputs and task-local Zig caches. Recorded free space
increased by 24.6 GB. Preview8 in use, Preview27, all 1,797 frozen benchmark inputs,
the Ghostty install and Linux VM/access helper were retained. Source HEAD and
worktree cleanliness were unchanged. Finished execution records were also cleared.

The Linux correctness mirror is `/home/parity/telar`. Its retained access helper
is `services/gui-cpp/out-dependencies/linux_vm_exec.py` on Personal; invoke it
from the task root with one shell-command argument. It is an owned VM with
4 GiB RAM and no swap, unsuitable for claims about native Linux performance.

## Existing user state

Preserve the installed app, configuration, previews, clipboard and runtime/PTYs.
At handoff, protected processes were host runtime35801, user Preview8 GUI52865,
QEMU7158 and guest Sway9469. Recheck executable paths and start times before any
process operation; these numbers are historical identities, not ownership proof.
The original agent has finished; its historical goal state is not a new task.

An unrelated private note was moved without reading to
`~/.local/share/telar-private-notes/gui-cpp-personal-20261029/personal-frame-delivery.md`.
Keep it private and outside the benchmark inputs.
