module telar.gui.foundation.core;

import std;
import telar.tbc;
import telar.base.text.json;
import telar.base.text.utf8;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::inline foundation::inline core {

  JsonWriter::JsonWriter(tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept
      : buffer_(buffer) {}

  tbc::view<std::string_view, tbc::lt::a> JsonWriter::view() const noexcept {
    return {buffer_.data(), length_};
  }

  void JsonWriter::bytes(std::span<const Byte> bytes) {
    const auto text = textView(bytes);
    if (inspectUtf8(text) == Utf8Validation::valid) {
      writeString(text);
    } else {
      array([&](JsonWriter& items) {
        for (const auto byte : bytes) {
          items.element(byte);
        }
      });
    }
  }

  void JsonWriter::open(Container kind) {
    append(kind == Container::object ? "{" : "[");
  }

  void JsonWriter::close(Container kind) {
    append(kind == Container::object ? "}" : "]");
  }

  void JsonWriter::separator() {
    if (!std::exchange(first_, false)) {
      append(",");
    }
  }

  void JsonWriter::append(std::string_view text) {
    if (text.size() > buffer_.size() - length_) {
      throw std::length_error{"WriteFailed"};
    }

    if (!text.empty()) {
      std::memcpy(buffer_.data() + length_, text.data(), text.size());
      length_ += text.size();
    }
  }

  void JsonWriter::write(std::string_view text) {
    validateUtf8(text);

    writeString(text);
  }

  void JsonWriter::writeString(std::string_view text) {
    append("\"");
    runtime::escapeJson(text, runtime::JsonEscapes::standard, [&](std::string_view piece) {
      append(piece);
    });

    append("\"");
  }

  namespace {

    template <typename Number>
    std::size_t writeNumber(std::span<char> output, Number value) {
      if (output.empty()) {
        throw std::length_error{"WriteFailed"};
      }

      const auto result = std::to_chars(output.data(), output.data() + output.size(), value);
      if (result.ec == std::errc::value_too_large) {
        throw std::length_error{"WriteFailed"};
      }

      return static_cast<std::size_t>(result.ptr - output.data());
    }

  }

  void JsonWriter::writeSigned(std::int64_t value) {
    length_ += writeNumber(buffer_.subspan(length_), value);
  }

  void JsonWriter::writeUnsigned(std::uint64_t value) {
    length_ += writeNumber(buffer_.subspan(length_), value);
  }

  template <std::same_as<bool> Boolean>
  void JsonWriter::write(Boolean value) {
    append(value ? "true" : "false");
  }

  template void JsonWriter::write<bool>(bool value);

  void JsonWriter::write(std::nullptr_t) {
    append("null");
  }

  void JsonWriter::write(float value) {
    write(static_cast<double>(value));
  }

  void JsonWriter::write(double value) {
    if (!std::isfinite(value)) {
      throw std::invalid_argument{"InvalidJsonNumber"};
    }

    constexpr std::size_t capacity = std::numeric_limits<double>::max_exponent10 + std::numeric_limits<double>::max_digits10 + sizeof("-0.");
    ds::Array<char, capacity> encoded{};
    const auto result = std::to_chars(encoded.dataMut(), encoded.dataMut() + encoded.size(), value, std::chars_format::fixed);
    if (result.ec == std::errc::value_too_large) {
      throw std::length_error{"WriteFailed"};
    }

    append({encoded.data(), static_cast<std::size_t>(result.ptr - encoded.data())});
  }

}
