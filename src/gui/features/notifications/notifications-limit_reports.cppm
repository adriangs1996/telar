// The limits the session reached: how often each was, when the user last saw it and what the
// runtime has yet to hear of. Nothing here is exported: only the feature's own units name it,
// through State.
export module telar.gui.features.notifications:limit_reports;

import std;

import :limits;
import telar.base.diagnostics;
import telar.base.memory.containers;
import telar.gui.foundation.text;

namespace telar::gui::features::notifications {

  class LimitReports {
  public:
    static constexpr std::size_t capacity = 128;
    static constexpr std::size_t name_capacity = LimitNotices::name_capacity;
    static constexpr std::size_t noun_capacity = LimitNotices::noun_capacity;
    static constexpr std::size_t route_capacity = LimitNotices::route_capacity;
    static constexpr std::size_t description_capacity = LimitNotices::description_capacity;
    static constexpr std::uint64_t notice_interval_ms = LimitNotices::notice_interval_ms;
    static constexpr std::uint64_t report_interval_ms = LimitNotices::report_interval_ms;

    using Time = LimitTime;

    struct Row {
      runtime::FixedText<name_capacity> name;
      runtime::FixedText<noun_capacity> noun;
      runtime::FixedText<route_capacity> route;
      std::uint64_t value = 0;
      std::optional<std::uint64_t> requested = std::nullopt;
      std::uint64_t hits = 0;
      std::uint32_t unreported = 0;
      std::int64_t last_ms = 0;
      std::optional<std::int64_t> shown_ms = std::nullopt;
      std::optional<std::int64_t> reported_ms = std::nullopt;

      [[nodiscard]] LimitReach reach() const noexcept;
    };

    using Slot = LimitSlot;

    using Recorded = LimitRecorded;

    [[nodiscard]] Recorded record(LimitReach reach, Time sampled, std::uint32_t hits);

    [[nodiscard]] std::optional<std::uint32_t> takeReport(Slot slot, std::int64_t awake_ms) noexcept;

    void restoreReport(Slot slot, std::uint32_t hits) noexcept;

    [[nodiscard]] const Row& row(Slot slot) const;

    [[nodiscard]] std::span<const Row> rows() const noexcept;

    [[nodiscard]] std::uint64_t evicted() const noexcept;

    [[nodiscard]] static BoundedText<description_capacity> describe(LimitReach reach, std::uint64_t hits);

  private:
    template <typename Number>
    [[nodiscard]] static Number saturatedAdd(Number left, Number right) noexcept;

    [[nodiscard]] static bool elapsed(std::int64_t now_ms, std::int64_t since_ms, std::uint64_t interval_ms) noexcept;

    static void appendNoun(BoundedText<description_capacity>& text, std::string_view noun);

    [[nodiscard]] std::optional<std::size_t> find(std::string_view name) const noexcept;

    std::size_t insert(std::string_view name);

    [[nodiscard]] std::size_t oldest() const noexcept;

    std::array<Row, capacity> rows_{};
    std::size_t count_ = 0;
    std::uint64_t evicted_ = 0;
  };

}
