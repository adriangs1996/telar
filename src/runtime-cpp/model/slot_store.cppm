module;
#include <cstddef>
#include <cstring>
#include <cstdio>
#include <sys/mman.h>
#include <cstdlib>
#include <new>



#include <cstdint>


export module telar.runtime.model.slot_store;

import std;

import telar.base.diagnostics;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;
import telar.config;
import telar.platform.primitives;
import telar.runtime.graphics.kitty;
export import telar.runtime.shell_integration.token;


// Interface: model/client_role.cppm
export {
namespace telar::runtime {

enum class ClientRole {
  undecided,
  interactive,
  control
};

inline ClientRole classifyRequest(ClientTag tag) noexcept {
  switch (tag) {
  case ClientTag::runtime_stop:
  case ClientTag::execution_request:
  case ClientTag::query_history:
  case ClientTag::import_history:
  case ClientTag::delete_history:
  case ClientTag::prune_history:
  case ClientTag::read_history_output:
  case ClientTag::history_stats:
  case ClientTag::show_notification:
  case ClientTag::request_client_command:
  case ClientTag::detach_client:
  case ClientTag::query_clients:
  case ClientTag::query_agents:
  case ClientTag::search_pane:
  case ClientTag::read_pane:
  case ClientTag::send_pane_text:
  case ClientTag::report_agent_session:
  case ClientTag::report_agent:
  case ClientTag::report_agent_command:
  case ClientTag::report_agent_title:
  case ClientTag::request_pane_focus:
  case ClientTag::register_worktree:
  case ClientTag::launch_worktree:
  case ClientTag::launch_tab:
  case ClientTag::forget_worktree:
  case ClientTag::interrupt_agent:
  case ClientTag::report_agent_progress:
  case ClientTag::verify_pane_descent:
  case ClientTag::query_limits:
  case ClientTag::report_limit:
    return ClientRole::control;
  default:
    return ClientRole::interactive;
  }
}

struct PendingClientCommand {
  std::uint64_t target;
  std::uint64_t request_id;
  ClientAction action;
  std::uint64_t target_id;
};

struct PendingPaneFocus {
  std::uint64_t target;
  std::uint64_t request_id;
  std::uint64_t pane_id;
  std::uint64_t pane_generation;
};

}
}

// Interface: model/exited_panes.cppm
export {
namespace telar::runtime {

class ExitedPanes {
public:
  static constexpr std::size_t capacity = 16;
  static constexpr std::size_t maximum_bytes = 16 * 1024;
  static constexpr std::uint16_t kept_rows = 200;

  struct Record {
    std::uint64_t pane_id = 0;
    std::uint64_t generation = 0;
    std::int32_t exit_code = 0;
    std::array<char, maximum_bytes> bytes{};
    std::size_t length = 0;
    bool truncated = false;

    inline PaneText response(const ReadPane &request) const noexcept {
      std::string_view text{bytes.data(), length};
      const auto last = text.find_last_not_of("\n ");
      text = last == std::string_view::npos ? std::string_view{} : text.substr(0, last + 1);
      auto start = text.size();
      unsigned lines = 0;

      while (start != 0) {
        if (text[start - 1] == '\n' && ++lines == request.rows) {
          break;
        }
        --start;
      }

      return PaneText{.request_id = request.request_id,
                      .pane_id = pane_id,
                      .truncated = start == 0 && truncated,
                      .text = text.substr(start),
                      .exit_code = exit_code};
    }
  };

  inline void record(std::uint64_t pane_id, std::uint64_t generation, const PaneText &text) noexcept {
    auto &entry = entries_[next_];
    entry.pane_id = pane_id;
    entry.generation = generation;
    entry.exit_code = text.exit_code.value_or(0);
    entry.length = std::min(text.text.size(), maximum_bytes);
    entry.truncated = text.truncated || entry.length != text.text.size();
    std::copy_n(text.text.end() - entry.length, entry.length, entry.bytes.begin());
    next_ = (next_ + 1) % capacity;
  }

  inline const Record *find(std::uint64_t pane_id, std::uint64_t generation) const noexcept {
    for (std::size_t offset = 0; offset < capacity; ++offset) {
      const auto &entry = entries_[(next_ + capacity - 1 - offset) % capacity];
      if (pane_id != 0 && entry.pane_id == pane_id && (generation == 0 || entry.generation == generation)) {
        return &entry;
      }
    }
    return nullptr;
  }

private:
  std::array<Record, capacity> entries_{};
  std::size_t next_ = 0;
};

}
}

// Interface: model/held_tabs.cppm
export {
namespace telar::runtime {

class HeldTabs {
public:
  static constexpr std::size_t capacity = 64;

  inline bool contains(TabLocation location) const noexcept {
    return find(location).has_value();
  }

  inline bool insert(TabLocation location) noexcept {
    if (contains(location)) {
      return true;
    }

    if (count_ == capacity) {
      return false;
    }

    locations_[count_++] = location;
    return true;
  }

  inline bool erase(TabLocation location) noexcept {
    const auto index = find(location);
    if (!index) {
      return false;
    }

    locations_[*index] = locations_[--count_];
    return true;
  }

  inline std::optional<TabLocation> pop() noexcept {
    if (count_ == 0) {
      return std::nullopt;
    }

    return locations_[--count_];
  }

private:
  inline std::optional<std::size_t> find(TabLocation location) const noexcept {
    for (std::size_t index = 0; index < count_; ++index) {
      const auto &candidate = locations_[index];
      if (candidate.workspace.kind == location.workspace.kind && candidate.workspace.id == location.workspace.id && candidate.tab_id == location.tab_id) {
        return index;
      }
    }

    return std::nullopt;
  }

  std::array<TabLocation, capacity> locations_;
  std::size_t count_ = 0;
};

}
}

