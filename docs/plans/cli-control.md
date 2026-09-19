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

- [ ] `client list`
- [ ] `client get`
- [ ] `client detach`

## Workspaces

- [x] `workspace list`
- [x] `workspace get`
- [x] `workspace create --directory`
- [x] `workspace rename`
- [ ] `workspace select`

## Tabs

- [x] `tab list`
- [x] `tab get`
- [ ] `tab create`
- [x] `tab rename`
- [x] `tab close`
- [x] `tab move`
- [ ] `tab select`
- [ ] `tab next`
- [ ] `tab previous`

## Panes

- [ ] `pane list`
- [ ] `pane get`
- [ ] `pane create`
- [ ] `pane split`
- [ ] `pane close`
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
- [ ] `agent watch`
- [x] `agent models`
- [x] `agent skills`
- [x] `agent conversations`
- [ ] `agent resume`
- [x] `agent clear`
- [x] `agent rename`
- [ ] `agent acknowledge`
- [ ] `agent report-state`
- [ ] `agent report-title`
- [ ] `agent report-command`

## Assistance

- [ ] `command suggest`

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

