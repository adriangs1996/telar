#pragma once

#include "launch_directory.hpp"
#include "pane_service.hpp"
#include <algorithm>
#include <csignal>
#include <sys/stat.h>

namespace telar::runtime {

template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
class WorkspaceService {
public:
  explicit WorkspaceService(Memory &memory, RuntimeModel<Memory> &model, PaneService<Memory, Poller, History> &panes)
      : memory_(memory),
        model_(model),
        panes_(panes) {}

  Workspace<Memory> &require(WorkspaceLocation location) const {
    auto *workspace = model_.workspaces.find(location.id);
    if (location.kind != WorkspaceLocation::Kind::workspace || workspace == nullptr) {
      throw RequestError{FailureCode::workspace_not_found, "Workspace does not exist"};
    }

    return *workspace;
  }

  Tab<Memory> &requireTab(TabLocation location) const {
    auto *tab = require(location.workspace).tab(location.tab_id);
    if (tab == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "Tab does not exist"};
    }

    return *tab;
  }

  void open(ClientSession<Memory> &client, const OpenPane &request) {
    Pane<Memory> *pane = nullptr;
    bool created = false;

    if (request.target.kind == PaneTarget::Kind::pane) {
      pane = &panes_.require(request.target.id);
      if (pane->close_requested || pane->exit_status) {
        throw RequestError{FailureCode::pane_not_found, "pane not found"};
      }
    } else if (request.target.kind == PaneTarget::Kind::workspace) {
      auto &workspace = require(WorkspaceLocation{.id = request.target.id});
      pane = firstPane(workspace);
    } else {
      if (!request.launch) {
        throw RequestError{FailureCode::invalid_request, "default pane launch is missing"};
      }

      auto launch = resolveLaunchDirectory(model_, client, *request.launch);
      Workspace<Memory> *workspace = nullptr;

      for (auto *candidate : model_.workspaces.items()) {
        if (candidate != nullptr && candidate->path == launch.cwd) {
          workspace = candidate;
          break;
        }
      }

      if (workspace != nullptr) {
        pane = firstPane(*workspace);
        if (pane == nullptr && !workspace->tabs.empty()) {
          pane = &createAt(client, TabLocation{WorkspaceLocation{.id = workspace->id}, workspace->tabs.front().id}, launch, request.size);
          created = true;
        }
      } else {
        pane = &createRoot(client, launch, request.size, {});
        created = true;
      }
    }

    if (pane == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "workspace has no running pane"};
    }

