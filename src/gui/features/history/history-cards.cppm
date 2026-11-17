module;
#include "tbc/annotations.hpp"

// The rows of the panel: a command's card, its facts and the footer under the list.
export module telar.gui.features.history:cards;

import std;

import :filters;
import telar.tbc;
import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.gui.foundation.drawing;
import telar.gui.foundation.text;

// Interface: presentation/history_row_geometry.cppm
export {
  namespace telar::gui::features::history {

    struct HistoryRowMeasurements {
      float command = 0;
      float cwd = 0;
      float time = 0;
      bool agent = false;
      bool show_cwd = true;
      bool has_cwd = false;
      bool has_time = false;
      bool expanded = false;
    };

    struct HistoryRowGeometry {
      static constexpr float horizontal_inset = 8;
      static constexpr float vertical_inset = 1;
      static constexpr float status_inset = 10;
      static constexpr float status_width = 20;
      static constexpr float command_inset = 40;
      static constexpr float right_inset = 12;
      static constexpr float fact_gap = 14;
      static constexpr float provider_side = 16;
      static constexpr float minimum_command = 160;
      static constexpr float corner_radius = 8;
      static constexpr float heading_inset = 18;
      static constexpr float provider_radius = 3;
      static constexpr float selection_tint_alpha = 0.08F;
      static constexpr float selection_ring_alpha = 0.28F;
      static constexpr float hover_alpha = 0.6F;
      static constexpr float cwd_alpha = 0.8F;

      Rect frame;
      Rect status;
      Rect command;
      Rect provider;
      Rect cwd;
      Rect time;

      [[nodiscard]] static HistoryRowGeometry derive(Rect bounds, ChromeMetrics chrome, float row_height, HistoryRowMeasurements measurements) noexcept;

      bool operator==(const HistoryRowGeometry&) const = default;

    private:
      enum class Kind : std::uint8_t {
        provider,
        cwd,
        time,
      };

      struct Token {
        Kind kind = Kind::provider;
        float width = 0;
      };

      struct Facts {
        static constexpr std::size_t capacity = 3;
        std::array<Token, capacity> tokens{};
        std::size_t count = 0;
        float width = 0;

        void append(Kind kind, float advance, float gap) noexcept;

        void remove(std::size_t index, float gap) noexcept;

        void removeCwd(float gap) noexcept;
      };
    };

  }
}

// Interface: presentation/history_card.cppm
export {
  namespace telar::gui::features::history {

    struct HistoryCardMetrics {
      float cell_width = 1;
      float cell_height = 1;
      float row_height = 0;
      float viewport_height = 0;
    };

    // A shown line of a command, as where it lies in the command the card was measured over.
    struct HistoryCardLine {
      std::uint32_t offset = 0;
      std::uint32_t length = 0;
    };

    struct HistoryCard {
      static constexpr std::size_t maximum_lines = 10;
      static constexpr std::uint16_t more_bound = 64;
      static constexpr float viewport_share = 0.45F;
      static constexpr float viewport_reservation = 32;
      static constexpr float viewport_clearance = 4;
      static constexpr float meta_gap = 4;
      static constexpr float bottom_inset = 8;
      static constexpr float minimum_meta_height = 22;
      static constexpr float meta_padding = 6;

      std::array<HistoryCardLine, maximum_lines> lines{};
      std::uint16_t shown = 0;
      std::uint16_t more = 0;
      std::uint16_t line_limit = maximum_lines;
      float text_y = 0;
      float intrinsic_height = 0;
      float height = 0;
      Rect meta;

      // The text of a shown line of the command the card was measured over.
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> line(tbc::view<std::string_view, tbc::lt::a> command, HistoryCardLine line) noexcept;

      // The card keeps where its lines lie in the command, so it views nothing the caller may replace.
      [[nodiscard]] static HistoryCard measure(const HistoryRowGeometry& row, ChromeMetrics chrome, HistoryCardMetrics metrics, std::string_view command) noexcept;

    private:
      [[nodiscard]] static std::uint16_t lineLimit(ChromeMetrics chrome, HistoryCardMetrics metrics) noexcept;
    };

  }
}

// Interface: presentation/history_facts.cppm
export {
  namespace telar::gui::features::history {

    struct HistoryFactData {
      std::string_view directory;
      std::string_view provider;
      std::string_view duration;
      std::string_view age;
      std::optional<std::int32_t> exit_code;
      HistoryStatus status = HistoryStatus::completed;
      HistoryKeyStyle key_style = HistoryKeyStyle::pc;
      std::uint16_t more = 0;
      bool truncated = false;
      bool loaded = true;
      bool show_directory = true;
      bool has_time = true;
      bool agent = false;
    };

    template <typename Sink>
    concept HistoryFactSink = requires(Sink& sink, std::string_view text, PaletteRole color) {
      { sink(text, color) } -> std::same_as<void>;
    };

    struct HistoryFacts {
      static constexpr std::size_t capacity = 6;
      static constexpr std::size_t notice_capacity = 64;
      static constexpr std::size_t outcome_capacity = 24;

      // Stays here: generic over the caller's sink, which the facts reach through a function pointer.
      template <HistoryFactSink Sink>
      TBC_GENERIC static void visit(const HistoryFactData& data, Sink& sink) {
        auto call = [&sink](std::string_view text, PaletteRole color) {
          sink(text, color);
        };

        const auto forward = [](void* target, std::string_view text, PaletteRole color) {
          (*static_cast<decltype(call)*>(target))(text, color);
        };

        visitErased(data, {.target = &call, .call = forward});
      }

    private:
      // The caller's sink behind a function pointer.
      struct ErasedSink {
        void* target = nullptr;
        void (*call)(void*, std::string_view, PaletteRole) = nullptr;

        void operator()(std::string_view text, PaletteRole color) const;
      };

      static void visitErased(const HistoryFactData& data, ErasedSink sink);

      static void notice(const HistoryFactData& data, ErasedSink& sink);
    };

  }
}

