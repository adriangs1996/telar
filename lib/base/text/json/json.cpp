module telar.base.text.json;

import std;
import telar.tbc;

namespace telar {

  const char* JsonError::what() const noexcept {
    return "Invalid JSON record";
  }

}

namespace telar::runtime {

  namespace {

    [[noreturn]] void invalid() {
      throw JsonError{};
    }

    void whitespace(std::string_view& input) noexcept {
      const auto end = input.find_first_not_of(" \r\n\t");

      input.remove_prefix(end == std::string_view::npos ? input.size() : end);
    }

    void take(std::string_view& input, char byte) {
      if (!input.starts_with(byte)) {
        invalid();
      }

      input.remove_prefix(1);
    }

    std::uint32_t hex(std::string_view input, std::size_t offset) {
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

    std::string_view stringToken(std::string_view& input) {
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

    std::size_t digits(std::string_view& input) noexcept {
      const auto length = input.find_first_not_of("0123456789");
      const auto consumed = length == std::string_view::npos ? input.size() : length;

      input.remove_prefix(consumed);
      return consumed;
    }

    void skip(std::string_view& input, unsigned depth, unsigned maximum_depth) {
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

    // Writes `value` as UTF-8 at `output` and returns the bytes it wrote.
    std::size_t encodeUtf8(std::uint32_t value, char* output) noexcept {
      if (value < 0x80) {
        output[0] = static_cast<char>(value);
        return 1;
      }

      if (value < 0x800) {
        output[0] = static_cast<char>(0xc0 | (value >> 6));
        output[1] = static_cast<char>(0x80 | (value & 0x3f));
        return 2;
      }

      if (value < 0x10000) {
        output[0] = static_cast<char>(0xe0 | (value >> 12));
        output[1] = static_cast<char>(0x80 | ((value >> 6) & 0x3f));
        output[2] = static_cast<char>(0x80 | (value & 0x3f));
        return 3;
      }

      output[0] = static_cast<char>(0xf0 | (value >> 18));
      output[1] = static_cast<char>(0x80 | ((value >> 12) & 0x3f));
      output[2] = static_cast<char>(0x80 | ((value >> 6) & 0x3f));
      output[3] = static_cast<char>(0x80 | (value & 0x3f));
      return 4;
    }

  }

  JsonValue::JsonValue(tbc::view<std::string_view, tbc::lt::b> bytes, unsigned maximum_depth)
      : bytes_(bytes),
        maximum_depth_(maximum_depth) {}

  tbc::view<std::string_view, tbc::lt::b> JsonValue::encoded() const noexcept {
    return bytes_;
  }

  tbc::view<std::optional<JsonValue>, tbc::lt::b> JsonValue::field(std::string_view name) const {
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

  bool JsonValue::equals(std::string_view expected) const {
    auto input = bytes_;

    return input.starts_with('"') && stringToken(input) == expected;
  }

  bool JsonValue::boolean() const noexcept {
    return bytes_ == "true";
  }

  tbc::view<JsonValue, tbc::lt::b> JsonValue::parse(tbc::view<std::string_view, tbc::lt::b> input, unsigned maximum_depth) {
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

  bool JsonValue::enter(std::string_view& input, char open, char close) {
    take(input, open);
    whitespace(input);
    return !input.starts_with(close);
  }

  bool JsonValue::advance(std::string_view& input, char close) {
    whitespace(input);
    if (input.starts_with(close)) {
      return false;
    }

    take(input, ',');
    whitespace(input);
    return true;
  }

  std::size_t JsonValue::skipKey(std::string_view& input) {
    const auto size = input.size();

    stringToken(input);
    const auto key = size - input.size();

    whitespace(input);
    take(input, ':');
    whitespace(input);
    return key;
  }

  void JsonValue::skipValue(std::string_view& input, unsigned maximum_depth) {
    skip(input, 0, maximum_depth);
  }

  tbc::view<std::string_view, tbc::lt::b> JsonValue::stringContents() const {
    auto input = bytes_;

    return stringToken(input);
  }

  template <Allocator Memory>
  void JsonValue::string(String<Memory>& output) const {
    const auto encoded = stringContents();

    output.clear();
    output.resize(encoded.size());
    output.resize(unescape(encoded, output.data()));
  }

  template void JsonValue::string<Memory>(String<Memory>& output) const;
  template void JsonValue::string<ConcurrentMemory>(String<ConcurrentMemory>& output) const;
  template void JsonValue::string<SystemAllocator>(String<SystemAllocator>& output) const;
  template void JsonValue::string<BudgetAllocator<SystemAllocator>>(String<BudgetAllocator<SystemAllocator>>& output) const;
  template void JsonValue::string<ErasingMemory>(String<ErasingMemory>& output) const;
  template void JsonValue::string<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>(String<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>& output) const;

  std::size_t JsonValue::unescape(std::string_view encoded, char* output) {
    std::size_t written = 0;

    for (std::size_t index = 0; index < encoded.size(); ++index) {
      const char byte = encoded[index];
      if (byte != '\\') {
        output[written++] = byte;
        continue;
      }

      if (++index == encoded.size()) {
        invalid();
      }

      switch (encoded[index]) {
      case '"':
      case '\\':
      case '/':
        output[written++] = encoded[index];
        break;
      case 'b':
        output[written++] = '\b';
        break;
      case 'f':
        output[written++] = '\f';
        break;
      case 'n':
        output[written++] = '\n';
        break;
      case 'r':
        output[written++] = '\r';
        break;
      case 't':
        output[written++] = '\t';
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

        written += encodeUtf8(codepoint, output + written);
        break;
      }
      default:
        invalid();
      }
    }

    return written;
  }

  std::size_t jsonFieldPosition(std::span<const std::string_view> names, std::string_view name) {
    const auto found = std::ranges::find(names, name);
    if (found == names.end()) {
      throw std::invalid_argument{"Unknown JSON field"};
    }

    return static_cast<std::size_t>(found - names.begin());
  }

  std::size_t unsetJsonFieldPosition(std::span<const std::string_view> names, std::span<const std::optional<JsonValue>> values, std::string_view name) {
    const auto position = jsonFieldPosition(names, name);
    if (values[position]) {
      throw std::invalid_argument{"Duplicate JSON field"};
    }

    return position;
  }

  const JsonValue& requiredJsonField(const std::optional<JsonValue>& value) {
    if (!value) {
      throw std::invalid_argument{"Missing JSON field"};
    }

    return *value;
  }

  template <Allocator Memory>
  JsonNode<Memory>::JsonNode(tbc::view<Memory&, tbc::lt::a> memory, JsonKind kind)
      : name_(AllocatorRef<char, Memory>{memory}),
        text_(AllocatorRef<char, Memory>{memory}),
        children_(AllocatorRef<JsonNode, Memory>{memory}),
        kind_(kind) {}

  template <Allocator Memory>
  auto JsonNode<Memory>::parse(tbc::view<Memory&, tbc::lt::a> memory, std::string_view source) -> tbc::view<JsonNode, tbc::lt::a> {
    if (inspectUtf8(source) != Utf8Validation::valid) {
      throw JsonError{};
    }

    return fromValue(memory, JsonValue::parse(source, maximum_depth));
  }

  template <Allocator Memory>
  JsonKind JsonNode<Memory>::kind() const noexcept {
    return kind_;
  }

  template <Allocator Memory>
  std::string_view JsonNode<Memory>::text() const noexcept {
    return text_;
  }

  template <Allocator Memory>
  std::span<JsonNode<Memory>> JsonNode<Memory>::children() noexcept {
    return children_;
  }

  template <Allocator Memory>
  std::span<const JsonNode<Memory>> JsonNode<Memory>::children() const noexcept {
    return children_;
  }

  template <Allocator Memory>
  JsonNode<Memory>* JsonNode<Memory>::find(std::string_view name) noexcept {
    if (kind_ != JsonKind::object) {
      return nullptr;
    }

    const auto found = std::ranges::find_if(children_, [name](const auto& child) {
      return child.name_ == name;
    });

    return found == children_.end() ? nullptr : &*found;
  }

  template <Allocator Memory>
  const JsonNode<Memory>* JsonNode<Memory>::find(std::string_view name) const noexcept {
    return const_cast<JsonNode*>(this)->find(name);
  }

  template <Allocator Memory>
  void JsonNode<Memory>::erase(std::size_t index) {
    children_.erase(children_.begin() + index);
  }

  template <Allocator Memory>
  JsonNode<Memory>& JsonNode<Memory>::ensure(std::string_view name, JsonKind kind) {
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

  template <Allocator Memory>
  void JsonNode<Memory>::setString(std::string_view name, std::string_view value) {
    auto& child = ensure(name, JsonKind::string);

    child.text_ = value;
  }

  template <Allocator Memory>
  void JsonNode<Memory>::setLiteral(std::string_view name, std::string_view value) {
    auto& child = ensure(name, JsonKind::literal);

    child.text_ = value;
  }

  template <Allocator Memory>
  void JsonNode<Memory>::append(JsonNode child) {
    if (kind_ != JsonKind::array) {
      throw std::invalid_argument{"Expected JSON array"};
    }

    children_.push_back(std::move(child));
  }

  template <Allocator Memory>
  void JsonNode<Memory>::remove(std::string_view name) {
    std::erase_if(children_, [name](const auto& child) {
      return child.name_ == name;
    });
  }

  template <Allocator Memory>
  String<Memory> JsonNode<Memory>::format() const {
    String<Memory> output{AllocatorRef<char, Memory>{memory()}};

    appendFormatted(output, 0);
    output += '\n';
    return output;
  }

  template <Allocator Memory>
  tbc::view<Memory&, tbc::lt::a> JsonNode<Memory>::memory() const noexcept {
    return text_.get_allocator().memory();
  }

  template <Allocator Memory>
  auto JsonNode<Memory>::fromValue(tbc::view<Memory&, tbc::lt::a> memory, JsonValue value) -> tbc::view<JsonNode, tbc::lt::a> {
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

  template <Allocator Memory>
  void JsonNode<Memory>::appendFormatted(String<Memory>& output, unsigned depth) const {
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

  template class JsonNode<Memory>;
  template class JsonNode<ConcurrentMemory>;
  template class JsonNode<SystemAllocator>;
  template class JsonNode<BudgetAllocator<SystemAllocator>>;

}