    panes_.attach(client, *pane, request.size);
    sendOpened(client, request.request_id, *pane, created);
  }

  void createWorkspace(ClientSession<Memory> &client, const CreateWorkspace &request) {
    auto launch = resolveLaunchDirectory(model_, client, request.launch);
    if (request.create_cwd && request.launch.cwd_source == 0) {
      createDirectories(launch.cwd);
    }

    auto &pane = createRoot(client, launch, request.size, request.name, true);
    sendOpened(client, request.request_id, pane, true, GenerationField::omitted);
  }

  void createTab(ClientSession<Memory> &client, const CreateTab &request) {
    auto &workspace = require(request.workspace);
    requireGeometry(client, workspace);
    const auto launch = resolveLaunchDirectory(model_, client, request.launch, request.workspace);
    if (workspace.tabs.size() == maximum_tabs) {
      throw RequestError{FailureCode::resource_limit, "Workspace tab limit reached"};
    }

    const auto tab_id = nextTabIdentity();
    workspace.tabs.emplace_back(memory_, tab_id, request.label);

    try {
      auto &pane = createAt(client, TabLocation{request.workspace, tab_id}, launch, request.size);
      ++model_.next_tab_id;
      client.connection.send(TabCreated{
          .request_id = request.request_id,
          .location = pane.location,
          .position = static_cast<std::uint16_t>(workspace.tabs.size() - 1),
          .label = workspace.tabs.back().label,
          .root_pane_id = pane.id,
          .pane_generation = pane.generation,
      });
    } catch (...) {
      if (workspace.tabs.back().panes.empty()) {
        workspace.tabs.pop_back();
      }

      throw;
    }
  }

  Pane<Memory> &launchBackground(const LaunchTab &request) {
    if (request.launch.cwd_source != 0) {
      throw RequestError{FailureCode::invalid_request, "A background tab requires an explicit working directory"};
    }

    auto &workspace = require(WorkspaceLocation{.id = request.workspace});
    if (workspace.tabs.size() == maximum_tabs) {
      throw RequestError{FailureCode::resource_limit, "Workspace tab limit reached"};
    }

    const auto tab_id = nextTabIdentity();
    workspace.tabs.emplace_back(memory_, tab_id, request.label);
    try {
      auto launch = request.launch;
      if (launch.cwd.empty()) {
        launch.cwd = workspace.path;
      }

      auto &pane = panes_.launch(launch, TabLocation{.workspace = {.id = workspace.id}, .tab_id = tab_id}, request.size);
      workspace.tabs.back().panes.push_back(pane.id);
      ++model_.next_tab_id;
      ++model_.workspace_revision;
      return pane;
    } catch (...) {
      workspace.tabs.pop_back();
      throw;
    }
  }

  void launchTab(ClientSession<Memory> &client, const LaunchTab &request) {
    const auto &pane = launchBackground(request);
    notifyWorkspaceObservers(model_, pane.location.workspace.id, client.id);
    sendOpened(client, request.request_id, pane, false);
  }

  void createPane(ClientSession<Memory> &client, const CreatePane &request) {
    const auto *workspace = model_.workspaces.find(request.location.workspace.id);
    const auto *tab = workspace == nullptr ? nullptr : workspace->tab(request.location.tab_id);
    if (request.location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr || firstPane(*tab) == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "tab not found"};
    }

    auto &pane = createAt(client, request.location, request.launch, request.size);
    sendOpened(client, request.request_id, pane, true, GenerationField::omitted);
  }

  void renameWorkspace(ClientSession<Memory> &client, const RenameWorkspace &request) {
    require(request.workspace).name.assign(request.name);
    ++model_.workspace_revision;
    notifyWorkspaceObservers(model_, request.workspace.id, client.id);
    workspaceSnapshot(client, RequestWorkspaceSnapshot{request.request_id, request.workspace});
  }

  void renameTab(ClientSession<Memory> &client, const RenameTab &request) {
    auto &tab = requireTab(request.location);
    tab.label.assign(request.label);
    ++model_.workspace_revision;
    notifyWorkspaceObservers(model_, request.location.workspace.id, client.id);
    client.connection.send(TabRenamed{.request_id = request.request_id,
                                      .location = request.location,
                                      .label = tab.label});
  }

  void moveTab(ClientSession<Memory> &client, const MoveTab &request) {
    auto &workspace = require(request.location.workspace);
    auto &tab = requireTab(request.location);
    const auto from = static_cast<std::size_t>(&tab - workspace.tabs.data());
    auto to = from;

    if (request.relative_to) {
      auto *relative = workspace.tab(*request.relative_to);
      if (relative == nullptr) {
        throw RequestError{FailureCode::tab_not_found, "Relative tab does not exist"};
      }

      to = static_cast<std::size_t>(relative - workspace.tabs.data());
      if (request.direction == TabMoveDirection::previous && from < to) {
        --to;
      }
      if (request.direction == TabMoveDirection::next && from > to) {
        ++to;
      }
    } else if (request.direction == TabMoveDirection::previous && from != 0) {
      to = from - 1;
    } else if (request.direction == TabMoveDirection::next && from + 1 < workspace.tabs.size()) {
      to = from + 1;
    }

    if (from < to) {
      std::rotate(workspace.tabs.begin() + from, workspace.tabs.begin() + from + 1, workspace.tabs.begin() + to + 1);
    } else if (to < from) {
      std::rotate(workspace.tabs.begin() + to, workspace.tabs.begin() + from, workspace.tabs.begin() + from + 1);
    }

    ++model_.workspace_revision;
    notifyWorkspaceObservers(model_, request.location.workspace.id, client.id);
    client.connection.send(TabMoved{.request_id = request.request_id,
                                    .location = request.location,
                                    .position = static_cast<std::uint16_t>(to)});
  }

  void closePane(ClientSession<Memory> &client, const ClosePane &request) {
    if (client.attachment(request.pane_id) == nullptr) {
      throw RequestError{FailureCode::pane_not_found, "pane not attached"};
    }

    auto &pane = panes_.require(request.pane_id);
    pane.requestClose();
  }

  void collectExited() {
    for (auto *pane : model_.panes.items()) {
      if (pane == nullptr || !pane->output_closed || !pane->exit_status || pane->observers != 0) {
        continue;
      }

      retainFinalText(*pane);

      const auto location = pane->location;
      const auto identity = pane->id;
      panes_.remove(identity);
      auto *workspace = model_.workspaces.find(location.workspace.id);
      auto *tab = workspace == nullptr ? nullptr : workspace->tab(location.tab_id);
      if (tab == nullptr) {
        leaveEmptyViews(location.workspace.id);
        continue;
      }

      std::erase(tab->panes, identity);
      if (!tab->panes.empty()) {
        leaveEmptyViews(location.workspace.id);
        continue;
      }

      std::erase_if(workspace->tabs, [&](const auto &entry) { return entry.id == location.tab_id; });
      const bool workspace_closed = workspace->tabs.empty();
      const auto previous = workspace_closed ? previousWorkspace(model_, workspace->id) : std::nullopt;
      if (workspace_closed) {
        model_.workspaces.erase(workspace->id);
      }

      ++model_.workspace_revision;
      for (auto *client : model_.clients.items()) {
        if (client == nullptr || client->workspace != location.workspace.id) {
          continue;
        }

        try {
          publishTabClosed(*client, TabClosed{.location = location,
                                              .workspace_closed = workspace_closed,
                                              .previous_workspace = previous});
        } catch (...) {
          client->connection.closing = true;
        }

        if (workspace_closed) {
          panes_.detachAll(*client);
        }
      }
      leaveEmptyViews(location.workspace.id);
    }
  }

  void closeTab(ClientSession<Memory> &client, const CloseTab &request) {
    auto closed = removeTab(request.location);
    notifyWorkspaceObservers(model_, request.location.workspace.id, client.id, closed.previous_workspace);
    closed.request_id = request.request_id;
    client.connection.send(closed);
  }

  void closeWorkspace(std::uint64_t identity) {
    auto *workspace = model_.workspaces.find(identity);
    while (workspace != nullptr && !workspace->tabs.empty()) {
      const auto closed = removeTab(TabLocation{WorkspaceLocation{.id = identity}, workspace->tabs.front().id});
      for (auto *client : model_.clients.items()) {
        if (client == nullptr || !client->connection.negotiated || client->connection.closing || client->workspace != identity) {
          continue;
        }

        try {
          publishTabClosed(*client, closed);
        } catch (...) {
          client->connection.closing = true;
        }
      }

      workspace = model_.workspaces.find(identity);
    }
  }

  void tabSnapshot(ClientSession<Memory> &client, const RequestTabSnapshot &request) {
    const auto *workspace = model_.workspaces.find(request.location.workspace.id);
    const auto *tab = workspace == nullptr ? nullptr : workspace->tab(request.location.tab_id);
    if (request.location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr || firstPane(*tab) == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "tab not found"};
    }

    client.connection.defer(request);
  }

  void workspaceSnapshot(ClientSession<Memory> &client, const RequestWorkspaceSnapshot &request) {
    const auto *workspace = model_.workspaces.find(request.workspace.id);
    if (request.workspace.kind != WorkspaceLocation::Kind::workspace || workspace == nullptr) {
      throw RequestError{FailureCode::workspace_not_found, "workspace not found"};
    }

    client.connection.defer(request);
    if (client.role == ClientRole::control && client.subscribed) {
      client.workspace = workspace->id;
    }
  }

  void publishList(ClientSession<Memory> &client) {
    std::array<WorkspaceListEntry, 64> entries{};
    std::size_t count = 0;

    for (const auto *workspace : model_.workspaces.items()) {
      if (workspace != nullptr) {
        entries[count++] = WorkspaceListEntry{
            .workspace = workspace->id,
            .name = workspace->displayName(),
            .path = workspace->path,
            .tab_count = static_cast<std::uint16_t>(workspace->tabs.size()),
            .branch = workspace->git_branch.view(),
            .dirty = workspace->git_dirty,
        };
      }
    }

    std::array<WorktreeListEntry, Worktrees<Memory>::capacity> worktrees;
    std::size_t worktree_count = 0;
    for (const auto *entry : model_.worktrees.items()) {
      if (entry != nullptr) {
        worktrees[worktree_count++] = entry->entry();
      }
    }

    client.connection.send(WorkspaceList{.revision = model_.workspace_revision,
                                         .entries = std::span<const WorkspaceListEntry>{entries}.first(count),
                                         .worktrees = std::span{worktrees}.first(worktree_count)});
    client.workspace_revision = model_.workspace_revision;
  }

