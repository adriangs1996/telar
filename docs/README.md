# Telar user guide

Start with [your first session](usage.md), then [configure the window and
shortcuts](configuration.md#start-with-a-small-config). You do not need a coding
agent, a plugin or a proxy to use Telar as a terminal.

| I want to… | Read |
| --- | --- |
| Build, launch and find my way around | [Using Telar](usage.md) |
| Find an action or navigate from the command palette | [Command palette](usage.md#find-an-action) |
| Change fonts, colors, shortcuts or profiles | [Configuration](configuration.md) |
| Connect an agent and give a task its own worktree | [Working with agents](agents.md) |
| Keep work on an SSH host | [Remote machines](remote.md) |
| Search and reuse a command | [Command history](usage.md#find-previous-commands) |
| Install a plugin | [Plugins](plugins.md#try-the-example-plugin) |
| Move between Neovim splits and Telar panes | [Neovim integration](../integrations/nvim/README.md) |
| Show images in a pane | [Terminal images](kitty-graphics.md#display-an-image) |
| Inspect application network traffic | [Optional TLS proxy](proxy-tls.md#try-the-proxy) |
| Install a desktop launcher | [Application packaging](packaging.md#install-a-local-build) |

The guides use `telar` on your PATH. [Using Telar](usage.md#put-telar-on-your-path)
explains how to set that up after a source build. Use `telar --help` to inspect
the command overview provided by your installed binary.

Telar is in early development. The documentation in a checkout describes that
checkout; when reporting a problem, include its Git commit as well as the
output of `telar --version`.

For contributors, [development](development.md) covers build dependencies and
tests. [Architecture](architecture.md), [invariants](invariants.md) and the
[flow index](flows/README.md) explain how Telar is implemented.
