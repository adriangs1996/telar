#pragma once

#include "session_channel.hpp"

namespace telar::runtime::cli::sessions {

template <Allocator Memory>
void tabSnapshot(Output<Memory> &output, const TabSnapshot &reply, bool json) {
  if (json) {
    output.raw("{\"workspace_id\":").number(reply.location.workspace.id).raw(",\"tab_id\":").number(reply.location.tab_id).raw(",\"panes\":[");
  } else {
    output.raw("PANE\tGENERATION\tLIFECYCLE\n");
  }

  bool first = true;
  for (const auto &pane : reply.panes) {
    const auto lifecycle = pane.lifecycle == PaneLifecycle::running ? "running" : "exited";
    if (json) {
      if (!first) {
        output.raw(",");
      }
      output.raw("{\"pane_id\":").number(pane.pane_id).raw(",\"pane_generation\":").number(pane.pane_generation).raw(",\"lifecycle\":").quoted(lifecycle).raw("}");
    } else {
      output.number(pane.pane_id).raw("\t").number(pane.pane_generation).raw("\t").raw(lifecycle).raw("\n");
    }
    first = false;
  }

  if (json) {
    output.raw("]}\n");
  }
}

template <Allocator Memory>
void tabList(Output<Memory> &output, const WorkspaceSnapshot &reply, bool json) {
  output.raw(json ? "[" : "ID\tPOSITION\tPANES\tLABEL\n");
  bool first = true;
  for (const auto &entry : reply.tabs) {
    if (json) {
      if (!first) {
        output.raw(",");
      }
      output.raw("{\"workspace_id\":").number(reply.workspace.id).raw(",\"tab_id\":").number(entry.tab_id).raw(",\"position\":").number(entry.position).raw(",\"pane_count\":").number(entry.pane_count).raw(",\"label\":").quoted(entry.label).raw("}");
    } else {
      output.number(entry.tab_id).raw("\t").number(entry.position).raw("\t").number(entry.pane_count).raw("\t").raw(entry.label).raw("\n");
    }
    first = false;
  }

  if (json) {
    output.raw("]\n");
  }
}

template <Allocator Memory>
void tabOperation(Channel<Memory> &session, Output<Memory> &output, const TabOptions &options, TabLocation location) {
  using Action = TabOptions::Action;
  if (options.action == Action::get) {
    const auto reply = session.template exchange<TabSnapshot>(RequestTabSnapshot{.location = location});
    checkLocation(reply.location, location);
    tabSnapshot(output, reply, options.json);
    return;
  }

  if (options.json) {
    output.raw("{\"workspace_id\":").number(location.workspace.id).raw(",\"tab_id\":").number(location.tab_id);
  } else {
    output.raw("tab ").number(location.tab_id);
  }

  switch (options.action) {
  case Action::rename: {
    wireTabLabel(*options.label);
    const auto reply = session.template exchange<TabRenamed>(RenameTab{.location = location, .label = *options.label});
    checkLocation(reply.location, location);
    if (options.json) {
      output.raw(",\"label\":").quoted(reply.label);
    } else {
      output.raw(" renamed to ").raw(reply.label);
    }
    break;
  }
  case Action::close: {
    const auto reply = session.template exchange<TabClosed>(CloseTab{.location = location});
    checkLocation(reply.location, location);
    if (options.json) {
      output.raw(",\"closed\":true,\"workspace_closed\":").boolean(reply.workspace_closed);
    } else {
      output.raw(" closed");
    }
    break;
  }
  case Action::move: {
    const auto reply = session.template exchange<TabMoved>(MoveTab{.location = location, .direction = options.direction, .relative_to = options.relative});
    checkLocation(reply.location, location);
    output.raw(options.json ? ",\"position\":" : " moved to position ").number(reply.position);
    break;
  }
  default:
    throw Failure{"InvalidTabAction"};
  }

  output.raw(options.json ? "}\n" : "\n");
}

template <Allocator Memory>
int tab(Memory &memory, const TabOptions &options) {
  try {
    const auto workspace = options.workspace.resolve("TELAR_WORKSPACE_ID");
    Channel session{memory, options.socket, false};
    Output output{memory};
    if (options.action == TabOptions::Action::create) {
      Channel catalog_session{memory, options.socket, false};
      const auto catalog = catalog_session.catalog();
      const auto entry = std::ranges::find(catalog.entries, workspace, &WorkspaceListEntry::workspace);
      if (entry == catalog.entries.end()) {
        throw Failure{"workspace not found"};
      }
      const std::array shell{loginShell()};
      wireTabLabel(options.label.value_or(""), true);
      const auto opened = session.template exchange<PaneOpened>(LaunchTab{.workspace = workspace, .label = options.label.value_or(""), .size = launch_size, .launch = {.cwd = entry->path, .arguments = shell}});
      if (options.json) {
        output.raw("{\"workspace_id\":").number(workspace).raw(",\"tab_id\":").number(opened.location.tab_id).raw(",\"pane_id\":").number(opened.pane_id).raw(",\"pane_generation\":").number(opened.pane_generation).raw("}\n");
      } else {
        output.raw("tab ").number(opened.location.tab_id).raw(" opened in workspace ").number(workspace).raw(": pane ").number(opened.pane_id).raw("\n");
      }
    } else if (options.action == TabOptions::Action::list) {
      const auto reply = session.template exchange<WorkspaceSnapshot>(RequestWorkspaceSnapshot{.workspace = {.id = workspace}});
      if (reply.workspace.kind != WorkspaceLocation::Kind::workspace || reply.workspace.id != workspace) {
        throw Failure{"unexpected reply from the runtime"};
      }
      tabList(output, reply, options.json);
    } else {
      const TabLocation location{.workspace = {.id = workspace}, .tab_id = options.target.resolve("TELAR_TAB_ID")};
      tabOperation(session, output, options, location);
    }

    output.flush();
    return 0;
  } catch (const Failure &error) {
    std::fprintf(stderr, "telar tab: %s\n", error.what());
    return error.status();
  } catch (const std::exception &error) {
    std::fprintf(stderr, "telar tab: %s\n", error.what());
    return 1;
  }
}

}
