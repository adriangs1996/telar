#pragma once

#include "application/notification_item.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/bounded_text.hpp"
#include "text/text_fit.hpp"
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

struct NotificationActionLabel {
  static constexpr std::size_t decoration_bytes = 16;
  using Buffer = BoundedText<max_notification_link_bytes + decoration_bytes>;

  [[nodiscard]] static constexpr std::string_view target(NotificationTarget::Kind kind) noexcept {
    switch (kind) {
    case NotificationTarget::Kind::pane:
      return "Open pane →";
    case NotificationTarget::Kind::tab:
      return "Open tab →";
    case NotificationTarget::Kind::workspace:
      return "Open workspace →";
    case NotificationTarget::Kind::none:
      return {};
    }

    return {};
  }

  template <LabelMeasure Measure>
  [[nodiscard]] static std::string_view fitHost(std::string_view host, float width, Measure &measure, Buffer &buffer) {
    if (!std::isfinite(width) || width < 0) {
      throw std::invalid_argument{"InvalidNotificationActionWidth"};
    }

    format(host, false, buffer);
    const auto full = static_cast<float>(measure(buffer.view()));
    if (!std::isfinite(full) || full <= 0) {
      throw std::invalid_argument{"InvalidNotificationActionMeasurement"};
    }

    if (full <= width) {
      return buffer.view();
    }

    auto keep = std::min(host.size(), static_cast<std::size_t>(std::floor(static_cast<float>(host.size()) * width / full)));
    while (keep > 0) {
      format(host.substr(host.size() - keep), true, buffer);
      if (measure(buffer.view()) <= width) {
        return buffer.view();
      }

      --keep;
    }

    buffer.truncate(0);
    buffer.append("Open ↗");

    return buffer.view();
  }

private:
  static void format(std::string_view host, bool truncated, Buffer &buffer) {
    buffer.truncate(0);
    buffer.append(truncated ? "Open …" : "Open ");
    buffer.append(host);
    buffer.append(" ↗");
  }
};

}
