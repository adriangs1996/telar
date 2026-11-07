module;
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <limits>
#include <array>
#include <charconv>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <concepts>
#include <cstddef>
#include <cstring>
#include <exception>
#include <memory>
#include <span>
#include <type_traits>
#include <cstdio>
#include <string>
#include <variant>
#include <vector>
#include <bit>

#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.diagnostics.runtime_counters;

import telar.base.diagnostics;
import telar.base.text;
import telar.client.protocol;
import telar.runtime.diagnostics.line;


// Interface: diagnostics/command_capture.cppm
export {
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

  inline void merge(const CommandCaptureCounters &other) noexcept {
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

  inline void write(Line &line) const {
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
}

// Interface: diagnostics/graphics_counters.cppm
export {
namespace telar::runtime::diagnostics {

struct GraphicsCounters {
  std::uint64_t messages = 0;
  std::uint64_t bytes = 0;
  std::uint64_t images = 0;
  std::uint64_t placements = 0;
  std::uint64_t transfers_staged = 0;
  std::uint64_t transfers_adopted = 0;
  std::uint64_t stage_blocked = 0;
  std::uint64_t stage_deferred = 0;

  template <typename Message>
  inline void record(const Message &message) {
    accumulate(messages);
    accumulate(bytes, Codec::encodedSize(message));
    if constexpr (std::same_as<Message, GraphicsImage> || std::same_as<Message, GraphicsSharedImage>) {
      accumulate(images);
    } else if constexpr (std::same_as<Message, GraphicsPlacementMessage>) {
      accumulate(placements);
    }
  }

  inline void write(Line &line) const {
    line.field("graphics_messages", messages);
    line.field("graphics_bytes", bytes);
    line.field("graphics_images_sent", images);
    line.field("graphics_placements_sent", placements);
    line.field("graphics_transfers_staged", transfers_staged);
    line.field("graphics_transfers_adopted", transfers_adopted);
    line.field("graphics_stage_blocked", stage_blocked);
    line.field("graphics_stage_deferred", stage_deferred);
    line.timing("graphics_freeze_avg_us", "graphics_freeze_max_us", Timing{});
  }
};

}
}

// Interface: diagnostics/media_counters.cppm
export {
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

  inline void merge(const MediaCounters &batch) noexcept {
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

  inline void write(Line &line) const {
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
}

// Interface: diagnostics/observation_counters.cppm
export {
namespace telar::runtime::diagnostics {

struct ObservationCounters {
  CommandCaptureCounters commands;
  std::uint64_t candidate_input_bytes = 0;
  std::uint64_t captured = 0;
  std::uint64_t dropped = 0;
  std::uint64_t resets = 0;
  std::uint64_t failures = 0;

  inline void merge(const ObservationCounters &batch) noexcept {
    commands.merge(batch.commands);
    accumulate(candidate_input_bytes, batch.candidate_input_bytes);
    accumulate(captured, batch.captured);
    accumulate(dropped, batch.dropped);
    accumulate(resets, batch.resets);
    accumulate(failures, batch.failures);
  }

  inline void write(Line &line) const {
    commands.write(line);
    line.field("history_candidate_input_bytes", candidate_input_bytes);
    line.field("history_captured", captured);
    line.field("history_dropped", dropped);
    line.field("history_observation_resets", resets);
    line.field("history_observation_failures", failures);
  }
};

}
}

// Interface: diagnostics/system_counters.cppm
export {
namespace telar::runtime::diagnostics {

struct SystemCounters {
  Timing sample;
  std::chrono::steady_clock::time_point captured{};

  inline void write(Line &line) const {
    line.timing("system_sample_avg_us", "system_sample_max_us", sample);
    const auto age = std::chrono::steady_clock::now() - captured;
    const auto age_ms = static_cast<std::uint64_t>(std::max<std::int64_t>(0, std::chrono::duration_cast<std::chrono::milliseconds>(age).count()));
    line.field("system_sample_age_ms", sample.count == 0 ? std::nullopt : std::optional<std::uint64_t>{age_ms});
  }
};

}
}

// Interface: diagnostics/runtime_counters.cppm
export {
namespace telar::runtime::diagnostics {

struct PaneCounters {
  std::uint64_t input_events = 0;
  std::uint64_t input_bytes = 0;
  std::uint64_t pty_events = 0;
  std::uint64_t pty_bytes = 0;
  std::uint64_t folded_pty_events = 0;
  Timing input_write;
  Timing ingest;

  inline void write(Line &line) const {
    line.field("input_events", input_events);
    line.field("input_bytes", input_bytes);
    line.field("pty_events", pty_events);
    line.field("pty_bytes", pty_bytes);
    line.field("folded_pty_events", folded_pty_events);
    line.timing("input_write_avg_us", "input_write_max_us", input_write);
    line.timing("ingest_avg_us", "ingest_max_us", ingest);
  }
};

struct FrameCounters {
  std::uint64_t frames = 0;
  std::uint64_t frame_bytes = 0;
  std::uint64_t frame_cells = 0;
  std::uint64_t frame_spans = 0;
  std::uint64_t snapshots = 0;
  std::uint64_t cursor_only_frames = 0;
  std::uint64_t noop_frames = 0;
  std::uint64_t damaged_rows = 0;
  std::uint64_t diff_scanned_cells = 0;
  Timing encode;
  Timing ack;

  inline void write(Line &line) const {
    line.field("frames", frames);
    line.field("frame_bytes", frame_bytes);
    line.field("frame_cells", frame_cells);
    line.field("frame_spans", frame_spans);
    line.field("snapshots", snapshots);
    line.field("cursor_only_frames", cursor_only_frames);
    line.field("noop_frames", noop_frames);
    line.field("damaged_rows", damaged_rows);
    line.field("diff_scanned_cells", diff_scanned_cells);
    line.timing("encode_avg_us", "encode_max_us", encode);
    line.timing("ack_avg_us", "ack_max_us", ack);
  }
};

struct RuntimeCounters {
#if TELAR_DIAGNOSTICS
  PaneCounters panes;
  FrameCounters frames;
  MediaCounters media;
  GraphicsCounters graphics;
  ObservationCounters observation;
  SystemCounters system;
  std::uint64_t client_messages = 0;
  std::uint64_t stale_client_messages = 0;
  std::uint64_t stale_pane_events = 0;
  std::uint64_t geometry_rejections = 0;
  std::uint64_t client_resyncs = 0;
  std::uint64_t agent_process_inspections = 0;
  std::uint64_t agent_process_misses = 0;
  Timing decode;

  inline void write(Line &line) const {
    line.field("client_messages", client_messages);
    line.field("stale_client_messages", stale_client_messages);
    line.field("stale_pane_events", stale_pane_events);
    line.field("geometry_rejections", geometry_rejections);
    line.field("client_resyncs", client_resyncs);
    line.field("agent_process_inspections", agent_process_inspections);
    line.field("agent_process_misses", agent_process_misses);
    line.timing("decode_avg_us", "decode_max_us", decode);
    panes.write(line);
    frames.write(line);
    media.write(line);
    graphics.write(line);
    observation.write(line);
    system.write(line);
  }
#endif
};

}
}
