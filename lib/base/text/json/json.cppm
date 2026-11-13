module;
#include "tbc/view.hpp"

export module telar.base.text.json;

import std;
import telar.base.memory.allocators;
import telar.base.text.utf8;

// Interface: telar_base/text/json_error.cppm
export {
  namespace telar {

    class JsonError final : public std::exception {
    public:
      inline const char* what() const noexcept override {
        return "Invalid JSON record";
      }
    };

  }
}

// Interface: telar_base/text/json.cppm
export {
  namespace telar::runtime {

    // A JSON value inside its text, region `b`; the values and texts it hands out view that text.
    class JsonValue {
    public:
      inline explicit JsonValue(tbc::view<std::string_view, tbc::lt::b> bytes, unsigned maximum_depth = 32)
          : bytes_(bytes),
            maximum_depth_(maximum_depth) {}

      inline tbc::view<std::string_view, tbc::lt::b> encoded() const noexcept {
        return bytes_;
      }

      template <typename Consumer>
      inline void eachElement(Consumer&& consume) const {
        auto input = bytes_;

        take(input, '[');
        whitespace(input);
        if (input.starts_with(']')) {
          return;
        }

        for (;;) {
          const auto before = input;

          skip(input, 0, maximum_depth_);
          consume(JsonValue{before.substr(0, before.size() - input.size()), maximum_depth_});
          whitespace(input);
          if (input.starts_with(']')) {
            return;
          }

          take(input, ',');
          whitespace(input);
        }
      }

      template <typename Consumer>
      inline void eachMember(Consumer&& consume) const {
        auto input = bytes_;

        take(input, '{');
        whitespace(input);
        if (input.starts_with('}')) {
          return;
        }

        for (;;) {
          const auto key_start = input;

          stringToken(input);
          const JsonValue key{key_start.substr(0, key_start.size() - input.size()), maximum_depth_};

          whitespace(input);
          take(input, ':');
          whitespace(input);
          const auto before = input;

          skip(input, 0, maximum_depth_);
          consume(key, JsonValue{before.substr(0, before.size() - input.size()), maximum_depth_});
          whitespace(input);
          if (input.starts_with('}')) {
            return;
          }

          take(input, ',');
          whitespace(input);
        }
      }

      inline tbc::view<std::optional<JsonValue>, tbc::lt::b> field(std::string_view name) const {
        auto input = bytes_;

        whitespace(input);
        take(input, '{');
        while (true) {
          whitespace(input);
          if (input.starts_with('}')) {
            return std::nullopt;
          }

          const auto key = stringToken(input);

          whitespace(input);
          take(input, ':');
          whitespace(input);
          const auto before = input;

          skip(input, 0, maximum_depth_);
          const auto value = before.substr(0, before.size() - input.size());

          if (key == name) {
            return JsonValue{value, maximum_depth_};
          }

          whitespace(input);
          if (input.starts_with('}')) {
            return std::nullopt;
          }

          take(input, ',');
        }
      }

      inline bool equals(std::string_view expected) const {
        auto input = bytes_;

        return input.starts_with('"') && stringToken(input) == expected;
      }

      inline bool boolean() const noexcept {
        return bytes_ == "true";
      }

      template <Allocator Memory>
      inline void string(String<Memory>& output) const {
        auto input = bytes_;
        const auto encoded = stringToken(input);

        output.clear();
        for (std::size_t index = 0; index < encoded.size(); ++index) {
          const char byte = encoded[index];
          if (byte != '\\') {
            output.push_back(byte);
            continue;
          }

          if (++index == encoded.size()) {
            invalid();
          }

          switch (encoded[index]) {
          case '"':
          case '\\':
          case '/':
            output.push_back(encoded[index]);
            break;
          case 'b':
            output.push_back('\b');
            break;
          case 'f':
            output.push_back('\f');
            break;
          case 'n':
            output.push_back('\n');
            break;
          case 'r':
            output.push_back('\r');
            break;
          case 't':
            output.push_back('\t');
            break;
          case 'u': {
            auto codepoint = hex(encoded, index + 1);

            index += 4;
            if (codepoint >= 0xd800 && codepoint <= 0xdbff) {
              if (encoded.substr(index + 1, 2) != "\\u") {
                invalid();
              }

              const auto low = hex(encoded, index + 3);
              if (low < 0xdc00 || low > 0xdfff) {
                invalid();
              }

              codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + low - 0xdc00;
              index += 6;
            } else if (codepoint >= 0xdc00 && codepoint <= 0xdfff) {
              invalid();
            }

            appendUtf8(output, codepoint);
            break;
          }
          default:
            invalid();
          }
        }
      }

      inline static tbc::view<JsonValue, tbc::lt::b> parse(tbc::view<std::string_view, tbc::lt::b> input, unsigned maximum_depth = 32) {
        whitespace(input);
        const auto original = input;

        skip(input, 0, maximum_depth);
        const auto value = original.substr(0, original.size() - input.size());

        whitespace(input);
        if (!input.empty()) {
          invalid();
        }

        return JsonValue{value, maximum_depth};
      }

    private:
      [[noreturn]] inline static void invalid() {
        throw JsonError{};
      }

      inline static void whitespace(std::string_view& input) noexcept {
        const auto end = input.find_first_not_of(" \r\n\t");

        input.remove_prefix(end == std::string_view::npos ? input.size() : end);
      }

      inline static void take(std::string_view& input, char byte) {
        if (!input.starts_with(byte)) {
          invalid();
        }

        input.remove_prefix(1);
      }

      inline static std::uint32_t hex(std::string_view input, std::size_t offset) {
        if (offset > input.size() || input.size() - offset < 4) {
          invalid();
        }

        std::uint32_t value = 0;
        const auto result = std::from_chars(input.data() + offset, input.data() + offset + 4, value, 16);
        if (result.ec != std::errc{} || result.ptr != input.data() + offset + 4) {
          invalid();
        }

        return value;
      }

      inline static std::string_view stringToken(std::string_view& input) {
        take(input, '"');
        const auto original = input;
        std::size_t index = 0;

        while (index < original.size()) {
          const auto byte = static_cast<unsigned char>(original[index]);
          if (byte == '"') {
            input.remove_prefix(index + 1);
            return original.substr(0, index);
          }

          if (byte < 0x20) {
            invalid();
          }

          if (byte == '\\') {
            if (++index == original.size()) {
              invalid();
            }

            if (original[index] == 'u') {
              hex(original, index + 1);
              index += 4;
            } else if (std::string_view{"\"\\/bfnrt"}.find(original[index]) == std::string_view::npos) {
              invalid();
            }
          }

          ++index;
        }

        invalid();
      }

      inline static void skip(std::string_view& input, unsigned depth, unsigned maximum_depth) {
        if (depth > maximum_depth || input.empty()) {
          invalid();
        }

        if (input.front() == '"') {
          stringToken(input);
          return;
        }

        if (input.front() == '{' || input.front() == '[') {
          const bool object = input.front() == '{';
          const char close = object ? '}' : ']';

          input.remove_prefix(1);
          whitespace(input);
          if (input.starts_with(close)) {
            input.remove_prefix(1);
            return;
          }

          for (;;) {
            if (object) {
              stringToken(input);
              whitespace(input);
              take(input, ':');
              whitespace(input);
            }

            skip(input, depth + 1, maximum_depth);
            whitespace(input);
            if (input.starts_with(close)) {
              input.remove_prefix(1);
              return;
            }

            take(input, ',');
            whitespace(input);
          }
        }

        const auto end = input.find_first_of(",]} \r\n\t");
        const auto atom = input.substr(0, end);
        if (atom != "true" && atom != "false" && atom != "null") {
          auto number = atom;
          if (number.starts_with('-')) {
            number.remove_prefix(1);
          }

          if (number.empty()) {
            invalid();
          }

          if (number.front() == '0') {
            number.remove_prefix(1);
          } else {
            if (number.front() < '1' || number.front() > '9') {
              invalid();
            }

            digits(number);
          }

          if (number.starts_with('.')) {
            number.remove_prefix(1);
            if (digits(number) == 0) {
              invalid();
            }
          }

          if (number.starts_with('e') || number.starts_with('E')) {
            number.remove_prefix(1);
            if (number.starts_with('+') || number.starts_with('-')) {
              number.remove_prefix(1);
            }

            if (digits(number) == 0) {
              invalid();
            }
          }

          if (!number.empty()) {
            invalid();
          }
        }

        input.remove_prefix(atom.size());
      }

      inline static std::size_t digits(std::string_view& input) noexcept {
        const auto length = input.find_first_not_of("0123456789");
        const auto consumed = length == std::string_view::npos ? input.size() : length;

        input.remove_prefix(consumed);
        return consumed;
      }

      template <Allocator Memory>
      inline static void appendUtf8(String<Memory>& output, std::uint32_t value) {
        if (value < 0x80) {
          output.push_back(static_cast<char>(value));
        } else if (value < 0x800) {
          output.push_back(static_cast<char>(0xc0 | (value >> 6)));
          output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
        } else if (value < 0x10000) {
          output.push_back(static_cast<char>(0xe0 | (value >> 12)));
          output.push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
          output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
        } else {
          output.push_back(static_cast<char>(0xf0 | (value >> 18)));
          output.push_back(static_cast<char>(0x80 | ((value >> 12) & 0x3f)));
          output.push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
          output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
        }
      }

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
    void escapeJson(std::string_view text, JsonEscapes escapes, Emit&& emit) {
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
    void appendJsonText(Text& output, std::string_view text, JsonEscapes escapes = JsonEscapes::standard) {
      output.push_back('"');
      escapeJson(text, escapes, [&](std::string_view piece) {
        output.append(piece);
      });

      output.push_back('"');
    }

  }
}

// Interface: telar_base/text/json_fields.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory, std::size_t Count>
    class JsonFields {
    public:
      // The fields view the object's text and the names, and allocate scratch text, all in region `a`.
      inline explicit JsonFields(tbc::view<Memory&, tbc::lt::a> memory, tbc::view<const JsonValue&, tbc::lt::a> object, tbc::view<const std::array<std::string_view, Count>&, tbc::lt::a> names)
          : names_(names),
            text_(AllocatorRef<char, Memory>{memory}) {
        object.eachMember([&](const JsonValue& key, const JsonValue& value) {
          key.string(text_);
          const auto index = position(text_);
          if (values_[index]) {
            throw std::invalid_argument{"Duplicate JSON field"};
          }

          values_[index] = value;
        });
      }

      inline const std::optional<JsonValue>& optional(std::string_view name) const {
        return values_[position(name)];
      }

      inline const JsonValue& required(std::string_view name) const {
        const auto& value = optional(name);
        if (!value) {
          throw std::invalid_argument{"Missing JSON field"};
        }

        return *value;
      }

      inline std::string_view string(std::string_view name) {
        required(name).string(text_);
        return text_;
      }

    private:
      inline std::size_t position(std::string_view name) const {
        const auto found = std::ranges::find(names_, name);
        if (found == names_.end()) {
          throw std::invalid_argument{"Unknown JSON field"};
        }

        return static_cast<std::size_t>(found - names_.begin());
      }

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
      inline explicit JsonNode(tbc::view<Memory&, tbc::lt::a> memory, JsonKind kind = JsonKind::object)
          : name_(AllocatorRef<char, Memory>{memory}),
            text_(AllocatorRef<char, Memory>{memory}),
            children_(AllocatorRef<JsonNode, Memory>{memory}),
            kind_(kind) {}

      inline static tbc::view<JsonNode, tbc::lt::a> parse(tbc::view<Memory&, tbc::lt::a> memory, std::string_view source) {
        if (inspectUtf8(source) != Utf8Validation::valid) {
          throw JsonError{};
        }

        return fromValue(memory, JsonValue::parse(source, maximum_depth));
      }

      inline JsonKind kind() const noexcept {
        return kind_;
      }

      inline std::string_view text() const noexcept {
        return text_;
      }

      inline std::span<JsonNode> children() noexcept {
        return children_;
      }

      inline std::span<const JsonNode> children() const noexcept {
        return children_;
      }

      inline JsonNode* find(std::string_view name) noexcept {
        if (kind_ != JsonKind::object) {
          return nullptr;
        }

        const auto found = std::ranges::find_if(children_, [name](const auto& child) {
          return child.name_ == name;
        });

        return found == children_.end() ? nullptr : &*found;
      }

      inline const JsonNode* find(std::string_view name) const noexcept {
        return const_cast<JsonNode*>(this)->find(name);
      }

      inline JsonNode& ensure(std::string_view name, JsonKind kind) {
        if (kind_ != JsonKind::object) {
          throw std::invalid_argument{"Expected JSON object"};
        }

        if (auto* existing = find(name)) {
          if (existing->kind_ != kind) {
            throw std::invalid_argument{"Unexpected JSON field type"};
          }

          return *existing;
        }

        JsonNode child{memory(), kind};

        child.name_ = name;
        children_.push_back(std::move(child));
        return children_.back();
      }

      inline void setString(std::string_view name, std::string_view value) {
        auto& child = ensure(name, JsonKind::string);

        child.text_ = value;
      }

      inline void setLiteral(std::string_view name, std::string_view value) {
        auto& child = ensure(name, JsonKind::literal);

        child.text_ = value;
      }

      inline void append(JsonNode child) {
        if (kind_ != JsonKind::array) {
          throw std::invalid_argument{"Expected JSON array"};
        }

        children_.push_back(std::move(child));
      }

      inline void erase(std::size_t index) {
        children_.erase(children_.begin() + index);
      }

      inline void remove(std::string_view name) {
        std::erase_if(children_, [name](const auto& child) {
          return child.name_ == name;
        });
      }

      inline String<Memory> format() const {
        String<Memory> output{AllocatorRef<char, Memory>{memory()}};

        appendFormatted(output, 0);
        output += '\n';
        return output;
      }

    private:
      static constexpr unsigned maximum_depth = 256;
      static constexpr unsigned indentation = 2;

      inline tbc::view<Memory&, tbc::lt::a> memory() const noexcept {
        return text_.get_allocator().memory();
      }

      inline static tbc::view<JsonNode, tbc::lt::a> fromValue(tbc::view<Memory&, tbc::lt::a> memory, JsonValue value) {
        const auto encoded = value.encoded();
        const auto kind = encoded.starts_with('{') ? JsonKind::object : encoded.starts_with('[') ? JsonKind::array
                                                                    : encoded.starts_with('"')   ? JsonKind::string
                                                                                                 : JsonKind::literal;
        JsonNode node{memory, kind};

        if (kind == JsonKind::object) {
          value.eachMember([&](JsonValue key, JsonValue item) {
            auto child = fromValue(memory, item);

            key.string(child.name_);
            node.children_.push_back(std::move(child));
          });

          Vector<std::string_view, Memory> names{AllocatorRef<std::string_view, Memory>{memory}};

          names.reserve(node.children_.size());
          for (const auto& child : node.children_) {
            names.push_back(child.name_);
          }

          std::ranges::sort(names);
          if (std::adjacent_find(names.begin(), names.end()) != names.end()) {
            throw std::invalid_argument{"Duplicate JSON field"};
          }
        } else if (kind == JsonKind::array) {
          value.eachElement([&](JsonValue item) {
            node.children_.push_back(fromValue(memory, item));
          });
        } else if (kind == JsonKind::string) {
          value.string(node.text_);
        } else {
          node.text_ = encoded;
        }

        return node;
      }

      inline void appendFormatted(String<Memory>& output, unsigned depth) const {
        if (kind_ == JsonKind::string) {
          appendJsonText(output, text_);
          return;
        }

        if (kind_ == JsonKind::literal) {
          output += text_;
          return;
        }

        output += kind_ == JsonKind::object ? '{' : '[';
        for (std::size_t index = 0; index < children_.size(); ++index) {
          output += index == 0 ? "\n" : ",\n";
          output.append((depth + 1) * indentation, ' ');
          const auto& child = children_[index];

          if (kind_ == JsonKind::object) {
            appendJsonText(output, child.name_);
            output += ": ";
          }

          child.appendFormatted(output, depth + 1);
        }

        if (!children_.empty()) {
          output += '\n';
          output.append(depth * indentation, ' ');
        }

        output += kind_ == JsonKind::object ? '}' : ']';
      }

      tbc::view<String<Memory>, tbc::lt::a> name_;
      tbc::view<String<Memory>, tbc::lt::a> text_;
      tbc::view<Vector<JsonNode, Memory>, tbc::lt::a> children_;
      JsonKind kind_;
    };

  }
}
