module;
#include <exception>
#include <memory>
#include <type_traits>
#include <cstdio>
#include <string>
#include <variant>
#include <vector>

#include <cstdint>
#include <algorithm>
#include <array>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <tuple>

#include <bit>
#include <optional>
#include <string_view>

#include <charconv>
#include <limits>
#include <system_error>
#include <utility>

#include <concepts>
#include <cstring>

export module telar.gui.input.key_encoder;

export import telar.config;


export import telar.gui.core.unicode_scalar;


export import telar.gui.text.json_unsigned_integer;
import telar.base.diagnostics;
import telar.client.protocol;

// Interface: input/binding.cppm
export {
namespace telar::gui {

using runtime::config::KeyChord;

struct BindingLimits {
  static constexpr std::size_t bindings = 256;
  static constexpr std::size_t keys = 5;
  static constexpr std::size_t physical_keys = 64;
  static constexpr std::uint64_t sequence_timeout_ns = std::uint64_t{1000} * 1000 * 1000;
};

inline int compareChords(KeyChord left, KeyChord right) noexcept {
  const auto left_value = std::tie(left.key, left.character, left.modifiers);
  const auto right_value = std::tie(right.key, right.character, right.modifiers);

  if (left_value < right_value) {
    return -1;
  }

  return static_cast<int>(left_value > right_value);
}

template <typename Action>
struct KeyBinding {
  std::array<KeyChord, BindingLimits::keys> keys{};
  std::size_t length = 0;
  Action action{};
  bool prefixed = false;

  [[nodiscard]] inline std::span<const KeyChord> sequence() const noexcept {
    return std::span{keys}.first(length);
  }

  [[nodiscard]] inline bool conflictsWith(const KeyBinding &other) const noexcept {
    const auto shared = std::min(length, other.length);

    return std::equal(keys.begin(), keys.begin() + shared, other.keys.begin());
  }
};

template <typename Action>
class BindingMap {
public:
  struct Range {
    std::size_t begin = 0;
    std::size_t end = 0;
  };

  inline explicit BindingMap(std::span<const KeyBinding<Action>> bindings = {}) {
    if (bindings.size() > BindingLimits::bindings) {
      throw std::invalid_argument{"Too many key bindings"};
    }

    for (const auto &binding : bindings) {
      if (binding.length == 0 || binding.length > BindingLimits::keys) {
        throw std::invalid_argument{"A binding must contain one to five keys"};
      }

      bindings_[length_] = binding;
      order_[length_] = static_cast<std::uint16_t>(length_);
      ++length_;
    }

    const auto ordered = std::span{order_}.first(length_);
    std::ranges::sort(ordered, [this](auto left, auto right) {
      return std::lexicographical_compare(bindings_[left].sequence().begin(), bindings_[left].sequence().end(), bindings_[right].sequence().begin(), bindings_[right].sequence().end(), [](KeyChord first, KeyChord second) {
        return compareChords(first, second) < 0;
      });
    });

    for (std::size_t index = 1; index < length_; ++index) {
      if (at(index - 1).conflictsWith(at(index))) {
        throw std::invalid_argument{"Duplicate or ambiguous binding sequence"};
      }
    }
  }

  [[nodiscard]] inline std::size_t size() const noexcept {
    return length_;
  }

  [[nodiscard]] inline std::span<const KeyBinding<Action>> configured() const noexcept {
    return std::span{bindings_}.first(length_);
  }

  [[nodiscard]] inline const KeyBinding<Action> &at(std::size_t index) const noexcept {
    return bindings_[order_[index]];
  }

  [[nodiscard]] inline Range match(Range candidates, std::size_t depth, KeyChord key) const noexcept {
    const auto first = boundary(candidates, depth, key, false);
    const auto last = boundary({first, candidates.end}, depth, key, true);

    return {first, last};
  }

private:
  [[nodiscard]] inline std::size_t boundary(Range range, std::size_t depth, KeyChord key, bool inclusive) const noexcept {
    while (range.begin < range.end) {
      const auto middle = range.begin + ((range.end - range.begin) / 2);
      const auto compared = compareChords(at(middle).keys[depth], key);
      if (compared < 0 || (inclusive && compared == 0)) {
        range.begin = middle + 1;
      } else {
        range.end = middle;
      }
    }

    return range.begin;
  }

  std::array<KeyBinding<Action>, BindingLimits::bindings> bindings_{};
  std::array<std::uint16_t, BindingLimits::bindings> order_{};
  std::size_t length_ = 0;
};

}
}

