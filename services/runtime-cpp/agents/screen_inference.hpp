#pragma once

#include "screen_observation.hpp"

namespace telar::runtime {

class AgentScreenSample {
public:
  template <Allocator Memory>
  std::string_view capture(const Screen<Memory> &screen) noexcept {
    start_ = bytes_.size();
    for (std::size_t row = screen.rows; row-- != 0;) {
      if (start_ != bytes_.size() && (screen.row_flags[row] & static_cast<Byte>(RowFlag::wrap)) == 0 && !prepend(" ")) {
        break;
      }

      auto cells = std::span{screen.cells}.subspan(row * screen.cols, screen.cols);
      while (!cells.empty() && (cells.back().length == 0 || (cells.back().length == 1 && cells.back().text[0] == ' '))) {
        cells = cells.first(cells.size() - 1);
      }

      for (std::size_t column = cells.size(); column-- != 0;) {
        const auto &cell = cells[column];
        const auto first = cell.text[0];
        const auto length = first < 0x80 ? 1U : first < 0xe0 ? 2U
                                            : first < 0xf0   ? 3U
                                                             : 4U;
        if (!prepend(cell.length == 0 ? std::string_view{" "} : std::string_view{reinterpret_cast<const char *>(cell.text.data()), std::min<std::size_t>(length, cell.length)})) {
          return text();
        }
      }
    }

    return text();
  }

private:
  bool prepend(std::string_view bytes) noexcept {
    if (bytes.size() > start_) {
      return false;
    }

    start_ -= bytes.size();
    std::memcpy(bytes_.data() + start_, bytes.data(), bytes.size());
    return true;
  }

  std::string_view text() const noexcept {
    return {bytes_.data() + start_, bytes_.size() - start_};
  }

  std::array<char, 16 * 1024> bytes_{};
  std::size_t start_ = bytes_.size();
};

class AgentScreenInference {
public:
  template <Allocator Memory>
  std::optional<AgentSignal> observe(Terminal<Memory> &terminal, const AgentManifests &manifests, AgentProvider provider, ObservationTime now) {
    if (!terminal.outputSettled()) {
      return std::nullopt;
    }

    terminal.refresh();
    const AgentScreenReader reader{terminal, manifests};
    const auto phrases = provider == AgentProvider::codex ? std::nullopt : manifests.detect(sample_.capture(terminal.screen));
    const auto codex = provider == AgentProvider::unknown || provider == AgentProvider::codex ? reader.signal(AgentProvider::codex) : std::nullopt;
    auto signal = phrases;
    if (provider == AgentProvider::codex || (provider == AgentProvider::unknown && codex && codex->identity_confirmed)) {
      signal = codex;
    } else if (provider == AgentProvider::unknown && phrases && phrases->provider == AgentProvider::codex) {
      signal.reset();
    } else if (provider == AgentProvider::cursor) {
      signal = phrases && phrases->status == AgentStatus::blocked ? phrases : reader.signal(AgentProvider::cursor);
    } else {
      const auto *manifest = phrases ? manifests.find(phrases->provider) : nullptr;
      if (!phrases || (phrases->status != AgentStatus::blocked && (manifest == nullptr || manifest->ready_prompt.entries().empty()))) {
        if (auto prompt = reader.signal(AgentProvider::claude)) {
          prompt->identity_confirmed = phrases && phrases->provider == prompt->provider && phrases->identity_confirmed;
          signal = prompt;
        }
      }
    }

    if (signal && (signal->provider == AgentProvider::codex || signal->provider == AgentProvider::cursor)) {
      if (signal->status == AgentStatus::working) {
        composer_lost_ = false;
      } else if (composer_lost_) {
        return std::nullopt;
      }
    }

    if (!signal) {
      last_signal_.reset();
      return std::nullopt;
    }

    if (signal == last_signal_ && !(signal->provider == AgentProvider::codex && signal->ready_confirmed) && now.milliseconds - last_signal_time_ < signal_refresh.count()) {
      return std::nullopt;
    }

    last_signal_ = signal;
    last_signal_time_ = now.milliseconds;
    return signal;
  }

  void reset() noexcept {
    last_signal_.reset();
    last_signal_time_ = 0;
    composer_lost_ = true;
  }

private:
  static constexpr std::chrono::milliseconds signal_refresh{15'000};
  AgentScreenSample sample_;
  std::optional<AgentSignal> last_signal_;
  std::int64_t last_signal_time_ = 0;
  bool composer_lost_ = false;
};

}
