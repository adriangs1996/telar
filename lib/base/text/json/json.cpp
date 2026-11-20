module telar.base.text.json;

import std;
import telar.tbc;
import telar.base.text.utf8;
import telar.base.ds;

namespace telar {

  const char* JsonError::what() const noexcept {
    return "Invalid JSON record";
  }

}

namespace telar::runtime {

  namespace {

    constexpr unsigned char first_printable = 0x20;
    constexpr int hex_base = 16;
    constexpr std::size_t hex_digits = 4;

    // The UTF-16 surrogates a \u escape pairs into one scalar past the basic plane.
    constexpr std::uint32_t high_surrogate_first = 0xd800;
    constexpr std::uint32_t high_surrogate_last = 0xdbff;
    constexpr std::uint32_t low_surrogate_first = 0xdc00;
    constexpr std::uint32_t low_surrogate_last = 0xdfff;
    constexpr std::uint32_t supplementary_first = 0x10000;
    constexpr unsigned surrogate_bits = 10;

    // UTF-8: the scalars below each limit take one byte more than those below the one before.
    constexpr std::uint32_t one_byte_limit = 0x80;
    constexpr std::uint32_t two_byte_limit = 0x800;
    constexpr std::uint32_t three_byte_limit = 0x10000;
    constexpr std::uint32_t two_byte_lead = 0xc0;
    constexpr std::uint32_t three_byte_lead = 0xe0;
    constexpr std::uint32_t four_byte_lead = 0xf0;
    constexpr std::uint32_t continuation_tag = 0x80;
    constexpr std::uint32_t continuation_mask = 0x3f;
    constexpr unsigned continuation_bits = 6;

    // A scalar a \u escape spells, and how many bytes it takes after the 'u'.
    struct EscapedScalar {
      std::uint32_t value;
      std::size_t length;
    };

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
      if (offset > input.size() || input.size() - offset < hex_digits) {
        invalid();
      }

      std::uint32_t value = 0;
      const auto digits = std::span<const char>{input}.subspan(offset, hex_digits);
      const auto* const end = std::to_address(digits.end());
      const auto result = std::from_chars(digits.data(), end, value, hex_base);

