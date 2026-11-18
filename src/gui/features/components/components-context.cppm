// What a render sees of the moment it runs: the client, the time, the host's metrics and a
// command's output, and the clock a component formats the time with.
export module telar.gui.features.components:context;

import std;

import telar.gui.foundation.actions;
import telar.gui.foundation.text;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: components/invocation.cppm
export {
  namespace telar::gui::features::components {

    struct Time {
      std::int64_t unix_seconds = 0;
      std::uint16_t year = 0;
      std::uint8_t month = 0;
      std::uint8_t day = 0;
      std::uint8_t hour = 0;
      std::uint8_t minute = 0;
      std::uint8_t second = 0;
      std::uint8_t weekday = 0;
    };

    struct Context {
      BindingContext client;
      Time time;
      ds::Option<SystemMetrics> metrics = ds::none;
      ds::Option<std::string_view> output = ds::none;
      std::string_view pane_title;
    };

  }
}

// Interface: components/clock.cppm
export {
  namespace telar::gui::features::components {

    class Clock {
    public:
      static constexpr std::size_t maximum_format_bytes = 32;
      static constexpr std::size_t maximum_output_bytes = maximum_format_bytes / 2 * std::string_view{"September"}.size();
      using Text = BoundedText<maximum_output_bytes>;

      [[nodiscard]] static Text format(std::string_view pattern, const Time& time);

      [[nodiscard]] static bool showsSeconds(std::string_view pattern) noexcept;

    private:
      static constexpr unsigned noon = 12;
      static constexpr unsigned century = 100;
      static constexpr unsigned decimal_base = 10;
      static constexpr ds::Array<std::string_view, 7> weekdays{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
      static constexpr ds::Array<std::string_view, 7> weekday_names{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
      static constexpr ds::Array<std::string_view, 12> months{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
      static constexpr ds::Array<std::string_view, 12> month_names{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"};

      static void decimal(Text& text, unsigned number, bool padded = true);

      template <std::size_t Count>
      static std::string_view named(const ds::Array<std::string_view, Count>& names, unsigned index) noexcept;

      static void directive(Text& text, char code, const Time& time);
    };

  }
}
