module telar.runtime.diagnostics.line;
import telar.base.ds;

namespace telar::runtime::diagnostics {

  void Line::reset() noexcept {
    bytes_.atMut(0) = '{';
    length_ = 1;
  }

  void Line::field(std::string_view name, std::uint64_t value) {
    key(name);

    const auto free = bytes_.viewMut().subspan(length_);
    const auto result = std::to_chars(free.data(), std::to_address(free.end()), value);
    if (result.ec == std::errc::value_too_large) {
      throw std::length_error{"Diagnostics line capacity exceeded"};
    }

    length_ = static_cast<std::size_t>(result.ptr - bytes_.data());
  }

  void Line::field(std::string_view name, ds::Option<std::uint64_t> value) {
    if (value) {
      field(name, *value);
    } else {
      literal(name, RawJson{.text = "null"});
    }
  }

  void Line::literal(std::string_view name, RawJson value) {
    key(name);
    append(value.text);
  }

  void Line::timing(TimingFields names, const Timing& value) {
    constexpr std::uint64_t nanoseconds_per_microsecond = 1000;

    field(names.average, value.average() / nanoseconds_per_microsecond);
    field(names.maximum, value.maximum_ns / nanoseconds_per_microsecond);
  }

  std::string_view Line::finish() {
    append("}\n");
    return {bytes_.data(), length_};
  }

  void Line::key(std::string_view name) {
    append(length_ == 1 ? "\"" : ",\"");
    append(name);
    append("\":");
  }

  void Line::append(std::string_view text) {
    if (text.size() > bytes_.size() - length_) {
      throw std::length_error{"Diagnostics line capacity exceeded"};
    }

    std::ranges::copy(text, bytes_.viewMut().subspan(length_).begin());
    length_ += text.size();
  }

}
