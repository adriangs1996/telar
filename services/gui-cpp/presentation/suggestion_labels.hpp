#pragma once

#include "suggestions/state.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <string_view>

namespace telar::gui {

struct SuggestionLabels {
  [[nodiscard]] static std::string_view heading(SuggestionPhase phase) noexcept {
    switch (phase) {
    case SuggestionPhase::idle:
      return "Start with a task";
    case SuggestionPhase::waiting:
      return "Generating a command…";
    case SuggestionPhase::ready:
      return "Suggested command";
    case SuggestionPhase::failed:
      return "Could not generate a command";
    }

    return {};
  }

  [[nodiscard]] static std::string_view message(SuggestionPhase phase, SuggestionStatus status) noexcept {
    if (phase == SuggestionPhase::idle) {
      return "Describe the command you need, then press Enter.";
    }

    if (phase == SuggestionPhase::waiting) {
      return "Keep editing or press Esc to cancel.";
    }

    if (phase == SuggestionPhase::ready) {
      return {};
    }

    switch (status) {
    case SuggestionStatus::ready:
      return "The engine returned no command. Try again.";
    case SuggestionStatus::unavailable:
      return "Configure runtime.engine to enable suggestions.";
    case SuggestionStatus::timeout:
      return "The engine timed out. Try again.";
    case SuggestionStatus::failed:
      return "The engine could not answer. Try again.";
    }

    return {};
  }

  [[nodiscard]] static std::string_view button(SuggestionPhase phase) noexcept {
    switch (phase) {
    case SuggestionPhase::idle:
      return "Generate  ↵";
    case SuggestionPhase::waiting:
      return "Generating…";
    case SuggestionPhase::ready:
      return "Paste command  ↵";
    case SuggestionPhase::failed:
      return "Try again  ↵";
    }

    return {};
  }

  [[nodiscard]] static std::string_view footer(SuggestionPhase phase) noexcept {
    return phase == SuggestionPhase::ready ? "Paste first, then run in shell." : "Review before pasting.";
  }

  [[nodiscard]] static bool canSubmit(SuggestionPhase phase, std::string_view query) noexcept {
    return phase != SuggestionPhase::waiting && (phase == SuggestionPhase::ready || !query.empty());
  }
};

}
