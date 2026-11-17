module telar.gui.application;

import std;
import telar.gui.features.notifications;
import telar.gui.foundation.terminal;
import telar.tbc;
import telar.gui.foundation.core;
import telar.gui.features.terminal.graphics;
import telar.config.client;
import telar.config.runtime;
import telar.wire.clients;
import telar.wire.layout;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.shell.syntax;

namespace telar::gui::application {

  Change Session::apply(const ClientCommand& message, const ClientCommandHandler& handler) {
    CompleteClientCommand reply;

    static_cast<ClientCommand&>(reply) = message;
    // The reply starts as the command, text included: the actions
    // whose text is only a request argument clear it.
    reply.status = ClientCommandStatus::applied;
    auto change = Change::model;

    try {
      if (message.status != ClientCommandStatus::request) {
        throw EncodingError{"Invalid routed command status"};
      }

      change = executeCommand(message, reply, handler);
    } catch (const std::exception& error) {
      reply.status = ClientCommandStatus::failed;
      reply.text = error.what();
      send(reply);

      return Change::none;
    }

    send(reply);

    return change;
  }

  Change Session::executeCommand(const ClientCommand& message, tbc::view<CompleteClientCommand&, tbc::lt::a> reply, const ClientCommandHandler& handler) {
    switch (message.action) {
    case ClientAction::layout_get:
      reply.text = workbench::exportLayout(*this);

      return Change::none;
    case ClientAction::layout_apply:
      workbench::importLayout(*this, message.text);
      reply.text = {};

      return Change::model;
    case ClientAction::tab_next:
    case ClientAction::tab_previous:
    case ClientAction::workspace_select:
    case ClientAction::tab_create:
    case ClientAction::tab_select:
      executeNavigationCommand(message, reply);

      return Change::model;
    case ClientAction::pane_create:
    case ClientAction::pane_split:
    case ClientAction::pane_close:
    case ClientAction::pane_focus:
    case ClientAction::pane_resize:
    case ClientAction::pane_fullscreen:
    case ClientAction::pane_scroll:
    case ClientAction::pane_copy:
      executePaneCommand(message, reply);

      return Change::model;
    case ClientAction::sidebar_get:
    case ClientAction::sidebar_show:
    case ClientAction::sidebar_hide:
    case ClientAction::sidebar_resize:
      return executeSidebarCommand(message, reply);
    case ClientAction::workspace_list_collapse:
    case ClientAction::workspace_list_expand:
      setWorkspaceListCollapsed(message.action == ClientAction::workspace_list_collapse);

      return Change::sidebar;
    case ClientAction::client_clipboard_copy:
      clipboard_ = message.text;
      reply.text = {};
      reply.status = ClientCommandStatus::admitted;

      return Change::clipboard;
    case ClientAction::notification_dismiss:
      if (!notifications::dismiss(*this, notifications::NotificationId{message.target_id})) {
        throw EncodingError{"NotificationNotFound"};
      }

      return Change::notification;
    default:
      handler(message, reply);

      return Change::none;
    }
  }

  void Session::executeNavigationCommand(const ClientCommand& message, CompleteClientCommand& reply) {
    switch (message.action) {
    case ClientAction::tab_next:
    case ClientAction::tab_previous: {
      if (!active_tab_) {
        throw EncodingError{"NoActiveTab"};
      }

      const auto before = *active_tab_;

      workbench::selectTabBeside(*this, message.action == ClientAction::tab_next ? 1 : -1);
      reply.status = sameTab(before, *active_tab_) ? ClientCommandStatus::applied : ClientCommandStatus::admitted;
      break;
    }
    case ClientAction::workspace_select: {
      if (message.target_id == 0) {
        throw EncodingError{"InvalidWorkspaceId"};
      }

      const WorkspaceLocation location{WorkspaceLocation::Kind::workspace, message.target_id};

      if (std::ranges::none_of(workspaces_, [&](const auto& workspace) {
            return workspace.location.kind == WorkspaceLocation::Kind::workspace && workspace.location.id == message.target_id;
          })) {
        throw EncodingError{"WorkspaceNotFound"};
      }

      if (active_tab_ && sameWorkspace(active_tab_->workspace, location)) {
        break;
      }

      if (!workbench::selectWorkspace(*this, location)) {
        throw EncodingError{"ClientBusy"};
      }

      reply.status = ClientCommandStatus::admitted;
      break;
    }
    case ClientAction::tab_create:
      if (workbench::createTab(*this, message.text) != TabCreationOutcome::requested) {
        throw EncodingError{"ClientBusy"};
      }

      reply.text = {};
      reply.status = ClientCommandStatus::admitted;
      break;
    case ClientAction::tab_select: {
      const auto tab = std::ranges::find_if(tabs_, [&](const auto& entry) {
        return entry->location.tab_id == message.target_id;
      });
      if (message.target_id == 0 || tab == tabs_.end()) {
        throw EncodingError{"TabNotFound"};
      }

      if (active_tab_ && sameTab(*active_tab_, (*tab)->location)) {
        break;
      }

      workbench::selectTab(*this, (*tab)->location);
      reply.status = ClientCommandStatus::admitted;
      break;
    }
    default:
      throw EncodingError{"Invalid navigation command"};
    }
  }

