#pragma once

#include "session_channel.hpp"

namespace telar::runtime::cli::sessions {

template <Allocator Memory>
void workspaceEntry(Output<Memory> &output, const WorkspaceListEntry &entry, bool json) {
  if (json) {
    output.text("{\"workspace_id\":").number(entry.workspace).text(",\"name\":").json(entry.name).text(",\"path\":").json(entry.path).text(",\"tab_count\":").number(entry.tab_count).text(",\"branch\":").json(entry.branch).text(",\"dirty\":").boolean(entry.dirty).text("}");
  } else {
    output.number(entry.workspace).text("\t").text(entry.name).text("\t").text(entry.path).text("\t").number(entry.tab_count).text("\t").text(entry.branch).text("\t").text(entry.dirty ? "dirty" : "clean").text("\n");
  }
}

template <Allocator Memory>
int workspace(Memory &memory, const WorkspaceOptions &options) {
  try {
    using Action = WorkspaceOptions::Action;
    Output output{memory};
    if (options.action == Action::create) {
      const auto directory = realDirectory(*options.directory);
      const auto default_name = std::filesystem::path{directory}.filename().string();
      const auto name = options.name.value_or(default_name);
      if (name.empty()) {
        throw Failure{"MissingWorkspaceName"};
      }
      if (options.command.size() > workspace_command_words) {
        throw Failure{"WorkspaceCommandTooLong"};
      }

      std::array<std::string_view, workspace_command_words> command;
      std::size_t count = 0;
      for (const auto word : options.command) {
        command[count++] = word;
      }
      if (count == 0) {
        const auto configured = ::getenv("SHELL");
        command[count++] = configured && *configured ? configured : "/bin/sh";
      }

      auto size = workspace_size;
      size.cols = options.columns.value_or(size.cols);
      Channel session{memory, options.socket, true};
      wireTabLabel(name);
      const auto opened = session.template exchange<PaneOpened>(CreateWorkspace{.size = size, .name = name, .launch = {.cwd = directory, .arguments = std::span{command}.first(count)}}, false);
      if (options.json) {
        output.text("{\"workspace_id\":").number(opened.location.workspace.id).text(",\"tab_id\":").number(opened.location.tab_id).text(",\"pane_id\":").number(opened.pane_id).text(",\"directory\":").json(directory, JsonEscapes::control).text("}\n");
      } else {
        output.text("workspace ").number(opened.location.workspace.id).text(" created at ").text(directory).text("\n");
      }
    } else if (options.action == Action::rename) {
      const auto id = options.target.resolve("TELAR_WORKSPACE_ID");
      Channel session{memory, options.socket, false};
      wireTabLabel(*options.name);
      const auto reply = session.template exchange<WorkspaceSnapshot>(RenameWorkspace{.workspace = {.id = id}, .name = *options.name}, false);
      if (reply.workspace.kind != WorkspaceLocation::Kind::workspace || reply.workspace.id != id) {
        throw Failure{"unexpected reply from the runtime"};
      }
      if (options.json) {
        output.text("{\"workspace_id\":").number(id).text(",\"name\":").json(reply.name).text("}\n");
      } else {
        output.text("workspace ").number(id).text(" renamed to ").text(reply.name).text("\n");
      }
    } else {
      const auto wanted = options.action == Action::get ? std::optional{options.target.resolve("TELAR_WORKSPACE_ID")} : std::nullopt;
      Channel session{memory, options.socket, false};
      const auto catalog = session.catalog();
      if (!wanted) {
        output.text(options.json ? "[" : "ID\tNAME\tDIRECTORY\tTABS\tBRANCH\tGIT\n");
      }
      bool first = true;
      for (const auto &entry : catalog.entries) {
        if (wanted && entry.workspace != *wanted) {
          continue;
        }
        if (options.json && !first) {
          output.text(",");
        }
        workspaceEntry(output, entry, options.json);
        first = false;
      }

      if (wanted && first) {
        throw Failure{"workspace not found"};
      }
      if (options.json) {
        output.text(wanted ? "\n" : "]\n");
      }
    }

    output.flush();
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "telar workspace: %s\n", error.what());
    return 1;
  }
}

}
