#pragma once

#include "../serializers/telar_serializer.hpp"

namespace telar {

#ifdef TELAR_DEBUG
  namespace debug {

    enum class FrameRow { bytes, labels, values };

    template <FrameRow Row>
    void printColumn(std::span<const Byte> bytes, const char *name, const char *value,
                     std::FILE *output, bool more) {
      if constexpr (Row == FrameRow::bytes) {
        printBytes(bytes, name, value, output, more);
      } else if constexpr (Row == FrameRow::labels) {
        printLabel(bytes.size(), name, value, output, more);
      } else {
        printValue(bytes.size(), name, value, output, more);
      }
    }

    template <typename Sch, FrameRow Row>
    void printPayload(std::span<const Byte> input, std::FILE *output) {
      if constexpr (requires { Sch::magic; }) {
        const auto bytes = input.first(Sch::magic.size());
        const auto value = valueText(FixedBytes<Sch::magic.size()>::decode(input));
        printColumn<Row>(bytes, "magic", value.data(), output, !input.empty());
      }

      const auto tag_bytes = input.first(u8::width);
      std::array<char, sizeof("0x00")> tag_value{};
      std::snprintf(tag_value.data(), tag_value.size(), "0x%02x",
                    static_cast<unsigned>(u8::decode(input)));
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
    void printFrameRow(std::span<const Byte> prefix, std::span<const Byte> payload,
                       std::FILE *output) {
      auto input = prefix;
      const auto length_value = valueText(u32::decode(input));
      printColumn<Row>(prefix, "length", length_value.data(), output, true);
      printPayload<Sch, Row>(payload, output);
      std::fputc('\n', output);
    }

    template <typename Sch> void printFrame(std::span<const Byte> payload, std::FILE *output) {
      std::array<Byte, frame_prefix_size> prefix{};
      std::span<Byte> prefix_output = prefix;
      u32::encode(static_cast<std::uint32_t>(payload.size()), prefix_output);

      std::fputs("Frame:\n", output);
      printFrameRow<Sch, FrameRow::bytes>(prefix, payload, output);
      printFrameRow<Sch, FrameRow::labels>(prefix, payload, output);
      printFrameRow<Sch, FrameRow::values>(prefix, payload, output);
    }

  } // namespace debug
#endif

  struct Codec {

#ifdef TELAR_DEBUG
    template <typename Message>
    static void pretty_print(const Message &message, std::FILE *output = stderr) {
      const auto payload = encode(message);
      debug::printFrame<MessageSchema<Message>>(payload, output);
    }
#endif

    template <typename Message> static auto encode(const Message &message) _throw(EncodingError) {
      using Sch = MessageSchema<Message>;
      static_assert(Sch::payload_size <= max_payload_size);

      if constexpr (requires { message.validate(); }) {
        message.validate();
      }

      std::array<Byte, Sch::payload_size> bytes{};
      std::span<Byte> output = bytes;

      u8::encode(static_cast<Byte>(Sch::tag), output);
      Sch::encodeBody(message, output);

      return bytes;
    }

    template <typename Message>
    static Message decode(std::span<const Byte> input) _throw(EncodingError) {
      using Sch = MessageSchema<Message>;

      if (input.size() != Sch::payload_size) {
        throw EncodingError{"Invalid message length"};
      }

      if (u8::decode(input) != static_cast<Byte>(Sch::tag)) {
        throw EncodingError{"Unexpected message tag"};
      }

      Message message{};
      Sch::decodeBody(input, message);

      if constexpr (requires { message.validate(); }) {
        message.validate();
      }

      return message;
    }
  };

#ifdef TELAR_DEBUG
  template <Direction Side, auto Tag, typename... Fields>
  template <typename Message>
  void Schema<Side, Tag, Fields...>::pretty_print(const Message &message, std::FILE *output) {
    Codec::pretty_print(message, output);
  }
#endif

} // namespace telar