// Interface: input/key_character.cppm
export {
namespace telar::gui {

struct KeyCharacter {
  [[nodiscard]] inline static std::uint32_t pack(std::uint32_t codepoint) {
    return std::bit_cast<std::uint32_t>(Utf8Scalar::encode(codepoint).bytes);
  }

  [[nodiscard]] inline static Utf8Scalar text(std::uint32_t storage) noexcept {
    Utf8Scalar result;
    result.bytes = std::bit_cast<std::array<char, sizeof(storage)>>(storage);
    const auto *const terminator = std::ranges::find(result.bytes, '\0');
    result.length = std::max<std::size_t>(1, static_cast<std::size_t>(terminator - result.bytes.begin()));

    return result;
  }

  [[nodiscard]] inline static std::uint32_t codepoint(std::uint32_t storage) {
    return Utf8Scalar::decode(text(storage).view());
  }
};

}
}

// Interface: input/key_event.cppm
export {
namespace telar::gui {

enum class KeyPhase : std::uint8_t {
  press,
  repeat,
  release,
};

struct BindingEvent {
  KeyChord chord;
  KeyPhase phase = KeyPhase::press;
  std::uint64_t physical = 0;
};

struct BindingRepeat {
  std::uint64_t interval_ns = 0;
  std::uint64_t owner = 0;

  bool operator==(const BindingRepeat &) const = default;
};

}
}

// Interface: input/terminal_key.cppm
export {
namespace telar::gui {

enum class KittyKeyboardFlag : std::uint8_t {
  disambiguate = 1,
  report_events = 2,
  alternate_keys = 4,
  all_keys = 8,
  associated_text = 16,
};

struct KittyCodepoints {
  std::uint32_t primary = 0;
  std::optional<std::uint32_t> shifted = std::nullopt;
  std::optional<std::uint32_t> base = std::nullopt;
};

struct TerminalKey {
  KeyChord::Key code = KeyChord::Key::character;
  std::uint32_t codepoint = 0;
  unsigned modifiers = 0;
  KeyPhase phase = KeyPhase::press;
  std::optional<KittyCodepoints> kitty = std::nullopt;

  [[nodiscard]] inline bool has(KeyChord::Modifier modifier) const noexcept {
    return (modifiers & static_cast<unsigned>(modifier)) != 0;
  }
};

}
}

