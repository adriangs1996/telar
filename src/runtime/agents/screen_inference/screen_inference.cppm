module;
#include "tbc/annotations.hpp"

export module telar.runtime.agents.screen_inference;

import std;
import telar.tbc;

export import telar.config.runtime;

export import telar.runtime.terminal.text_reader;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
import telar.runtime.platform.session_host;

// Interface: agents/prompt_budget.cppm
export {
  namespace telar::runtime {

    class PromptBudget {
    public:
      bool spend(std::uint64_t sender, std::uint64_t target, std::chrono::steady_clock::time_point now) noexcept;

    private:
      struct Pair {
        std::uint64_t sender = 0;
        std::uint64_t target = 0;
        std::chrono::steady_clock::time_point started{};
        unsigned count = 0;
      };

      static constexpr std::chrono::seconds window{60};
      static constexpr unsigned prompts_per_window = 8;
      std::array<Pair, 32> pairs_{};
    };

  }
}

// Interface: agents/resume.cppm
export {
  namespace telar::runtime {

    struct AgentResume {
      AgentProvider provider = AgentProvider::unknown;
      FixedText<64> session{};
      FixedText<96> title{};
      AgentTitleSource title_source = AgentTitleSource::telar;
      bool in_pane = false;
    };

    bool hexadecimal(char value) noexcept;
    bool validResumeSession(AgentProvider provider, std::string_view value) noexcept;

    // The arguments view the session and the caller's array.
    tbc::view<std::span<const std::string_view>, tbc::lt::a> resumeArguments(tbc::view<const AgentResume&, tbc::lt::a> resume, tbc::view<std::array<std::string_view, 4>&, tbc::lt::a> arguments) noexcept;

  }
}

// Interface: agents/screen_observation.cppm
export {
  namespace telar::runtime {

    struct AgentScreenObservation {
      std::optional<AgentStatus> status;
      bool restored_draft = false;
      bool identity_confirmed = false;
    };

    std::uint32_t cellCodepoint(const ScreenCell& cell) noexcept;

    struct AgentScreenRow {
      std::array<char, 1024> bytes{};
      std::size_t length = 0;
      std::uint32_t first = 0;
      std::size_t column = 0;

      std::string_view text() const noexcept;
    };

    // What the agent readers look at in a screen, whatever allocator the screen uses.
    struct AgentScreenView {
      std::span<const ScreenCell> cells;
      std::span<const Byte> row_flags;
      std::uint16_t cols = 0;
      std::uint16_t rows = 0;
      Cursor cursor{};
    };

    // The screen comes with the allocator its caller chose, the tests' included.
    template <Allocator Memory>
    TBC_HOT_PATH inline AgentScreenView agentScreenView(const Screen<Memory>& screen) noexcept {
      return AgentScreenView{
          .cells = std::span{screen.cells},
          .row_flags = std::span{screen.row_flags},
          .cols = screen.cols,
          .rows = screen.rows,
          .cursor = screen.cursor,
      };
    }

    class AgentScreenReader {
    public:
      // The terminal comes with the allocator its caller chose, the tests' included.
      template <Allocator Memory>
      TBC_HOT_PATH inline explicit AgentScreenReader(const Terminal<Memory>& terminal, const AgentManifests& manifests = builtin_manifests)
          : AgentScreenReader(agentScreenView(terminal.screen), terminal.effects.title(), manifests) {}

      AgentScreenReader(AgentScreenView screen, std::string_view title, const AgentManifests& manifests) noexcept;

      AgentScreenObservation observe(AgentProvider provider) const noexcept;
      std::optional<AgentSignal> signal(AgentProvider provider) const noexcept;

    private:
      std::span<const ScreenCell> rowCells(std::size_t row) const noexcept;
      AgentScreenRow row(std::size_t y) const noexcept;
      static bool blank(std::uint32_t codepoint) noexcept;
      AgentScreenObservation claude() const noexcept;
      static bool codexStatus(const AgentScreenRow& row) noexcept;
      AgentScreenObservation codex() const noexcept;
      AgentScreenObservation cursor() const noexcept;

      static constexpr std::uint32_t claude_prompt = 0x276f;
      AgentScreenView screen_;
      std::string_view title_;
      const AgentManifests& manifests_;
    };

    bool hasIdleScreen(AgentProvider provider) noexcept;

  }
}

// Interface: agents/screen_inference.cppm
export {
  namespace telar::runtime {

    class AgentScreenSample {
    public:
      std::string_view capture(AgentScreenView screen) noexcept;

    private:
      bool prepend(std::string_view bytes) noexcept;
      std::string_view text() const noexcept;

      std::array<char, 16 * 1024> bytes_{};
      std::size_t start_ = bytes_.size();
    };

    class AgentScreenInference {
    public:
      // The terminal comes with the allocator its caller chose; the inference itself is not generic.
      template <Allocator Memory>
      TBC_HOT_PATH inline std::optional<AgentSignal> observe(Terminal<Memory>& terminal, const AgentManifests& manifests, AgentProvider provider, ObservationTime now) {
        if (!terminal.outputSettled()) {
          return std::nullopt;
        }

        terminal.refresh();

        const auto screen = agentScreenView(terminal.screen);

        return infer(AgentScreenReader{screen, terminal.effects.title(), manifests}, screen, manifests, provider, now);
      }

      void reset() noexcept;

    private:
      std::optional<AgentSignal> infer(const AgentScreenReader& reader, AgentScreenView screen, const AgentManifests& manifests, AgentProvider provider, ObservationTime now);

      static constexpr std::chrono::milliseconds signal_refresh{15'000};
      AgentScreenSample sample_;
      std::optional<AgentSignal> last_signal_;
      std::int64_t last_signal_time_ = 0;
      bool composer_lost_ = false;
    };

  }
}
