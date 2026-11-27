module;

// The inspection of one command: its labels, facts and output, and the modal that shows it.
export module telar.gui.features.history:inspection;

import std;

import :entry;
import :filters;
import telar.tbc;
import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.gui.foundation.text;
import telar.gui.foundation.forms;
import telar.base.ds;

// Interface: presentation/history_labels.cppm
export {
  namespace telar::gui::features::history {

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
      static constexpr ds::Array<std::string_view, 12> month_names{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
      static constexpr ds::Array<std::string_view, 7> weekday_names{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
      static constexpr ds::Array<std::string_view, 7> short_weekday_names{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
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

      [[nodiscard]] static constexpr Status status(HistoryStatus status, ds::Option<std::int32_t> exit_code) noexcept {
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

      [[nodiscard]] static ds::Option<std::chrono::year_month_day> calendar(std::int64_t day) noexcept;

      static void appendClockPart(Text& text, std::uint64_t value);
    };

  }
}

// Interface: presentation/history_inspection.cppm
export {
  namespace telar::gui::features::history {

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
      ds::Option<std::int32_t> exit_code;
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
      [[nodiscard]] static tbc::val_a<HistoryInspectionFacts> derive(tbc::val_a<HistoryInspectionEntry> entry, CalendarSample sampled);

      [[nodiscard]] ds::Array<HistoryInspectionLine, count> lines() const noexcept;

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

      [[nodiscard]] ds::Option<HistoryInspectionLine> next() noexcept;

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
  namespace telar::gui::features::history {

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

// Interface: presentation/history_modal_geometry.cppm
export {
  namespace telar::gui::features::history {

    struct HistoryModalMetrics {
      Rect viewport{};
      ChromeMetrics chrome{};
      float cell_height = 0;
    };

    struct HistoryModalGeometry {
      static constexpr float maximum_width = 1360;
      static constexpr float minimum_height = 640;
      static constexpr float height_share = 0.8F;
      static constexpr float split_width = 900;
      static constexpr float list_share = 0.44F;
      static constexpr float margin = 28;
      static constexpr float margin_divisor = 12;
      static constexpr float row_minimum = 34;
      static constexpr float row_padding = 12;
      static constexpr float group_minimum = 28;
      static constexpr float group_padding = 10;
      static constexpr float header_minimum = 46;
      static constexpr float header_padding = 22;
      static constexpr float search_minimum = 52;
      static constexpr float search_padding = 24;
      static constexpr float footer_minimum = 36;
      static constexpr float footer_padding = 14;
      static constexpr float compact_width = 420;
      static constexpr float compact_height = 260;
      static constexpr float inspection_inset = 18;
      static constexpr float inspection_inset_divisor = 8;
      static constexpr float action_minimum = 28;
      static constexpr float action_padding = 8;

      Rect viewport;
      Rect bounds;
      Rect header;
      Rect results;
      Rect inspection;
      Rect search;
      Rect footer;
      float row_height = 0;
      float group_height = 0;
      bool compact = false;

      [[nodiscard]] static HistoryModalGeometry measure(const HistoryModalMetrics& metrics, bool inspecting) noexcept;
      void offsetY(float offset) noexcept;
      [[nodiscard]] Rect inspectionContent(const ChromeMetrics& chrome) const noexcept;
      [[nodiscard]] Rect inspectionActions(const ChromeMetrics& chrome) const noexcept;

    private:
      [[nodiscard]] float inspectionInset(const ChromeMetrics& chrome) const noexcept;
      static Rect takeBottom(Rect& remaining, float height) noexcept;
      static Rect takeTop(Rect& remaining, float height) noexcept;
    };

  }
}

// Interface: presentation/history_inspection_geometry.cppm
export {
  namespace telar::gui::features::history {

    struct HistoryInspectionGeometry {
      static constexpr std::size_t maximum_actions = history_inspection_action_count;
      static constexpr float command_padding = 8;
      static constexpr float fact_label_width = 64;
      static constexpr float fact_label_divisor = 3;
      static constexpr float button_padding = 24;
      static constexpr float button_gap = 8;
      static constexpr float button_radius = FormButtonStyle::radius;
      static constexpr float disabled_alpha = FormButtonStyle::disabled_alpha;
      static constexpr float pressed_alpha = FormButtonStyle::pressed_alpha;

      Rect content;
      Rect actions;
      std::uint16_t columns = 0;
      std::uint16_t rows = 0;
      float row_height = 0;
      float label_width = 0;
      float command_inset = 0;

      [[nodiscard]] static HistoryInspectionGeometry derive(Rect area, ChromeMetrics chrome, Point cell) noexcept;
      [[nodiscard]] Rect row(std::size_t index) const noexcept;
      [[nodiscard]] Rect text(Rect row, HistoryInspectionLine::Kind kind) const noexcept;
      [[nodiscard]] ds::Array<Rect, maximum_actions> buttons(std::span<const float> advances, ChromeMetrics chrome) const noexcept;
    };

  }
}
