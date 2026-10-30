#pragma once

#include "../model/runtime_model.hpp"

namespace telar::runtime {

template <Allocator Memory>
class ClipboardService {
public:
  explicit ClipboardService(RuntimeModel<Memory> &model) : model_(model) {}

  static bool eligible(const ClientSession<Memory> &client, const Pane<Memory> &pane) noexcept {
    const auto *attachment = client.attachment(pane.id);
    return !pane.close_requested && !pane.output_closed && client.role == ClientRole::interactive && !client.connection.closing && attachment != nullptr && attachment->desktop && attachment->desktop->pane_generation == pane.generation && attachment->desktop->visible && attachment->desktop->clipboard;
  }

  void configure(Pane<Memory> &pane) {
    std::array<control::ClipboardRoute, control::ClipboardGrants::capacity> routes;
    std::size_t count = 0;
    const ClientSession<Memory> *preferred = nullptr;
    for (const auto *client : model_.clients.items()) {
      if (client == nullptr || !eligible(*client, pane)) {
        continue;
      }
      if (count == routes.size()) {
        break;
      }
      routes[count++] = {client->id, client->generation};
      if (preferred == nullptr || precedes(*client, *preferred, pane.id)) {
        preferred = client;
      }
    }
    pane.terminal.clipboardControl().routes(std::span{routes}.first(count), preferred != nullptr ? std::optional{control::ClipboardRoute{preferred->id, preferred->generation}} : std::nullopt);
  }

  bool advance(Pane<Memory> &pane, std::chrono::steady_clock::time_point now) {
    auto &clipboard = pane.terminal.clipboardControl();
    clipboard.expire(now);
    if (const auto cancellation = clipboard.cancellation()) {
      auto *client = model_.clients.find(cancellation->route.client);
      if (client == nullptr || client->generation != cancellation->route.generation || client->connection.closing) {
        clipboard.cancelled();
      } else {
        try {
          client->connection.send(CancelClipboardDesktop{cancellation->ticket});
          clipboard.cancelled();
        } catch (const ResponseQueueFull &) {
        } catch (const std::bad_alloc &) {
        }
      }
    }
    const auto route = clipboard.route();
    if (route) {
      auto *client = model_.clients.find(route->client);
      if (client == nullptr || client->generation != route->generation || !eligible(*client, pane)) {
        configure(pane);
      } else {
        try {
          if (const auto request = clipboard.request(pane.id, pane.generation)) {
            client->connection.send(*request);
            clipboard.announced();
          } else {
            clipboard.expire(std::chrono::steady_clock::now());
            if (const auto execution = clipboard.execution()) {
              client->connection.send(*execution);
              clipboard.committed();
            }
          }
        } catch (const ResponseQueueFull &) {
          // The owned request survives queue pressure until its deadline.
        } catch (const std::bad_alloc &) {
          // The deadline also bounds retries under the runtime memory budget.
        }
      }
    }
    if (clipboard.hasReply()) {
      pane.terminal.resumeControl();
      return true;
    }
    return false;
  }

  Pane<Memory> *complete(ClientSession<Memory> &sender, const CompleteClipboardDesktop &completion) {
    auto *pane = model_.panes.find(completion.ticket.pane_id);
    if (pane == nullptr || pane->generation != completion.ticket.pane_generation || sender.generation != completion.ticket.client_generation || !eligible(sender, *pane)) {
      return nullptr;
    }
    pane->terminal.clipboardControl().expire(std::chrono::steady_clock::now());
    if (!pane->terminal.clipboardControl().complete({sender.id, sender.generation}, completion)) {
      return nullptr;
    }
    pane->terminal.resumeControl();
    return pane;
  }

private:
  static bool precedes(const ClientSession<Memory> &candidate, const ClientSession<Memory> &current, std::uint64_t pane) noexcept {
    const bool candidate_focus = candidate.attachment(pane)->desktop->focused;
    const bool current_focus = current.attachment(pane)->desktop->focused;
    if (candidate_focus != current_focus) {
      return candidate_focus;
    }
    const auto candidate_input = candidate.last_input_pane == pane ? candidate.last_input_sequence : 0;
    const auto current_input = current.last_input_pane == pane ? current.last_input_sequence : 0;
    return candidate_input != current_input ? candidate_input > current_input : candidate.id < current.id;
  }

  RuntimeModel<Memory> &model_;
};

}
