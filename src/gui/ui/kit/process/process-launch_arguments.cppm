export module telar.gui.ui.kit.process:launch_arguments;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.base.ds;

export namespace telar::gui::qt {

  class LaunchArguments {
  public:
    static constexpr std::size_t maximum_arguments = 64;

    [[tbc::hot_path]] inline explicit LaunchArguments(const QStringList& arguments) {
      if (arguments.size() > static_cast<qsizetype>(maximum_arguments)) {
        throw std::length_error{"Launch command exceeds its argument capacity"};
      }

      count_ = static_cast<std::size_t>(arguments.size());
      for (std::size_t index = 0; index < count_; ++index) {
        storage_.atMut(index) = arguments[static_cast<qsizetype>(index)].toUtf8();
        views_.atMut(index) = {storage_[index].constData(), static_cast<std::size_t>(storage_[index].size())};
      }
    }

    LaunchArguments(const LaunchArguments&) = delete;
    LaunchArguments& operator=(const LaunchArguments&) = delete;
    LaunchArguments(LaunchArguments&&) = delete;
    LaunchArguments& operator=(LaunchArguments&&) = delete;
    ~LaunchArguments() = default;

    [[tbc::hot_path]] [[nodiscard]] inline std::span<const std::string_view> argv() const noexcept {
      return std::span{views_}.first(count_);
    }

  private:
    ds::Array<QByteArray, maximum_arguments> storage_;
    // Each view reads the bytes stored beside it.
    tbc::val_self<ds::Array<std::string_view, maximum_arguments>> views_{};
    std::size_t count_ = 0;
  };

}
