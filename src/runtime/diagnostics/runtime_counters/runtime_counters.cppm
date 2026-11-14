module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.diagnostics.runtime_counters;

import std;

import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.wire.graphics;
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

      void merge(const CommandCaptureCounters& other) noexcept;

      void write(Line& line) const;
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

      void merge(const GraphicsCounters& other) noexcept;

      // Counts each graphics message a client is sent; the messages are an open set no unit can instantiate ahead.
      template <typename Message>
      TBC_GENERIC inline void record(const Message& message) {
        accumulate(messages);
        accumulate(bytes, Codec::encodedSize(message));
        if constexpr (std::same_as<Message, GraphicsImage> || std::same_as<Message, GraphicsSharedImage>) {
          accumulate(images);
        } else if constexpr (std::same_as<Message, GraphicsPlacementMessage>) {
          accumulate(placements);
        }
      }

      void write(Line& line) const;
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

      void merge(const MediaCounters& batch) noexcept;

      void write(Line& line) const;
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

      void merge(const ObservationCounters& batch) noexcept;

      void write(Line& line) const;
    };

  }
}

// Interface: diagnostics/system_counters.cppm
export {
  namespace telar::runtime::diagnostics {

    struct SystemCounters {
      Timing sample;
      std::chrono::steady_clock::time_point captured{};

      void write(Line& line) const;
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

      void write(Line& line) const;
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

      void merge(const FrameCounters& other) noexcept;

      void write(Line& line) const;
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

      void write(Line& line) const;
#endif
    };

  }
}