  void Session::admitPaneSplit(ClientLayoutAxis axis, CompleteClientCommand& reply) {
    if (!workbench::split(*this, axis)) {
      throw EncodingError{"PaneCreationUnavailable"};
    }

    reply.status = ClientCommandStatus::admitted;
  }

  void Session::executePaneCommand(const ClientCommand& message, CompleteClientCommand& reply) {
    switch (message.action) {
    case ClientAction::pane_create:
      admitPaneSplit(ClientLayoutAxis::horizontal, reply);
      break;
    case ClientAction::pane_split:
      if (message.text != "horizontal" && message.text != "vertical") {
        throw EncodingError{"InvalidSplitAxis"};
      }

      focusCommandPane(message.target_id);
      admitPaneSplit(message.text == "horizontal" ? ClientLayoutAxis::horizontal : ClientLayoutAxis::vertical, reply);
      reply.text = {};
      break;
    case ClientAction::pane_close:
      focusCommandPane(message.target_id);
      if (!workbench::closePane(*this, message.target_id)) {
        throw EncodingError{"PaneClosureUnavailable"};
      }

      reply.status = ClientCommandStatus::admitted;
      break;
    case ClientAction::pane_focus:
      focusCommandPane(message.target_id);
      break;
    case ClientAction::pane_resize: {
      const auto direction = parseDirection(message.text);

      focusCommandPane(message.target_id);
      if (!workbench::resizeToward(*this, direction)) {
        throw EncodingError{"PaneResizeUnavailable"};
      }

      reply.text = {};
    } break;
    case ClientAction::pane_fullscreen:
      focusCommandPane(message.target_id);
      workbench::toggleFullscreen(*this);
      reply.value = activeTab()->fullscreen;
      break;
    case ClientAction::pane_scroll:
      if (message.value < std::numeric_limits<std::int32_t>::min() || message.value > std::numeric_limits<std::int32_t>::max()) {
        throw EncodingError{"InvalidScrollDelta"};
      }

      if (!commandPane(message.target_id).attached || features::terminal::copy_mode::view(copy_mode_).active()) {
        throw EncodingError{"PaneViewportUnavailable"};
      }

      scroll({.pane_id = message.target_id, .rows = -message.value});
      break;
    case ClientAction::pane_copy:
      if (!commandPane(message.target_id).attached) {
        throw EncodingError{"TerminalPaneNotAttached"};
      }

      send(CopyRangeParser::parse(message.target_id, message.text));
      reply.text = {};
      reply.status = ClientCommandStatus::admitted;
      break;
    default:
      throw EncodingError{"Invalid pane command"};
    }
  }

  Change Session::executeSidebarCommand(const ClientCommand& message, CompleteClientCommand& reply) {
    bool changed = false;

    if (message.action == ClientAction::sidebar_resize) {
      const auto width = SidebarColumns::clamp(host_columns_, message.value);

      changed = width != sidebar_columns_;
      sidebar_columns_ = width;
      if (changed) {
        workbench::retainLayout(*this);
      }
    } else if (message.action != ClientAction::sidebar_get) {
      changed = configuration_.sidebar_visible != (message.action == ClientAction::sidebar_show);
      if (changed) {
        setSidebarVisible(message.action == ClientAction::sidebar_show);
      }
    }

    reply.value = sidebar_columns_;
    reply.text = configuration_.sidebar_visible ? "visible" : "hidden";

    return changed ? Change::sidebar : Change::none;
  }

  PaneDirection Session::parseDirection(std::string_view text) {
    if (text == "left") {
      return PaneDirection::left;
    }

    if (text == "right") {
      return PaneDirection::right;
    }

    if (text == "up") {
      return PaneDirection::up;
    }

    if (text == "down") {
      return PaneDirection::down;
    }

    throw EncodingError{"Invalid pane direction"};
  }

  const Pane<Memory>& Session::commandPane(std::uint64_t identity) const {
    const auto* pane = findPane(identity);
    if (pane == nullptr || !active_tab_ || !sameTab(pane->location, *active_tab_)) {
      throw EncodingError{"Pane does not belong to the active tab"};
    }

    return *pane;
  }

  void Session::focusCommandPane(std::uint64_t identity) {
    workbench::focusPane(*this, commandPane(identity).id);
  }

  Change Session::apply(const PaneFocusCommand& message) {
    auto outcome = PaneFocusOutcome::source_not_focused;
    const auto* source = focusedPane();
    if (source != nullptr && source->id == message.pane_id && source->generation == message.pane_generation) {
      const auto neighbor = workbench::neighbor(*this, message.direction);

      outcome = neighbor == 0 ? PaneFocusOutcome::no_neighbor : PaneFocusOutcome::focused;
      if (neighbor != 0) {
        workbench::focusPane(*this, neighbor);
      }
    }

    const auto* focused = focusedPane();

    send(CompletePaneFocus{message.requester, message.request_id, message.pane_id, message.pane_generation, outcome, focused == nullptr ? 0 : focused->id});

    return Change::model;
  }

}
