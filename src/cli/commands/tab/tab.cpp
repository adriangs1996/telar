module telar.cli.commands.tab;

import telar.sys.posix;

import telar.tbc;
import telar.cli.console.output;
import telar.platform.process;
import telar.cli.console.command_limit;
import telar.platform.primitives;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::runtime::cli::sessions {

  namespace {

    void tabSnapshot(Output& output, const TabSnapshot& reply, bool json) {
      if (json) {
        output.text("{\"workspace_id\":").number(reply.location.workspace.id).text(",\"tab_id\":").number(reply.location.tab_id).text(",\"panes\":[");
      } else {
        output.text("PANE\tGENERATION\tLIFECYCLE\n");
      }

      bool first = true;

      for (const auto& pane : reply.panes) {
        const auto* const lifecycle = pane.lifecycle == PaneLifecycle::running ? "running" : "exited";

        if (json) {
          if (!first) {
            output.text(",");
          }

          output.text("{\"pane_id\":").number(pane.pane_id).text(",\"pane_generation\":").number(pane.pane_generation).text(",\"lifecycle\":").json(lifecycle).text("}");
        } else {
          output.number(pane.pane_id).text("\t").number(pane.pane_generation).text("\t").text(lifecycle).text("\n");
        }

        first = false;
      }

      if (json) {
        output.text("]}\n");
      }
    }

    void tabList(Output& output, const WorkspaceSnapshot& reply, bool json) {
      output.text(json ? "[" : "ID\tPOSITION\tPANES\tLABEL\n");
      bool first = true;

      for (const auto& entry : reply.tabs) {
        if (json) {
          if (!first) {
            output.text(",");
          }

          output.text("{\"workspace_id\":").number(reply.workspace.id).text(",\"tab_id\":").number(entry.tab_id).text(",\"position\":").number(entry.position).text(",\"pane_count\":").number(entry.pane_count).text(",\"label\":").json(entry.label).text("}");
        } else {
          output.number(entry.tab_id).text("\t").number(entry.position).text("\t").number(entry.pane_count).text("\t").text(entry.label).text("\n");
        }

        first = false;
      }

      if (json) {
        output.text("]\n");
      }
    }

    // Renames, closes or moves the tab and writes what the reply says.
    void tabEdit(Channel& session, Output& output, const TabOptions& options, TabLocation location) {
      using Action = TabOptions::Action;

      switch (options.action) {
      case Action::rename: {
        wireTabLabel(*options.label);
        const auto reply = session.template exchange<TabRenamed>(RenameTab{.location = location, .label = *options.label});

        checkLocation(reply.location, location);
        if (options.json) {
          output.text(",\"label\":").json(reply.label);
        } else {
          output.text(" renamed to ").text(reply.label);
        }

        return;
      }
      case Action::close: {
        const auto reply = session.template exchange<TabClosed>(CloseTab{.location = location});

        checkLocation(reply.location, location);
        if (options.json) {
          output.text(R"(,"closed":true,"workspace_closed":)").boolean(reply.workspace_closed);
        } else {
          output.text(" closed");
        }

        return;
      }
      case Action::move: {
        const auto reply = session.template exchange<TabMoved>(MoveTab{.location = location, .direction = options.direction, .relative_to = options.relative});

        checkLocation(reply.location, location);
        output.text(options.json ? ",\"position\":" : " moved to position ").number(reply.position);
        return;
      }
      case Action::list:
      case Action::get:
      case Action::create:
        break;
      }

      // An action that edits no tab, or one outside the enum.
      throw Failure{"InvalidTabAction"};
    }

    void tabOperation(Channel& session, Output& output, const TabOptions& options, TabLocation location) {
      using Action = TabOptions::Action;

      if (options.action == Action::get) {
        const auto reply = session.template exchange<TabSnapshot>(RequestTabSnapshot{.location = location});

        checkLocation(reply.location, location);
        tabSnapshot(output, reply, options.json);
        return;
      }

      if (options.json) {
        output.text("{\"workspace_id\":").number(location.workspace.id).text(",\"tab_id\":").number(location.tab_id);
      } else {
        output.text("tab ").number(location.tab_id);
      }

      tabEdit(session, output, options, location);

      output.text(options.json ? "}\n" : "\n");
    }

  }

  int tab(Memory& memory, const TabOptions& options) {
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

        const auto login = loginShell();
        const ds::Array shell{login.view()};

        wireTabLabel(options.label.valueOr(""), true);
        const auto opened = session.template exchange<PaneOpened>(LaunchTab{.workspace = workspace, .label = options.label.valueOr(""), .size = launch_size, .launch = {.cwd = entry->path, .arguments = shell}});

        if (options.json) {
          output.text("{\"workspace_id\":").number(workspace).text(",\"tab_id\":").number(opened.location.tab_id).text(",\"pane_id\":").number(opened.pane_id).text(",\"pane_generation\":").number(opened.pane_generation).text("}\n");
        } else {
          output.text("tab ").number(opened.location.tab_id).text(" opened in workspace ").number(workspace).text(": pane ").number(opened.pane_id).text("\n");
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
    } catch (const Failure& error) {
      writeFormatted(STDERR_FILENO, "telar tab: {}\n", std::string_view{error.what()});
      return error.status();
    } catch (const std::exception& error) {
      writeFormatted(STDERR_FILENO, "telar tab: {}\n", std::string_view{error.what()});
      return 1;
    }
  }

}
