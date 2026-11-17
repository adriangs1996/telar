module;
#include "tbc/annotations.hpp"

export module telar.gui.presentation.history_inspection;

import std;

import telar.tbc;
import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.gui.foundation.text;
import telar.gui.history.browser;
import telar.gui.foundation.actions;

// Interface: presentation/history_labels.cppm
export {
  namespace telar::gui {

    struct HistoryLabels {
      static constexpr std::size_t text_capacity = 32;
      static constexpr std::int64_t nanoseconds_per_millisecond = 1'000'000;
      static constexpr std::int64_t milliseconds_per_second = 1000;
      static constexpr std::int64_t milliseconds_per_tenth = 100;
      static constexpr std::int64_t seconds_per_minute = 60;
      static constexpr std::int64_t minutes_per_hour = 60;
      static constexpr std::int64_t hours_per_day = 24;
      static constexpr std::int64_t seconds_per_hour = seconds_per_minute * minutes_per_hour;
      static constexpr std::int64_t seconds_per_day = seconds_per_hour * hours_per_day;
      static constexpr std::int64_t days_per_week = 7;
      static constexpr std::int64_t epoch_weekday = 4;
      static constexpr int last_calendar_year = 9999;
      static constexpr std::int64_t last_calendar_day = std::chrono::sys_days{std::chrono::year{last_calendar_year} / std::chrono::December / 31}.time_since_epoch().count();
      static constexpr std::array<std::string_view, 12> month_names{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
      static constexpr std::array<std::string_view, 7> weekday_names{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
      static constexpr std::array<std::string_view, 7> short_weekday_names{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
      using Text = BoundedText<text_capacity>;

      struct Status {
        std::string_view glyph;
        PaletteRole color = PaletteRole::text;
      };

      [[nodiscard]] static Text duration(std::int64_t nanoseconds);

      [[nodiscard]] static Text age(std::int64_t milliseconds);

      [[nodiscard]] static Text ageAt(std::int64_t started_ms, CalendarSample sampled);

      [[nodiscard]] static std::int64_t localDay(std::int64_t milliseconds, std::int16_t utc_offset_min) noexcept;

      [[nodiscard]] static Text clock(std::int64_t milliseconds, std::int16_t utc_offset_min);

      [[nodiscard]] static Text dayLabel(std::int64_t day, std::int64_t today);

      [[nodiscard]] static Text dateLabel(std::int64_t milliseconds, CalendarSample sampled);

      [[nodiscard]] static constexpr Status status(HistoryStatus status, std::optional<std::int32_t> exit_code) noexcept {
        switch (status) {
        case HistoryStatus::running:
          return {.glyph = "◌", .color = PaletteRole::teal};
        case HistoryStatus::interrupted:
          return {.glyph = "■", .color = PaletteRole::yellow};
        case HistoryStatus::completed:
          if (!exit_code) {
            return {.glyph = "·", .color = PaletteRole::subtext0};
          }

          return *exit_code == 0 ? Status{.glyph = "·", .color = PaletteRole::overlay0} : Status{.glyph = "✕", .color = PaletteRole::red};
        }

        return {.glyph = "·", .color = PaletteRole::subtext0};
      }

    private:
      [[nodiscard]] static std::int64_t floorDivide(std::int64_t value, std::int64_t divisor) noexcept;

      [[nodiscard]] static std::int64_t positiveRemainder(std::int64_t value, std::int64_t divisor) noexcept;

      [[nodiscard]] static std::int64_t localSeconds(std::int64_t milliseconds, std::int16_t utc_offset_min) noexcept;

      [[nodiscard]] static std::size_t weekday(std::int64_t day) noexcept;

      [[nodiscard]] static std::optional<std::chrono::year_month_day> calendar(std::int64_t day) noexcept;

      static void appendClockPart(Text& text, std::uint64_t value);
    };

  }
}

// Interface: presentation/history_inspection.cppm
export {
  namespace telar::gui {

    struct HistoryInspectionLine {
      enum class Kind : std::uint8_t {
        command,
        blank,
        fact,
        heading,
        output,
      };

      Kind kind = Kind::blank;
      std::string_view text;
      std::string_view label;
      PaletteRole color = PaletteRole::text;
      bool mono = false;
    };

    struct HistoryInspectionEntry {
      std::string_view directory;
      std::string_view provider;
      std::string_view tab;
      std::uint64_t id = 0;
      std::uint64_t pane_id = 0;
      std::int64_t started_at_ms = 0;
      std::int64_t duration_ns = 0;
      std::optional<std::int32_t> exit_code;
      HistoryStatus status = HistoryStatus::completed;
      HistoryAuthor author = HistoryAuthor::human;
      HistoryOrigin origin = HistoryOrigin::pane;
      bool pane_open = false;
    };

    struct HistoryInspectionFacts {
      static constexpr std::size_t count = 6;
      static constexpr std::size_t text_capacity = 128;
      static constexpr std::size_t pane_capacity = std::numeric_limits<std::uint64_t>::digits10 + 1 + std::string_view{"  ·  tab "}.size() + TabCaption::capacity;
      static constexpr std::int64_t last_timestamp_ms = 253'402'300'799'999;

      BoundedText<text_capacity> when;
      HistoryLabels::Text took;
      HistoryLabels::Text exit;
      BoundedText<pane_capacity> pane;
      BoundedText<text_capacity> by;
      std::string_view directory;
      PaletteRole exit_color = PaletteRole::text;

      // The facts view the entry's directory, region `a`.
      [[nodiscard]] static tbc::view<HistoryInspectionFacts, tbc::lt::a> derive(tbc::view<HistoryInspectionEntry, tbc::lt::a> entry, CalendarSample sampled);

      [[nodiscard]] std::array<HistoryInspectionLine, count> lines() const noexcept;

      [[nodiscard]] static BoundedText<text_capacity> outputHeading(HistoryPhase phase, bool truncated, std::size_t bytes);

    private:
      void describeWhen(const HistoryInspectionEntry& entry, CalendarSample sampled);

      void describeExit(const HistoryInspectionEntry& entry);

      void describePane(const HistoryInspectionEntry& entry);

      void describeAuthor(const HistoryInspectionEntry& entry);
    };

    struct HistoryInspectionDocument {
      std::string_view command;
      std::span<const HistoryInspectionLine> facts;
      std::string_view heading;
      std::string_view output;
    };

    class HistoryInspectionLines {
    public:
      HistoryInspectionLines(HistoryInspectionDocument document, std::uint16_t columns) noexcept;

      [[nodiscard]] std::optional<HistoryInspectionLine> next() noexcept;

      [[nodiscard]] std::uint32_t count() const noexcept;

    private:
      enum class Phase : std::uint8_t {
        command,
        after_command,
        facts,
        after_facts,
        heading,
        output,
        done,
      };

      std::span<const HistoryInspectionLine> facts_;
      std::string_view heading_;
      std::string_view output_;
      WrappedLines wrapped_;
      std::uint16_t columns_;
      std::size_t fact_ = 0;
      Phase phase_ = Phase::command;
    };

  }
}

// Interface: presentation/history_path.cppm
export {
  namespace telar::gui {

    struct HistoryPath {
      static constexpr std::size_t byte_capacity = 61;
      static constexpr std::size_t plain_codepoints = 30;
      static constexpr std::size_t tail_codepoints = 28;
      static constexpr std::string_view prefix = "…/";
      using Text = BoundedText<byte_capacity>;

      [[nodiscard]] static Text compact(std::string_view path);

    private:
      struct Limits {
        std::size_t bytes;
        std::size_t codepoints;
      };

      [[nodiscard]] static std::size_t codepoints(std::string_view cluster) noexcept;

      [[nodiscard]] static std::size_t tailStart(std::string_view text, Limits limits) noexcept;

      static void append(Text& destination, std::string_view path);

      [[nodiscard]] static Text copy(std::string_view path);

      static constexpr unsigned utf8_prefix_mask = 0xc0;
    };

  }
}

// Interface: presentation/mode_hints.cppm
export {
  namespace telar::gui {

    enum class StatusMode : std::uint8_t {
      normal,
      prefix,
      copy,
    };

    struct ModeHint {
      KeyChord key;
      std::string_view label;
    };

    template <typename Router>
    concept PrefixHintRouter = requires(const Router& router, const BindingAction& action) {
      { router.prefixedKeyForAction(action) } -> std::same_as<std::optional<KeyChord>>;
    };

    class ModeHints {
    public:
      static constexpr auto actions = std::to_array<std::pair<BindingActionKind, std::string_view>>({
          {BindingActionKind::split_horizontal, "split right"},
          {BindingActionKind::split_vertical, "split down"},
          {BindingActionKind::new_tab, "new tab"},
          {BindingActionKind::new_workspace, "new workspace"},
          {BindingActionKind::rename_tab, "rename tab"},
          {BindingActionKind::rename_workspace, "rename workspace"},
          {BindingActionKind::close_pane, "close pane"},
          {BindingActionKind::copy_mode, "copy mode"},
      });
      static constexpr std::size_t capacity = actions.size();

      // Stays here: generic over the caller's router.
      template <PrefixHintRouter Router>
      // The labels of the hints a router binds are literals.
      [[nodiscard]] TBC_GENERIC static tbc::view<ModeHints, tbc::lt::static_storage> resolve(const Router& router) noexcept {
        ModeHints result;

        for (const auto& [action, label] : actions) {
          if (const auto key = router.prefixedKeyForAction({.kind = action})) {
            result.append({.key = *key, .label = label});
          }
        }

        return result;
      }

      // The hints view their labels, region `a`.
      void append(tbc::view<ModeHint, tbc::lt::a> hint) noexcept;

      [[nodiscard]] tbc::view<std::span<const ModeHint>, tbc::lt::a> items() const noexcept;

    private:
      tbc::view<std::array<ModeHint, capacity>, tbc::lt::a> hints_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: presentation/mode_key_label.cppm
export {
  namespace telar::gui {

    struct ModeKeyLabel {
      static constexpr std::size_t capacity = 48;
      using Text = BoundedText<capacity>;

      [[nodiscard]] static Text format(KeyChord key);

    private:
      [[nodiscard]] static std::string_view name(KeyChord::Key key) noexcept;
    };

  }
}

// Interface: presentation/mode_bar_labels.cppm
export {
  namespace telar::gui {

    struct ModeBarHint {
      static constexpr std::size_t word_capacity = 32;
      ModeKeyLabel::Text key;
      BoundedText<word_capacity> word;
    };

    // What the bar shows while a mode holds the keyboard: the mode's name and the keys it answers.
    class ModeBarLabels {
    public:
      static constexpr auto copy_hints = std::to_array<std::pair<std::string_view, std::string_view>>({
          {"h j k l", "move"},
          {"v", "select"},
          {"V", "lines"},
          {"/", "search"},
          {"y", "copy"},
          {"o", "open"},
          {"q", "exit"},
      });
      static constexpr std::string_view cancel_key = "Esc";
      static constexpr std::string_view cancel_word = "cancel";
      static constexpr std::size_t capacity = std::max(copy_hints.size(), 1 + ModeHints::capacity);

      [[nodiscard]] static ModeBarLabels resolve(StatusMode mode, const ModeHints& hints);

      [[nodiscard]] std::string_view title() const noexcept;

      [[nodiscard]] std::span<const ModeBarHint> hints() const noexcept;

    private:
      void append(std::string_view key, std::string_view word);

      std::string_view title_;
      std::array<ModeBarHint, capacity> hints_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: presentation/workspace_mark.cppm
export {
  namespace telar::gui {

    struct WorkspaceMark {
      static constexpr auto hues = std::to_array<PaletteRole>({PaletteRole::red, PaletteRole::peach, PaletteRole::yellow, PaletteRole::green, PaletteRole::teal, PaletteRole::blue, PaletteRole::mauve});

      Utf8Scalar initial;
      PaletteRole hue = hues.front();

      [[nodiscard]] static WorkspaceMark resolve(std::string_view name);

    private:
      [[nodiscard]] static std::uint32_t hash(std::string_view name) noexcept;
    };

  }
}
