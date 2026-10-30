#pragma once

#include <cstddef>
#include <cstdint>
#include <stdexcept>

namespace telar::gui {

struct AttachmentLimits {
  static constexpr std::size_t maximum_items = 4;
  static constexpr std::size_t maximum_source_bytes = std::size_t{32} * 1024 * 1024;
  static constexpr std::size_t maximum_png_bytes = std::size_t{32} * 1024 * 1024;
  static constexpr std::uint64_t maximum_pixels = std::uint64_t{36} * 1024 * 1024;
  static constexpr std::size_t maximum_retained_bytes = std::size_t{32} * 1024 * 1024;
  static constexpr std::uint8_t maximum_marker_navigation_steps = 120;
  static constexpr std::uint8_t deletion_watch_frames = 3;
  static constexpr std::size_t maximum_input_bytes = std::size_t{8} * 1024;
  static constexpr std::size_t maximum_bytes_per_key = 32;
  static constexpr std::size_t maximum_removal_keys = maximum_input_bytes / maximum_bytes_per_key;
};

enum class AttachmentMarkerPolicy : std::uint8_t {
  ordered,
  stable_number,
  pasted_path,
};

struct AttachmentTarget {
  static constexpr std::uint64_t invalid_pane = 0;
  static constexpr std::uint64_t invalid_generation = 0;

  std::uint64_t pane_id = invalid_pane;
  std::uint64_t pane_generation = invalid_generation;

  void validate() const {
    if (pane_id == invalid_pane || pane_generation == invalid_generation) {
      throw std::invalid_argument{"InvalidAttachmentTarget"};
    }
  }

  bool operator==(const AttachmentTarget &) const = default;
};

struct ClipboardCapture {
  static constexpr std::uint64_t invalid_id = 0;
  static constexpr std::uint64_t first_id = 1;

  std::uint64_t id = invalid_id;
  AttachmentTarget target;

  bool operator==(const ClipboardCapture &) const = default;
};

struct ClipboardCaptureRequest {
  ClipboardCapture capture;
  AttachmentMarkerPolicy marker_policy = AttachmentMarkerPolicy::ordered;
};

}
