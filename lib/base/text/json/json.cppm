module;
#include "tbc/annotations.hpp"

export module telar.base.text.json;

import std;
import telar.tbc;
import telar.base.memory.allocators;
import telar.base.text.utf8;

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
      TBC_HOT_PATH void eachElement(Consumer&& consume) const {
        auto input = bytes_;

        for (bool more = enter(input, '[', ']'); more; more = advance(input, ']')) {
          const auto before = input;

          skipValue(input, maximum_depth_);
          consume(JsonValue{before.substr(0, before.size() - input.size()), maximum_depth_});
        }
      }

      template <typename Consumer>
      TBC_HOT_PATH void eachMember(Consumer&& consume) const {
        auto input = bytes_;

        for (bool more = enter(input, '{', '}'); more; more = advance(input, '}')) {
          const auto key_start = input;
          const JsonValue key{key_start.substr(0, skipKey(input)), maximum_depth_};
          const auto before = input;

          skipValue(input, maximum_depth_);
          consume(key, JsonValue{before.substr(0, before.size() - input.size()), maximum_depth_});
        }
      }

      tbc::view<std::optional<JsonValue>, tbc::lt::b> field(std::string_view name) const;
      bool equals(std::string_view expected) const;
      bool boolean() const noexcept;

      template <Allocator Memory>
      TBC_HOT_PATH void string(String<Memory>& output) const {
        const auto encoded = stringContents();

        output.clear();
        output.resize(encoded.size());
        output.resize(unescape(encoded, output.data()));
      }

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

    // How a JSON string spells control bytes: `standard` uses every short escape JSON has; `control`
    // spells backspace and form feed as \u escapes and escapes DEL too, for text a terminal shows.
    enum class JsonEscapes : std::uint8_t {
      standard,
      control,
    };

    // Passes `text` to `emit` as the inside of a JSON string literal, in pieces: runs of bytes that
    // need no escape, and each escape.
    template <typename Emit>
    TBC_HOT_PATH void escapeJson(std::string_view text, JsonEscapes escapes, Emit&& emit) {
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
          const std::array escaped{'\\', shorthand};

          emit(std::string_view{escaped.data(), escaped.size()});
        } else {
          const std::array escaped{'\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 15]};

          emit(std::string_view{escaped.data(), escaped.size()});
        }
      }

      emit(text.substr(plain));
    }

    // Appends `text` to `output` as one JSON string literal, quotes included.
    template <typename Text>
    TBC_HOT_PATH void appendJsonText(Text& output, std::string_view text, JsonEscapes escapes = JsonEscapes::standard) {
      output.push_back('"');
      escapeJson(text, escapes, [&](std::string_view piece) {
        output.append(piece);
      });

      output.push_back('"');
    }

  }
}

// Interface: telar_base/text/json_fields.cppm
namespace telar::runtime {

  // What JsonFields does that depends on neither its allocator nor its count.
  std::size_t jsonFieldPosition(std::span<const std::string_view> names, std::string_view name);
  std::size_t unsetJsonFieldPosition(std::span<const std::string_view> names, std::span<const std::optional<JsonValue>> values, std::string_view name);
  const JsonValue& requiredJsonField(const std::optional<JsonValue>& value);

}

export {
  namespace telar::runtime {

    template <Allocator Memory, std::size_t Count>
    class TBC_HOT_PATH JsonFields {
    public:
      // The fields view the object's text and the names, and allocate scratch text, all in region `a`.
      inline explicit JsonFields(tbc::view<Memory&, tbc::lt::a> memory, tbc::view<const JsonValue&, tbc::lt::a> object, tbc::view<const std::array<std::string_view, Count>&, tbc::lt::a> names)
          : names_(names),
            text_(AllocatorRef<char, Memory>{memory}) {
        object.eachMember([&](const JsonValue& key, const JsonValue& value) {
          key.string(text_);
          values_[unsetJsonFieldPosition(names_, values_, text_)] = value;
        });
      }

      inline const std::optional<JsonValue>& optional(std::string_view name) const {
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
      tbc::view<std::array<std::string_view, Count>, tbc::lt::a> names_;
      tbc::view<std::array<std::optional<JsonValue>, Count>, tbc::lt::a> values_;
      tbc::view<String<Memory>, tbc::lt::a> text_;
    };

    template <Allocator Memory, std::size_t Count>
    JsonFields(Memory& memory, const JsonValue& object, const std::array<std::string_view, Count>& names) -> JsonFields<Memory, Count>;

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

      // The accessors and erase stay here because the lifetime checker learns only from a body what
      // a non-const method leaves untouched; callers keep borrows of a node across them.
      TBC_HOT_PATH JsonKind kind() const noexcept {
        return kind_;
      }

      TBC_HOT_PATH std::string_view text() const noexcept {
        return text_;
      }

      TBC_HOT_PATH std::span<JsonNode> children() noexcept {
        return children_;
      }

      TBC_HOT_PATH std::span<const JsonNode> children() const noexcept {
        return children_;
      }

      TBC_HOT_PATH JsonNode* find(std::string_view name) noexcept {
        if (kind_ != JsonKind::object) {
          return nullptr;
        }

        const auto found = std::ranges::find_if(children_, [name](const auto& child) {
          return child.name_ == name;
        });

        return found == children_.end() ? nullptr : &*found;
      }

      TBC_HOT_PATH const JsonNode* find(std::string_view name) const noexcept {
        return const_cast<JsonNode*>(this)->find(name);
      }

      TBC_HOT_PATH void erase(std::size_t index) {
        children_.erase(children_.begin() + index);
      }

      JsonNode& ensure(std::string_view name, JsonKind kind);
      void setString(std::string_view name, std::string_view value);
      void setLiteral(std::string_view name, std::string_view value);
      void append(JsonNode child);
      void remove(std::string_view name);
      String<Memory> format() const;

    private:
      static constexpr unsigned maximum_depth = 256;
      static constexpr unsigned indentation = 2;

      tbc::view<Memory&, tbc::lt::a> memory() const noexcept;
      static tbc::view<JsonNode, tbc::lt::a> fromValue(tbc::view<Memory&, tbc::lt::a> memory, JsonValue value);
      void appendFormatted(String<Memory>& output, unsigned depth) const;

      tbc::view<String<Memory>, tbc::lt::a> name_;
      tbc::view<String<Memory>, tbc::lt::a> text_;
      tbc::view<Vector<JsonNode, Memory>, tbc::lt::a> children_;
      JsonKind kind_;
    };

    // Instantiated in json.cpp for the type-erased allocators and for the compositions of base
    // allocators the tests still name. No extern template declaration: it would hide the bodies
    // above from the lifetime checker.

  }
}
