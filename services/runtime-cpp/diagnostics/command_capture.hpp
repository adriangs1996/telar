#pragma once

#include "line.hpp"

namespace telar::runtime::diagnostics {

struct CommandCaptureCounters {
  std::uint64_t prompt_markers = 0;
  std::uint64_t input_markers = 0;
  std::uint64_t output_markers = 0;
  std::uint64_t finished_markers = 0;
  std::uint64_t osc_started = 0;
  std::uint64_t osc_finished = 0;
  std::uint64_t submissions = 0;
  std::uint64_t captures = 0;
  std::uint64_t capture_failures = 0;
  std::uint64_t foreground_completions = 0;
  std::uint64_t next_input_completions = 0;
  std::uint64_t auxiliary_completions = 0;

  void merge(const CommandCaptureCounters &other) noexcept {
    accumulate(prompt_markers, other.prompt_markers);
    accumulate(input_markers, other.input_markers);
    accumulate(output_markers, other.output_markers);
    accumulate(finished_markers, other.finished_markers);
    accumulate(osc_started, other.osc_started);
    accumulate(osc_finished, other.osc_finished);
    accumulate(submissions, other.submissions);
    accumulate(captures, other.captures);
    accumulate(capture_failures, other.capture_failures);
    accumulate(foreground_completions, other.foreground_completions);
    accumulate(next_input_completions, other.next_input_completions);
    accumulate(auxiliary_completions, other.auxiliary_completions);
  }

  void write(Line &line) const {
    line.field("history_prompt_markers", prompt_markers);
    line.field("history_input_markers", input_markers);
    line.field("history_output_markers", output_markers);
    line.field("history_finished_markers", finished_markers);
    line.field("history_osc_started", osc_started);
    line.field("history_osc_finished", osc_finished);
    line.field("history_pty_submissions", submissions);
    line.field("history_pty_captures", captures);
    line.field("history_pty_capture_failures", capture_failures);
    line.field("history_foreground_completions", foreground_completions);
    line.field("history_next_input_completions", next_input_completions);
    line.field("history_auxiliary_completions", auxiliary_completions);
  }
};

}
