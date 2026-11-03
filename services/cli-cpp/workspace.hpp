#pragma once

#include "session_channel.hpp"

namespace telar::runtime::cli::sessions {

template <Allocator Memory>
void workspaceEntry(Output<Memory> &output, const WorkspaceListEntry &entry, bool json) {
  if (json) {
    output.raw("{\"workspace_id\":").number(entry.workspace).raw(",\"name\":").quoted(entry.name).raw(",\"path\":").quoted(entry.path).raw(",\"tab_count\":").number(entry.tab_count).raw(",\"branch\":").quoted(entry.branch).raw(",\"dirty\":").boolean(entry.dirty).raw("}");
  } else {
    output.number(entry.workspace).raw("\t").raw(entry.name).raw("\t").raw(entry.path).raw("\t").number(entry.tab_count).raw("\t").raw(entry.branch).raw("\t").raw(entry.dirty ? "dirty" : "clean").raw("\n");
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
        output.raw("{\"workspace_id\":").number(opened.location.workspace.id).raw(",\"tab_id\":").number(opened.location.tab_id).raw(",\"pane_id\":").number(opened.pane_id).raw(",\"directory\":").quoted(directory, JsonEscapes::control).raw("}\n");
      } else {
        output.raw("workspace ").number(opened.location.workspace.id).raw(" created at ").raw(directory).raw("\n");
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
        output.raw("{\"workspace_id\":").number(id).raw(",\"name\":").quoted(reply.name).raw("}\n");
      } else {
        output.raw("workspace ").number(id).raw(" renamed to ").raw(reply.name).raw("\n");
      }
    } else {
      const auto wanted = options.action == Action::get ? std::optional{options.target.resolve("TELAR_WORKSPACE_ID")} : std::nullopt;
      Channel session{memory, options.socket, false};
      const auto catalog = session.catalog();
      if (!wanted) {
        output.raw(options.json ? "[" : "ID\tNAME\tDIRECTORY\tTABS\tBRANCH\tGIT\n");
      }
      bool first = true;
      for (const auto &entry : catalog.entries) {
        if (wanted && entry.workspace != *wanted) {
          continue;
        }
        if (options.json && !first) {
          output.raw(",");
        }
        workspaceEntry(output, entry, options.json);
        first = false;
      }

      if (wanted && first) {
        throw Failure{"workspace not found"};
      }
      if (options.json) {
        output.raw(wanted ? "\n" : "]\n");
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
