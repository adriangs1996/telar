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
- [x] `pane focus by ID`
- [x] `pane resize`
- [x] `pane fullscreen`
- [x] `pane search`
- [x] `pane scroll`
- [x] `pane copy`
- [x] `pane watch`

## Layouts

- [x] `layout get`
- [x] `layout apply`

## Agents

- [x] `agent create`
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

- [x] `proxy watch`

## Configuration

- [x] `config show`
- [x] `config reload`

## Plugins

- [x] `plugin list`
- [x] `plugin get`
- [x] `plugin enable`
- [x] `plugin disable`
- [x] `plugin run`

## Client presentation

- [x] `sidebar get`
- [x] `sidebar show`
- [x] `sidebar hide`
- [x] `sidebar resize`
- [x] `workspace-list expand`
- [x] `workspace-list collapse`
- [x] `client open goto`
- [x] `client open history`
- [x] `client copy-mode`
- [x] `notification dismiss`
- [x] `client open-link`
- [x] `agent draft get`
- [x] `agent draft set`
- [x] `agent draft attach`
- [x] `agent view expand`
- [x] `agent view collapse`
- [x] `client clipboard copy`

## Diagnostics

- [x] `diagnostics logs`