// Interface: input/key_encoder.cppm
export {
namespace telar::gui {

class KeyEncoder {
public:
  static constexpr std::size_t maximum_codepoint_fields = 3;
  static constexpr std::size_t codepoint_digits = std::numeric_limits<std::uint32_t>::digits10 + 1;
  static constexpr std::size_t modifier_digits = std::numeric_limits<std::uint8_t>::digits10 + 1;
  static constexpr std::size_t event_digits = 1;
  static constexpr std::size_t scalar_digits = 7;
  static constexpr std::size_t capacity = std::string_view{"\x1b[::;:;u"}.size() + (maximum_codepoint_fields * codepoint_digits) + modifier_digits + event_digits + scalar_digits;

  [[nodiscard]] inline std::string_view encode(const TerminalKey &key, const InputModes &modes) {
    used_ = 0;

    if (key.has(KeyChord::Modifier::super)) {
      return view();
    }

    const Encoding encoding{key, modes};
    if (key.phase == KeyPhase::release && !encoding.event) {
      return view();
    }

    if (encodeText(key, encoding)) {
      return view();
    }

    if (encoding.usesKitty(key)) {
      encodeKitty(key, encoding);
    } else if (key.phase != KeyPhase::release || reportsLegacyRelease(key.code)) {
      encodeLegacy(key, encoding, modes);
    }

    return view();
  }

private:
  using Code = KeyChord::Key;
  using Modifier = KeyChord::Modifier;

  enum class SequenceCode : std::uint8_t {
    cursor = 1,
    erase = 3,
    page_up = 5,
    page_down = 6,
  };

  static constexpr char escape = '\x1b';
  static constexpr char erase = '\x7f';

  inline static bool reportsLegacyRelease(Code code) noexcept {
    switch (code) {
    case Code::enter:
    case Code::backspace:
    case Code::tab:
    case Code::back_tab:
      return false;
    default:
      return true;
    }
  }

  struct Encoding {
    inline explicit Encoding(const TerminalKey &key, const InputModes &modes)
        : modifier(1 + (key.has(Modifier::shift) ? 1 : 0) + (key.has(Modifier::alt) ? 2 : 0) + (key.has(Modifier::control) ? 4 : 0)),
          flags(modes.kitty_keyboard_flags),
          cursor_keys(modes.cursor_keys) {
      if (has(KittyKeyboardFlag::report_events) && key.phase != KeyPhase::press) {
        event = static_cast<unsigned>(key.phase) + 1;
      }
    }

    [[nodiscard]] inline bool has(KittyKeyboardFlag flag) const noexcept {
      return (flags & static_cast<unsigned>(flag)) != 0;
    }

    [[nodiscard]] inline bool usesKitty(const TerminalKey &key) const noexcept {
      if (flags == 0) {
        return false;
      }

      if (key.code == Code::character || key.code == Code::escape) {
        return true;
      }

      return (key.code == Code::enter || key.code == Code::backspace || key.code == Code::tab) && (modifier != 1 || has(KittyKeyboardFlag::all_keys) || (has(KittyKeyboardFlag::report_events) && key.kitty.has_value()));
    }

    unsigned modifier;
    unsigned flags;
    bool cursor_keys;
    std::optional<unsigned> event;
  };

  [[nodiscard]] inline std::string_view view() const noexcept {
    return {bytes_.data(), used_};
  }

  inline void append(std::string_view text) {
    if (text.size() > bytes_.size() - used_) {
      throw std::length_error{"Encoded key exceeds its byte capacity"};
    }

    for (const auto byte : text) {
      bytes_[used_++] = byte;
    }
  }

  inline void byte(char value) {
    append({&value, 1});
  }

  inline void number(std::uint32_t value) {
    const auto encoded = std::to_chars(bytes_.data() + used_, bytes_.data() + bytes_.size(), value);
    if (encoded.ec != std::errc{}) {
      throw std::length_error{"Encoded key number exceeds its byte capacity"};
    }

    used_ = static_cast<std::size_t>(encoded.ptr - bytes_.data());
  }

  inline static std::uint32_t textCodepoint(const TerminalKey &key) {
    const auto codepoint = key.has(Modifier::shift) && key.kitty && key.kitty->shifted ? *key.kitty->shifted : key.codepoint;
    if (!Utf8Scalar::valid(codepoint)) {
      throw std::invalid_argument{"Key contains an invalid Unicode scalar"};
    }

    return codepoint;
  }

  inline bool encodeText(const TerminalKey &key, const Encoding &encoding) {
    if (key.code != Code::character || encoding.has(KittyKeyboardFlag::all_keys) || (encoding.has(KittyKeyboardFlag::report_events) && key.kitty) || key.has(Modifier::control) || key.has(Modifier::alt)) {
      return false;
    }

    if (key.phase != KeyPhase::release) {
      append(Utf8Scalar::encode(textCodepoint(key)).view());
    }

    return true;
  }

  inline static std::optional<std::uint32_t> associatedText(const TerminalKey &key, const Encoding &encoding) {
    if (!encoding.has(KittyKeyboardFlag::associated_text) || key.phase == KeyPhase::release || key.code != Code::character || key.has(Modifier::control) || key.has(Modifier::alt)) {
      return {};
    }

    constexpr std::uint32_t first_private_key = 57344;
    constexpr std::uint32_t last_private_key = 63743;
    if (key.kitty && key.kitty->primary >= first_private_key && key.kitty->primary <= last_private_key) {
      return {};
    }

    const auto codepoint = textCodepoint(key);
    constexpr std::uint32_t first_printable = 32;
    constexpr std::uint32_t first_c1_control = 127;
    constexpr std::uint32_t last_c1_control = 159;

    return codepoint < first_printable || (codepoint >= first_c1_control && codepoint <= last_c1_control) ? std::nullopt : std::optional{codepoint};
  }

  inline void kittyCodepoints(const TerminalKey &key, const Encoding &encoding) {
    if (key.kitty) {
      number(key.kitty->primary);
      if (encoding.has(KittyKeyboardFlag::alternate_keys) && (key.kitty->shifted || key.kitty->base)) {
        byte(':');
        if (key.kitty->shifted) {
          number(*key.kitty->shifted);
        }

        if (key.kitty->base) {
          byte(':');
          number(*key.kitty->base);
        }
      }

      return;
    }

    switch (key.code) {
    case Code::character:
      if (!Utf8Scalar::valid(key.codepoint)) {
        throw std::invalid_argument{"Key contains an invalid Unicode scalar"};
      }

      number(key.codepoint);
      break;
    case Code::enter:
      number('\r');
      break;
    case Code::escape:
      number(escape);
      break;
    case Code::backspace:
      number(erase);
      break;
    case Code::tab:
      number('\t');
      break;
    default:
      throw std::invalid_argument{"Key has no Kitty codepoint"};
    }
  }

  inline void encodeKitty(const TerminalKey &key, const Encoding &encoding) {
    const auto associated = associatedText(key, encoding);
    append("\x1b[");
    kittyCodepoints(key, encoding);
    if (encoding.modifier != 1 || encoding.event || associated) {
      byte(';');
      number(encoding.modifier);
    }

    if (encoding.event) {
      byte(':');
      number(*encoding.event);
    }

    if (associated) {
      byte(';');
      number(*associated);
    }

    byte('u');
  }

  inline void altText(const TerminalKey &key, std::string_view text) {
    if (key.has(Modifier::alt)) {
      byte(escape);
    }

    append(text);
  }

  inline static std::optional<char> controlByte(std::uint32_t codepoint) noexcept {
    constexpr unsigned control_mask = 0x1f;
    if ((codepoint >= 'a' && codepoint <= 'z') || (codepoint >= 'A' && codepoint <= 'Z')) {
      return static_cast<char>(codepoint & control_mask);
    }

    constexpr auto controls = std::to_array<std::pair<std::uint32_t, char>>({
        {' ', '\0'},
        {'@', '\0'},
        {'2', '\0'},
        {'[', '\x1b'},
        {'3', '\x1b'},
        {'\\', '\x1c'},
        {'4', '\x1c'},
        {']', '\x1d'},
        {'5', '\x1d'},
        {'^', '\x1e'},
        {'~', '\x1e'},
        {'6', '\x1e'},
        {'_', '\x1f'},
        {'/', '\x1f'},
        {'7', '\x1f'},
        {'?', erase},
        {'8', erase},
    });
    for (const auto &[known, value] : controls) {
      if (codepoint == known) {
        return value;
      }
    }

    return {};
  }

  inline void legacyCharacter(const TerminalKey &key) {
    if (key.has(Modifier::alt)) {
      byte(escape);
    }

    const auto control = key.has(Modifier::control) ? controlByte(key.codepoint) : std::nullopt;
    if (control) {
      byte(*control);
    } else {
      append(Utf8Scalar::encode(key.codepoint).view());
    }
  }

  inline void sequence(SequenceCode code, char final, const Encoding &encoding) {
    if (code == SequenceCode::cursor && !encoding.event && encoding.modifier == 1) {
      append(encoding.cursor_keys && !encoding.has(KittyKeyboardFlag::report_events) ? "\x1bO" : "\x1b[");
      byte(final);

      return;
    }

    append("\x1b[");
    number(static_cast<unsigned>(code));
    if (encoding.modifier != 1 || encoding.event) {
      byte(';');
      number(encoding.modifier);
    }

    if (encoding.event) {
      byte(':');
      number(*encoding.event);
    }

    byte(final);
  }

  inline void encodeLegacy(const TerminalKey &key, const Encoding &encoding, const InputModes &modes) {
    switch (key.code) {
    case Code::character:
      legacyCharacter(key);
      break;
    case Code::up:
      sequence(SequenceCode::cursor, 'A', encoding);
      break;
    case Code::down:
      sequence(SequenceCode::cursor, 'B', encoding);
      break;
    case Code::right:
      sequence(SequenceCode::cursor, 'C', encoding);
      break;
    case Code::left:
      sequence(SequenceCode::cursor, 'D', encoding);
      break;
    case Code::home:
      sequence(SequenceCode::cursor, 'H', encoding);
      break;
    case Code::end:
      sequence(SequenceCode::cursor, 'F', encoding);
      break;
    case Code::erase:
      sequence(SequenceCode::erase, '~', encoding);
      break;
    case Code::page_up:
      sequence(SequenceCode::page_up, '~', encoding);
      break;
    case Code::page_down:
      sequence(SequenceCode::page_down, '~', encoding);
      break;
    case Code::enter:
      if (modes.modify_other_keys_2 && encoding.modifier != 1) {
        append("\x1b[27;");
        number(encoding.modifier);
        append(";13~");
      } else {
        altText(key, "\r");
      }

      break;
    case Code::escape:
      altText(key, "\x1b");
      break;
    case Code::backspace:
      altText(key, key.has(Modifier::control) ? "\x08" : "\x7f");
      break;
    case Code::tab:
      altText(key, key.has(Modifier::shift) ? "\x1b[Z" : "\t");
      break;
    case Code::back_tab:
      altText(key, "\x1b[Z");
      break;
    }
  }

  std::array<char, capacity> bytes_{};
  std::size_t used_ = 0;
};

}
}

