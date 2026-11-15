module telar.runtime.diagnostics.line;

namespace telar::runtime::diagnostics {

  void Line::reset() noexcept {
    length_ = 0;
    append("{");
  }

  void Line::field(std::string_view name, std::uint64_t value) {
    key(name);

    const auto result = std::to_chars(bytes_.data() + length_, bytes_.data() + bytes_.size(), value);
    if (result.ec != std::errc{}) {
      throw std::length_error{"Diagnostics line capacity exceeded"};
    }

    length_ = static_cast<std::size_t>(result.ptr - bytes_.data());
  }

  void Line::field(std::string_view name, std::optional<std::uint64_t> value) {
    if (value) {
      field(name, *value);
    } else {
      literal(name, "null");
    }
  }

  void Line::literal(std::string_view name, std::string_view value) {
    key(name);
    append(value);
  }

  void Line::timing(std::string_view average_name, std::string_view maximum_name, const Timing& value) {
    field(average_name, value.average() / 1000);
    field(maximum_name, value.maximum_ns / 1000);
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

    std::ranges::copy(text, bytes_.begin() + length_);
    length_ += text.size();
  }

}
