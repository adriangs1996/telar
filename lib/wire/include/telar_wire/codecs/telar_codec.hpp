#pragma once

#include "../serializers/telar_serializer.hpp"
#include "telar_base/ds/values.hpp"

#ifdef TELAR_DEBUG
#include "telar_base/ds/containers.hpp"
#include <charconv>
#include <cstdio>
#include <variant>
#endif

namespace telar {

#ifdef TELAR_DEBUG
  namespace debug {

    template <Allocator Memory>
    using Text = ds::String<Memory>;

    template <Allocator Memory, typename Value>
    Text<Memory> inspectValue(Memory& memory, const Value& value) {
      using T = std::remove_cvref_t<Value>;

      if constexpr (std::is_same_v<T, bool>) {
        return Text<Memory>{memory, value ? "true" : "false"};
      } else if constexpr (std::is_enum_v<T>) {
        return inspectValue(memory, static_cast<std::underlying_type_t<T>>(value));
      } else if constexpr (std::is_integral_v<T>) {
        ds::Array<char, 24> digits;
        const auto end = std::to_chars(digits.dataMut(), digits.dataMut() + digits.size(), value).ptr;

        return Text<Memory>{memory, std::string_view{digits.data(), end}};
      } else if constexpr (std::is_same_v<T, std::string_view>) {
        Text<Memory> text{memory, "\""};

        for (const auto character : value) {
          const auto byte = static_cast<Byte>(character);
          if (byte >= 0x20 && byte <= 0x7e && byte != '"' && byte != '\\') {
            text.push(character);
          } else {
            ds::Array<char, 5> escaped{};

            std::snprintf(escaped.dataMut(), escaped.size(), "\\x%02x", static_cast<unsigned>(byte));
            text.append(escaped.data());
          }
        }

        text.push('"');
        return text;
      } else if constexpr (requires {
                             value.has_value();
                             *value;
                           }) {
        return value ? inspectValue(memory, *value) : Text<Memory>{memory, "null"};
      } else if constexpr (requires { std::variant_size<T>::value; }) {
        return std::visit(
            [&](const auto& entry) {
              return inspectValue(memory, entry);
            },
            value
        );
      } else if constexpr (std::is_same_v<T, std::monostate>) {
        return Text<Memory>{memory, "none"};
      } else if constexpr (requires {
                             value.size();
                             value.begin();
                           }) {
        Text<Memory> text{memory, "["};

        for (const auto& entry : value) {
          if (text.size() > 1) {
            text.append(", ");
          }

          text.append(inspectValue(memory, entry));
        }

        text.push(']');
        return text;
      } else if constexpr (requires {
                             value.kind;
                             value.id;
                           }) {
        Text<Memory> text{memory, "{kind="};

        text.append(inspectValue(memory, value.kind));
        text.append(", id=");
        text.append(inspectValue(memory, value.id));
        text.push('}');
        return text;
      } else {
        return Text<Memory>{memory, "{body}"};
      }
    }

    template <Allocator Memory>
    struct Column {
      Text<Memory> name;
      std::span<const Byte> bytes;
      Text<Memory> value;
    };

    // `name` followed by each of `parts`.
    template <Allocator Memory, typename... Parts>
    Text<Memory> joined(const Text<Memory>& name, const Parts&... parts) {
      auto text = name.clone();

      (text.append(parts), ...);
      return text;
    }

