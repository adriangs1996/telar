module;
#include "tbc/annotations.hpp"

export module telar.gui.input.key_encoder;

import std;

export import telar.config.client;

export import telar.gui.core.unicode_scalar;

export import telar.gui.text.json_unsigned_integer;
import telar.base.diagnostics;
import telar.base.text;
import telar.wire.vocabulary;

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

    int compareChords(KeyChord left, KeyChord right) noexcept;

    template <typename Action>
    struct TBC_HOT_PATH KeyBinding {
      std::array<KeyChord, BindingLimits::keys> keys{};
      std::size_t length = 0;
      Action action{};
      bool prefixed = false;

      [[nodiscard]] inline std::span<const KeyChord> sequence() const noexcept {
        return std::span{keys}.first(length);
      }

      [[nodiscard]] inline bool conflictsWith(const KeyBinding& other) const noexcept {
        const auto shared = std::min(length, other.length);

        return std::equal(keys.begin(), keys.begin() + shared, other.keys.begin());
      }
    };

    template <typename Action>
    class TBC_HOT_PATH BindingMap {
    public:
      struct Range {
        std::size_t begin = 0;
        std::size_t end = 0;
      };

      inline explicit BindingMap(std::span<const KeyBinding<Action>> bindings = {}) {
        if (bindings.size() > BindingLimits::bindings) {
          throw std::invalid_argument{"Too many key bindings"};
        }

        for (const auto& binding : bindings) {
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

      [[nodiscard]] inline const KeyBinding<Action>& at(std::size_t index) const noexcept {
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
      [[nodiscard]] static std::uint32_t pack(std::uint32_t codepoint);

      [[nodiscard]] static Utf8Scalar text(std::uint32_t storage) noexcept;

      [[nodiscard]] static std::uint32_t codepoint(std::uint32_t storage);
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

      bool operator==(const BindingRepeat&) const = default;
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

      [[nodiscard]] bool has(KeyChord::Modifier modifier) const noexcept;
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

      // The key one alternate-scroll step sends: Up or Down as the cursor key mode encodes them, as
      // Ghostty sends it (Surface.zig), whatever keyboard protocol the application asked for.
      [[nodiscard]] std::string_view alternateScroll(bool up, const InputModes& modes);

      [[nodiscard]] std::string_view encode(const TerminalKey& key, const InputModes& modes);

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

      static bool reportsLegacyRelease(Code code) noexcept;

      struct Encoding {
        explicit Encoding(const TerminalKey& key, const InputModes& modes);

        [[nodiscard]] bool has(KittyKeyboardFlag flag) const noexcept;

        [[nodiscard]] bool usesKitty(const TerminalKey& key) const noexcept;

        unsigned modifier;
        unsigned flags;
        bool cursor_keys;
        std::optional<unsigned> event;
      };

      [[nodiscard]] std::string_view view() const noexcept;

      void append(std::string_view text);

      void byte(char value);

      void number(std::uint32_t value);

      static std::uint32_t textCodepoint(const TerminalKey& key);

      bool encodeText(const TerminalKey& key, const Encoding& encoding);

      static std::optional<std::uint32_t> associatedText(const TerminalKey& key, const Encoding& encoding);

      void kittyCodepoints(const TerminalKey& key, const Encoding& encoding);

      void encodeKitty(const TerminalKey& key, const Encoding& encoding);

      void altText(const TerminalKey& key, std::string_view text);

      static std::optional<char> controlByte(std::uint32_t codepoint) noexcept;

      void legacyCharacter(const TerminalKey& key);

      void sequence(SequenceCode code, char final, const Encoding& encoding);

      void encodeLegacy(const TerminalKey& key, const Encoding& encoding, const InputModes& modes);

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

      [[nodiscard]] static Text chord(std::optional<KeyChord> prefix, KeyChord key, KeyLabelStyle style);

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

      static void append(Text& text, KeyChord key, KeyLabelStyle style);
    };

  }
}

// Interface: input/key_router.cppm
export {
  namespace telar::gui {

    template <typename Event>
    concept BindingInput = requires(const Event& event) {
      { event.chord } -> std::convertible_to<KeyChord>;
      { event.phase } -> std::convertible_to<KeyPhase>;
      { event.physical } -> std::convertible_to<std::uint64_t>;
    };

    // The physical keys a router holds down, and whether a binding or the application owns what each
    // one does until it is released.
    class KeyLeases {
    public:
      enum class Owner : std::uint8_t {
        binding,
        application,
      };

      [[nodiscard]] std::optional<Owner> owner(std::uint64_t physical) const noexcept;

      // A new press of a held key gives it back to the bindings; nothing is held past the table's size.
      bool acquire(std::uint64_t physical) noexcept;

      void transfer(std::uint64_t physical) noexcept;

      std::optional<Owner> release(std::uint64_t physical) noexcept;

      void clear() noexcept;

      [[nodiscard]] std::uint64_t overflowCount() const noexcept;

    private:
      struct Lease {
        std::uint64_t physical = 0;
        Owner owner = Owner::binding;
      };

      [[nodiscard]] std::size_t find(std::uint64_t physical) const noexcept;

      std::array<Lease, BindingLimits::physical_keys> leases_{};
      std::size_t count_ = 0;
      std::uint64_t overflow_ = 0;
    };

    template <typename Action, BindingInput Event = BindingEvent>
    class TBC_HOT_PATH KeyRouter {
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

      [[nodiscard]] inline bool wantsBinding(const Event& event) const noexcept {
        if (event.phase != KeyPhase::press) {
          return leases_.owner(event.physical) == Owner::binding;
        }

        const auto matched = map_.match({0, map_.size()}, 0, event.chord);

        return depth_ != 0 || matched.begin != matched.end;
      }

      [[nodiscard]] inline bool prefixPending() const noexcept {
        return prefix_pending_;
      }

      [[nodiscard]] inline std::optional<KeyChord> prefixedKeyForAction(const Action& action) const noexcept {
        if (!prefix_) {
          return std::nullopt;
        }

        for (const auto& binding : map_.configured()) {
          if (binding.length == 2 && binding.keys[0] == *prefix_ && binding.action == action) {
            return binding.keys[1];
          }
        }

        return std::nullopt;
      }

      [[nodiscard]] inline bool hasPhysicalKey(std::uint64_t physical) const noexcept {
        return leases_.owner(physical).has_value();
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

      inline Decision route(const Event& event, std::uint64_t now_ns, Context context = {}) {
        if (event.phase == KeyPhase::press) {
          repeating_.reset();
        }

        if (event.physical != 0) {
          if (event.phase == KeyPhase::press && !leases_.acquire(event.physical)) {
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
          for (const auto& held : std::span{decision.held}.first(decision.held_count)) {
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

      inline void actionCompleted(const Decision& decision, std::optional<BindingRepeat> policy) {
        if (!decision.repeated && decision.event.physical != 0 && policy && policy->interval_ns != 0) {
          repeating_ = Repeating{decision.event, decision.action, *policy, decision.now_ns};
        }
      }

      [[nodiscard]] inline std::optional<Action> repeatAction() const {
        return repeating_ ? std::optional{repeating_->action} : std::nullopt;
      }

      inline void eventFailed(const Event& event) noexcept {
        repeating_.reset();
        if (event.phase == KeyPhase::press) {
          release(event.physical);
        }
      }

      inline void inheritLeases(const KeyRouter& previous) noexcept {
        leases_ = previous.leases_;
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
        leases_.clear();
      }

      [[nodiscard]] inline std::uint64_t overflowCount() const noexcept {
        return leases_.overflowCount();
      }

    private:
      using Owner = KeyLeases::Owner;

      struct Repeating {
        Event event;
        Action action;
        BindingRepeat policy;
        std::uint64_t last_ns = 0;
      };

      inline void transfer(std::uint64_t physical) noexcept {
        leases_.transfer(physical);
      }

      inline std::optional<Owner> release(std::uint64_t physical) noexcept {
        if (repeating_ && repeating_->event.physical == physical) {
          repeating_.reset();
        }

        return leases_.release(physical);
      }

      inline Decision routeLease(const Event& event, std::uint64_t now_ns, std::optional<BindingRepeat> policy) {
        if (event.phase == KeyPhase::release) {
          return release(event.physical) == Owner::application ? Decision{.outcome = Outcome::forward, .event = event} : Decision{};
        }

        const auto owner = leases_.owner(event.physical);
        if (!owner) {
          return {};
        }

        if (*owner == Owner::application) {
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

      inline Decision match(const Event& event, std::uint64_t now_ns) {
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

        const auto& binding = map_.at(matched.begin);
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

      inline Decision missed(const Event& event) {
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
          for (const auto& held : std::span{held_}.first(depth_)) {
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
      KeyLeases leases_;
      std::optional<Repeating> repeating_;
      std::optional<std::uint64_t> since_;
      std::uint64_t timeout_ns_ = BindingLimits::sequence_timeout_ns;
      std::size_t depth_ = 0;
      bool prefix_pending_ = false;
    };

  }
}

// Interface: input/paste_encoding.cppm
export {
  namespace telar::gui {

    // A paste as one bounded value, encoded by the paste encoder the runtime uses too.
    struct PasteEncoding {
      template <std::size_t Capacity>
      [[nodiscard]] TBC_HOT_PATH inline static BoundedText<Capacity + BracketedPaste::framing_bytes> encode(std::string_view text, bool bracketed) {
        if (text.size() > Capacity) {
          throw std::length_error{"Paste text exceeds its capacity"};
        }

        BoundedText<Capacity + BracketedPaste::framing_bytes> encoded;

        BracketedPaste::encode(text, bracketed, [&](std::string_view piece) {
          encoded.append(piece);
        });

        return encoded;
      }
    };

  }
}
