# Machine presentation

One window holds every enabled machine and shows one of them. Switching
machines switches the whole window: workspaces, tabs, panes, sidebar and
bars. The machines the window does not show stay connected for metadata only,
so their agents' attention and CPU reach the window without their panes
attaching.

## End-to-end path

```text
GuiAdapter.init                           clients: *[Machines.capacity]Client,
                                          app = &clients[local_slot]
GuiAdapter.start                          the window's own client, this machine
  runtime_link.start(own)
  window_machines.open
    profile_file.path/fingerprint/load    machines.json, read once
    machines.add(local_slot)              label: local_label or the host name
    machines.add(profile) per profile     the window's rows, enabled or not
    --remote / --machine                  a saved row by destination or label,
                                          or a temporary row never written back;
                                          pinned unless its profile enables it
    openClient per enabled row            Client.init, follows own's config,
                                          presented = false, runtime_link.start
    select(requested)                     when --remote or --machine named one
    watchProfiles                         a worker waits for the file to change

next-machine | previous-machine | machine picker | sidebar tab | top bar
  host effect .machine                    MachineRequest: offset, slot, or unpin
                                          when the picker disables a machine
  window_machines.choose -> select
    a frame in flight                     pending_machine, shown after it
    machine_presentation.hide(app)        leave the workspace or worktree once idle
    machines.active = slot, app = &clients[slot]
    machine_presentation.show(app)        open the deferred pane, or reopen the
                                          workspace or worktree it left

a machine's event
  window_machines.handle
    app.update(message)
    machines.summarize                    three comparisons; a new agent
                                          snapshot, metrics sample or link
                                          phase rewrites the row
    machine_presentation.settle           finish leaving once idle

machines.json replaced
  profile_file.waitForChange              stat fingerprint once per second
  .profiles_changed
    window_machines.profilesChanged
      reconcile                           add, update, stop, remove rows
      watchProfiles                       wait again
```

## Clients

- **One slot per machine.** `GuiAdapter.clients` is allocated once, so no
  client moves under a job. `Machines` is a table with one row per slot;
  `local_slot` is this machine. A client's completions come back as
  `MachineMessage { slot, message }`, and the window's own client keeps the
  plain `.client` event.
- **The window's own client owns the configuration.** It loads Lua, runs
  the configuration watch and draws the bars. Every other client points at
  its generation (`config_adoption.followConfiguration`, with
  `owns_configuration = false`) and takes each reload after it.
- **A hidden client never touches the host.** Its host effects are dropped,
  a pending clipboard capture fails, and its first pane waits until it is
  shown (`open_deferred`). Hiding a client leaves its workspace or worktree
  once no request is in flight (`leave_pending`,
  `machine_presentation.settle`), so the runtime stops sending it frames.
  Showing it again reopens a workspace through its remembered pane, and a
  worktree through the pane the navigation history kept for it, with the
  worktree's source workspace as the fallback.
- **Each client keeps its own images.** Every runtime numbers its panes
  from the same start, so the window keeps one graphics store per slot
  (`GuiAdapter.graphics_stores`, `host_ports.graphicsRetention(gui, slot)`).
  A hidden client clearing or hiding its pane's images never touches a pane
  with the same id on the shown machine.
- **A row is written when its machine's facts change.** After each of a
  client's events, `Machines.summarize` compares the client's agent
  revision, metrics revision and link phase with the ones the row last
  read. Only a change reads the clock (a new metrics sample) or walks the
  agent snapshot (a new one); a pane frame costs the three comparisons.
- **The inbox holds every machine's link.** A client holds at most eight
  tickets for its link and its timers: a runtime read
  (`RuntimeTransportState.beginRead`), a runtime write
  (`Outbox.send_pending`), one wait per timer kind
  (`DeadlineScheduler.pending`), a connection attempt (`connect_pending`)
  and a sound (`SoundPlayback.active`). The window's inbox keeps the default
  64 for its own work and for best-effort work such as system notices, and
  adds eight per other machine (`gui_event.Message.inbox_capacity`, 192
  with sixteen). A runtime read the inbox rejects loses that machine's link
  (`runtime_io.receiveRuntime`). With these budgets sixteen busy machines
  leave the window's own and best-effort work the headroom it has beside
  one machine; a read is rejected only when that work alone fills it, as
  with one machine.
- **One identity per window and machine.** `machineIdentity` hashes the
  window identity with the destination, so each runtime keeps this window's
  layout for its own machine.

## Surfaces

- **Top bar.** `MachineSegment` names the active machine, with its color and
  an attention dot when another machine asks for the person, only while the
  window holds more than one machine. A click opens the machine picker.
- **Sidebar.** With the sidebar expanded and two or more machines,
  `MachineSwitcher` draws one tab per machine above the projects list and
  folds what does not fit into a picker control. It opens the same picker
  as the top bar's segment, so it is placed as `.machine_fold`
  (`BandPlacement`): each keeps its own identity, hover and focus.
- **Bottom bar.** `telar.bar.machines()` draws a chip per enabled machine
  with its link state, attention and CPU, while the window holds more than
  one machine.
- **Palette.** The `:` prefix lists the machines; `next-machine`,
  `previous-machine`, `machine-picker` and `add-machine` are actions and Lua
  helpers (`telar.action.next_machine()` and so on). Plugins cannot run them.