// Interface: presentation/history_footer.cppm
export {
  namespace telar::gui::features::history {

    enum class HistoryFooterAction : std::uint8_t {
      none,
      submit,
      alternate,
      inspect,
      visit,
    };

    struct HistoryFooterHint {
      std::string_view key;
      std::string_view word;
      HistoryFooterAction action = HistoryFooterAction::none;
    };

    struct HistoryFooterOptions {
      HistoryKeyStyle key_style = HistoryKeyStyle::pc;
      std::uint32_t offset = 0;
      std::uint16_t count = 0;
      bool inspecting = false;
      bool enter_runs = false;
      bool has_more = false;
      bool fuzzy = false;
      bool has_query = false;
    };

    struct HistoryFooter {
      static constexpr std::size_t browse_count = 3;
      static constexpr std::size_t inspect_count = 4;
      static constexpr std::size_t capacity = inspect_count;
      static constexpr std::size_t range_capacity = 64;
      using Range = BoundedText<range_capacity>;

      std::array<HistoryFooterHint, capacity> hints{};
      std::size_t count = 0;

      [[nodiscard]] static constexpr HistoryFooter resolve(HistoryFooterOptions options) noexcept {
        const bool mac = options.key_style == HistoryKeyStyle::mac;
        HistoryFooter result;

        result.hints.front() = {.key = mac ? "↩" : "Enter", .word = options.enter_runs ? "run" : "paste", .action = HistoryFooterAction::submit};
        if (options.inspecting) {
          result.hints[1] = {.key = HistoryActions::inspectionKey(options.key_style), .word = "back", .action = HistoryFooterAction::inspect};
          result.hints[2] = {.key = mac ? "⇞⇟" : "PgUp PgDn", .word = "scroll"};
          result.hints[3] = {.key = mac ? "⌥↩" : "Alt+Enter", .word = "go to pane", .action = HistoryFooterAction::visit};
          result.count = inspect_count;
        } else {
          result.hints[1] = {.key = mac ? "⇧↩" : "Shift+Enter", .word = options.enter_runs ? "paste" : "run", .action = HistoryFooterAction::alternate};
          result.hints[2] = {.key = HistoryActions::inspectionKey(options.key_style), .word = "details", .action = HistoryFooterAction::inspect};
          result.count = browse_count;
        }

        return result;
      }

      [[nodiscard]] static Range range(HistoryFooterOptions options);
    };

  }
}

// Interface: presentation/history_footer_geometry.cppm
export {
  namespace telar::gui::features::history {

    struct HistoryFooterMeasurements {
      std::array<HistoryHintMeasurements, HistoryFooter::capacity> hints{};
      std::size_t count = 0;
      float range = 0;
      bool empty = true;
      bool error = false;
    };

    struct HistoryFooterGeometry {
      static constexpr float horizontal_inset = 16;
      static constexpr float vertical_inset = 5;
      static constexpr float hint_gap = 4;
      static constexpr float range_gap = 12;
      static constexpr float separator_height = 1;

      std::array<HistoryHintGeometry, HistoryFooter::capacity> hints{};
      std::size_t count = 0;
      Rect separator;
      Rect range;
      Rect error;
      bool range_visible = false;
      bool error_visible = false;

      [[nodiscard]] static HistoryFooterGeometry derive(Rect area, ChromeMetrics chrome, const HistoryFooterMeasurements& measured) noexcept;
    };

  }
}

// Interface: presentation/history_meta_geometry.cppm
export {
  namespace telar::gui::features::history {

    struct HistoryMetaMeasurements {
      std::array<float, HistoryFacts::capacity> facts{};
      std::array<HistoryHintMeasurements, HistoryActions::count> actions{};
      std::size_t fact_count = 0;
      bool selected = true;
      bool pane_open = false;
    };

    struct HistoryMetaGeometry {
      static constexpr float action_gap = 2;
      static constexpr float facts_right_inset = 10;

      std::array<Rect, HistoryFacts::capacity> facts{};
      std::array<HistoryHintGeometry, HistoryActions::count> actions{};
      std::size_t fact_count = 0;
      std::size_t action_count = 0;
      Rect facts_area;

      [[nodiscard]] static HistoryMetaGeometry derive(Rect bounds, ChromeMetrics chrome, const HistoryMetaMeasurements& measured) noexcept;
    };

  }
}