private:
  static void publishTabClosed(ClientSession<Memory> &client, const TabClosed &closed) {
    if (!client.connection.trySend(closed)) {
      client.workspace_resync = ResyncRequired{.workspace = closed.location.workspace,
                                               .workspace_closed = closed.workspace_closed,
                                               .previous_workspace = closed.previous_workspace};
    }
  }

  TabClosed removeTab(TabLocation location) {
    auto *workspace = model_.workspaces.find(location.workspace.id);
    auto *tab = workspace == nullptr ? nullptr : workspace->tab(location.tab_id);
    if (location.workspace.kind != WorkspaceLocation::Kind::workspace || tab == nullptr) {
      throw RequestError{FailureCode::tab_not_found, "tab not found"};
    }

    const auto previous = workspace->tabs.size() == 1 ? previousWorkspace(model_, workspace->id) : std::nullopt;
    for (const auto identity : tab->panes) {
      if (auto *pane = model_.panes.find(identity)) {
        pane->requestClose();
      }
    }

    std::erase_if(workspace->tabs, [&](const auto &candidate) { return candidate.id == location.tab_id; });
    const bool workspace_closed = workspace->tabs.empty();
    if (workspace_closed) {
      model_.workspaces.erase(workspace->id);
    }

    ++model_.workspace_revision;
    return TabClosed{.location = location, .workspace_closed = workspace_closed, .previous_workspace = previous};
  }

  void leaveEmptyViews(std::uint64_t workspace) noexcept {
    for (const auto *pane : model_.panes.items()) {
      if (pane != nullptr && pane->location.workspace.id == workspace && pane->exit_status) {
        return;
      }
    }

    for (auto *client : model_.clients.items()) {
      if (client != nullptr && client->workspace == workspace && client->attachments.empty()) {
        panes_.detachAll(*client);
      }
    }
  }

  void retainFinalText(Pane<Memory> &pane) noexcept {
    const auto exit_code = pane.exitCode();
    try {
      TextReader reader{memory_, pane.terminal, ExitedPanes::maximum_bytes};
      reader.read(PaneTextSource::recent, ExitedPanes::kept_rows);
      std::size_t rows = 0;
      checkGhostty(ghostty_terminal_get(pane.terminal.handle(), GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &rows));
      model_.exited_panes.record(pane.id, pane.generation, PaneText{
                                                               .truncated = reader.truncated() || rows > ExitedPanes::kept_rows,
                                                               .text = reader.text(),
                                                               .exit_code = exit_code,
                                                           });
    } catch (...) {
      model_.exited_panes.record(pane.id, pane.generation, PaneText{.truncated = true, .exit_code = exit_code});
    }
  }

  Pane<Memory> &createRoot(ClientSession<Memory> &client, const Launch &launch, TerminalSize size, std::string_view name, bool replace_view = false) {
    if (model_.next_tab_id == 0 || model_.workspaces.nextCounter() == 0) {
      throw RequestError{FailureCode::resource_limit, "could not create workspace"};
    }

    const auto workspace_id = model_.workspaces.nextId();
    auto workspace = makeOwned<Workspace<Memory>>(memory_, memory_, workspace_id, launch.cwd, name);
    const auto tab_id = model_.next_tab_id;
    workspace->tabs.emplace_back(memory_, tab_id, std::string_view{});
    model_.workspaces.insertProvisional(workspace_id, std::move(workspace));
    Pane<Memory> *pane = nullptr;

    try {
      const TabLocation location{.workspace = {.id = workspace_id},
                                 .tab_id = tab_id};
      pane = &panes_.launch(launch, location, size);
      model_.workspaces.find(workspace_id)->tabs.front().panes.push_back(pane->id);
      if (replace_view) {
        panes_.detachAll(client);
      }
      panes_.attach(client, *pane, size);
    } catch (...) {
      if (pane != nullptr) {
        panes_.remove(pane->id);
      }

      model_.workspaces.erase(workspace_id);
      throw;
    }

    model_.workspaces.advanceCounter(workspace_id + 1);
    ++model_.next_tab_id;
    ++model_.workspace_revision;
    notifyWorkspaceObservers(model_, workspace_id, client.id);
    return *pane;
  }

  std::uint64_t nextTabIdentity() const {
    if (model_.next_tab_id == 0) {
      throw RequestError{FailureCode::spawn_failed, "could not start the command"};
    }

    return model_.next_tab_id;
  }

  Pane<Memory> &createAt(ClientSession<Memory> &client, TabLocation location, Launch launch, TerminalSize size) {
    auto &workspace = require(location.workspace);
    auto &tab = requireTab(location);
    requireGeometry(client, workspace);

    launch = resolveLaunchDirectory(model_, client, launch, location);
    if (tab.panes.size() == maximum_panes_per_tab) {
      throw RequestError{FailureCode::resource_limit, "Tab pane limit reached"};
    }

    if (launch.cwd.empty()) {
      launch.cwd = workspace.path;
    }

    auto &pane = panes_.launch(launch, location, size);

    try {
      panes_.attach(client, pane, size);
      tab.panes.push_back(pane.id);
    } catch (...) {
      panes_.remove(pane.id);
      throw;
    }

    ++model_.workspace_revision;
    notifyWorkspaceObservers(model_, workspace.id, client.id);
    return pane;
  }

  Pane<Memory> *firstPane(const Workspace<Memory> &workspace) const noexcept {
    return workspace.tabs.empty() ? nullptr : firstPane(workspace.tabs.front());
  }

  Pane<Memory> *firstPane(const Tab<Memory> &tab) const noexcept {
    for (const auto identity : tab.panes) {
      if (auto *pane = model_.panes.find(identity); pane != nullptr && !pane->close_requested && !pane->exit_status) {
        return pane;
      }
    }

    return nullptr;
  }

  void requireGeometry(const ClientSession<Memory> &client, Workspace<Memory> &workspace) {
    if (!acquireGeometry(model_, client, workspace)) {
      throw RequestError{FailureCode::resource_limit, "workspace geometry is leased by another client"};
    }
  }

  static void createDirectories(std::string_view path) {
    if (path.empty() || path.size() >= PATH_MAX || path.front() != '/') {
      throw RequestError{FailureCode::invalid_request, "Working directory must be an absolute path"};
    }

    std::array<char, PATH_MAX> directory{};
    std::copy(path.begin(), path.end(), directory.begin());
    for (std::size_t index = 1; index <= path.size(); ++index) {
      if (directory[index] != '/' && directory[index] != '\0') {
        continue;
      }

      const char separator = directory[index];
      directory[index] = '\0';
      if (::mkdir(directory.data(), 0700) != 0 && errno != EEXIST) {
        throw SystemError{"create working directory"};
      }

      directory[index] = separator;
    }
  }

  enum class GenerationField { included,
                               omitted };

  static void sendOpened(ClientSession<Memory> &client, std::uint64_t request, const Pane<Memory> &pane, bool created, GenerationField generation = GenerationField::included) {
    client.connection.send(PaneOpened{
        .request_id = request,
        .pane_id = pane.id,
        .location = pane.location,
        .created = created,
        .pane_generation = generation == GenerationField::included ? pane.generation : 0,
    });
  }

  static constexpr std::size_t maximum_tabs = 64;
  static constexpr std::size_t maximum_panes_per_tab = 64;
  Memory &memory_;
  RuntimeModel<Memory> &model_;
  PaneService<Memory, Poller, History> &panes_;
};

}