- **Link state.** `LinkStatus` covers the workbench while the shown machine
  is connecting, lost, failed or disabled.

## Managing machines from the window

The `:` list holds every saved machine, disabled ones included, and an
"Add machine…" row after them. Its legend names the keys:

| Key | Row | Effect |
| --- | --- | --- |
| Enter | a machine | shows it; an unreachable one is also tried again now, skipping the rest of its backoff (`runtime_link.retryNow`); a disabled one is enabled |
| Enter | a machine that lacks this build | runs `telar machine setup LABEL --confirm` (the destination for a `--remote` row) in a new tab of this machine, which the window shows and where setup waits for a yes before it changes anything ([machine setup](machine-setup.md)); its row says `no telar for this build · enter sets it up` |
| Shift+Enter | a saved machine | enables or disables it |
| Ctrl+R | a saved machine | asks for a new label |
| Ctrl+D or ⌘⌫ | a saved machine | removes it |
| Enter | Add machine… | asks for the label, then the SSH destination, in one prompt |

This machine's row only shows it. Every change goes through
`machine_profiles.start`: the client copies it into its own storage and a
background job loads `machines.json`, makes the change with the same
procedure as `telar machine` (`machine_profiles.change`) and replaces the
file. The window's watch then applies it like any other change, so the
window and the CLI never disagree. One change is written at a time; a
failed one, such as a taken label or an invalid destination, comes back as
a notice with the same text the CLI prints. An added machine connects as
soon as the file is applied, and its row shows whether that worked.

## machines.json in an open window

`reconcile` applies the file the CLI or an editor just replaced:

- a new enabled machine gets a client and connects;
- a disabled machine's link stops: the socket closes once idle, the SSH session
  stops and no retry follows. Enabling it again connects the same client;
- a removed machine's row goes. Its client stays live in the slot, stopped,
  and the next machine added there reuses it with the new destination;
- a changed destination stops the link and starts it to the new one, with the
  identity for that destination;
- a new profile for the destination of a temporary `--remote` row takes that
  row, so one destination never gets two clients;
- a machine `--remote` or `--machine` opened without a profile that enables
  it is pinned (`Machines.pinned`): it stays open while its profile stays
  disabled, whatever else the file changes. Once the profile enables it the
  profile decides, and disabling it in the machine list closes it even when
  the profile was already disabled (`MachineRequest.unpin`). `telar machine
  disable` on a profile that is already disabled changes nothing, so it
  does not close a pinned machine;
- the window shows this machine first when the machine it shows is disabled
  or removed, and a notice says so;
- a label or color change only redraws.

A file that cannot be read or parsed keeps the machines the window holds and
shows a notice with the reason. The
watch compares a stat fingerprint (kind, size and modification time) on a
worker once per second and wakes the window only when it changes.

A connection attempt reads the destination from a copy the client makes when
it queues the attempt, never from the table, so a rename during an attempt
cannot change what SSH connects to. See [Runtime link](runtime-link.md) for
the attempts a change supersedes.

## Placement data

Each row keeps what a placement rule needs from its machine's last metrics
sample: CPU percentage and count, used and total memory, and when the sample
arrived by the window's monotonic clock. Nothing chooses a machine
automatically. `telar --machine LABEL runtime metrics --json` reports the same
values for scripts and coordinators. The runtime reads the host's counts: in a
container they are the host's or VM's, not the container's CPU or memory
limits.

## Validation

- `src/client/machines/Machines.zig` tests slots, summaries and placement
  columns.
- `src/client/execution/client_tests.zig` tests that a hidden machine defers
  its first pane and leaves its workspace once idle.
- `src/gui/tests/machines.zig` tests switching both ways, a switch during a
  frame, reopening a worktree, separate graphics per client, sixteen
  machines' reads in the window's inbox, the top bar segment, the sidebar
  tabs and their fold, a folded sidebar drawn frame after frame with both
  picker controls opening the picker, a pinned machine across
  `machines.json` changes and the machine list, and a `machines.json` sequence of add, disable, move
  during a running attempt, and removal of the shown machine.
- `frontend.client.machine_frame_event` in `telar-benchmarks` times a
  one-cell frame through a machine's client with a full agent snapshot,
  followed by the row refresh the window runs after each event.
- `src/client/config/generation_support.zig` tests `telar.bar.machines()` and
  the machine actions from Lua.
- `src/model/state/name_prompt.zig` tests the two steps of adding a machine
  and the list's rename and remove commands; `src/gui/tests/machines.zig`
  adds, disables, renames and removes a machine from the list through a real
  `machines.json`; `src/client/machines/machine_profiles.zig` tests the
  changes and the local label rule; `src/client/connection/runtime_link.zig`
  tests retrying now.
- Against the Linux SSH box (`tools/local-docker`), with a window open:
  `telar machine enable box` attaches a metadata-only client within two
  seconds, `disable` removes it and its forward within one, enabling again
  reuses the client, remove and add work, a destination moved away and back
  reconnects within a second, and disabling the shown machine returns the
  window to this machine. `telar gui --machine box` shows box first.
- Not verified here: the drawn segment, tabs and chips, because this session
  cannot capture the window (macOS screen recording permission).
