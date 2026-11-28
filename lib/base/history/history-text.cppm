// What the history's search reads text with, for the module's own units: UTF-8 one character at
// a time, the case fold and the latin diacritics, and the class of a character that its match
// bonus depends on. Built at compile time; none of it allocates.
module telar.base.history:text;

import std;
import telar.base.ds;

namespace telar::runtime::history_text {

  // One character of UTF-8 at the start of a text, and its bytes; a byte that starts none is a
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

  inline constexpr ds::Array<Sequence, 4> sequences{
      {
          {.lead_mask = 0x80, .lead_bits = 0x00, .payload = 0x7f, .end = 0x80},
          {.lead_mask = 0xe0, .lead_bits = 0xc0, .payload = 0x1f, .end = 0x800},
          {.lead_mask = 0xf0, .lead_bits = 0xe0, .payload = 0x0f, .end = 0x10000},
          {.lead_mask = 0xf8, .lead_bits = 0xf0, .payload = 0x07, .end = 0x110000},
      },
  };

  inline constexpr std::uint32_t first_non_ascii = 0x80;
  inline constexpr unsigned continuation_mask = 0xc0U;
  inline constexpr unsigned continuation_bits = 0x80U;
  inline constexpr unsigned continuation_payload = 0x3fU;
  inline constexpr unsigned continuation_shift = 6U;
  // Past Unicode's last character, where a byte that starts no character goes.
  inline constexpr std::uint32_t outside = 0x110000;