// Interface: model/identity_counter.cppm
export {
namespace telar::runtime {

inline void advanceIdentityCounter(std::uint64_t &counter, std::uint64_t next) noexcept {
  // Zero marks exhaustion after the last nonzero identity; restoring an older counter must not reopen it.
  if (counter != 0) {
    counter = next == 0 ? 0 : std::max(counter, next);
  }
}

}
}

// Interface: model/pane_launch.cppm
export {
namespace telar::runtime {

struct PaneLaunch {
  TerminalSize size;
  MediaBudget &media_budget;
  GraphicsLimits graphics;
  // Present when the pane runs a shell telar integrated with.
  std::optional<ShellLaunch> shell{};
};

}
}

// Interface: model/slot_store.cppm
export {
namespace telar::runtime {

template <typename Value, std::size_t Capacity, Allocator Memory>
class SlotStore {
  static_assert(Capacity > 0 && Capacity <= UINT16_MAX);

public:
  inline explicit SlotStore(Memory &memory) noexcept
      : memory_(memory) {}

  inline ~SlotStore() {
    for (auto *value : items_) {
      if (value != nullptr) {
        AllocationDeleter<Value, Memory>{memory_}(value);
      }
    }
  }

  SlotStore(const SlotStore &) = delete;
  SlotStore &operator=(const SlotStore &) = delete;

  inline std::uint64_t nextId() const {
    if (count_ == Capacity || next_id_ == 0) {
      throw std::bad_alloc{};
    }

    return next_id_;
  }

  inline std::uint64_t insert(std::uint64_t id, Owned<Value, Memory> value) {
    const auto handle = insertProvisional(id, std::move(value));
    advanceCounter(id + 1);
    return handle;
  }

  inline std::uint64_t insertProvisional(std::uint64_t id, Owned<Value, Memory> value) {
    if (id == 0 || count_ == Capacity || find(id) != nullptr) {
      throw std::bad_alloc{};
    }

    std::size_t slot = 0;
    while (items_[slot] != nullptr) {
      ++slot;
    }

    if (generations_[slot] == std::numeric_limits<std::uint64_t>::max() / Capacity - 1) {
      throw std::bad_alloc{};
    }

    ++generations_[slot];
    identities_[slot] = id;
    lookup_[bucket(id)] = static_cast<std::uint16_t>(slot + 1);
    items_[slot] = value.release();
    ++count_;
    return generations_[slot] * Capacity + slot;
  }

  inline Value *findHandle(std::uint64_t handle) const noexcept {
    const auto slot = handle % Capacity;
    return generations_[slot] == handle / Capacity ? items_[slot] : nullptr;
  }

  inline Value *find(std::uint64_t id) const noexcept {
    const auto slot = slotOf(id);
    return slot ? items_[*slot] : nullptr;
  }

  inline void erase(std::uint64_t id) noexcept {
    auto *value = find(id);
    if (value == nullptr) {
      return;
    }

    const auto position = bucket(id);
    const auto slot = lookup_[position] - 1;
    removeBucket(position);
    identities_[slot] = 0;
    items_[slot] = nullptr;
    --count_;
    AllocationDeleter<Value, Memory>{memory_}(value);
  }

  inline std::size_t size() const noexcept {
    return count_;
  }

  inline void advanceCounter(std::uint64_t next) noexcept {
    advanceIdentityCounter(next_id_, next);
  }

  inline std::uint64_t nextCounter() const noexcept {
    return next_id_;
  }

  inline std::span<Value *const> items() const noexcept {
    return items_;
  }

  inline std::optional<std::size_t> slotOf(std::uint64_t id) const noexcept {
    const auto stored = id == 0 ? 0 : lookup_[bucket(id)];
    return stored == 0 ? std::nullopt : std::optional<std::size_t>{stored - 1};
  }

private:
  static constexpr std::size_t lookup_capacity = 2 * Capacity;

  inline static std::size_t hash(std::uint64_t identity) noexcept {
    return static_cast<std::size_t>(identity % lookup_capacity);
  }

  inline std::size_t bucket(std::uint64_t identity) const noexcept {
    auto position = hash(identity);
    while (lookup_[position] != 0 && identities_[lookup_[position] - 1] != identity) {
      position = (position + 1) % lookup_capacity;
    }

    return position;
  }

  inline void removeBucket(std::size_t hole) noexcept {
    auto position = (hole + 1) % lookup_capacity;
    while (lookup_[position] != 0) {
      const auto origin = hash(identities_[lookup_[position] - 1]);
      const auto distance = (position + lookup_capacity - origin) % lookup_capacity;
      const auto hole_distance = (hole + lookup_capacity - origin) % lookup_capacity;
      if (hole_distance < distance) {
        lookup_[hole] = lookup_[position];
        hole = position;
      }

      position = (position + 1) % lookup_capacity;
    }

    lookup_[hole] = 0;
  }

  Memory &memory_;
  std::array<Value *, Capacity> items_{};
  std::array<std::uint64_t, Capacity> identities_{};
  std::array<std::uint64_t, Capacity> generations_{};
  std::array<std::uint16_t, lookup_capacity> lookup_{};
  std::uint64_t next_id_ = 1;
  std::size_t count_ = 0;
};

}
}
