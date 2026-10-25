#pragma once

#include "line.hpp"

namespace telar::runtime::diagnostics {

struct MediaCounters {
  std::uint64_t bytes = 0;
  std::uint64_t discarded_frames = 0;
  std::uint64_t unavailable_frames = 0;
  std::uint64_t forwarded_frames = 0;
  std::uint64_t direct_frames = 0;
  std::uint64_t file_frames = 0;
  std::uint64_t prepared_frames = 0;
  std::uint64_t resets = 0;
  std::uint64_t failures = 0;
  Timing ingest;

  void merge(const MediaCounters &batch) noexcept {
    accumulate(bytes, batch.bytes);
    accumulate(discarded_frames, batch.discarded_frames);
    accumulate(unavailable_frames, batch.unavailable_frames);
    accumulate(forwarded_frames, batch.forwarded_frames);
    accumulate(direct_frames, batch.direct_frames);
    accumulate(file_frames, batch.file_frames);
    accumulate(prepared_frames, batch.prepared_frames);
    accumulate(resets, batch.resets);
    accumulate(failures, batch.failures);
    ingest.merge(batch.ingest);
  }

  void write(Line &line) const {
    line.field("media_bytes", bytes);
    line.field("media_discarded_frames", discarded_frames);
    line.field("media_unavailable_frames", unavailable_frames);
    line.field("media_forwarded_frames", forwarded_frames);
    line.field("media_direct_frames", direct_frames);
    line.field("media_file_frames", file_frames);
    line.field("graphics_transfers_prepared", prepared_frames);
    line.field("media_resets", resets);
    line.field("media_failures", failures);
    line.timing("media_ingest_avg_us", "media_ingest_max_us", ingest);
  }
};

}
