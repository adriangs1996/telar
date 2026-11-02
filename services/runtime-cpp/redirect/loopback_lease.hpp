#pragma once

#include "pf_loopback.hpp"
#include "record_file.hpp"

namespace telar::runtime::redirect {

template <Allocator Memory>
class LoopbackLeases {
public:
  explicit LoopbackLeases(Memory &memory) : memory_(memory), owners_(AllocatorRef<char, Memory>{memory}) {}

  template <typename Store, typename Interface>
  void acquire(Store &store, Interface &interface, std::string_view owner) {
    validateOwner(owner);
    load(store);
    const auto marker = ownerMarker(owner);
    const bool present = std::string_view{owners_}.contains(marker);
    if (!present && owners_.size() / owner_bytes >= maximum_owners) {
      throw std::runtime_error{"Too many transparent redirect loopback owners"};
    }
    const bool skipped = interface.skipped();
    restore_skip_ = restore_skip_ || skipped;
    if (!present) {
      owners_.append(marker);
    }
    // Persist before the ioctl so a failed change or a crash can be recovered.
    save(store);
    if (skipped) {
      interface.setSkipped(false);
    }
  }

  template <typename Store, typename Interface>
  void release(Store &store, Interface &interface, std::string_view owner) {
    validateOwner(owner);
    load(store);
    const auto marker = ownerMarker(owner);
    const auto position = owners_.find(marker);
    if (position == String<Memory>::npos) {
      return;
    }
    owners_.erase(position, marker.size());
    if (owners_.empty()) {
      if (restore_skip_) {
        interface.setSkipped(true);
      }
      store.clear();
    } else {
      save(store);
    }
  }

private:
  static constexpr std::size_t owner_bytes = 21;
  static constexpr std::size_t maximum_owners = 64;

  static void validateOwner(std::string_view owner) {
    if (owner.size() != owner_bytes - 1 || !owner.starts_with("tlr_") || owner.substr(4).find_first_not_of("0123456789abcdef") != std::string_view::npos) {
      throw std::invalid_argument{"Invalid PF loopback owner"};
    }
  }

  String<Memory> ownerMarker(std::string_view owner) {
    String<Memory> marker{owner, AllocatorRef<char, Memory>{memory_}};
    marker += '\n';
    return marker;
  }

  template <typename Store>
  void load(Store &store) {
    owners_.clear();
    restore_skip_ = false;
    const auto saved = store.load();
    if (!saved) {
      return;
    }
    auto content = std::string_view{*saved};
    if (!content.starts_with("skip\n") && !content.starts_with("filter\n")) {
      throw std::runtime_error{"Invalid PF loopback recovery record"};
    }
    restore_skip_ = content.starts_with("skip\n");
    content.remove_prefix(restore_skip_ ? 5 : 7);
    if (content.empty() || content.size() % owner_bytes != 0 || content.size() > maximum_owners * owner_bytes) {
      throw std::runtime_error{"Invalid PF loopback owner list"};
    }
    while (!content.empty()) {
      const auto owner = content.substr(0, owner_bytes - 1);
      validateOwner(owner);
      const auto marker = content.substr(0, owner_bytes);
      if (marker.back() != '\n' || std::string_view{owners_}.contains(marker)) {
        throw std::runtime_error{"Invalid or duplicate PF loopback owner"};
      }
      owners_.append(marker);
      content.remove_prefix(owner_bytes);
    }
  }

  template <typename Store>
  void save(Store &store) {
    String<Memory> content{restore_skip_ ? "skip\n" : "filter\n", AllocatorRef<char, Memory>{memory_}};
    content.append(owners_);
    store.save(content);
  }

  Memory &memory_;
  String<Memory> owners_;
  bool restore_skip_ = false;
};

template <Allocator Memory, typename Interface>
class SharedLoopback {
public:
  explicit SharedLoopback(Memory &memory, Interface &interface, std::string_view owner) noexcept
      : memory_(memory), interface_(interface), owner_(owner) {}

  void acquire() {
    RecordFile file{memory_, "loopback", RecordLock::update};
    LoopbackLeases leases{memory_};
    leases.acquire(file, interface_, owner_);
  }

  void release() {
    RecordFile file{memory_, "loopback", RecordLock::update};
    LoopbackLeases leases{memory_};
    leases.release(file, interface_, owner_);
  }

private:
  Memory &memory_;
  Interface &interface_;
  std::string_view owner_;
};

}
