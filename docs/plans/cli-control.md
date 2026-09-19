# CLI control implementation

Worktree branch: `feat/cli-control`, based on `a81a49f2`.
One tested action per commit. Existing commands remain compatible.
Runtime operations retain runtime authority; presentation operations must route
to an explicit client and execute through that client’s existing controllers.
No simulated keyboard input is a substitute for an implemented command.

## Runtime

- [x] `runtime status`
- [x] `runtime watch`
- [x] `runtime metrics`

## Clients

- [x] `client list`
- [x] `client get`
- [x] `client detach`

## Workspaces

- [x] `workspace list`
- [x] `workspace get`
- [x] `workspace create --directory`
- [x] `workspace rename`
- [x] `workspace select`

## Tabs

- [x] `tab list`
- [x] `tab get`
- [x] `tab create`
- [x] `tab rename`
- [x] `tab close`
- [x] `tab move`
- [x] `tab select`
- [x] `tab next`
- [x] `tab previous`

## Panes

- [x] `pane list`
- [x] `pane get`
- [x] `pane create`
- [x] `pane split`
- [x] `pane close`
- [ ] `pane focus by ID`
- [ ] `pane resize`
- [ ] `pane fullscreen`
- [ ] `pane search`
- [ ] `pane scroll`
- [ ] `pane copy`
- [ ] `pane watch`

## Layouts

- [ ] `layout get`
- [ ] `layout apply`

## Agents

- [ ] `agent create`
- [x] `agent prompt for managed panes`
- [x] `agent prompt --image`
- [x] `agent prompt --model/--effort/--access`
- [x] `agent interrupt`
- [x] `agent approvals`
- [x] `agent approve`
- [x] `agent reject`
- [x] `agent thread`
- [x] `agent history`
- [x] `agent watch`
- [x] `agent models`
- [x] `agent skills`
- [x] `agent conversations`
- [x] `agent resume`
- [x] `agent clear`
- [x] `agent rename`
- [x] `agent acknowledge`
- [x] `agent report-state`
- [x] `agent report-title`
- [x] `agent report-command`

## Assistance

- [x] `command suggest`

## Proxy

- [ ] `proxy watch`

## Configuration

- [ ] `config show`
- [ ] `config reload`

## Plugins

- [ ] `plugin list`
- [ ] `plugin get`
- [ ] `plugin enable`
- [ ] `plugin disable`
- [ ] `plugin run`

## Client presentation

- [ ] `sidebar get`
- [ ] `sidebar show`
- [ ] `sidebar hide`
- [ ] `sidebar resize`
- [ ] `workspace-list expand`
- [ ] `workspace-list collapse`
- [ ] `client open goto`
- [ ] `client open history`
- [ ] `client copy-mode`
- [ ] `notification dismiss`
- [ ] `client open-link`
- [ ] `agent draft get`
- [ ] `agent draft set`
- [ ] `agent draft attach`
- [ ] `agent view expand`
- [ ] `agent view collapse`
- [ ] `client clipboard copy`

## Diagnostics

- [ ] `diagnostics logs`

