#pragma once

#include <QByteArray>
#include <QStringList>
#include <QtCore/qtypes.h>
#include <array>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui::qt {

class LaunchArguments {
public:
  static constexpr std::size_t maximum_arguments = 64;

  explicit LaunchArguments(const QStringList &arguments) {
    if (arguments.size() > static_cast<qsizetype>(maximum_arguments)) {
      throw std::length_error{"Launch command exceeds its argument capacity"};
    }

    count_ = static_cast<std::size_t>(arguments.size());
    for (std::size_t index = 0; index < count_; ++index) {
      storage_[index] = arguments[static_cast<qsizetype>(index)].toUtf8();
      views_[index] = {storage_[index].constData(), static_cast<std::size_t>(storage_[index].size())};
    }
  }

  LaunchArguments(const LaunchArguments &) = delete;
  LaunchArguments &operator=(const LaunchArguments &) = delete;
  LaunchArguments(LaunchArguments &&) = delete;
  LaunchArguments &operator=(LaunchArguments &&) = delete;
  ~LaunchArguments() = default;

  [[nodiscard]] std::span<const std::string_view> argv() const noexcept {
    return std::span{views_}.first(count_);
  }

private:
  std::array<QByteArray, maximum_arguments> storage_;
  std::array<std::string_view, maximum_arguments> views_{};
  std::size_t count_ = 0;
};

}
