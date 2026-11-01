#pragma once

#include "invocation.hpp"
#include "text/bounded_text.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <stdexcept>
#include <string_view>

namespace telar::gui::components {

class Clock {
public:
  static constexpr std::size_t maximum_format_bytes = 32;
  static constexpr std::size_t maximum_output_bytes = maximum_format_bytes / 2 * std::string_view{"September"}.size();
  using Text = BoundedText<maximum_output_bytes>;

  [[nodiscard]] static Text format(std::string_view pattern, const Time &time) {
    if (pattern.size() > maximum_format_bytes) {
      throw std::length_error{"Clock format exceeds its byte limit"};
    }

    Text result;
    for (std::size_t index = 0; index < pattern.size(); ++index) {
      if (pattern[index] == '%' && index + 1 < pattern.size()) {
        directive(result, pattern[++index], time);
      } else {
        result.append(pattern.substr(index, 1));
      }
    }

    return result;
  }

  [[nodiscard]] static bool showsSeconds(std::string_view pattern) noexcept {
    return pattern.contains("%S");
  }

private:
  static constexpr unsigned noon = 12;
  static constexpr unsigned century = 100;
  static constexpr unsigned decimal_base = 10;
  static constexpr std::array<std::string_view, 7> weekdays{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
  static constexpr std::array<std::string_view, 7> weekday_names{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
  static constexpr std::array<std::string_view, 12> months{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
  static constexpr std::array<std::string_view, 12> month_names{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"};

  static void decimal(Text &text, unsigned number, bool padded = true) {
    if (padded && number < decimal_base) {
      text.append("0");
    }

    text.appendDecimal(number);
  }

  template <std::size_t Count>
  static std::string_view named(const std::array<std::string_view, Count> &names, unsigned index) noexcept {
    return names[std::min<std::size_t>(index, Count - 1)];
  }

  static void directive(Text &text, char code, const Time &time) {
    switch (code) {
    case 'H':
      decimal(text, time.hour);
      break;
    case 'M':
      decimal(text, time.minute);
      break;
    case 'S':
      decimal(text, time.second);
      break;
    case 'I':
      decimal(text, time.hour % noon == 0 ? noon : time.hour % noon);
      break;
    case 'p':
      text.append(time.hour < noon ? "AM" : "PM");
      break;
    case 'd':
      decimal(text, time.day);
      break;
    case 'e':
      decimal(text, time.day, false);
      break;
    case 'm':
      decimal(text, time.month);
      break;
    case 'y':
      decimal(text, time.year % century);
      break;
    case 'Y':
      decimal(text, time.year, false);
      break;
    case 'a':
      text.append(named(weekdays, time.weekday));
      break;
    case 'A':
      text.append(named(weekday_names, time.weekday));
      break;
    case 'b':
      text.append(named(months, time.month == 0 ? 0 : time.month - 1U));
      break;
    case 'B':
      text.append(named(month_names, time.month == 0 ? 0 : time.month - 1U));
      break;
    case '%':
      text.append("%");
      break;
    default:
      text.append("%");
      text.append({&code, 1});
      break;
    }
  }
};

}
