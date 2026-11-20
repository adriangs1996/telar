module;
#include "tbc/annotations.hpp"

export module telar.gui.foundation.core:json_writer;

import std;
import telar.tbc;
import telar.base.text.json;
import telar.wire.vocabulary;
import telar.base.ds;

// Interface: core/json_writer.cppm
export {
  namespace telar::gui::inline foundation::inline core {

    // Writes JSON into the caller's buffer, region `a`, which the written text views.
    class JsonWriter {
    public:
      explicit JsonWriter(tbc::val_a<std::span<char>> buffer) noexcept;

      template <typename Consumer>
      TBC_GENERIC void object(Consumer&& consume) {
        container(Container::object, std::forward<Consumer>(consume));
      }

      template <typename Consumer>
      TBC_GENERIC void array(Consumer&& consume) {
        container(Container::array, std::forward<Consumer>(consume));
      }

      template <typename Value>
      TBC_GENERIC void member(std::string_view name, const Value& value) {
        separator();
        write(name);
        append(":");
        write(value);
      }

      template <typename Value>
      TBC_GENERIC void element(const Value& value) {
        separator();
        write(value);
      }

      [[nodiscard]] tbc::val_a<std::string_view> view() const noexcept;

      template <typename Value>
      TBC_GENERIC void value(const Value& value) {
        write(value);
      }

      void bytes(std::span<const Byte> bytes);

    private:
      enum class Container : std::uint8_t {
        object,
        array,
      };

      template <typename Consumer>
      TBC_GENERIC void container(Container kind, Consumer&& consume) {
        open(kind);
        const auto previous = std::exchange(first_, true);

        std::invoke(std::forward<Consumer>(consume), *this);
        close(kind);
        first_ = previous;
      }

      void open(Container kind);
      void close(Container kind);
      void separator();
      void append(std::string_view text);
      void write(std::string_view text);
      void writeString(std::string_view text);
      void writeSigned(std::int64_t value);
      void writeUnsigned(std::uint64_t value);

      template <typename Text>
        requires(std::is_array_v<Text> && std::same_as<std::remove_extent_t<Text>, char>)
      TBC_GENERIC void write(const Text& text) {
        const auto bytes = std::span{text};
        const auto end = std::ranges::find(bytes, '\0');

        write(std::string_view{bytes.data(), static_cast<std::size_t>(end - bytes.begin())});
      }

      // A template so that no pointer or number converts to it; instantiated only for bool.
      template <std::same_as<bool> Boolean>
      void write(Boolean value);

      void write(std::nullptr_t);

      template <typename Value>
      TBC_GENERIC void write(const ds::Option<Value>& value) {
        if (value) {
          write(*value);
        } else {
          write(nullptr);
        }
      }

      template <std::integral Number>
        requires(!std::same_as<Number, bool>)
      TBC_GENERIC void write(Number value) {
        if constexpr (std::is_signed_v<Number>) {
          writeSigned(value);
        } else {
          writeUnsigned(value);
        }
      }

      void write(float value);
      void write(double value);

      template <typename Consumer>
        requires std::invocable<Consumer, JsonWriter&>
      TBC_GENERIC void write(Consumer&& consume) {
        std::invoke(std::forward<Consumer>(consume), *this);
      }

      tbc::val_a<std::span<char>> buffer_;
      std::size_t length_ = 0;
      bool first_ = true;
    };

    extern template void JsonWriter::write<bool>(bool value);

  }
}