  inline Decoded decode(std::string_view text) noexcept {
    const auto lead = static_cast<unsigned char>(text.front());
    std::size_t length = 0;

    if (lead < first_non_ascii) {
      return {.character = lead};
    }

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
  inline std::size_t encode(std::uint32_t character, std::span<char> out) noexcept {
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

  // Characters [first, last], every `stride`th, that fold `offset` away; `upper` when they are
  // capitals, which make a search term case sensitive. Generated from Unicode 15's simple case
  // folding: each set of characters that fold together goes to the one of them with the
  // shortest UTF-8, the small letter when there is a tie, so no text grows as it folds (ⱥ and ⱦ
  // go to their capitals). A capital that folds to nothing shorter is listed with offset 0.
  struct FoldEntry {
    std::uint32_t first;
    std::uint32_t last;
    std::int32_t offset;
    std::uint32_t stride;
    bool upper;
  };

  inline constexpr ds::Array<FoldEntry, 209> fold_entries{
      {
          {.first = 0x41, .last = 0x5a, .offset = 32, .stride = 1, .upper = true},
          {.first = 0xb5, .last = 0xb5, .offset = 775, .stride = 1, .upper = false},
          {.first = 0xc0, .last = 0xd6, .offset = 32, .stride = 1, .upper = true},
          {.first = 0xd8, .last = 0xde, .offset = 32, .stride = 1, .upper = true},
          {.first = 0x100, .last = 0x12e, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x130, .last = 0x130, .offset = 0, .stride = 1, .upper = true},
          {.first = 0x132, .last = 0x136, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x139, .last = 0x147, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x14a, .last = 0x176, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x178, .last = 0x178, .offset = -121, .stride = 1, .upper = true},
          {.first = 0x179, .last = 0x17d, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x17f, .last = 0x17f, .offset = -268, .stride = 1, .upper = false},
          {.first = 0x181, .last = 0x181, .offset = 210, .stride = 1, .upper = true},
          {.first = 0x182, .last = 0x184, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x186, .last = 0x186, .offset = 206, .stride = 1, .upper = true},
          {.first = 0x187, .last = 0x187, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x189, .last = 0x18a, .offset = 205, .stride = 1, .upper = true},
          {.first = 0x18b, .last = 0x18b, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x18e, .last = 0x18e, .offset = 79, .stride = 1, .upper = true},
          {.first = 0x18f, .last = 0x18f, .offset = 202, .stride = 1, .upper = true},
          {.first = 0x190, .last = 0x190, .offset = 203, .stride = 1, .upper = true},
          {.first = 0x191, .last = 0x191, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x193, .last = 0x193, .offset = 205, .stride = 1, .upper = true},
          {.first = 0x194, .last = 0x194, .offset = 207, .stride = 1, .upper = true},
          {.first = 0x196, .last = 0x196, .offset = 211, .stride = 1, .upper = true},
          {.first = 0x197, .last = 0x197, .offset = 209, .stride = 1, .upper = true},
          {.first = 0x198, .last = 0x198, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x19c, .last = 0x19c, .offset = 211, .stride = 1, .upper = true},
          {.first = 0x19d, .last = 0x19d, .offset = 213, .stride = 1, .upper = true},
          {.first = 0x19f, .last = 0x19f, .offset = 214, .stride = 1, .upper = true},
          {.first = 0x1a0, .last = 0x1a4, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x1a6, .last = 0x1a6, .offset = 218, .stride = 1, .upper = true},
          {.first = 0x1a7, .last = 0x1a7, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x1a9, .last = 0x1a9, .offset = 218, .stride = 1, .upper = true},
          {.first = 0x1ac, .last = 0x1ac, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x1ae, .last = 0x1ae, .offset = 218, .stride = 1, .upper = true},
          {.first = 0x1af, .last = 0x1af, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x1b1, .last = 0x1b2, .offset = 217, .stride = 1, .upper = true},
          {.first = 0x1b3, .last = 0x1b5, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x1b7, .last = 0x1b7, .offset = 219, .stride = 1, .upper = true},
          {.first = 0x1b8, .last = 0x1b8, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x1bc, .last = 0x1bc, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x1c4, .last = 0x1c4, .offset = 2, .stride = 1, .upper = true},
          {.first = 0x1c5, .last = 0x1c5, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x1c7, .last = 0x1c7, .offset = 2, .stride = 1, .upper = true},
          {.first = 0x1c8, .last = 0x1c8, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x1ca, .last = 0x1ca, .offset = 2, .stride = 1, .upper = true},
          {.first = 0x1cb, .last = 0x1db, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x1de, .last = 0x1ee, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x1f1, .last = 0x1f1, .offset = 2, .stride = 1, .upper = true},
          {.first = 0x1f2, .last = 0x1f4, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x1f6, .last = 0x1f6, .offset = -97, .stride = 1, .upper = true},
          {.first = 0x1f7, .last = 0x1f7, .offset = -56, .stride = 1, .upper = true},
          {.first = 0x1f8, .last = 0x21e, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x220, .last = 0x220, .offset = -130, .stride = 1, .upper = true},
          {.first = 0x222, .last = 0x232, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x23a, .last = 0x23a, .offset = 0, .stride = 1, .upper = true},
          {.first = 0x23b, .last = 0x23b, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x23d, .last = 0x23d, .offset = -163, .stride = 1, .upper = true},
          {.first = 0x23e, .last = 0x23e, .offset = 0, .stride = 1, .upper = true},
          {.first = 0x241, .last = 0x241, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x243, .last = 0x243, .offset = -195, .stride = 1, .upper = true},
          {.first = 0x244, .last = 0x244, .offset = 69, .stride = 1, .upper = true},
          {.first = 0x245, .last = 0x245, .offset = 71, .stride = 1, .upper = true},
          {.first = 0x246, .last = 0x24e, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x345, .last = 0x345, .offset = 116, .stride = 1, .upper = false},
          {.first = 0x370, .last = 0x372, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x376, .last = 0x376, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x37f, .last = 0x37f, .offset = 116, .stride = 1, .upper = true},
          {.first = 0x386, .last = 0x386, .offset = 38, .stride = 1, .upper = true},
          {.first = 0x388, .last = 0x38a, .offset = 37, .stride = 1, .upper = true},
          {.first = 0x38c, .last = 0x38c, .offset = 64, .stride = 1, .upper = true},
          {.first = 0x38e, .last = 0x38f, .offset = 63, .stride = 1, .upper = true},
          {.first = 0x391, .last = 0x3a1, .offset = 32, .stride = 1, .upper = true},
          {.first = 0x3a3, .last = 0x3ab, .offset = 32, .stride = 1, .upper = true},
          {.first = 0x3c2, .last = 0x3c2, .offset = 1, .stride = 1, .upper = false},
          {.first = 0x3cf, .last = 0x3cf, .offset = 8, .stride = 1, .upper = true},
          {.first = 0x3d0, .last = 0x3d0, .offset = -30, .stride = 1, .upper = false},
          {.first = 0x3d1, .last = 0x3d1, .offset = -25, .stride = 1, .upper = false},
          {.first = 0x3d5, .last = 0x3d5, .offset = -15, .stride = 1, .upper = false},
          {.first = 0x3d6, .last = 0x3d6, .offset = -22, .stride = 1, .upper = false},
          {.first = 0x3d8, .last = 0x3ee, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x3f0, .last = 0x3f0, .offset = -54, .stride = 1, .upper = false},
          {.first = 0x3f1, .last = 0x3f1, .offset = -48, .stride = 1, .upper = false},
          {.first = 0x3f4, .last = 0x3f4, .offset = -60, .stride = 1, .upper = true},
          {.first = 0x3f5, .last = 0x3f5, .offset = -64, .stride = 1, .upper = false},
          {.first = 0x3f7, .last = 0x3f7, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x3f9, .last = 0x3f9, .offset = -7, .stride = 1, .upper = true},
          {.first = 0x3fa, .last = 0x3fa, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x3fd, .last = 0x3ff, .offset = -130, .stride = 1, .upper = true},
          {.first = 0x400, .last = 0x40f, .offset = 80, .stride = 1, .upper = true},
          {.first = 0x410, .last = 0x42f, .offset = 32, .stride = 1, .upper = true},
          {.first = 0x460, .last = 0x480, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x48a, .last = 0x4be, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x4c0, .last = 0x4c0, .offset = 15, .stride = 1, .upper = true},
          {.first = 0x4c1, .last = 0x4cd, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x4d0, .last = 0x52e, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x531, .last = 0x556, .offset = 48, .stride = 1, .upper = true},
          {.first = 0x10a0, .last = 0x10c5, .offset = 7264, .stride = 1, .upper = true},
          {.first = 0x10c7, .last = 0x10c7, .offset = 7264, .stride = 1, .upper = true},
          {.first = 0x10cd, .last = 0x10cd, .offset = 7264, .stride = 1, .upper = true},
          {.first = 0x13a0, .last = 0x13f5, .offset = 0, .stride = 1, .upper = true},
          {.first = 0x13f8, .last = 0x13fd, .offset = -8, .stride = 1, .upper = false},
          {.first = 0x1c80, .last = 0x1c80, .offset = -6222, .stride = 1, .upper = false},
          {.first = 0x1c81, .last = 0x1c81, .offset = -6221, .stride = 1, .upper = false},
          {.first = 0x1c82, .last = 0x1c82, .offset = -6212, .stride = 1, .upper = false},
          {.first = 0x1c83, .last = 0x1c84, .offset = -6210, .stride = 1, .upper = false},
          {.first = 0x1c85, .last = 0x1c85, .offset = -6211, .stride = 1, .upper = false},
          {.first = 0x1c86, .last = 0x1c86, .offset = -6204, .stride = 1, .upper = false},
          {.first = 0x1c87, .last = 0x1c87, .offset = -6180, .stride = 1, .upper = false},
          {.first = 0x1c88, .last = 0x1c88, .offset = 35267, .stride = 1, .upper = false},
          {.first = 0x1c90, .last = 0x1cba, .offset = -3008, .stride = 1, .upper = true},
          {.first = 0x1cbd, .last = 0x1cbf, .offset = -3008, .stride = 1, .upper = true},
          {.first = 0x1e00, .last = 0x1e94, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x1e9b, .last = 0x1e9b, .offset = -58, .stride = 1, .upper = false},
          {.first = 0x1e9e, .last = 0x1e9e, .offset = -7615, .stride = 1, .upper = true},
          {.first = 0x1ea0, .last = 0x1efe, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x1f08, .last = 0x1f0f, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1f18, .last = 0x1f1d, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1f28, .last = 0x1f2f, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1f38, .last = 0x1f3f, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1f48, .last = 0x1f4d, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1f59, .last = 0x1f59, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1f5b, .last = 0x1f5b, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1f5d, .last = 0x1f5d, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1f5f, .last = 0x1f5f, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1f68, .last = 0x1f6f, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1f88, .last = 0x1f8f, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1f98, .last = 0x1f9f, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1fa8, .last = 0x1faf, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1fb8, .last = 0x1fb9, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1fba, .last = 0x1fbb, .offset = -74, .stride = 1, .upper = true},
          {.first = 0x1fbc, .last = 0x1fbc, .offset = -9, .stride = 1, .upper = true},
          {.first = 0x1fbe, .last = 0x1fbe, .offset = -7173, .stride = 1, .upper = false},
          {.first = 0x1fc8, .last = 0x1fcb, .offset = -86, .stride = 1, .upper = true},
          {.first = 0x1fcc, .last = 0x1fcc, .offset = -9, .stride = 1, .upper = true},
          {.first = 0x1fd8, .last = 0x1fd9, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1fda, .last = 0x1fdb, .offset = -100, .stride = 1, .upper = true},
          {.first = 0x1fe8, .last = 0x1fe9, .offset = -8, .stride = 1, .upper = true},
          {.first = 0x1fea, .last = 0x1feb, .offset = -112, .stride = 1, .upper = true},
          {.first = 0x1fec, .last = 0x1fec, .offset = -7, .stride = 1, .upper = true},
          {.first = 0x1ff8, .last = 0x1ff9, .offset = -128, .stride = 1, .upper = true},
          {.first = 0x1ffa, .last = 0x1ffb, .offset = -126, .stride = 1, .upper = true},
          {.first = 0x1ffc, .last = 0x1ffc, .offset = -9, .stride = 1, .upper = true},
          {.first = 0x2126, .last = 0x2126, .offset = -7517, .stride = 1, .upper = true},
          {.first = 0x212a, .last = 0x212a, .offset = -8383, .stride = 1, .upper = true},
          {.first = 0x212b, .last = 0x212b, .offset = -8262, .stride = 1, .upper = true},
          {.first = 0x2132, .last = 0x2132, .offset = 28, .stride = 1, .upper = true},
          {.first = 0x2160, .last = 0x216f, .offset = 16, .stride = 1, .upper = true},
          {.first = 0x2183, .last = 0x2183, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x24b6, .last = 0x24cf, .offset = 26, .stride = 1, .upper = true},
          {.first = 0x2c00, .last = 0x2c2f, .offset = 48, .stride = 1, .upper = true},
          {.first = 0x2c60, .last = 0x2c60, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x2c62, .last = 0x2c62, .offset = -10743, .stride = 1, .upper = true},
          {.first = 0x2c63, .last = 0x2c63, .offset = -3814, .stride = 1, .upper = true},
          {.first = 0x2c64, .last = 0x2c64, .offset = -10727, .stride = 1, .upper = true},
          {.first = 0x2c65, .last = 0x2c65, .offset = -10795, .stride = 1, .upper = false},
          {.first = 0x2c66, .last = 0x2c66, .offset = -10792, .stride = 1, .upper = false},
          {.first = 0x2c67, .last = 0x2c6b, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x2c6d, .last = 0x2c6d, .offset = -10780, .stride = 1, .upper = true},
          {.first = 0x2c6e, .last = 0x2c6e, .offset = -10749, .stride = 1, .upper = true},
          {.first = 0x2c6f, .last = 0x2c6f, .offset = -10783, .stride = 1, .upper = true},
          {.first = 0x2c70, .last = 0x2c70, .offset = -10782, .stride = 1, .upper = true},
          {.first = 0x2c72, .last = 0x2c72, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x2c75, .last = 0x2c75, .offset = 1, .stride = 1, .upper = true},
          {.first = 0x2c7e, .last = 0x2c7f, .offset = -10815, .stride = 1, .upper = true},
          {.first = 0x2c80, .last = 0x2ce2, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x2ceb, .last = 0x2ced, .offset = 1, .stride = 2, .upper = true},
          {.first = 0x2cf2, .last = 0x2cf2, .offset = 1, .stride = 1, .upper = true},
          {.first = 0xa640, .last = 0xa66c, .offset = 1, .stride = 2, .upper = true},
          {.first = 0xa680, .last = 0xa69a, .offset = 1, .stride = 2, .upper = true},
          {.first = 0xa722, .last = 0xa72e, .offset = 1, .stride = 2, .upper = true},
          {.first = 0xa732, .last = 0xa76e, .offset = 1, .stride = 2, .upper = true},
          {.first = 0xa779, .last = 0xa77b, .offset = 1, .stride = 2, .upper = true},
          {.first = 0xa77d, .last = 0xa77d, .offset = -35332, .stride = 1, .upper = true},
          {.first = 0xa77e, .last = 0xa786, .offset = 1, .stride = 2, .upper = true},
          {.first = 0xa78b, .last = 0xa78b, .offset = 1, .stride = 1, .upper = true},
          {.first = 0xa78d, .last = 0xa78d, .offset = -42280, .stride = 1, .upper = true},
          {.first = 0xa790, .last = 0xa792, .offset = 1, .stride = 2, .upper = true},
          {.first = 0xa796, .last = 0xa7a8, .offset = 1, .stride = 2, .upper = true},
          {.first = 0xa7aa, .last = 0xa7aa, .offset = -42308, .stride = 1, .upper = true},
          {.first = 0xa7ab, .last = 0xa7ab, .offset = -42319, .stride = 1, .upper = true},
          {.first = 0xa7ac, .last = 0xa7ac, .offset = -42315, .stride = 1, .upper = true},
          {.first = 0xa7ad, .last = 0xa7ad, .offset = -42305, .stride = 1, .upper = true},
          {.first = 0xa7ae, .last = 0xa7ae, .offset = -42308, .stride = 1, .upper = true},
          {.first = 0xa7b0, .last = 0xa7b0, .offset = -42258, .stride = 1, .upper = true},
          {.first = 0xa7b1, .last = 0xa7b1, .offset = -42282, .stride = 1, .upper = true},
          {.first = 0xa7b2, .last = 0xa7b2, .offset = -42261, .stride = 1, .upper = true},
          {.first = 0xa7b3, .last = 0xa7b3, .offset = 928, .stride = 1, .upper = true},
          {.first = 0xa7b4, .last = 0xa7c2, .offset = 1, .stride = 2, .upper = true},
          {.first = 0xa7c4, .last = 0xa7c4, .offset = -48, .stride = 1, .upper = true},
          {.first = 0xa7c5, .last = 0xa7c5, .offset = -42307, .stride = 1, .upper = true},
          {.first = 0xa7c6, .last = 0xa7c6, .offset = -35384, .stride = 1, .upper = true},
          {.first = 0xa7c7, .last = 0xa7c9, .offset = 1, .stride = 2, .upper = true},
          {.first = 0xa7d0, .last = 0xa7d0, .offset = 1, .stride = 1, .upper = true},
          {.first = 0xa7d6, .last = 0xa7d8, .offset = 1, .stride = 2, .upper = true},
          {.first = 0xa7f5, .last = 0xa7f5, .offset = 1, .stride = 1, .upper = true},
          {.first = 0xab70, .last = 0xabbf, .offset = -38864, .stride = 1, .upper = false},
          {.first = 0xff21, .last = 0xff3a, .offset = 32, .stride = 1, .upper = true},
          {.first = 0x10400, .last = 0x10427, .offset = 40, .stride = 1, .upper = true},
          {.first = 0x104b0, .last = 0x104d3, .offset = 40, .stride = 1, .upper = true},
          {.first = 0x10570, .last = 0x1057a, .offset = 39, .stride = 1, .upper = true},
          {.first = 0x1057c, .last = 0x1058a, .offset = 39, .stride = 1, .upper = true},
          {.first = 0x1058c, .last = 0x10592, .offset = 39, .stride = 1, .upper = true},
          {.first = 0x10594, .last = 0x10595, .offset = 39, .stride = 1, .upper = true},
          {.first = 0x10c80, .last = 0x10cb2, .offset = 64, .stride = 1, .upper = true},
          {.first = 0x118a0, .last = 0x118bf, .offset = 32, .stride = 1, .upper = true},
          {.first = 0x16e40, .last = 0x16e5f, .offset = 32, .stride = 1, .upper = true},
          {.first = 0x1e900, .last = 0x1e921, .offset = 34, .stride = 1, .upper = true},
      },
  };

  // The fold of a character and whether it is a capital, packed as (offset + bias) * 2 +
  // capital; the bias keeps every offset positive.
  using PackedFold = std::uint32_t;

  inline constexpr std::int32_t fold_bias = 1'048'576;

  constexpr PackedFold pack(const FoldEntry& entry) noexcept {
    return (static_cast<PackedFold>(entry.offset + fold_bias) << 1U) | (entry.upper ? 1U : 0U);
  }

  constexpr bool covers(const FoldEntry& entry, std::uint32_t character) noexcept {
    return character >= entry.first && character <= entry.last && (character - entry.first) % entry.stride == 0;
  }

  // The Basic Multilingual Plane in pages of 256 characters: a page no entry reaches shares the
  // first, which folds nothing, so a lookup is two reads with no branch.
  inline constexpr std::size_t page_bits = 8;
  inline constexpr std::size_t page_size = std::size_t{1} << page_bits;
  inline constexpr std::size_t plane_pages = 0x10000 / page_size;
  inline constexpr std::uint32_t first_supplementary = 0x10000;

  constexpr std::size_t foldPageCount() noexcept {
    std::size_t count = 1;
    std::size_t previous = plane_pages;

    // The entries are in order, so each page they reach comes after the one before.
    for (const auto& entry : fold_entries) {
      for (auto page = entry.first >> page_bits; page <= (entry.last >> page_bits) && page < plane_pages; ++page) {
        if (page != previous) {
          ++count;
          previous = page;
        }
      }
    }

    return count;
  }

  struct FoldPages {
    ds::Array<std::uint8_t, plane_pages> page_of;
    ds::Array<ds::Array<PackedFold, page_size>, foldPageCount()> pages;
  };

  constexpr FoldPages buildFoldPages() noexcept {
    FoldPages table{};
    std::size_t used = 1;

    // A character no entry reaches folds to itself.
    for (auto& page : table.pages.viewMut()) {
      page.fill(pack({.first = 0, .last = 0, .offset = 0, .stride = 1, .upper = false}));
    }

    for (const auto& entry : fold_entries) {
      for (auto character = entry.first; character <= entry.last && character < first_supplementary; character += entry.stride) {
        const auto page = character >> page_bits;

        if (table.page_of[page] == 0) {
          table.page_of.atMut(page) = static_cast<std::uint8_t>(used++);
        }

        table.pages.atMut(table.page_of[page]).atMut(character & (page_size - 1)) = pack(entry);
      }
    }

    return table;
  }

  inline constexpr FoldPages fold_pages = buildFoldPages();

  // The first entry past the plane, where a lookup of a supplementary character starts.
  inline constexpr std::size_t first_supplementary_entry = static_cast<std::size_t>(
      std::ranges::find_if(fold_entries, [](const FoldEntry& entry) {
        return entry.first >= first_supplementary;
      }) -
      fold_entries.begin()
  );

  struct Folded {
    std::uint32_t character;
    bool upper;
  };

  constexpr Folded unpack(std::uint32_t character, PackedFold packed) noexcept {
    const auto offset = static_cast<std::int32_t>(packed >> 1U) - fold_bias;

    return {.character = static_cast<std::uint32_t>(static_cast<std::int32_t>(character) + offset), .upper = (packed & 1U) != 0};
  }

  // `character` folded, and whether it is a capital. A byte outside Unicode is itself.
  constexpr Folded fold(std::uint32_t character) noexcept {
    constexpr std::uint32_t small_letter_offset = 'a' - 'A';

    if (character < first_non_ascii) {
      const bool upper = character >= 'A' && character <= 'Z';

      return {.character = upper ? character + small_letter_offset : character, .upper = upper};
    }

    if (character < first_supplementary) {
      return unpack(character, fold_pages.pages[fold_pages.page_of[character >> page_bits]][character & (page_size - 1)]);
    }

    const auto entries = fold_entries.view().subspan(first_supplementary_entry);
    const auto after = std::ranges::upper_bound(entries, character, {}, &FoldEntry::first);

    if (after == entries.begin() || !covers(*std::prev(after), character)) {
      return {.character = character, .upper = false};
    }

    return unpack(character, pack(*std::prev(after)));
  }

  // The latin letter a character carries a diacritic on, in its case, or 0: Latin-1, Latin
  // Extended-A and -B and Latin Extended Additional, from their decompositions and, for the
  // letters with a stroke, a bar or a hook that decompose to nothing, from their names.
  inline constexpr std::string_view latin_letters =
      "AAAAAA.CEEEEIIII.NOOOOO.OUUUUY..aaaaaa.ceeeeiiii.nooooo.ouuuuy.y"
      "AaAaAaCcCcCcCcDdDdEeEeEeEeEeGgGgGgGgHhHhIiIiIiIiIi..JjKk.LlLlLlL"
      "lLlNnNnNn...OoOoOo..RrRrRrSsSsSsSsTtTtTtUuUuUuUuUuUuWwYyYZzZzZz."
      "bBBb...Cc.DDd....FfG...IKkl..NnOOo..Pp.....tTtTUu.VYyZz........."
      ".....D..L..N.AaIiOoUuUuUuUuUu.AaAa..GgGgKkOoOo..j.D.Gg..NnAa..Oo"
      "AaAaEeEeIiIiOoOoRrRrUuUuSsTt..HhNd..ZzAaEeOoOoOoOoYylntj..ACcLTs"
      "z..B..EeJj.qRrYy";
  inline constexpr std::uint32_t first_latin = 0xc0;
  inline constexpr std::string_view latin_additional_letters =
      "AaBbBbBbCcDdDdDdDdDdEeEeEeEeEeFfGgHhHhHhHhHhIiIiKkKkKkLlLlLlLlMm"
      "MmMmNnNnNnNnOoOoOoOoPpPpRrRrRrRrSsSsSsSsSsTtTtTtTtUuUuUuUuUuVvVv"
      "WwWwWwWwWwXxXxYyZzZzZzhtwya.....AaAaAaAaAaAaAaAaAaAaAaAaEeEeEeEe"
      "EeEeEeEeIiIiOoOoOoOoOoOoOoOoOoOoOoOoUuUuUuUuUuUuUuYyYyYyYy....Yy";
  inline constexpr std::uint32_t first_latin_additional = 0x1e00;

  inline constexpr std::uint32_t past_latin = 0x250;
  inline constexpr std::uint32_t past_latin_additional = 0x1f00;

  static_assert(latin_letters.size() == past_latin - first_latin);
  static_assert(latin_additional_letters.size() == past_latin_additional - first_latin_additional);

  // `character` without its diacritic: the latin letter it carries one on, or itself.
  constexpr std::uint32_t unaccent(std::uint32_t character) noexcept {
    constexpr char none = '.';
    char letter = none;

    if (character >= first_latin && character - first_latin < latin_letters.size()) {
      letter = latin_letters[character - first_latin];
    } else if (character >= first_latin_additional && character - first_latin_additional < latin_additional_letters.size()) {
      letter = latin_additional_letters[character - first_latin_additional];
    }

    return letter == none ? character : static_cast<std::uint32_t>(letter);
  }

  // What a character is to the bonus of the one after it, as fzf classes them: a match right
  // after a space, a delimiter or another character that is no part of a word starts one.
  enum class CharacterClass : std::uint8_t {
    white,
    non_word,
    delimiter,
    lower,
    upper,
    letter,
    number,
  };

  inline constexpr std::size_t character_classes = 7;

  inline constexpr ds::Array<CharacterClass, first_non_ascii> ascii_classes = [] {
    constexpr std::string_view white = " \t\n\v\f\r";
    constexpr std::string_view delimiters = "/,:;|";
    ds::Array<CharacterClass, first_non_ascii> classes{};

    for (std::uint32_t character = 0; character < first_non_ascii; ++character) {
      auto& entry = classes.atMut(character);
      const auto byte = static_cast<char>(character);

      if (white.contains(byte)) {
        entry = CharacterClass::white;
      } else if (delimiters.contains(byte)) {
        entry = CharacterClass::delimiter;
      } else if (byte >= 'a' && byte <= 'z') {
        entry = CharacterClass::lower;
      } else if (byte >= 'A' && byte <= 'Z') {
        entry = CharacterClass::upper;
      } else if (byte >= '0' && byte <= '9') {
        entry = CharacterClass::number;
      } else {
        entry = CharacterClass::non_word;
      }
    }

    return classes;
  }();

  // A character past ASCII, without Unicode's property tables: its spaces and the punctuation
  // of Latin-1, general punctuation and CJK are no part of a word, the fullwidth forms are what
  // ASCII's are, a character the fold changes is a capital, the letters of the scripts below
  // Armenian's end are small, and the rest are letters. A byte outside Unicode is no part of a
  // word.
  constexpr CharacterClass classOf(std::uint32_t character) noexcept {
    struct Span {
      std::uint32_t first;
      std::uint32_t last;
      CharacterClass value;
    };

    constexpr ds::Array<Span, 16> spans{
        {
            {.first = 0x85, .last = 0x85, .value = CharacterClass::white},
            {.first = 0xa0, .last = 0xa0, .value = CharacterClass::white},
            {.first = 0x80, .last = 0xa9, .value = CharacterClass::non_word},
            {.first = 0xab, .last = 0xb4, .value = CharacterClass::non_word},
            {.first = 0xb6, .last = 0xb9, .value = CharacterClass::non_word},
            {.first = 0xbb, .last = 0xbf, .value = CharacterClass::non_word},
            {.first = 0xd7, .last = 0xd7, .value = CharacterClass::non_word},
            {.first = 0xf7, .last = 0xf7, .value = CharacterClass::non_word},
            {.first = 0x1680, .last = 0x1680, .value = CharacterClass::white},
            {.first = 0x2000, .last = 0x200a, .value = CharacterClass::white},
            {.first = 0x2028, .last = 0x2029, .value = CharacterClass::white},
            {.first = 0x202f, .last = 0x202f, .value = CharacterClass::white},
            {.first = 0x205f, .last = 0x205f, .value = CharacterClass::white},
            {.first = 0x2010, .last = 0x205e, .value = CharacterClass::non_word},
            {.first = 0x3000, .last = 0x3000, .value = CharacterClass::white},
            {.first = 0x3001, .last = 0x303f, .value = CharacterClass::non_word},
        },
    };

    constexpr std::uint32_t first_fullwidth = 0xff01;
    constexpr std::uint32_t last_fullwidth_ascii = 0xff5e;
    constexpr std::uint32_t last_fullwidth_punctuation = 0xff65;
    constexpr std::uint32_t last_small_script = 0x52f;

    if (character < first_non_ascii) {
      return ascii_classes[character];
    }

    if (character >= outside) {
      return CharacterClass::non_word;
    }

    for (const auto& span : spans) {
      if (character >= span.first && character <= span.last) {
        return span.value;
      }
    }

    // The fullwidth forms are ASCII's, a delimiter among them no part of a word.
    if (character >= first_fullwidth && character <= last_fullwidth_punctuation) {
      const auto ascii = character <= last_fullwidth_ascii ? ascii_classes[character - first_fullwidth + '!'] : CharacterClass::non_word;

      return ascii == CharacterClass::delimiter ? CharacterClass::non_word : ascii;
    }

    if (fold(character).upper) {
      return CharacterClass::upper;
    }

    return character <= last_small_script ? CharacterClass::lower : CharacterClass::letter;
  }

}
