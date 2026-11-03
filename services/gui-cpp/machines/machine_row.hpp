#pragma once

#include "identity.hpp"
#include "limits.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::gui {

struct MachineFields {
  MachineId id{};
  std::string_view label;
  std::string_view destination;
  std::optional<std::string_view> color = std::nullopt;
  bool enabled = true;
  std::optional<std::string_view> program = std::nullopt;
};

enum class MachinePhase : std::uint8_t {
  connecting,
  connected,
  lost,
  failed,
  stopped,
};

struct MachineMetrics {
  std::uint8_t cpu_percent = 0;
  std::uint16_t cpu_count = 0;
  std::uint16_t memory_used_decigib = 0;
  std::uint16_t memory_total_decigib = 0;
};

struct MachineObservation {
  MachinePhase phase = MachinePhase::connecting;
  bool needs_setup = false;
  bool attention = false;
  std::optional<MachineMetrics> metrics = std::nullopt;
  std::uint64_t metrics_revision = 0;
  std::uint64_t agent_revision = 0;
  std::uint64_t workspace_revision = 0;
  std::uint64_t now_ns = 0;
};

struct MachineRow {
  bool used = false;
  std::uint64_t generation = 0;
  MachineId id;
  runtime::FixedText<MachineLimits::label_bytes> label;
  runtime::FixedText<MachineLimits::destination_bytes> destination;
  runtime::FixedText<MachineLimits::color_bytes> color;
  runtime::FixedText<MachineLimits::program_bytes> program;
  bool enabled = false;
  bool pinned = false;
  bool live = false;
  MachinePhase phase = MachinePhase::connecting;
  bool needs_setup = false;
  bool attention = false;
  std::optional<std::uint8_t> cpu_percent;
  std::uint16_t cpu_count = 0;
  std::uint16_t memory_used_decigib = 0;
  std::uint16_t memory_total_decigib = 0;
  std::uint64_t sampled_ns = 0;
  std::uint64_t metrics_revision = 0;
  std::uint64_t agent_revision = 0;
  std::uint64_t workspace_revision = 0;

  void write(MachineFields fields) {
    id = fields.id;
    label.assign(fields.label.substr(0, MachineLimits::label_bytes));
    destination.assign(fields.destination.substr(0, MachineLimits::destination_bytes));
    color.assign(fields.color.value_or("").substr(0, MachineLimits::color_bytes));
    const auto path = fields.program.value_or("");
    program.assign(path.size() <= MachineLimits::program_bytes ? path : std::string_view{});
    enabled = fields.enabled;
  }
};

}
