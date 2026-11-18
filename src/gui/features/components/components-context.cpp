module telar.gui.features.components;

import std;

import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::features::components {

  Clock::Text Clock::format(std::string_view pattern, const Time& time) {
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

  bool Clock::showsSeconds(std::string_view pattern) noexcept {
    return pattern.contains("%S");
  }

  void Clock::decimal(Text& text, unsigned number, bool padded) {
    if (padded && number < decimal_base) {
      text.append("0");
    }

    text.appendDecimal(number);
  }

  template <std::size_t Count>
  std::string_view Clock::named(const ds::Array<std::string_view, Count>& names, unsigned index) noexcept {
    return names[std::min<std::size_t>(index, Count - 1)];
  }

  void Clock::directive(Text& text, char code, const Time& time) {
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

}