    template <Allocator Memory, typename Value>
    void appendColumns(ds::Vec<Column<Memory>, Memory>& columns, Text<Memory> name, std::span<const Byte> bytes, const Value& value) {
      using T = std::remove_cvref_t<Value>;
      auto& memory = columns.memory();
      const auto column = [&](Text<Memory> label, std::span<const Byte> raw, std::string_view text) {
        columns.push(Column<Memory>{std::move(label), raw, Text<Memory>{memory, text}});
      };
      const auto visitor = [&](const char* field, std::span<const Byte> raw, const auto& entry) {
        appendColumns(columns, joined(name, ".", field), raw, entry);
      };

      if constexpr (requires { BodySchema<T>::visitFields(value, bytes, visitor); }) {
        BodySchema<T>::visitFields(value, bytes, visitor);
      } else if constexpr (requires {
                             value.has_value();
                             *value;
                           }) {
        using Element = std::remove_cvref_t<decltype(*value)>;

        if constexpr (requires { BodySchema<Element>::encodedSize(*value); }) {
          if (value) {
            const auto size = BodySchema<Element>::encodedSize(*value);
            const auto prefix = bytes.size() - size;
            if (prefix != 0) {
              column(joined(name, ".length_or_present"), bytes.first(prefix), "present");
            }

            appendColumns(columns, std::move(name), bytes.subspan(prefix), *value);
          } else {
            column(std::move(name), bytes, "null");
          }
        } else {
          columns.push(Column<Memory>{std::move(name), bytes, inspectValue(memory, value)});
        }
      } else if constexpr (requires {
                             typename T::element_type;
                             value.size();
                           }) {
        using Element = std::remove_cv_t<typename T::element_type>;

        if constexpr (requires(const Element& entry) { BodySchema<Element>::encodedSize(entry); }) {
          std::size_t size = 0;

          for (const auto& entry : value) {
            size += BodySchema<Element>::encodedSize(entry);
          }

          const auto prefix = bytes.size() - size;
          if (prefix != 0) {
            columns.push(Column<Memory>{joined(name, ".count"), bytes.first(prefix), inspectValue(memory, value.size())});
          }

          bytes = bytes.subspan(prefix);
          for (std::size_t i = 0; i < value.size(); ++i) {
            const auto width = BodySchema<Element>::encodedSize(value[i]);

            appendColumns(columns, joined(name, "[", inspectValue(memory, i), "]"), bytes.first(width), value[i]);
            bytes = bytes.subspan(width);
          }

          if (value.empty() && prefix == 0) {
            column(std::move(name), {}, "[]");
          }
        } else {
          columns.push(Column<Memory>{std::move(name), bytes, inspectValue(memory, value)});
        }
      } else {
        columns.push(Column<Memory>{std::move(name), bytes, inspectValue(memory, value)});
      }
    }

    enum class FrameRow {
      bytes,
      labels,
      values,
    };

    template <FrameRow Row>
    void printColumn(std::span<const Byte> bytes, const char* name, const char* value, std::FILE* output, bool more) {
      if constexpr (Row == FrameRow::bytes) {
        printBytes(bytes, name, value, output, more);
      } else if constexpr (Row == FrameRow::labels) {
        printLabel(bytes.size(), name, value, output, more);
      } else {
        printValue(bytes.size(), name, value, output, more);
      }
    }

    template <typename Sch, FrameRow Row>
    void printPayload(std::span<const Byte> input, std::FILE* output) {
      if constexpr (requires { Sch::magic; }) {
        const auto bytes = input.first(Sch::magic.size());
        const auto value = valueText(FixedBytes<Sch::magic.size()>::decode(input));

        printColumn<Row>(bytes, "magic", value.data(), output, !input.empty());
      }

      const auto tag_bytes = input.first(u8::width);
      ds::Array<char, sizeof("0x00")> tag_value{};

      std::snprintf(tag_value.dataMut(), tag_value.size(), "0x%02x", static_cast<unsigned>(u8::decode(input)));
      printColumn<Row>(tag_bytes, "tag", tag_value.data(), output, !input.empty());

      if constexpr (Row == FrameRow::bytes) {
        Sch::pretty_print_fields(input, output);
      } else if constexpr (Row == FrameRow::labels) {
        Sch::pretty_print_labels(input, output);
      } else {
        Sch::pretty_print_values(input, output);
      }
    }

    template <typename Sch, FrameRow Row>
    void
    printFrameRow(std::span<const Byte> prefix, std::span<const Byte> payload, std::FILE* output) {
      auto input = prefix;
      const auto length_value = valueText(u32::decode(input));

      printColumn<Row>(prefix, "length", length_value.data(), output, true);
      printPayload<Sch, Row>(payload, output);
      std::fputc('\n', output);
    }

    template <typename Sch>
    void printFrame(std::span<const Byte> payload, std::FILE* output) {
      ds::Array<Byte, frame_prefix_size> prefix{};
      std::span<Byte> prefix_output = prefix.viewMut();

      u32::encode(static_cast<std::uint32_t>(payload.size()), prefix_output);

      std::fputs("Frame:\n", output);
      printFrameRow<Sch, FrameRow::bytes>(prefix, payload, output);
      printFrameRow<Sch, FrameRow::labels>(prefix, payload, output);
      printFrameRow<Sch, FrameRow::values>(prefix, payload, output);
    }

  } // namespace debug
#endif

  struct Codec {
    template <typename Message>
    static void validate(const Message& message) {
      if constexpr (requires { message.validate(); }) {
        message.validate();
      }

      if constexpr (requires { MessageSchema<Message>::validate(message); }) {
        MessageSchema<Message>::validate(message);
      }
    }