// Interface: input/key_label.cppm
export {
namespace telar::gui {

enum class KeyLabelStyle : std::uint8_t {
  pc,
  mac,
};

class KeyLabel {
public:
  static constexpr std::size_t capacity = 64;
  using Text = BoundedText<capacity>;

  [[nodiscard]] inline static Text chord(std::optional<KeyChord> prefix, KeyChord key, KeyLabelStyle style) {
    Text text;
    if (prefix) {
      append(text, *prefix, style);
      text.append(" ");
    }

    append(text, key, style);

    return text;
  }

private:
  struct ModifierLabel {
    KeyChord::Modifier modifier;
    std::string_view pc;
    std::string_view mac;
  };

  struct KeyName {
    KeyChord::Key key;
    std::string_view pc;
    std::string_view mac;
  };

  inline static void append(Text &text, KeyChord key, KeyLabelStyle style) {
    constexpr auto modifiers = std::to_array<ModifierLabel>({
        {.modifier = KeyChord::Modifier::control, .pc = "Ctrl+", .mac = "⌃"},
        {.modifier = KeyChord::Modifier::alt, .pc = "Alt+", .mac = "⌥"},
        {.modifier = KeyChord::Modifier::shift, .pc = "Shift+", .mac = "⇧"},
        {.modifier = KeyChord::Modifier::super, .pc = "Super+", .mac = "⌘"},
    });
    for (const auto &modifier : modifiers) {
      if (key.has(modifier.modifier)) {
        text.append(style == KeyLabelStyle::mac ? modifier.mac : modifier.pc);
      }
    }

    if (key.key == KeyChord::Key::character) {
      constexpr auto case_offset = 'a' - 'A';
      const auto ascii_lower = key.character >= 'a' && key.character <= 'z';
      const auto character = style == KeyLabelStyle::mac && ascii_lower ? key.character - case_offset : key.character;
      text.append(Utf8Scalar::encode(character).view());

      return;
    }

    constexpr auto names = std::to_array<KeyName>({
        {.key = KeyChord::Key::up, .pc = "Up", .mac = "↑"},
        {.key = KeyChord::Key::down, .pc = "Down", .mac = "↓"},
        {.key = KeyChord::Key::left, .pc = "Left", .mac = "←"},
        {.key = KeyChord::Key::right, .pc = "Right", .mac = "→"},
        {.key = KeyChord::Key::home, .pc = "Home", .mac = "↖"},
        {.key = KeyChord::Key::end, .pc = "End", .mac = "↘"},
        {.key = KeyChord::Key::erase, .pc = "Del", .mac = "⌦"},
        {.key = KeyChord::Key::page_up, .pc = "PgUp", .mac = "⇞"},
        {.key = KeyChord::Key::page_down, .pc = "PgDn", .mac = "⇟"},
        {.key = KeyChord::Key::enter, .pc = "Enter", .mac = "↩"},
        {.key = KeyChord::Key::escape, .pc = "Esc", .mac = "esc"},
        {.key = KeyChord::Key::backspace, .pc = "Backspace", .mac = "⌫"},
        {.key = KeyChord::Key::tab, .pc = "Tab", .mac = "⇥"},
        {.key = KeyChord::Key::back_tab, .pc = "Shift+Tab", .mac = "⇧⇥"},
    });
    for (const auto &name : names) {
      if (name.key == key.key) {
        text.append(style == KeyLabelStyle::mac ? name.mac : name.pc);

        return;
      }
    }
  }
};

}
}

