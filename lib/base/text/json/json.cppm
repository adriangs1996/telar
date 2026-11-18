module;
#include "tbc/annotations.hpp"

export module telar.base.text.json;

import std;
import telar.tbc;
import telar.base.memory.allocators;
import telar.base.ds;

// Interface: telar_base/text/json_error.cppm
export {
  namespace telar {

    class JsonError final : public std::exception {
    public:
      const char* what() const noexcept override;
    };

  }
}

// Interface: telar_base/text/json.cppm
export {
  namespace telar::runtime {

    // A JSON value inside its text, region `b`; the values and texts it hands out view that text.
    class JsonValue {
    public:
      explicit JsonValue(tbc::view<std::string_view, tbc::lt::b> bytes, unsigned maximum_depth = 32);

      tbc::view<std::string_view, tbc::lt::b> encoded() const noexcept;

      template <typename Consumer>
      TBC_GENERIC void eachElement(Consumer&& consume) const {
        auto input = bytes_;

        for (bool more = enter(input, '[', ']'); more; more = advance(input, ']')) {
          const auto before = input;

          skipValue(input, maximum_depth_);
          consume(JsonValue{before.substr(0, before.size() - input.size()), maximum_depth_});
        }
      }

      template <typename Consumer>
      TBC_GENERIC void eachMember(Consumer&& consume) const {
        auto input = bytes_;

        for (bool more = enter(input, '{', '}'); more; more = advance(input, '}')) {
          const auto key_start = input;
          const JsonValue key{key_start.substr(0, skipKey(input)), maximum_depth_};
          const auto before = input;

          skipValue(input, maximum_depth_);
          consume(key, JsonValue{before.substr(0, before.size() - input.size()), maximum_depth_});
        }
      }

      tbc::view<ds::Option<JsonValue>, tbc::lt::b> field(std::string_view name) const;
      bool equals(std::string_view expected) const;
      bool boolean() const noexcept;

      template <Allocator Memory>
      void string(ds::String<Memory>& output) const;

      static tbc::view<JsonValue, tbc::lt::b> parse(tbc::view<std::string_view, tbc::lt::b> input, unsigned maximum_depth = 32);

    private:
      // The steps of eachElement and eachMember. `enter` consumes the opening bracket and tells
      // whether a first item follows; `advance` consumes the separator after an item and tells
      // whether another follows. `skipKey` consumes a member's name and the colon after it, and
      // returns the size of the name.
      static bool enter(std::string_view& input, char open, char close);
      static bool advance(std::string_view& input, char close);
      static std::size_t skipKey(std::string_view& input);
      static void skipValue(std::string_view& input, unsigned maximum_depth);

      // The escaped text between the quotes of this string value.
      tbc::view<std::string_view, tbc::lt::b> stringContents() const;

      // Writes the unescaped `encoded` to `output`, which holds at least encoded.size() bytes,
      // and returns how many it wrote: an escape never takes fewer bytes than what it spells.
      static std::size_t unescape(std::string_view encoded, char* output);

      tbc::view<std::string_view, tbc::lt::b> bytes_;
      unsigned maximum_depth_;
    };

    // Built in json.cpp for the base allocators its callers use.
    extern template void JsonValue::string<Memory>(ds::String<Memory>& output) const;
    extern template void JsonValue::string<ConcurrentMemory>(ds::String<ConcurrentMemory>& output) const;
    extern template void JsonValue::string<SystemAllocator>(ds::String<SystemAllocator>& output) const;
    extern template void JsonValue::string<BudgetAllocator<SystemAllocator>>(ds::String<BudgetAllocator<SystemAllocator>>& output) const;
    extern template void JsonValue::string<ErasingMemory>(ds::String<ErasingMemory>& output) const;
    extern template void JsonValue::string<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>(ds::String<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>& output) const;

    // How a JSON string spells control bytes: `standard` uses every short escape JSON has; `control`
    // spells backspace and form feed as \u escapes and escapes DEL too, for text a terminal shows.
    enum class JsonEscapes : std::uint8_t {
      standard,
      control,
    };

    // Passes `text` to `emit` as the inside of a JSON string literal, in pieces: runs of bytes that
    // need no escape, and each escape.
    template <typename Emit>
    TBC_GENERIC void escapeJson(std::string_view text, JsonEscapes escapes, Emit&& emit) {
      constexpr std::string_view hex = "0123456789abcdef";
      constexpr unsigned char first_printable = 0x20;
      constexpr unsigned char delete_byte = 0x7f;
      std::size_t plain = 0;

      for (std::size_t index = 0; index < text.size(); ++index) {
        const auto byte = static_cast<unsigned char>(text[index]);
        char shorthand = 0;

        switch (byte) {
        case '"':
          shorthand = '"';
          break;
        case '\\':
          shorthand = '\\';
          break;
        case '\n':
          shorthand = 'n';
          break;
        case '\r':
          shorthand = 'r';
          break;
        case '\t':
          shorthand = 't';
          break;
        case '\b':
          shorthand = escapes == JsonEscapes::standard ? 'b' : 0;
          break;
        case '\f':
          shorthand = escapes == JsonEscapes::standard ? 'f' : 0;
          break;
        default:
          break;
        }

        if (shorthand == 0 && byte >= first_printable && !(byte == delete_byte && escapes == JsonEscapes::control)) {
          continue;
        }

        emit(text.substr(plain, index - plain));
        plain = index + 1;
        if (shorthand != 0) {
          const ds::Array escaped{'\\', shorthand};

          emit(std::string_view{escaped.data(), escaped.size()});
        } else {
          const ds::Array escaped{'\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 15]};

          emit(std::string_view{escaped.data(), escaped.size()});
        }
      }

      emit(text.substr(plain));
    }

    // Appends `text` to `output` as one JSON string literal, quotes included.
    template <typename Text>
    TBC_GENERIC void appendJsonText(Text& output, std::string_view text, JsonEscapes escapes = JsonEscapes::standard) {
      output.append(std::string_view{"\""});
      escapeJson(text, escapes, [&](std::string_view piece) {
        output.append(piece);
      });

      output.append(std::string_view{"\""});
    }

    // `text` as one JSON string literal, quotes included, when it is formatted: the escapes go
    // straight into the output, with no text built apart.
    struct JsonQuoted {
      std::string_view text;
      JsonEscapes escapes = JsonEscapes::standard;
    };

  }
}

template <>
struct std::formatter<telar::runtime::JsonQuoted, char> {
  constexpr auto parse(std::format_parse_context& context) {
    return context.begin();
  }

  template <typename Context>
  auto format(const telar::runtime::JsonQuoted& quoted, Context& context) const {
    auto output = context.out();

    *output++ = '"';
    telar::runtime::escapeJson(quoted.text, quoted.escapes, [&](std::string_view piece) {
      output = std::ranges::copy(piece, output).out;
    });
    *output++ = '"';
    return output;
  }
};

// Interface: telar_base/text/json_fields.cppm
namespace telar::runtime {

  // What JsonFields does that depends on neither its allocator nor its count.
  std::size_t jsonFieldPosition(std::span<const std::string_view> names, std::string_view name);
  std::size_t unsetJsonFieldPosition(std::span<const std::string_view> names, std::span<const ds::Option<JsonValue>> values, std::string_view name);
  const JsonValue& requiredJsonField(const ds::Option<JsonValue>& value);

}

export {
  namespace telar::runtime {

    template <Allocator Memory, std::size_t Count>
    class TBC_GENERIC JsonFields {
    public:
      // The fields view the object's text and the names, and allocate scratch text, all in region `a`.
      inline explicit JsonFields(tbc::view<Memory&, tbc::lt::a> memory, tbc::view<const JsonValue&, tbc::lt::a> object, tbc::view<const ds::Array<std::string_view, Count>&, tbc::lt::a> names)
          : names_(names),
            text_(memory) {
        object.eachMember([&](const JsonValue& key, const JsonValue& value) {
          key.string(text_);
          values_.atMut(unsetJsonFieldPosition(names_, values_, text_)) = value;
        });
      }

      inline const ds::Option<JsonValue>& optional(std::string_view name) const {
        return values_[jsonFieldPosition(names_, name)];
      }

      inline const JsonValue& required(std::string_view name) const {
        return requiredJsonField(optional(name));
      }

      inline std::string_view string(std::string_view name) {
        required(name).string(text_);
        return text_;
      }

    private:
      tbc::view<ds::Array<std::string_view, Count>, tbc::lt::a> names_;
      tbc::view<ds::Array<ds::Option<JsonValue>, Count>, tbc::lt::a> values_;
      tbc::view<ds::String<Memory>, tbc::lt::a> text_;
    };

    template <Allocator Memory, std::size_t Count>
    JsonFields(Memory& memory, const JsonValue& object, const ds::Array<std::string_view, Count>& names) -> JsonFields<Memory, Count>;

  }
}

// Interface: telar_base/text/json_node.cppm
export {
  namespace telar::runtime {

    enum class JsonKind {
      object,
      array,
      string,
      literal,
    };

    template <Allocator Memory>
    class JsonNode {
    public:
      // A node allocates its text and children from the allocator in region `a`.
      explicit JsonNode(tbc::view<Memory&, tbc::lt::a> memory, JsonKind kind = JsonKind::object);

      static tbc::view<JsonNode, tbc::lt::a> parse(tbc::view<Memory&, tbc::lt::a> memory, std::string_view source);

      JsonKind kind() const noexcept;
      std::string_view text() const noexcept;
      std::span<JsonNode> childrenMut() noexcept;
      std::span<const JsonNode> children() const noexcept;
      JsonNode* findMut(std::string_view name) noexcept;
      const JsonNode* find(std::string_view name) const noexcept;
      void erase(std::size_t index);
      JsonNode& ensure(std::string_view name, JsonKind kind);
      void setString(std::string_view name, std::string_view value);
      void setLiteral(std::string_view name, std::string_view value);
      void append(JsonNode child);
      void remove(std::string_view name);
      ds::String<Memory> format() const;

    private:
      static constexpr unsigned maximum_depth = 256;
      static constexpr unsigned indentation = 2;

      tbc::view<Memory&, tbc::lt::a> memory() const noexcept;
      static tbc::view<JsonNode, tbc::lt::a> fromValue(tbc::view<Memory&, tbc::lt::a> memory, JsonValue value);
      void appendFormatted(ds::String<Memory>& output, unsigned depth) const;

      tbc::view<ds::String<Memory>, tbc::lt::a> name_;
      tbc::view<ds::String<Memory>, tbc::lt::a> text_;
      tbc::view<ds::Vec<JsonNode, Memory>, tbc::lt::a> children_;
      JsonKind kind_;
    };

    // Instantiated in json.cpp for the type-erased allocators and for the compositions of base
    // allocators the tests still name.
    extern template class JsonNode<Memory>;
    extern template class JsonNode<ConcurrentMemory>;
    extern template class JsonNode<SystemAllocator>;
    extern template class JsonNode<BudgetAllocator<SystemAllocator>>;

  }
}
