module;
#include "telar_client/telar_client.hpp"
#include <concepts>
#include <generator>
#include <mutex>
#include <variant>
export module app_context;

export import app_state;

#define MAX_PARALLEL_EVENTS 1000
#define _lock_autorelease_block

export template <typename T>
concept Notifier = requires(T &notifier) {
  { notifier.wakeup() } noexcept -> std::same_as<void>;
};

export struct KeyPress {
  char key;
};

export struct Exit {
  std::uint8_t code = 0;
};

export struct WorkspaceUpdated {
  std::uint64_t revision = 0;
  std::vector<WorkspaceSummary> workspaces;
};

export using Event = std::variant<KeyPress, Exit, WorkspaceUpdated>;

export template <Notifier INotifier> struct EventQueue {
  explicit EventQueue(INotifier &notifier) : notifier(notifier) {}

  bool push(Event &&event) {
    _lock_autorelease_block {
      std::lock_guard lock(mutex);

      if (slot == MAX_PARALLEL_EVENTS) {
        return false;
      }

      buffer[slot++] = std::move(event);
    }

    notifier.wakeup();
    return true;
  }

  std::generator<Event> drain() {
    std::array<Event, MAX_PARALLEL_EVENTS> batch;
    std::uint16_t batch_size = 0;
    {
      std::lock_guard lock(mutex);
      if (slot > 0) {
        batch_size = slot;
        std::move(buffer, buffer + slot, batch.begin());
        slot = 0;
      }
    }

    for (std::uint16_t i = 0; i < batch_size; ++i) {
      co_yield std::move(batch[i]);
    }
  }

  std::uint16_t count() {
    std::lock_guard lock(mutex);
    return slot;
  }

private:
  INotifier &notifier;
  std::mutex mutex;
  std::uint16_t slot = 0;
  Event buffer[MAX_PARALLEL_EVENTS];
};

export template <Notifier INotifier> struct AppContext {
  telar::Client &client;
  EventQueue<INotifier> &input_queue;
};