    template <typename Message>
    static std::size_t encodedSize(const Message& message) {
      validate(message);
      return checkedWireSize(u8::width, MessageSchema<Message>::encodedSize(message));
    }

    // The encoded bytes, written into the caller's buffer.
    template <typename Message>
    static tbc::view<std::span<Byte>, tbc::lt::a> encode(const Message& message, tbc::view<std::span<Byte>, tbc::lt::a> buffer) {
      const auto size = encodedSize(message);
      if (buffer.size() < size) {
        throw EncodingError{"Output buffer too small"};
      }

      auto output = buffer.first(size);

      u8::encode(static_cast<Byte>(MessageSchema<Message>::tag), output);
      MessageSchema<Message>::encodeBody(message, output);

      if (!output.empty()) {
        throw EncodingError{"Message serializer size mismatch"};
      }

      return buffer.first(size);
    }

#ifdef TELAR_DEBUG
    // Prints the frame's bytes, field names and values in three aligned rows; the text it builds lives
    // in `memory` until it returns.
    template <typename Message, Allocator Memory>
    static void pretty_print(Memory& memory, const Message& message, std::FILE* output = stderr) {
      ds::Vec<Byte, Memory> buffer{memory};

      buffer.resize(encodedSize(message));
      const auto payload = encode(message, buffer.viewMut());
      ds::Array<Byte, frame_prefix_size> prefix{};
      auto prefix_output = std::span<Byte>{prefix.viewMut()};

      u32::encode(static_cast<std::uint32_t>(payload.size()), prefix_output);
      ds::Vec<debug::Column<Memory>, Memory> columns{memory};

      columns.push({debug::Text<Memory>{memory, "length"}, prefix.view(), debug::inspectValue(memory, payload.size())});
      ds::Array<char, 5> tag_text{};

      std::snprintf(tag_text.dataMut(), tag_text.size(), "0x%02x", static_cast<unsigned>(MessageSchema<Message>::tag));
      columns.push({debug::Text<Memory>{memory, "tag"}, payload.first(1), debug::Text<Memory>{memory, tag_text.data()}});
      auto body = std::span<const Byte>{payload.subspan(1)};

      MessageSchema<Message>::visitFields(message, body, [&](const char* name, auto bytes, const auto& value) {
        debug::appendColumns(columns, debug::Text<Memory>{memory, name}, bytes, value);
      });

      std::fputs("Frame:\n", output);
      for (int row = 0; row < 3; ++row) {
        for (std::size_t i = 0; i < columns.size(); ++i) {
          const auto& column = columns[i];
          const auto more = i + 1 < columns.size();

          if (row == 0) {
            debug::printBytes(column.bytes, column.name.data(), column.value.data(), output, more);
          } else if (row == 1) {
            debug::printLabel(column.bytes.size(), column.name.data(), column.value.data(), output, more);
          } else {
            debug::printValue(column.bytes.size(), column.name.data(), column.value.data(), output, more);
          }
        }

        std::fputc('\n', output);
      }
    }
#endif

    template <typename Message>
    static auto encode(const Message& message) _throw(EncodingError) {
      using Sch = MessageSchema<Message>;
      static_assert(Sch::fixed_size, "Variable messages require Codec::encode(message, buffer)");
      static_assert(Sch::payload_size <= max_payload_size);

      ds::Array<Byte, Sch::payload_size> bytes{};

      encode(message, bytes.viewMut());

      return bytes;
    }

    template <typename Message>
    static Message decode(std::span<const Byte> input) _throw(EncodingError) {
      DecodeStorage storage{};

      return decode<Message>(input, storage);
    }

    template <typename Message>
    static Decoded<Message> decode(DecodeFrame input, DecodeStorage& storage) {
      using Sch = MessageSchema<Message>;

      if (input.empty() || input.size() > max_payload_size) {
        throw EncodingError{"Invalid message length"};
      }

      if (u8::decode(input) != static_cast<Byte>(Sch::tag)) {
        throw EncodingError{"Unexpected message tag"};
      }

      Message message{};

      Sch::decodeBody(input, message, storage);
      if (!input.empty()) {
        throw EncodingError{"Trailing bytes in message"};
      }

      validate(message);

      return message;
    }
  };

#ifdef TELAR_DEBUG
  template <Direction Side, auto Tag, typename Body>
  template <typename Message, Allocator Memory>
  void MessageLayout<Side, Tag, Body>::pretty_print(Memory& memory, const Message& message, std::FILE* output) {
    Codec::pretty_print(memory, message, output);
  }
#endif

} // namespace telar
