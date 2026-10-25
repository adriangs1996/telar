#pragma once

#include "pane_media.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class MediaProcessor {
public:
  struct Entry {
    std::uint64_t pane = 0;
    std::uint64_t generation = 0;
    std::shared_ptr<PaneMedia<Memory>> media;
    bool reset = false;
#if TELAR_DIAGNOSTICS
    diagnostics::MediaCounters metrics{};
#endif
  };

  struct Request {
    std::array<Entry, 8> entries;
    std::size_t count = 0;
  };

  using Result = Request;

  Result observe(const Request &request) noexcept {
    TELAR_TRACE("media.worker");
    auto result = request;
    for (auto &entry : std::span{result.entries}.first(result.count)) {
      entry.reset = entry.media->process();
      TELAR_DIAGNOSTIC(entry.metrics = entry.media->batchMetrics());
    }
    return result;
  }

  void stop() noexcept {}
};

}
