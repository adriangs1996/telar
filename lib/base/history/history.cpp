module telar.base.history;

import std;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // One character of UTF-8 at the start of `text`, and its bytes; a byte that starts none is a
    // character of its own above Unicode's, so it matches only itself.
    struct Decoded {
      std::uint32_t character = 0;
      std::size_t bytes = 1;
    };

    // UTF-8's sequences by their length: the bits that mark a lead byte, those of the character
    // it carries, and the first character past what the sequence holds.
    struct Sequence {
      unsigned lead_mask;
      unsigned lead_bits;
      unsigned payload;
      std::uint32_t end;
    };

    constexpr ds::Array<Sequence, 4> sequences{
        {
            {.lead_mask = 0x80, .lead_bits = 0x00, .payload = 0x7f, .end = 0x80},
            {.lead_mask = 0xe0, .lead_bits = 0xc0, .payload = 0x1f, .end = 0x800},
            {.lead_mask = 0xf0, .lead_bits = 0xe0, .payload = 0x0f, .end = 0x10000},
            {.lead_mask = 0xf8, .lead_bits = 0xf0, .payload = 0x07, .end = 0x110000},
        },
    };

    constexpr std::uint32_t first_non_ascii = 0x80;
    constexpr unsigned continuation_mask = 0xc0U;
    constexpr unsigned continuation_bits = 0x80U;
    constexpr unsigned continuation_payload = 0x3fU;
    constexpr unsigned continuation_shift = 6U;
    // Past Unicode's last character, where a byte that starts no character goes.
    constexpr std::uint32_t outside = 0x110000;

    Decoded decode(std::string_view text) noexcept {
      const auto lead = static_cast<unsigned char>(text.front());
      std::size_t length = 0;

      for (const auto& sequence : sequences) {
        ++length;
        if ((lead & sequence.lead_mask) != sequence.lead_bits) {
          continue;
        }

        std::uint32_t character = lead & sequence.payload;

        for (std::size_t index = 1; index < length; ++index) {
          if (index >= text.size() || (static_cast<unsigned char>(text[index]) & continuation_mask) != continuation_bits) {
            return {.character = outside + lead};
          }

          character = (character << continuation_shift) | (static_cast<unsigned char>(text[index]) & continuation_payload);
        }

        return {.character = character, .bytes = length};
      }

      return {.character = outside + lead};
    }

    // Writes `character`, one of Unicode's, at the start of `out`, and says how many bytes.
    std::size_t encode(std::uint32_t character, std::span<char> out) noexcept {
      std::size_t length = 0;
      unsigned lead_bits = 0;

      for (const auto& sequence : sequences) {
        ++length;
        lead_bits = sequence.lead_bits;
        if (character < sequence.end) {
          break;
        }
      }

      for (std::size_t index = length; index-- > 1;) {
        out[index] = static_cast<char>(continuation_bits | (character & continuation_payload));
        character >>= continuation_shift;
      }

      out[0] = static_cast<char>(lead_bits | character);
      return length;
    }

    // A run of capitals [first, last] whose small letters are `offset` away.
    struct FoldRange {
      std::uint32_t first;
      std::uint32_t last;
      std::int32_t offset;
    };

    // Runs where capital and small letter alternate, the capital even, from `first` to `last`.
    struct FoldPairs {
      std::uint32_t first;
      std::uint32_t last;
    };

    constexpr ds::Array<FoldRange, 18> fold_ranges{
        {
            {.first = 'A', .last = 'Z', .offset = 32},
            {.first = 0xc0, .last = 0xd6, .offset = 32},
            {.first = 0xd8, .last = 0xde, .offset = 32},
            {.first = 0x386, .last = 0x386, .offset = 38},
            {.first = 0x388, .last = 0x38a, .offset = 37},
            {.first = 0x38c, .last = 0x38c, .offset = 64},
            {.first = 0x38e, .last = 0x38f, .offset = 63},
            {.first = 0x391, .last = 0x3a1, .offset = 32},
            {.first = 0x3a3, .last = 0x3ab, .offset = 32},
            {.first = 0x3c2, .last = 0x3c2, .offset = 1},
            {.first = 0x400, .last = 0x40f, .offset = 80},
            {.first = 0x410, .last = 0x42f, .offset = 32},
            {.first = 0x531, .last = 0x556, .offset = 48},
            {.first = 0x10a0, .last = 0x10c5, .offset = 0x2d00 - 0x10a0},
            {.first = 0x2126, .last = 0x2126, .offset = 0x3c9 - 0x2126},
            {.first = 0x212a, .last = 0x212a, .offset = 'k' - 0x212a},
            {.first = 0x212b, .last = 0x212b, .offset = 0xe5 - 0x212b},
            {.first = 0xff21, .last = 0xff3a, .offset = 32},
        },
    };

    constexpr ds::Array<FoldPairs, 9> fold_pairs{
        {
            {.first = 0x100, .last = 0x12f},
            {.first = 0x132, .last = 0x137},
            {.first = 0x14a, .last = 0x177},
            {.first = 0x3d8, .last = 0x3ef},
            {.first = 0x460, .last = 0x481},
            {.first = 0x48a, .last = 0x4bf},
            {.first = 0x4d0, .last = 0x52f},
            {.first = 0x1e00, .last = 0x1e95},
            {.first = 0x1ea0, .last = 0x1eff},
        },
    };

    // Runs where capital and small letter alternate, the capital odd.
    constexpr ds::Array<FoldPairs, 3> odd_fold_pairs{
        {
            {.first = 0x139, .last = 0x148},
            {.first = 0x179, .last = 0x17e},
            {.first = 0x4c1, .last = 0x4ce},
        },
    };

    constexpr std::uint32_t small_letter_offset = 'a' - 'A';

  }

  std::uint32_t historyFold(std::uint32_t character) noexcept {
    // Latin Extended-A's odd runs, where the capital is odd, and its outliers.
    constexpr std::uint32_t long_s = 0x17f;
    constexpr std::uint32_t y_diaeresis = 0x178;
    constexpr std::uint32_t small_y_diaeresis = 0xff;
    constexpr std::uint32_t capital_sharp_s = 0x1e9e;
    constexpr std::uint32_t small_sharp_s = 0xdf;
    constexpr std::uint32_t cyrillic_palochka = 0x4c0;
    constexpr std::uint32_t cyrillic_small_palochka = 0x4cf;

    if (character < first_non_ascii) {
      return character >= 'A' && character <= 'Z' ? character + small_letter_offset : character;
    }

    for (const auto& range : fold_ranges) {
      if (character >= range.first && character <= range.last) {
        return static_cast<std::uint32_t>(static_cast<std::int32_t>(character) + range.offset);
      }
    }

    for (const auto& pairs : fold_pairs) {
      if (character >= pairs.first && character <= pairs.last) {
        return character | 1U;
      }
    }

    for (const auto& pairs : odd_fold_pairs) {
      if (character >= pairs.first && character <= pairs.last) {
        return (character & 1U) != 0 ? character + 1 : character;
      }
    }

    switch (character) {
    case long_s:
      return 's';
    case y_diaeresis:
      return small_y_diaeresis;
    case capital_sharp_s:
      return small_sharp_s;
    case cyrillic_palochka:
      return cyrillic_small_palochka;
    default:
      return character;
    }
  }

  std::size_t historyFold(std::string_view text, std::span<char> out) noexcept {
    std::size_t written = 0;

    while (!text.empty()) {
      const auto decoded = decode(text);
      const auto folded = decoded.character >= outside ? decoded.character : historyFold(decoded.character);

      if (folded == decoded.character) {
        std::ranges::copy_n(text.begin(), static_cast<std::ptrdiff_t>(decoded.bytes), out.subspan(written).begin());
        written += decoded.bytes;
      } else {
        written += encode(folded, out.subspan(written));
      }

      text.remove_prefix(decoded.bytes);
    }

    return written;
  }

  // NOLINTNEXTLINE(bugprone-easily-swappable-parameters): the command is scored for the query, as the declaration names them
  ds::Option<std::uint32_t> historyScore(std::string_view command, std::string_view query) noexcept {
    if (query.empty()) {
      return 1;
    }

    // The query's characters, folded once; a query past what this holds is never typed.
    constexpr std::size_t maximum_query = 1024;
    ds::Array<std::uint32_t, maximum_query> wanted{};
    std::size_t wanted_count = 0;

    for (auto rest = query; !rest.empty() && wanted_count < wanted.size();) {
      const auto decoded = decode(rest);

      wanted.atMut(wanted_count++) = historyFold(decoded.character);
      rest.remove_prefix(decoded.bytes);
    }

    std::size_t matched = 0;
    std::size_t first = 0;
    std::size_t index = 0;

    for (auto rest = command; !rest.empty(); ++index) {
      const auto decoded = decode(rest);

      rest.remove_prefix(decoded.bytes);
      if (historyFold(decoded.character) != wanted[matched]) {
        continue;
      }

      if (matched == 0) {
        first = index;
      }

      ++matched;
      if (matched == wanted_count) {
        constexpr std::uint32_t base_score = 4096;
        constexpr std::uint32_t leading_penalty = 8;
        constexpr std::uint32_t inner_penalty = 16;
        const auto penalty = (first * leading_penalty) + ((index - first + 1 - wanted_count) * inner_penalty);

        return penalty >= base_score ? 0 : base_score - static_cast<std::uint32_t>(penalty);
      }
    }

    return ds::none;
  }

  std::string_view historyGroup(std::string_view command) noexcept {
    constexpr std::string_view sudo = "sudo ";
    const auto trim = [](std::string_view text) {
      text.remove_prefix(std::min(text.find_first_not_of(' '), text.size()));
      return text;
    };

    // The first `count` bytes of the command, which holds them.
    const auto head = [](std::string_view text, std::size_t count) {
      text.remove_suffix(text.size() - count);
      return text;
    };

    command = trim(command);
    if (command.starts_with(sudo)) {
      command.remove_prefix(sudo.size());
      command = trim(command);
    }

    const auto first_end = command.find(' ');
    if (first_end == std::string_view::npos) {
      return command;
    }

    constexpr ds::Array<std::string_view, 11> leaders{"git", "docker", "kubectl", "cargo", "zig", "npm", "pnpm", "yarn", "make", "brew", "systemctl"};
    const auto first = head(command, first_end);

    if (std::ranges::find(leaders, first) == leaders.end()) {
      return head(command, first_end);
    }

    auto remainder = command;

    remainder.remove_prefix(first_end);
    remainder = trim(remainder);
    if (remainder.empty() || remainder.front() == '-') {
      return head(command, first_end);
    }

    const auto second_end = remainder.find(' ');

    return head(command, static_cast<std::size_t>(remainder.data() - command.data()) + std::min(second_end, remainder.size()));
  }

  void IntegrationMarkFilter::reset() noexcept {
    state_ = State::ground;
    held_count_ = 0;
    number_ = 0;
  }

  IntegrationMarkFilter::Step IntegrationMarkFilter::step(std::uint8_t byte) noexcept {
    constexpr std::uint8_t bell = 0x07;
    constexpr std::uint8_t cancel = 0x18;
    constexpr std::uint8_t substitute = 0x1a;
    constexpr std::uint32_t prompt_mark = 133;
    constexpr std::uint32_t private_mark = 6973;
    constexpr std::uint32_t decimal = 10;

    switch (state_) {
    case State::ground:
      held_.atMut(0) = byte;
      held_count_ = 1;
      state_ = State::escape;
      return Step::consumed;
    case State::escape:
      if (byte != ']') {
        state_ = State::ground;
        return Step::release;
      }

      held_.atMut(held_count_++) = byte;
      number_ = 0;
      state_ = State::number;
      return Step::consumed;
    case State::number: {
      const bool digit = byte >= '0' && byte <= '9';
      if (digit && held_count_ < held_.size()) {
        held_.atMut(held_count_++) = byte;
        number_ = (number_ * decimal) + (byte - '0');
        return Step::consumed;
      }

      const bool ends = byte == ';' || byte == bell || byte == escape;
      if (digit || !ends || (number_ != prompt_mark && number_ != private_mark)) {
        state_ = State::ground;
        return Step::release;
      }

      held_count_ = 0;
      if (byte == ';') {
        state_ = State::mark;
      } else {
        state_ = byte == bell ? State::ground : State::mark_escape;
      }

      return Step::consumed;
    }
    case State::mark:
      if (byte == bell || byte == cancel || byte == substitute) {
        state_ = State::ground;
      } else if (byte == escape) {
        state_ = State::mark_escape;
      }

      return Step::consumed;
    case State::mark_escape:
      // ESC \ ends the mark; ESC before anything else ends it too, and that byte is read anew.
      state_ = State::ground;
      return byte == '\\' ? Step::consumed : Step::release;
    }

    return Step::consumed;
  }

}
