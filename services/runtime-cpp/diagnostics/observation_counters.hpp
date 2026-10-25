#pragma once

#include "command_capture.hpp"

namespace telar::runtime::diagnostics {

struct ObservationCounters {
  CommandCaptureCounters commands;
  std::uint64_t candidate_input_bytes = 0;
  std::uint64_t captured = 0;
  std::uint64_t dropped = 0;
  std::uint64_t resets = 0;
  std::uint64_t failures = 0;

  void merge(const ObservationCounters &batch) noexcept {
    commands.merge(batch.commands);
    accumulate(candidate_input_bytes, batch.candidate_input_bytes);
    accumulate(captured, batch.captured);
    accumulate(dropped, batch.dropped);
    accumulate(resets, batch.resets);
    accumulate(failures, batch.failures);
  }

  void write(Line &line) const {
    commands.write(line);
    line.field("history_candidate_input_bytes", candidate_input_bytes);
    line.field("history_captured", captured);
    line.field("history_dropped", dropped);
    line.field("history_observation_resets", resets);
    line.field("history_observation_failures", failures);
  }
};

}
