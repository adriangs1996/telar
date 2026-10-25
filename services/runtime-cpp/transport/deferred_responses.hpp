#pragma once

#include "../memory/allocator.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>
#include <stdexcept>
#include <variant>

namespace telar::runtime {

template <typename Request>
concept DeferredRequest = std::same_as<Request, ReadPane> || std::same_as<Request, RequestTabSnapshot> || std::same_as<Request, RequestWorkspaceSnapshot> || std::same_as<Request, QueryLimits>;

using DeferredResponse = std::variant<ReadPane, RequestTabSnapshot, RequestWorkspaceSnapshot, QueryLimits>;

struct RejectDeferredResponse {
  void operator()(const DeferredResponse &, auto &&) const {
    throw std::logic_error{"A deferred response requires an encoder"};
  }
};

template <typename Encoder>
concept DeferredResponseEncoder = requires(Encoder &encoder, const DeferredResponse &response) {
  encoder(response, [](const auto &) {});
};

template <Allocator Memory>
class DeferredResponses {
public:
  explicit DeferredResponses(Memory &memory) : entries_(AllocatorRef<Entry, Memory>{memory}) {}

  void append(std::size_t offset, const DeferredResponse &response) {
    entries_.push_back(Entry{offset, response});
  }

  bool precedes(std::size_t offset) const noexcept {
    return !entries_.empty() && entries_.front().offset <= offset;
  }

  std::size_t offset() const noexcept { return entries_.front().offset; }
  const DeferredResponse &response() const noexcept { return entries_.front().response; }
  bool empty() const noexcept { return entries_.empty(); }
  void clear() noexcept { entries_.clear(); }

  void resolved(std::size_t size) noexcept {
    entries_.erase(entries_.begin());
    for (auto &entry : entries_) {
      entry.offset += size;
    }
  }

  // Offsets mark admission boundaries in the encoded byte queue. Removing a
  // higher-priority frame collapses any boundaries inside that byte range.
  void eraseBytes(std::size_t offset, std::size_t count) noexcept {
    for (auto &entry : entries_) {
      if (entry.offset > offset) {
        entry.offset -= std::min(count, entry.offset - offset);
      }
    }
  }

private:
  struct Entry {
    std::size_t offset;
    DeferredResponse response;
  };

  Vector<Entry, Memory> entries_;
};

}
