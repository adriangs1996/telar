// The options a pick offers, stored within fixed bounds, and the ones a query matches.
export module telar.gui.features.components:picks;

import std;

import telar.config.core;
import telar.base.ds;

// Interface: components/pick_items.cppm
export {
  namespace telar::gui::features::components {

    using PickSwatch = std::array<std::uint32_t, 3>;

    struct PickInput {
      std::string_view label;
      std::string_view detail;
      ds::Option<std::string_view> value = ds::none;
      ds::Option<PickSwatch> swatch = ds::none;
      bool selected = false;
    };

    struct PickOption {
      std::string_view label;
      std::string_view value;
      std::string_view detail;
      ds::Option<PickSwatch> swatch;
      bool selected;
    };

    class PickItems {
    public:
      static constexpr std::size_t maximum_items = 4096;
      static constexpr std::size_t maximum_text_bytes = std::size_t{256} * 1024;
      static constexpr std::size_t maximum_label_bytes = 128;
      static constexpr std::size_t maximum_value_bytes = 512;
      static constexpr std::size_t maximum_detail_bytes = 128;

      void clear() noexcept;

      // A value remains one argv element; only labels and details may be shortened.
      void keep(const PickInput& input);

      [[nodiscard]] std::size_t size() const noexcept;

      [[nodiscard]] PickOption at(std::size_t index) const;

      void report(runtime::config::LimitNotices& limits) const noexcept;

    private:
      struct Range {
        std::uint32_t offset = 0;
        std::uint16_t length = 0;
      };

      struct Row {
        Range label;
        Range value;
        Range detail;
        ds::Option<PickSwatch> swatch = ds::none;
        bool selected = false;
      };

      struct Offered {
        std::uint32_t items = 0;
        std::uint32_t text = 0;
        std::uint32_t label = 0;
        std::uint32_t value = 0;
        std::uint32_t detail = 0;
        bool text_full = false;
      };

      static std::uint32_t saturated(std::size_t value) noexcept;

      static void offer(std::uint32_t& total, std::size_t value) noexcept;

      static void validate(std::string_view text, bool tabs);

      Range store(std::string_view value) noexcept;

      [[nodiscard]] std::string_view text(Range range) const noexcept;

      std::array<char, maximum_text_bytes> bytes_{};
      std::array<Row, maximum_items> rows_{};
      std::size_t count_ = 0;
      std::size_t used_ = 0;
      Offered offered_;
    };

  }
}

// Interface: components/pick_matches.cppm
export {
  namespace telar::gui::features::components {

    class PickMatches {
    public:
      struct Match {
        std::uint32_t score = 0;
        std::uint16_t index = 0;
      };

      void collect(const PickItems& items, std::string_view query);

      [[nodiscard]] std::span<const Match> rows() const noexcept;

    private:
      std::array<Match, PickItems::maximum_items> matches_{};
      std::size_t count_ = 0;
    };

  }
}