// Interface: input/key_router.cppm
export {
namespace telar::gui {

template <typename Event>
concept BindingInput = requires(const Event &event) {
  { event.chord } -> std::convertible_to<KeyChord>;
  { event.phase } -> std::convertible_to<KeyPhase>;
  { event.physical } -> std::convertible_to<std::uint64_t>;
};

template <typename Action, BindingInput Event = BindingEvent>
class KeyRouter {
public:
  enum class Outcome : std::uint8_t {
    forward,
    replay,
    action,
    pending,
    discard,
  };

  struct Decision {
    Outcome outcome = Outcome::discard;
    Action action{};
    Event event{};
    std::array<Event, BindingLimits::keys> held{};
    std::size_t held_count = 0;
    bool has_current = false;
    bool repeated = false;
    std::uint64_t now_ns = 0;
  };

  struct Context {
    bool captures_keys = false;
    std::optional<BindingRepeat> repeat;
  };

  inline explicit KeyRouter(BindingMap<Action> map = BindingMap<Action>{}, std::optional<KeyChord> prefix = {})
      : map_(std::move(map)),
        prefix_(prefix),
        candidates_{0, map_.size()} {}

  [[nodiscard]] inline bool wantsBinding(const Event &event) const noexcept {
    if (event.phase != KeyPhase::press) {
      const auto *lease = findLease(event.physical);

      return lease != nullptr && lease->owner == Owner::binding;
    }

    const auto matched = map_.match({0, map_.size()}, 0, event.chord);

    return depth_ != 0 || matched.begin != matched.end;
  }

  [[nodiscard]] inline bool prefixPending() const noexcept {
    return prefix_pending_;
  }

  [[nodiscard]] inline std::optional<KeyChord> prefixedKeyForAction(const Action &action) const noexcept {
    if (!prefix_) {
      return std::nullopt;
    }

    for (const auto &binding : map_.configured()) {
      if (binding.length == 2 && binding.keys[0] == *prefix_ && binding.action == action) {
        return binding.keys[1];
      }
    }

    return std::nullopt;
  }

  [[nodiscard]] inline bool hasPhysicalKey(std::uint64_t physical) const noexcept {
    return findLease(physical) != nullptr;
  }

  [[nodiscard]] inline std::optional<std::uint64_t> deadline() const noexcept {
    if (prefix_pending_ || !since_) {
      return {};
    }

    const auto available = std::numeric_limits<std::uint64_t>::max() - *since_;

    return *since_ + std::min(timeout_ns_, available);
  }

  inline void setTimeout(std::uint64_t timeout_ns) noexcept {
    timeout_ns_ = timeout_ns;
  }

  inline Decision expire(std::uint64_t now_ns) {
    const auto due = deadline();

    return due && now_ns >= *due ? replay() : Decision{.outcome = Outcome::pending};
  }

  inline Decision route(const Event &event, std::uint64_t now_ns, Context context = {}) {
    if (event.phase == KeyPhase::press) {
      repeating_.reset();
    }

    if (event.physical != 0) {
      if (event.phase == KeyPhase::press && !acquire(event.physical)) {
        return {};
      }

      if (event.phase != KeyPhase::press) {
        return routeLease(event, now_ns, context.repeat);
      }
    }

    if (context.captures_keys) {
      auto decision = replay();
      transfer(event.physical);
      if (decision.outcome == Outcome::replay) {
        decision.event = event;
        decision.has_current = true;

        return decision;
      }

      return {.outcome = Outcome::forward, .event = event};
    }

    const bool was_pending = depth_ != 0;
    auto decision = match(event, now_ns);
    if (decision.outcome == Outcome::forward) {
      transfer(event.physical);
    } else if (decision.outcome == Outcome::replay) {
      for (const auto &held : std::span{decision.held}.first(decision.held_count)) {
        transfer(held.physical);
      }

      transfer(event.physical);
    } else if (decision.outcome == Outcome::pending && !was_pending && !prefix_pending_) {
      since_ = now_ns;
    }

    if (depth_ == 0) {
      since_.reset();
    }

    return decision;
  }

  inline void actionCompleted(const Decision &decision, std::optional<BindingRepeat> policy) {
    if (!decision.repeated && decision.event.physical != 0 && policy && policy->interval_ns != 0) {
      repeating_ = Repeating{decision.event, decision.action, *policy, decision.now_ns};
    }
  }

  [[nodiscard]] inline std::optional<Action> repeatAction() const {
    return repeating_ ? std::optional{repeating_->action} : std::nullopt;
  }

  inline void eventFailed(const Event &event) noexcept {
    repeating_.reset();
    if (event.phase == KeyPhase::press) {
      release(event.physical);
    }
  }

  inline void inheritLeases(const KeyRouter &previous) noexcept {
    leases_ = previous.leases_;
    lease_count_ = previous.lease_count_;
    overflow_ = previous.overflow_;
    repeating_.reset();
  }

  inline void relinquish(std::uint64_t physical) noexcept {
    release(physical);
  }

  inline Decision interrupt() {
    repeating_.reset();

    return replay();
  }

  inline void cancelSequence() noexcept {
    resetMatch();
    since_.reset();
    repeating_.reset();
  }

  inline void clear() noexcept {
    cancelSequence();
    lease_count_ = 0;
  }

  [[nodiscard]] inline std::uint64_t overflowCount() const noexcept {
    return overflow_;
  }

private:
  enum class Owner : std::uint8_t {
    binding,
    application,
  };

  struct Lease {
    std::uint64_t physical = 0;
    Owner owner = Owner::binding;
  };

  struct Repeating {
    Event event;
    Action action;
    BindingRepeat policy;
    std::uint64_t last_ns = 0;
  };

  inline Lease *findLease(std::uint64_t physical) noexcept {
    auto *const end = leases_.begin() + lease_count_;
    auto *const found = std::ranges::find(leases_.begin(), end, physical, &Lease::physical);

    return physical == 0 || found == end ? nullptr : found;
  }

  [[nodiscard]] inline const Lease *findLease(std::uint64_t physical) const noexcept {
    const auto *const end = leases_.begin() + lease_count_;
    const auto *const found = std::ranges::find(leases_.begin(), end, physical, &Lease::physical);

    return physical == 0 || found == end ? nullptr : found;
  }

  inline bool acquire(std::uint64_t physical) noexcept {
    auto *slot = findLease(physical);
    if (slot == nullptr) {
      if (lease_count_ == leases_.size()) {
        ++overflow_;

        return false;
      }

      slot = &leases_[lease_count_++];
    }

    *slot = {.physical = physical, .owner = Owner::binding};

    return true;
  }

  inline void transfer(std::uint64_t physical) noexcept {
    if (auto *lease = findLease(physical)) {
      lease->owner = Owner::application;
    }
  }

  inline std::optional<Owner> release(std::uint64_t physical) noexcept {
    if (repeating_ && repeating_->event.physical == physical) {
      repeating_.reset();
    }

    auto *lease = findLease(physical);
    if (lease == nullptr) {
      return {};
    }

    const auto owner = lease->owner;
    *lease = leases_[--lease_count_];

    return owner;
  }

  inline Decision routeLease(const Event &event, std::uint64_t now_ns, std::optional<BindingRepeat> policy) {
    if (event.phase == KeyPhase::release) {
      return release(event.physical) == Owner::application ? Decision{.outcome = Outcome::forward, .event = event} : Decision{};
    }

    const auto *lease = findLease(event.physical);
    if (lease == nullptr) {
      return {};
    }

    if (lease->owner == Owner::application) {
      return {.outcome = Outcome::forward, .event = event};
    }

    if (!repeating_ || repeating_->event.physical != event.physical) {
      return {};
    }

    if (repeating_->event.chord != event.chord || policy != repeating_->policy) {
      repeating_.reset();

      return {};
    }

    if (now_ns < repeating_->last_ns || now_ns - repeating_->last_ns < repeating_->policy.interval_ns) {
      return {};
    }

    repeating_->last_ns = now_ns;

    return {.outcome = Outcome::action, .action = repeating_->action, .event = event, .repeated = true, .now_ns = now_ns};
  }

  inline Decision match(const Event &event, std::uint64_t now_ns) {
    constexpr KeyChord escape{.key = KeyChord::Key::escape};
    if (prefix_pending_ && event.chord == escape) {
      resetMatch();

      return {};
    }

    const auto candidates = depth_ == 0 ? typename BindingMap<Action>::Range{0, map_.size()} : candidates_;
    const auto matched = map_.match(candidates, depth_, event.chord);
    if (matched.begin == matched.end) {
      return missed(event);
    }

    const auto &binding = map_.at(matched.begin);
    if (binding.length == depth_ + 1) {
      const auto action = binding.action;
      resetMatch();

      return {.outcome = Outcome::action, .action = action, .event = event, .now_ns = now_ns};
    }

    held_[depth_] = event;
    ++depth_;
    candidates_ = matched;
    if (depth_ == 1 && prefix_) {
      prefix_pending_ = event.chord == *prefix_;
    }

    return {.outcome = Outcome::pending};
  }

  inline Decision missed(const Event &event) {
    if (depth_ == 0) {
      return {.outcome = Outcome::forward, .event = event};
    }

    auto decision = replay();
    if (decision.outcome == Outcome::replay) {
      decision.event = event;
      decision.has_current = true;
    }

    return decision;
  }

  inline Decision replay() {
    Decision decision;
    if (depth_ != 0 && !prefix_pending_) {
      decision.outcome = Outcome::replay;
      decision.held_count = depth_;
      std::copy_n(held_.begin(), depth_, decision.held.begin());
      for (const auto &held : std::span{held_}.first(depth_)) {
        transfer(held.physical);
      }
    }

    resetMatch();
    since_.reset();

    return decision;
  }

  inline void resetMatch() noexcept {
    candidates_ = {0, map_.size()};
    depth_ = 0;
    prefix_pending_ = false;
  }

  BindingMap<Action> map_;
  std::optional<KeyChord> prefix_;
  BindingMap<Action>::Range candidates_;
  std::array<Event, BindingLimits::keys> held_{};
  std::array<Lease, BindingLimits::physical_keys> leases_{};
  std::optional<Repeating> repeating_;
  std::optional<std::uint64_t> since_;
  std::uint64_t timeout_ns_ = BindingLimits::sequence_timeout_ns;
  std::uint64_t overflow_ = 0;
  std::size_t lease_count_ = 0;
  std::size_t depth_ = 0;
  bool prefix_pending_ = false;
};

}
}

// Interface: input/paste_encoding.cppm
export {
namespace telar::gui {

struct PasteEncoding {
  static constexpr std::string_view begin = "\x1b[200~";
  static constexpr std::string_view end = "\x1b[201~";
  static constexpr std::size_t framing_bytes = begin.size() + end.size();

  template <std::size_t Capacity>
  [[nodiscard]] inline static BoundedText<Capacity + framing_bytes> encode(std::string_view text, bool bracketed) {
    if (text.size() > Capacity) {
      throw std::length_error{"Paste text exceeds its capacity"};
    }

    BoundedText<Capacity + framing_bytes> encoded;
    if (bracketed) {
      encoded.append(begin);
    }

    encoded.append(text);
    if (bracketed) {
      encoded.append(end);
    }

    return encoded;
  }
};

}
}
