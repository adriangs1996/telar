module;
#include "telar_client/telar_client.hpp"
#include <generator>
#include <mutex>
#include <variant>
export module app_context;

#define MAX_PARALLEL_EVENTS 1000

export struct KeyPress {
  char key;
};

export struct Exit {
  std::uint8_t code = 0;
};

export using Event = std::variant<KeyPress, Exit>;

export struct EventQueue {

  bool push(Event event) {
    std::lock_guard lock(mutex);
    if (slot == MAX_PARALLEL_EVENTS) {
      return false;
    }

    buffer[slot++] = std::move(event);
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
  std::mutex mutex;
  std::uint16_t slot = 0;
  Event buffer[MAX_PARALLEL_EVENTS];
};

export struct AppContext {
  telar::Client &client;
  EventQueue &input_queue;
};
