#pragma once

#include "../diagnostics/trace.hpp"
#include "../model/runtime_model.hpp"
#include "../terminal/text_reader.hpp"

namespace telar::runtime {

template <Allocator Memory>
class ResponseProjection {
public:
  explicit ResponseProjection(Memory &memory, RuntimeModel<Memory> &model) noexcept : memory_(memory), model_(model) {}

  void operator()(const DeferredResponse &response, auto &&send) const {
    TELAR_TRACE("runtime.projectResponse");
    std::visit([&](const auto &request) { project(request, send); }, response);
  }

private:
  static bool matchesSnapshot(const Pane<Memory> &pane, TabLocation location) noexcept {
    return !pane.close_requested && !pane.exit_status && pane.location.workspace.kind == location.workspace.kind && pane.location.workspace.id == location.workspace.id && pane.location.tab_id == location.tab_id;
  }

  void project(const ReadPane &request, auto &send) const {
    auto *pane = model_.panes.find(request.pane_id);
    if (pane == nullptr || (request.pane_generation != 0 && pane->generation != request.pane_generation)) {
      if (const auto *exited = model_.exited_panes.find(request.pane_id, request.pane_generation)) {
        send(exited->response(request));
      } else {
        send(RequestFailed{.request_id = request.request_id, .code = FailureCode::pane_not_found, .message = "pane closed before its text was read"});
      }
      return;
    }

    constexpr std::size_t maximum_text_bytes = 262144;
    TextReader reader{memory_, pane->terminal, maximum_text_bytes};
    reader.read(request.source, request.rows);
    send(PaneText{.request_id = request.request_id, .pane_id = pane->id, .truncated = reader.truncated(), .text = reader.text(), .exit_code = pane->exitCode()});
  }

  void project(const RequestTabSnapshot &request, auto &send) const {
    std::array<PaneDescriptor, 64> descriptors;
    std::size_t count = 0;
    for (const auto *pane : model_.panes.items()) {
      if (pane != nullptr && matchesSnapshot(*pane, request.location)) {
        descriptors[count++] = PaneDescriptor{.pane_id = pane->id, .lifecycle = PaneLifecycle::running, .pane_generation = pane->generation};
      }
    }

    send(TabSnapshot{.request_id = request.request_id, .location = request.location, .panes = std::span{descriptors}.first(count)});
  }

  void project(const RequestWorkspaceSnapshot &request, auto &send) const {
    const auto *workspace = model_.workspaces.find(request.workspace.id);
    if (request.workspace.kind != WorkspaceLocation::Kind::workspace || workspace == nullptr) {
      send(RequestFailed{.request_id = request.request_id, .code = FailureCode::workspace_not_found, .message = "workspace closed before its snapshot was sent"});
      return;
    }

    std::array<TabDescriptor, 64> descriptors;
    std::array<PaneForeground, 256> foregrounds;
    std::size_t foreground_count = 0;
    std::size_t count = 0;
    for (const auto &tab : workspace->tabs) {
      const auto first = foreground_count;
      const TabLocation location{request.workspace, tab.id};
      for (const auto *pane : model_.panes.items()) {
        if (pane != nullptr && matchesSnapshot(*pane, location)) {
          const auto name = pane->foreground.view();
          foregrounds[foreground_count++] = PaneForeground{pane->id, name.empty() ? "shell" : name};
        }
      }

      const auto names = std::span{foregrounds}.subspan(first, foreground_count - first);
      descriptors[count] = TabDescriptor{.tab_id = tab.id, .position = static_cast<std::uint16_t>(count), .pane_count = static_cast<std::uint16_t>(names.size()), .label = tab.label, .foregrounds = names};
      ++count;
    }

    send(WorkspaceSnapshot{.request_id = request.request_id, .workspace = request.workspace, .name = workspace->displayName(), .tabs = std::span{descriptors}.first(count)});
  }

  void project(const QueryLimits &request, auto &send) const {
    std::array<LimitListEntry, 2 * LimitLedger::capacity> entries;
    std::size_t count = 0;
    for (const auto &row : model_.limits.runtime.rows()) {
      entries[count++] = {row.reach(), LimitOrigin::runtime, row.hits, row.last_ms};
    }

    for (const auto &row : model_.limits.clients.rows()) {
      entries[count++] = {row.reach(), LimitOrigin::client, row.hits, row.last_ms};
    }

    send(LimitList{request.request_id, model_.limits.runtime.evicted(), model_.limits.clients.evicted(), model_.limits.refused_reports, std::span{entries}.first(count)});
  }

  Memory &memory_;
  RuntimeModel<Memory> &model_;
};

template <Allocator Memory>
ResponseProjection(Memory &memory, RuntimeModel<Memory> &model) -> ResponseProjection<Memory>;

}