      // from_chars reports success as the errc of value 0, which names no error.
      if (std::to_underlying(result.ec) != 0 || result.ptr != end) {
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

        if (byte < first_printable) {
          invalid();
        }

        if (byte == '\\') {
          if (++index == original.size()) {
            invalid();
          }

          if (original[index] == 'u') {
            hex(original, index + 1);
            index += hex_digits;
          } else if (!std::string_view{"\"\\/bfnrt"}.contains(original[index])) {
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

    // Throws unless `number` is a JSON number whole.
    void checkNumber(std::string_view number) {
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

    // Consumes a literal or a number, up to the byte that ends it.
    void skipAtom(std::string_view& input) {
      const auto end = input.find_first_of(",]} \r\n\t");
      const auto atom = input.substr(0, end);
      if (atom != "true" && atom != "false" && atom != "null") {
        checkNumber(atom);
      }

      input.remove_prefix(atom.size());
    }

    void skip(std::string_view& input, unsigned depth, unsigned maximum_depth) { // NOLINT(misc-no-recursion): nested values recurse at most maximum_depth deep
      if (depth > maximum_depth || input.empty()) {
        invalid();
      }

      if (input.front() == '"') {
        stringToken(input);
        return;
      }

      if (input.front() != '{' && input.front() != '[') {
        skipAtom(input);
        return;
      }

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

    // A continuation byte of UTF-8: the six bits of `value` from `shift` up.
    char continuation(std::uint32_t value, unsigned shift) noexcept {
      return static_cast<char>(continuation_tag | ((value >> shift) & continuation_mask));
    }

    // Writes `value` as UTF-8 at the front of `output` and returns the bytes it wrote.
    std::size_t encodeUtf8(std::uint32_t value, std::span<char> output) noexcept {
      if (value < one_byte_limit) {
        output[0] = static_cast<char>(value);
        return 1;
      }

      if (value < two_byte_limit) {
        output[0] = static_cast<char>(two_byte_lead | (value >> continuation_bits));
        output[1] = continuation(value, 0);
        return 2;
      }

      if (value < three_byte_limit) {
        output[0] = static_cast<char>(three_byte_lead | (value >> (2 * continuation_bits)));
        output[1] = continuation(value, continuation_bits);
        output[2] = continuation(value, 0);
        return 3;
      }

      output[0] = static_cast<char>(four_byte_lead | (value >> (3 * continuation_bits)));
      output[1] = continuation(value, 2 * continuation_bits);
      output[2] = continuation(value, continuation_bits);
      output[3] = continuation(value, 0);
      return 4;
    }

    // The byte a short escape spells after its backslash; none for a letter that spells none.
    ds::Option<char> shortEscape(char letter) noexcept {
      switch (letter) {
      case '"':
      case '\\':
      case '/':
        return letter;
      case 'b':
        return '\b';
      case 'f':
        return '\f';
      case 'n':
        return '\n';
      case 'r':
        return '\r';
      case 't':
        return '\t';
      default:
        return ds::none;
      }
    }

    // The scalar the \u escape at `offset` of `encoded`, just past its 'u', spells: a high surrogate
    // takes the low one's escape after it.
    EscapedScalar unicodeEscape(std::string_view encoded, std::size_t offset) {
      const auto unit = hex(encoded, offset);
      if (unit >= low_surrogate_first && unit <= low_surrogate_last) {
        invalid();
      }

      if (unit < high_surrogate_first || unit > high_surrogate_last) {
        return {.value = unit, .length = hex_digits};
      }

      if (encoded.substr(offset + hex_digits, 2) != "\\u") {
        invalid();
      }

      const auto low = hex(encoded, offset + hex_digits + 2);
      if (low < low_surrogate_first || low > low_surrogate_last) {
        invalid();
      }

      return {
          .value = supplementary_first + ((unit - high_surrogate_first) << surrogate_bits) + low - low_surrogate_first,
          .length = (2 * hex_digits) + 2,
      };
    }

    // The kind of the value `encoded` spells, by its first byte.
    JsonKind kindOf(std::string_view encoded) noexcept {
      if (encoded.starts_with('{')) {
        return JsonKind::object;
      }

      if (encoded.starts_with('[')) {
        return JsonKind::array;
      }

      return encoded.starts_with('"') ? JsonKind::string : JsonKind::literal;
    }

  }

  JsonValue::JsonValue(tbc::val_b<std::string_view> bytes, unsigned maximum_depth)
      : bytes_(bytes),
        maximum_depth_(maximum_depth) {}

  tbc::val_b<std::string_view> JsonValue::encoded() const noexcept {
    return bytes_;
  }

  tbc::val_b<ds::Option<JsonValue>> JsonValue::field(std::string_view name) const {
    auto input = bytes_;

    whitespace(input);
    take(input, '{');
    while (true) {
      whitespace(input);
      if (input.starts_with('}')) {
        return ds::none;
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
        return ds::none;
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

  tbc::val_b<JsonValue> JsonValue::parse(tbc::val_b<std::string_view> input, unsigned maximum_depth) {
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

  bool JsonValue::enter(std::string_view& input, Brackets brackets) {
    take(input, brackets.open);
    whitespace(input);
    return !input.starts_with(brackets.close);
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

  tbc::val_b<std::string_view> JsonValue::stringContents() const {
    auto input = bytes_;

    return stringToken(input);
  }

  template <Allocator Memory>
  void JsonValue::string(ds::String<Memory>& output) const {
    const auto encoded = stringContents();

    output.clear();
    output.resize(encoded.size());
    output.resize(unescape(encoded, output.viewMut()));
  }

  template void JsonValue::string<Memory>(ds::String<Memory>& output) const;
  template void JsonValue::string<ConcurrentMemory>(ds::String<ConcurrentMemory>& output) const;
  template void JsonValue::string<SystemAllocator>(ds::String<SystemAllocator>& output) const;
  template void JsonValue::string<BudgetAllocator<SystemAllocator>>(ds::String<BudgetAllocator<SystemAllocator>>& output) const;
  template void JsonValue::string<ErasingMemory>(ds::String<ErasingMemory>& output) const;
  template void JsonValue::string<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>(ds::String<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>& output) const;

  std::size_t JsonValue::unescape(std::string_view encoded, std::span<char> output) {
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

      if (encoded[index] == 'u') {
        const auto scalar = unicodeEscape(encoded, index + 1);

        index += scalar.length;
        written += encodeUtf8(scalar.value, output.subspan(written));
        continue;
      }

      const auto escaped = shortEscape(encoded[index]);
      if (!escaped) {
        invalid();
      }

      output[written++] = *escaped;
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

  std::size_t unsetJsonFieldPosition(std::span<const std::string_view> names, std::span<const ds::Option<JsonValue>> values, std::string_view name) {
    const auto position = jsonFieldPosition(names, name);
    if (values[position]) {
      throw std::invalid_argument{"Duplicate JSON field"};
    }

    return position;
  }

  const JsonValue& requiredJsonField(const ds::Option<JsonValue>& value) {
    if (!value) {
      throw std::invalid_argument{"Missing JSON field"};
    }

    return *value;
  }

  template <Allocator Memory>
  JsonNode<Memory>::JsonNode(tbc::mut_a<Memory> memory, JsonKind kind)
      : name_(memory),
        text_(memory),
        children_(memory),
        kind_(kind) {}

  template <Allocator Memory>
  auto JsonNode<Memory>::parse(tbc::mut_a<Memory> memory, std::string_view source) -> tbc::val_a<JsonNode> {
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
  std::span<JsonNode<Memory>> JsonNode<Memory>::childrenMut() noexcept {
    return children_.viewMut();
  }

  template <Allocator Memory>
  std::span<const JsonNode<Memory>> JsonNode<Memory>::children() const noexcept {
    return children_;
  }

  template <Allocator Memory>
  JsonNode<Memory>* JsonNode<Memory>::findMut(std::string_view name) noexcept {
    if (kind_ != JsonKind::object) {
      return nullptr;
    }

    const auto children = children_.viewMut();
    const auto found = std::ranges::find_if(children, [name](const auto& child) {
      return child.name_ == name;
    });

    return found == children.end() ? nullptr : &*found;
  }

  template <Allocator Memory>
  const JsonNode<Memory>* JsonNode<Memory>::find(std::string_view name) const noexcept {
    if (kind_ != JsonKind::object) {
      return nullptr;
    }

    for (const auto& child : children_) {
      if (child.name_ == name) {
        return &child;
      }
    }

    return nullptr;
  }

  template <Allocator Memory>
  void JsonNode<Memory>::erase(std::size_t index) {
    static_cast<void>(children_.remove(index));
  }

  template <Allocator Memory>
  JsonNode<Memory>& JsonNode<Memory>::ensure(std::string_view name, JsonKind kind) {
    if (kind_ != JsonKind::object) {
      throw std::invalid_argument{"Expected JSON object"};
    }

    if (auto* existing = findMut(name)) {
      if (existing->kind_ != kind) {
        throw std::invalid_argument{"Unexpected JSON field type"};
      }

      return *existing;
    }

    JsonNode child{text_.memory(), kind};

    child.name_.assign(name);
    children_.push(std::move(child));
    return children_.atMut(children_.size() - 1);
  }

  template <Allocator Memory>
  void JsonNode<Memory>::setString(std::string_view name, std::string_view value) {
    auto& child = ensure(name, JsonKind::string);

    child.text_.assign(value);
  }

  template <Allocator Memory>
  void JsonNode<Memory>::setLiteral(std::string_view name, std::string_view value) {
    auto& child = ensure(name, JsonKind::literal);

    child.text_.assign(value);
  }

  template <Allocator Memory>
  void JsonNode<Memory>::append(JsonNode child) {
    if (kind_ != JsonKind::array) {
      throw std::invalid_argument{"Expected JSON array"};
    }

    children_.push(std::move(child));
  }

  template <Allocator Memory>
  void JsonNode<Memory>::remove(std::string_view name) {
    static_cast<void>(children_.retain([name](const auto& child) {
      return child.name_ != name;
    }));
  }

  template <Allocator Memory>
  ds::String<Memory> JsonNode<Memory>::format() const {
    ds::String<Memory> output{text_.memory()};

    appendFormatted(output, 0);
    output.push('\n');
    return output;
  }

  // A node's children are nodes, which these build and format as deep as maximum_depth lets a value
  // nest.
  // NOLINTBEGIN(misc-no-recursion): a node's children recurse at most maximum_depth deep
  template <Allocator Memory>
  auto JsonNode<Memory>::fromValue(tbc::mut_a<Memory> memory, JsonValue value) -> tbc::val_a<JsonNode> {
    const auto encoded = value.encoded();
    const auto kind = kindOf(encoded);
    JsonNode node{memory, kind};

    if (kind == JsonKind::object) {
      value.eachMember([&](JsonValue key, JsonValue item) {
        auto child = fromValue(memory, item);

        key.string(child.name_);
        node.children_.push(std::move(child));
      });

      ds::Vec<std::string_view, Memory> names{memory};

      names.reserve(node.children_.size());
      for (const auto& child : node.children_) {
        names.push(child.name_);
      }

      std::ranges::sort(names.viewMut());
      if (std::adjacent_find(names.begin(), names.end()) != names.end()) {
        throw std::invalid_argument{"Duplicate JSON field"};
      }
    } else if (kind == JsonKind::array) {
      value.eachElement([&](JsonValue item) {
        node.children_.push(fromValue(memory, item));
      });
    } else if (kind == JsonKind::string) {
      value.string(node.text_);
    } else {
      node.text_.assign(encoded);
    }

    return node;
  }

  template <Allocator Memory>
  void JsonNode<Memory>::appendFormatted(ds::String<Memory>& output, unsigned depth) const {
    if (kind_ == JsonKind::string) {
      appendJsonText(output, text_);
      return;
    }

    if (kind_ == JsonKind::literal) {
      output.append(text_);
      return;
    }

    output.push(kind_ == JsonKind::object ? '{' : '[');
    for (std::size_t index = 0; index < children_.size(); ++index) {
      output.append(index == 0 ? "\n" : ",\n");
      output.resize(output.size() + ((depth + 1) * indentation), ' ');
      const auto& child = children_[index];

      if (kind_ == JsonKind::object) {
        appendJsonText(output, child.name_);
        output.append(": ");
      }

      child.appendFormatted(output, depth + 1);
    }

    if (!children_.empty()) {
      output.push('\n');
      output.resize(output.size() + (depth * indentation), ' ');
    }

    output.push(kind_ == JsonKind::object ? '}' : ']');
  }

  // NOLINTEND(misc-no-recursion)

  template class JsonNode<Memory>;
  template class JsonNode<ConcurrentMemory>;
  template class JsonNode<SystemAllocator>;
  template class JsonNode<BudgetAllocator<SystemAllocator>>;

}
