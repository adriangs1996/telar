#pragma once

#include "config.hpp"
#include "graphics_counters.hpp"
#include "line.hpp"
#include "media_counters.hpp"
#include "observation_counters.hpp"
#include "system_counters.hpp"

namespace telar::runtime::diagnostics {

struct PaneCounters {
  std::uint64_t input_events = 0;
  std::uint64_t input_bytes = 0;
  std::uint64_t pty_events = 0;
  std::uint64_t pty_bytes = 0;
  std::uint64_t folded_pty_events = 0;
  Timing input_write;
  Timing ingest;

  void write(Line &line) const {
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

  void write(Line &line) const {
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

  void write(Line &line) const {
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
