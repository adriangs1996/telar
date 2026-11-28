module telar.base.history;

import std;
import telar.base.ds;
import :text;

// fzf's FuzzyMatchV2 (src/algo/algo.go) with its history scheme, and the term matchers of its
// extended search. The scores, the bonuses and the backtrace are fzf's, so a query ranks as it
// does there; what differs is where the work goes: a byte path for ASCII commands, a prefilter
// that rejects in one scan and bounds each row of the matrix to the columns that can still lead
// to a whole match, and short patterns scored in one pass without a matrix.
namespace telar::runtime {

  namespace {

    using history_text::CharacterClass;
    using Characters = std::span<const std::uint32_t>;

    constexpr std::int16_t score_match = 16;
    constexpr std::int16_t score_gap_start = -3;
    constexpr std::int16_t score_gap_extension = -1;
    constexpr std::int16_t bonus_boundary = score_match / 2;
    constexpr std::int16_t bonus_non_word = score_match / 2;
    constexpr std::int16_t bonus_camel = bonus_boundary + score_gap_extension;
    constexpr std::int16_t bonus_consecutive = -(score_gap_start + score_gap_extension);
    constexpr std::int16_t first_character_multiplier = 2;
    // The history scheme: a word after a space or a delimiter earns what any other boundary does,
    // as a command line has no path or file name to favour.
    constexpr std::int16_t bonus_boundary_white = bonus_boundary;
    constexpr std::int16_t bonus_boundary_delimiter = bonus_boundary;
    constexpr CharacterClass initial_class = CharacterClass::white;

    // What a fuzzy term must score per character to be a match: a term whose characters lie
    // farther apart than about eight on average, none on a word's start, is noise. A match
    // scores 16 per character and every bonus adds to that, so any run of two or more and
    // anything on word starts passes.
    constexpr std::int32_t quality_floor = 8;
    // A substring term that starts the command, 2^20: above any score that does not.
    constexpr std::int32_t prefix_rank = 1'048'576;

    constexpr std::size_t classIndex(CharacterClass value) noexcept {
      return static_cast<std::size_t>(value);
    }

    // What a word character earns after `previous`, which starts the word unless it is part of
    // one.
    constexpr std::int16_t boundaryBonus(CharacterClass previous) noexcept {
      switch (previous) {
      case CharacterClass::white:
        return bonus_boundary_white;
      case CharacterClass::delimiter:
        return bonus_boundary_delimiter;
      case CharacterClass::non_word:
        return bonus_boundary;
      case CharacterClass::lower:
      case CharacterClass::upper:
      case CharacterClass::letter:
      case CharacterClass::number:
        return 0;
      }

      return 0;
    }

    constexpr std::int16_t bonusFor(CharacterClass previous, CharacterClass current) noexcept {
      if (current > CharacterClass::non_word && boundaryBonus(previous) != 0) {
        return boundaryBonus(previous);
      }

      // camelCase and letter123.
      if ((previous == CharacterClass::lower && current == CharacterClass::upper) || (previous != CharacterClass::number && current == CharacterClass::number)) {
        return bonus_camel;
      }

      switch (current) {
      case CharacterClass::non_word:
      case CharacterClass::delimiter:
        return bonus_non_word;
      case CharacterClass::white:
        return bonus_boundary_white;
      case CharacterClass::lower:
      case CharacterClass::upper:
      case CharacterClass::letter:
      case CharacterClass::number:
        return 0;
      }

      return 0;
    }

    using BonusRow = ds::Array<std::uint8_t, history_text::character_classes>;

    constexpr ds::Array<BonusRow, history_text::character_classes> bonus_matrix = [] {
      ds::Array<BonusRow, history_text::character_classes> matrix{};

      for (std::size_t previous = 0; previous < history_text::character_classes; ++previous) {
        for (std::size_t current = 0; current < history_text::character_classes; ++current) {
          matrix.atMut(previous).atMut(current) = static_cast<std::uint8_t>(bonusFor(static_cast<CharacterClass>(previous), static_cast<CharacterClass>(current)));
        }
      }

      return matrix;
    }();

    inline std::int16_t bonusAt(CharacterClass previous, CharacterClass current) noexcept {
      return bonus_matrix[classIndex(previous)][classIndex(current)];
    }

    constexpr bool isWhite(std::uint32_t character) noexcept {
      return history_text::classOf(character) == CharacterClass::white;
    }

#if defined(__SSE2__) || (defined(__aarch64__) && defined(__AARCH64EL__))
    constexpr bool vector_search = true;
#else
    constexpr bool vector_search = false;
#endif

    constexpr std::size_t vector_width = 16;
    using Bytes = std::uint8_t __attribute__((ext_vector_type(vector_width)));
    using Chunk = ds::Array<char, vector_width>;

#if defined(__aarch64__) && defined(__AARCH64EL__)
    // NEON has no byte mask: four bits a byte, by narrowing each pair of bytes.
    constexpr unsigned mask_bits = 4;

    inline std::uint64_t byteMask(Bytes matches) noexcept {
      using Halves = std::uint16_t __attribute__((ext_vector_type(vector_width / 2)));
      using Narrow = std::uint8_t __attribute__((ext_vector_type(vector_width / 2)));

      return __builtin_bit_cast(std::uint64_t, __builtin_convertvector(__builtin_bit_cast(Halves, matches) >> mask_bits, Narrow));
    }
#else
    constexpr unsigned mask_bits = 1;

    inline std::uint64_t byteMask(Bytes matches) noexcept {
      using Mask = bool __attribute__((ext_vector_type(vector_width)));

      return __builtin_bit_cast(std::uint16_t, __builtin_convertvector(matches, Mask));
    }
#endif

    // Two bytes a search looks for at once: a letter in both its cases.
    struct BytePair {
      char one;
      char other;
    };

    // A bit, or four, for each of sixteen bytes that is either of `pair`: SSE2's pcmpeqb and
    // pmovmskb, NEON's cmeq and shrn, through the compiler's vectors. The copy is one load.
    inline std::uint64_t matchMask(std::span<const char> bytes, BytePair pair) noexcept {
      Chunk chunk;

      std::ranges::copy_n(bytes.begin(), vector_width, chunk.dataMut());

      const auto loaded = __builtin_bit_cast(Bytes, chunk);
      const auto one = static_cast<std::uint8_t>(pair.one);
      const auto other = static_cast<std::uint8_t>(pair.other);

      return byteMask(__builtin_bit_cast(Bytes, (loaded == one) | (loaded == other)));
    }

    // Where either of `pair` first is in bytes[from, size), sixteen bytes at a time; where the
    // scalar search goes on from, when it found none.
    std::size_t findVector(std::span<const char> bytes, std::size_t from, BytePair pair, bool& found) noexcept {
      for (; bytes.size() - from >= vector_width; from += vector_width) {
        const auto mask = matchMask(bytes.subspan(from, vector_width), pair);
        if (mask != 0) {
          found = true;
          return from + (static_cast<std::size_t>(std::countr_zero(mask)) / mask_bits);
        }
      }

      return from;
    }

    // Where either of `pair` last is in bytes[from, before), sixteen bytes at a time; where the
    // scalar search goes on from, when it found none.
    std::size_t findLastVector(std::span<const char> bytes, std::size_t from, std::size_t before, BytePair pair, bool& found) noexcept {
      for (; before - from >= vector_width; before -= vector_width) {
        const auto mask = matchMask(bytes.subspan(before - vector_width, vector_width), pair);
        if (mask != 0) {
          found = true;
          return before - vector_width + ((static_cast<std::size_t>(std::bit_width(mask)) - 1) / mask_bits);
        }
      }

      return before;
    }

    // Where either of `pair` first is in bytes[from, size), or size; with `vector`, sixteen bytes
    // at a time where the machine compares them at once.
    std::size_t findByte(std::span<const char> bytes, std::size_t from, BytePair pair, bool vector) noexcept {
      bool found = false;

      if (vector_search && vector) {
        from = findVector(bytes, from, pair, found);
        if (found) {
          return from;
        }
      }

      for (; from < bytes.size(); ++from) {
        if (bytes[from] == pair.one || bytes[from] == pair.other) {
          return from;
        }
      }

      return bytes.size();
    }

    // Where either of `pair` last is in bytes[from, before), or npos.
    std::size_t findLastByte(std::span<const char> bytes, std::size_t from, std::size_t before, BytePair pair, bool vector) noexcept {
      bool found = false;

      if (vector_search && vector) {
        before = findLastVector(bytes, from, before, pair, found);
        if (found) {
          return before;
        }
      }

      while (before > from) {
        --before;
        if (bytes[before] == pair.one || bytes[before] == pair.other) {
          return before;
        }
      }

      return std::string_view::npos;
    }

    // An ASCII command, read a byte a character: a case insensitive term looks for a letter in
    // both its cases at once.
    struct ByteText {
      std::span<const char> bytes;
      bool fold = false;
      bool vector = true;

      [[nodiscard]] std::size_t size() const noexcept {
        return bytes.size();
      }

      [[nodiscard]] std::uint32_t key(std::size_t index) const noexcept {
        const auto byte = static_cast<unsigned char>(bytes[index]);

        return fold ? asciiLower(byte) : byte;
      }

      [[nodiscard]] CharacterClass classAt(std::size_t index) const noexcept {
        return history_text::ascii_classes[static_cast<unsigned char>(bytes[index])];
      }

      [[nodiscard]] BytePair cases(std::uint32_t key) const noexcept {
        const auto byte = static_cast<char>(key);
        const bool letter = fold && byte >= 'a' && byte <= 'z';

        return {.one = byte, .other = letter ? static_cast<char>(byte - ('a' - 'A')) : byte};
      }

      // NOLINTNEXTLINE(bugprone-easily-swappable-parameters): a key and a position, as every find takes them
      [[nodiscard]] std::size_t find(std::uint32_t key, std::size_t from) const noexcept {
        if (key >= history_text::first_non_ascii) {
          return size();
        }

        return findByte(bytes, from, cases(key), vector);
      }

      // NOLINTNEXTLINE(bugprone-easily-swappable-parameters): a key and the bounds of where it is looked for
      [[nodiscard]] std::size_t findLast(std::uint32_t key, std::size_t from, std::size_t before) const noexcept {
        return findLastByte(bytes, from, before, cases(key), vector);
      }
    };

    // A command past ASCII, decoded into the arena, with one term's keys over its characters.
    struct RuneText {
      std::span<const std::uint32_t> keys;
      std::span<const std::uint8_t> classes;

      [[nodiscard]] std::size_t size() const noexcept {
        return keys.size();
      }

      [[nodiscard]] std::uint32_t key(std::size_t index) const noexcept {
        return keys[index];
      }

      [[nodiscard]] CharacterClass classAt(std::size_t index) const noexcept {
        return static_cast<CharacterClass>(classes[index]);
      }

      // NOLINTNEXTLINE(bugprone-easily-swappable-parameters): a key and a position, as every find takes them
      [[nodiscard]] std::size_t find(std::uint32_t key, std::size_t from) const noexcept {
        const auto rest = keys.subspan(from);

        return from + static_cast<std::size_t>(std::ranges::find(rest, key) - rest.begin());
      }

      // NOLINTNEXTLINE(bugprone-easily-swappable-parameters): a key and the bounds of where it is looked for
      [[nodiscard]] std::size_t findLast(std::uint32_t key, std::size_t from, std::size_t before) const noexcept {
        while (before > from) {
          --before;
          if (keys[before] == key) {
            return before;
          }
        }

        return std::string_view::npos;
      }
    };

    // The characters a match covers, as [begin, end) of character indices, in the arena.
    class Marks {
    public:
      explicit Marks(std::span<HistoryMatchRange> storage) noexcept
          : storage_(storage) {}

      void add(std::size_t begin, std::size_t end) noexcept {
        if (count_ < storage_.size()) {
          storage_[count_++] = {.begin = static_cast<std::uint32_t>(begin), .end = static_cast<std::uint32_t>(end)};
        }
      }

      [[nodiscard]] std::span<HistoryMatchRange> marked() const noexcept {
        return storage_.first(count_);
      }

    private:
      std::span<HistoryMatchRange> storage_;
      std::size_t count_ = 0;
    };

    // The arena's matrices and rows, as one fuzzy term uses them.
    struct Workspace {
      std::span<std::uint8_t> bonuses;
      std::span<std::int16_t> scores;
      std::span<std::int16_t> runs;
      std::span<std::uint32_t> row_first;
      std::span<std::uint32_t> row_last;
      std::span<std::uint32_t> row_cells;
      bool fast = true;
      bool floor = true;
    };

    template <typename Text>
    std::int16_t bonusOf(Text text, std::size_t index) noexcept {
      return bonusAt(index == 0 ? initial_class : text.classAt(index - 1), text.classAt(index));
    }

    // The bonus of a match that a run of `consecutive` before it leads to, as fzf's
    // calculateScore weighs it; `first_bonus` is what the run's first character earned, and a
    // boundary inside the run starts a chunk of its own.
    inline std::int16_t runBonus(std::int16_t bonus, std::int16_t& first_bonus, std::int16_t consecutive) noexcept {
      if (consecutive == 0) {
        first_bonus = bonus;
        return bonus;
      }

      if (bonus >= bonus_boundary && bonus > first_bonus) {
        first_bonus = bonus;
      }

      return std::max({bonus, first_bonus, bonus_consecutive});
    }

    // fzf's calculateScore: `pattern` matched greedily over text[first, end), where it is known
    // to match.
    template <typename Text>
    std::int32_t calculateScore(Text text, Characters pattern, std::size_t first, std::size_t end, Marks* marks) noexcept {
      std::size_t matched = 0;
      std::int32_t score = 0;
      bool in_gap = false;
      std::int16_t consecutive = 0;
      std::int16_t first_bonus = 0;
      auto previous = first == 0 ? initial_class : text.classAt(first - 1);

      for (auto index = first; index < end; ++index) {
        const auto current = text.classAt(index);

        if (matched < pattern.size() && text.key(index) == pattern[matched]) {
          const auto bonus = runBonus(bonusAt(previous, current), first_bonus, consecutive);

          if (marks != nullptr) {
            marks->add(index, index + 1);
          }

          score += score_match + (matched == 0 ? bonus * first_character_multiplier : bonus);
          in_gap = false;
          ++consecutive;
          ++matched;
        } else {
          score += in_gap ? score_gap_extension : score_gap_start;
          in_gap = true;
          consecutive = 0;
          first_bonus = 0;
        }

        previous = current;
      }

      return score;
    }

    // fzf's FuzzyMatchV1, for a window too large for the arena: the first match, narrowed from
    // its end to the latest start, scored as it lies. `first` holds the pattern's greedy first
    // occurrences.
    template <typename Text>
    std::int32_t fuzzyGreedy(Text text, Characters pattern, std::span<const std::uint32_t> first, Marks* marks) noexcept {
      const std::size_t end = first[pattern.size() - 1] + 1;
      std::size_t start = first[0];
      std::size_t wanted = pattern.size() - 1;

      for (auto index = end; index-- > first[0];) {
        if (text.key(index) != pattern[wanted]) {
          continue;
        }

        if (wanted == 0) {
          start = index;
          break;
        }

        --wanted;
      }

      return calculateScore(text, pattern, start, end, marks);
    }

    // A one character pattern: its occurrence with the best bonus, the first of them; no
    // occurrence earns more than a boundary, so the first on one ends the search.
    template <typename Text>
    std::int32_t oneCharacter(Text text, std::uint32_t key, std::size_t first, Marks* marks) noexcept {
      std::int32_t best = -1;
      std::size_t best_at = first;

      for (auto index = first; index < text.size(); index = text.find(key, index + 1)) {
        const auto bonus = bonusOf(text, index);
        const std::int32_t score = score_match + (bonus * first_character_multiplier);

        if (score > best) {
          best = score;
          best_at = index;
          if (bonus >= bonus_boundary) {
            break;
          }
        }
      }

      if (marks != nullptr) {
        marks->add(best_at, best_at + 1);
      }

      return best;
    }

    // One cell of the matrix: its score, the run of consecutive matches it ends, and whether
    // the cell after it extends a gap.
    struct Cell {
      std::int16_t score = 0;
      std::int16_t run = 0;
      bool in_gap = false;
    };

    // What a match in a row past the first reads of its neighbours: the cell before it in the
    // row above, the bonus it earns, and the bonus of the character that starts the run it
    // would extend.
    struct Diagonal {
      Cell above;
      std::int16_t bonus = 0;
      std::int16_t run_bonus = 0;
    };

    // The cell after `left` in the first row: a match scores afresh, with the first character's
    // double bonus; anything else extends the gap.
    inline Cell firstRowCell(Cell left, bool matches, std::int16_t bonus) noexcept {
      if (matches) {
        return {.score = static_cast<std::int16_t>(score_match + (bonus * first_character_multiplier)), .run = 1};
      }

      const auto gap = static_cast<std::int16_t>(left.score + (left.in_gap ? score_gap_extension : score_gap_start));

      return {.score = std::max(gap, std::int16_t{0}), .in_gap = true};
    }

    // The cell after `left` in a row past the first, as fzf's phase 2 scores it: the gap from
    // `left`, or, when its character matches, the match from `diagonal`, whichever scores more.
    inline Cell nextCell(Cell left, const Diagonal* diagonal) noexcept {
      const auto gap = static_cast<std::int16_t>(left.score + (left.in_gap ? score_gap_extension : score_gap_start));

      if (diagonal == nullptr) {
        return {.score = std::max(gap, std::int16_t{0}), .in_gap = 0 < gap};
      }

      auto run = static_cast<std::int16_t>(diagonal->above.run + 1);
      auto earned = diagonal->bonus;

      if (run > 1) {
        // A boundary inside a run starts a chunk of its own.
        if (earned >= bonus_boundary && earned > diagonal->run_bonus) {
          run = 1;
        } else {
          earned = std::max({earned, bonus_consecutive, diagonal->run_bonus});
        }
      }

      auto score = static_cast<std::int16_t>(diagonal->above.score + score_match);

      if (score + earned < gap) {
        score = static_cast<std::int16_t>(score + diagonal->bonus);
        run = 0;
      } else {
        score = static_cast<std::int16_t>(score + earned);
      }

      return {.score = std::max({score, gap, std::int16_t{0}}), .run = run, .in_gap = score < gap};
    }

    // Where a pattern of two characters may lie: from the first's first occurrence, the
    // second's first after it, to the second's last.
    struct PairWindow {
      std::size_t first0;
      std::size_t first1;
      std::size_t last1;
    };

    // A two character pattern, scored as the matrix scores it but in one pass that keeps only
    // the cell to the left in each row: row 0 spans [first0, last1 - 1], row 1 [first1, last1].
    // Never asked for the cells it covers, which need the matrix's backtrace.
    template <typename Text>
    std::int32_t twoCharacters(Text text, Characters pattern, PairWindow window) noexcept {
      Cell above;
      Cell left;
      std::int16_t best = 0;
      std::int16_t previous_bonus = 0;
      auto previous = window.first0 == 0 ? initial_class : text.classAt(window.first0 - 1);

      for (auto index = window.first0; index <= window.last1; ++index) {
        const auto current = text.classAt(index);
        const auto bonus = bonusAt(previous, current);
        const auto key = text.key(index);

        if (index >= window.first1) {
          const Diagonal diagonal{.above = above, .bonus = bonus, .run_bonus = previous_bonus};

          left = nextCell(left, key == pattern[1] ? &diagonal : nullptr);
          best = std::max(best, left.score);
        }

        if (index < window.last1) {
          above = firstRowCell(above, key == pattern[0], bonus);
        }

        previous_bonus = bonus;
        previous = current;
      }

      return best;
    }

    // The best cell of a row, the first of them.
    struct Best {
      std::int16_t score = 0;
      std::size_t at = 0;
    };

    // One row of the matrix in spans of its own, as fzf slices its rows, so that its loop keeps
    // its bounds and its neighbours in registers. `above` starts at the column before the row's
    // first; `bonuses` are the window's, which starts at column `window`.
    struct Row {
      std::size_t begin = 0;
      std::span<std::int16_t> scores;
      std::span<std::int16_t> runs;
      std::span<const std::int16_t> above_scores;
      std::span<const std::int16_t> above_runs;
      std::span<const std::uint8_t> bonuses;
      std::size_t window = 0;
    };

    template <typename Text>
    Best firstRow(Text text, std::uint32_t wanted, const Row& row) noexcept {
      const auto row_bonuses = row.bonuses.subspan(row.begin - row.window, row.scores.size());
      Cell cell;
      Best best;

      for (std::size_t offset = 0; offset < row.scores.size(); ++offset) {
        cell = firstRowCell(cell, text.key(row.begin + offset) == wanted, row_bonuses[offset]);
        row.scores[offset] = cell.score;
        row.runs[offset] = cell.run;
        if (cell.score > best.score) {
          best = {.score = cell.score, .at = row.begin + offset};
        }
      }

      return best;
    }

    template <typename Text>
    Best nextRow(Text text, std::uint32_t wanted, const Row& row) noexcept {
      const auto start = row.begin - row.window;
      const auto row_bonuses = row.bonuses.subspan(start, row.scores.size());
      Cell cell;
      Best best;

      for (std::size_t offset = 0; offset < row.scores.size(); ++offset) {
        if (text.key(row.begin + offset) == wanted) {
          const auto above_run = row.above_runs[offset];
          const Diagonal diagonal{
              .above = {.score = row.above_scores[offset], .run = above_run},
              .bonus = row_bonuses[offset],
              .run_bonus = row.bonuses[start + offset - static_cast<std::size_t>(above_run)],
          };

          cell = nextCell(cell, &diagonal);
        } else {
          cell = nextCell(cell, nullptr);
        }

        row.scores[offset] = cell.score;
        row.runs[offset] = cell.run;
        if (cell.score > best.score) {
          best = {.score = cell.score, .at = row.begin + offset};
        }
      }

      return best;
    }

    // The banded matrix of one fuzzy term: row i spans [first[i], end(i)], its cells from
    // cells[i] on.
    struct Matrix {
      std::span<const std::uint32_t> first;
      std::span<const std::uint32_t> last;
      std::span<const std::uint32_t> cells;
      std::span<const std::int16_t> scores;
      std::span<const std::int16_t> runs;

      [[nodiscard]] std::size_t end(std::size_t row) const noexcept {
        return row + 1 == first.size() ? last[row] : last[row + 1] - 1;
      }

      [[nodiscard]] bool covers(std::size_t row, std::size_t column) const noexcept {
        return row < first.size() && column >= first[row] && column <= end(row);
      }

      [[nodiscard]] std::size_t cell(std::size_t row, std::size_t column) const noexcept {
        return cells[row] + (column - first[row]);
      }
    };

    // fzf's backtrace: from the best cell of the last row, left and up along the cells whose
    // score a match there explains, preferring a match that continues a run.
    template <typename Text>
    void backtrace(Text text, Characters pattern, const Matrix& matrix, std::size_t best_at, Marks& marks) noexcept {
      std::size_t row = pattern.size() - 1;
      std::size_t column = best_at;
      bool prefer = true;

      while (column >= matrix.first[row]) {
        const auto cell_at = matrix.cell(row, column);
        const auto here = matrix.scores[cell_at];
        const std::int16_t diagonal = row > 0 ? matrix.scores[matrix.cell(row - 1, column - 1)] : 0;
        const std::int16_t left = column > matrix.first[row] ? matrix.scores[cell_at - 1] : 0;
        const auto below = row + 1;
        const bool matches = text.key(column) == pattern[row] && here > diagonal && (here > left || (here == left && prefer));

        if (matches) {
          marks.add(column, column + 1);
          if (row == 0) {
            return;
          }

          --row;
        }

        prefer = matrix.runs[cell_at] > 1 || (matrix.covers(below, column + 1) && matrix.runs[matrix.cell(below, column + 1)] > 0);
        if (column == 0) {
          return;
        }

        --column;
      }
    }

    template <typename Text>
    void fillBonuses(Text text, std::size_t window, std::span<std::uint8_t> bonuses) noexcept {
      auto previous = window == 0 ? initial_class : text.classAt(window - 1);

      for (std::size_t offset = 0; offset < bonuses.size(); ++offset) {
        const auto current = text.classAt(window + offset);

        bonuses[offset] = static_cast<std::uint8_t>(bonusAt(previous, current));
        previous = current;
      }
    }

    // A score, or none under the quality floor of a pattern of `length` characters.
    inline ds::Option<std::int32_t> passing(std::int32_t score, std::size_t length, bool floor) noexcept {
      if (floor && score < quality_floor * static_cast<std::int32_t>(length)) {
        return ds::none;
      }

      return score;
    }

    // The matrix, once the prefilter found every character of the pattern in order: `first`
    // and `last` hold where each row starts and where the next can still follow. Out of line,
    // so that the prefilter, which rejects most commands, stays a small function. Row i is
    // banded to [first occurrence of pattern[i] after row i - 1's, last occurrence of
    // pattern[i + 1] that the rest of the pattern can still follow, minus one]: a cell outside
    // reaches no whole match.
    template <typename Text>
    [[gnu::noinline]] ds::Option<std::int32_t> fuzzyMatrix(Text text, Characters pattern, const Workspace& work, Marks* marks) noexcept {
      const auto length = pattern.size();
      const Matrix matrix{
          .first = work.row_first.first(length),
          .last = work.row_last.first(length),
          .cells = work.row_cells.first(length),
          .scores = work.scores,
          .runs = work.runs,
      };

      const std::size_t window = matrix.first[0];
      const std::size_t width = matrix.last[length - 1] - window + 1;
      std::size_t cells = 0;

      for (std::size_t row = 0; row < length && cells <= work.scores.size(); ++row) {
        work.row_cells[row] = static_cast<std::uint32_t>(cells);
        cells += matrix.end(row) - matrix.first[row] + 1;
      }

      if (width > work.bonuses.size() || cells > work.scores.size()) {
        return passing(fuzzyGreedy(text, pattern, matrix.first, marks), length, work.floor);
      }

      fillBonuses(text, window, work.bonuses.first(width));

      Best best;

      for (std::size_t row = 0; row < length; ++row) {
        const auto count = matrix.end(row) - matrix.first[row] + 1;
        // The row above from the column before this row's first: each cell's diagonal.
        const auto diagonal_at = row == 0 ? 0 : matrix.cell(row - 1, matrix.first[row] - 1);
        const Row spans{
            .begin = matrix.first[row],
            .scores = work.scores.subspan(work.row_cells[row], count),
            .runs = work.runs.subspan(work.row_cells[row], count),
            .above_scores = work.scores.subspan(diagonal_at, count),
            .above_runs = work.runs.subspan(diagonal_at, count),
            .bonuses = work.bonuses.first(width),
            .window = window,
        };

        best = row == 0 ? firstRow(text, pattern[0], spans) : nextRow(text, pattern[row], spans);
      }

      const auto score = passing(best.score, length, work.floor);

      if (score && marks != nullptr) {
        backtrace(text, pattern, matrix, best.at, *marks);
      }

      return score;
    }

    // fzf's FuzzyMatchV2 for a pattern of `pattern.size()` characters: the best alignment by
    // Smith-Waterman with fzf's scores, the cells it covers by its backtrace. The prefilter
    // finds each character's first occurrence after the one before, or rejects; and from the
    // end, the last occurrence of each that the rest can still follow, which bound the rows.
    template <typename Text>
    ds::Option<std::int32_t> fuzzyMatch(Text text, Characters pattern, const Workspace& work, Marks* marks) noexcept {
      const auto length = pattern.size();
      const auto first = work.row_first.first(length);
      const auto last = work.row_last.first(length);
      std::size_t from = 0;

      for (std::size_t row = 0; row < length; ++row) {
        const auto found = text.find(pattern[row], from);
        if (found >= text.size()) {
          return ds::none;
        }

        first[row] = static_cast<std::uint32_t>(found);
        from = found + 1;
      }

      if (length == 1 && work.fast) {
        return passing(oneCharacter(text, pattern[0], first[0], marks), length, work.floor);
      }

      last[length - 1] = static_cast<std::uint32_t>(text.findLast(pattern[length - 1], first[length - 1], text.size()));
      for (auto row = length - 1; row-- > 0;) {
        last[row] = static_cast<std::uint32_t>(text.findLast(pattern[row], first[row], last[row + 1]));
      }

      if (length == 2 && work.fast && marks == nullptr) {
        return passing(twoCharacters(text, pattern, {.first0 = first[0], .first1 = first[1], .last1 = last[1]}), length, work.floor);
      }

      return fuzzyMatrix(text, pattern, work, marks);
    }

    // Whether `pattern`'s characters are all in `text`, in order.
    template <typename Text>
    bool inOrder(Text text, Characters pattern) noexcept {
      std::size_t from = 0;

      for (const auto character : pattern) {
        from = text.find(character, from);
        if (from >= text.size()) {
          return false;
        }

        ++from;
      }

      return true;
    }

    template <typename Text>
    bool matchesAt(Text text, Characters pattern, std::size_t start) noexcept {
      for (std::size_t index = 0; index < pattern.size(); ++index) {
        if (text.key(start + index) != pattern[index]) {
          return false;
        }
      }

      return true;
    }

    template <typename Text>
    std::size_t leadingWhite(Text text) noexcept {
      std::size_t count = 0;

      while (count < text.size() && text.classAt(count) == CharacterClass::white) {
        ++count;
      }

      return count;
    }

    template <typename Text>
    std::size_t trailingWhite(Text text) noexcept {
      std::size_t count = 0;

      while (count < text.size() && text.classAt(text.size() - count - 1) == CharacterClass::white) {
        ++count;
      }

      return count;
    }

    // fzf's PrefixMatch: the command's start, past its leading spaces unless the term starts
    // with one.
    template <typename Text>
    ds::Option<std::int32_t> prefixMatch(Text text, Characters pattern, Marks* marks) noexcept {
      const auto start = isWhite(pattern.front()) ? 0 : leadingWhite(text);
      if (text.size() - start < pattern.size() || !matchesAt(text, pattern, start)) {
        return ds::none;
      }

      return calculateScore(text, pattern, start, start + pattern.size(), marks);
    }

    // fzf's SuffixMatch: the command's end, before its trailing spaces unless the term ends with
    // one.
    template <typename Text>
    ds::Option<std::int32_t> suffixMatch(Text text, Characters pattern, Marks* marks) noexcept {
      const auto end = text.size() - (isWhite(pattern.back()) ? 0 : trailingWhite(text));
      if (end < pattern.size() || !matchesAt(text, pattern, end - pattern.size())) {
        return ds::none;
      }

      return calculateScore(text, pattern, end - pattern.size(), end, marks);
    }

    // fzf's EqualMatch: the whole command, spaces around it aside.
    template <typename Text>
    ds::Option<std::int32_t> equalMatch(Text text, Characters pattern, Marks* marks) noexcept {
      const auto start = isWhite(pattern.front()) ? 0 : leadingWhite(text);
      const auto end = text.size() - (isWhite(pattern.back()) ? 0 : trailingWhite(text));

      if (end < start || end - start != pattern.size() || !matchesAt(text, pattern, start)) {
        return ds::none;
      }

      if (marks != nullptr) {
        marks->add(start, end);
      }

      const auto length = static_cast<std::int32_t>(pattern.size());

      return ((score_match + bonus_boundary_white) * length) + ((first_character_multiplier - 1) * bonus_boundary_white);
    }

    // fzf's ExactMatchNaive: the occurrence whose first character has the best bonus, the first
    // of them; `boundary` takes only one that starts and ends a word.
    template <typename Text>
    ds::Option<std::size_t> bestOccurrence(Text text, Characters pattern, bool boundary) noexcept {
      ds::Option<std::size_t> best;
      std::int16_t best_bonus = -1;

      for (auto start = text.find(pattern.front(), 0); start + pattern.size() <= text.size(); start = text.find(pattern.front(), start + 1)) {
        const auto bonus = bonusOf(text, start);
        const auto end = start + pattern.size();
        const bool bounded = bonus >= bonus_boundary && (end == text.size() || text.classAt(end) <= CharacterClass::delimiter);

        if (bonus <= best_bonus || (boundary && !bounded) || !matchesAt(text, pattern, start)) {
          continue;
        }

        best = start;
        best_bonus = bonus;
        if (bonus >= bonus_boundary) {
          break;
        }
      }

      return best;
    }

    // An exact term: its best occurrence, scored as it lies. A substring term that starts the
    // command ranks above every one that does not.
    template <typename Text>
    ds::Option<std::int32_t> exactMatch(Text text, Characters pattern, bool boundary, bool ranks_prefix, Marks* marks) noexcept {
      if (pattern.size() > text.size()) {
        return ds::none;
      }

      if (ranks_prefix) {
        if (const auto prefix = prefixMatch(text, pattern, marks)) {
          return *prefix + prefix_rank;
        }
      }

      const auto start = bestOccurrence(text, pattern, boundary);
      if (!start) {
        return ds::none;
      }

      return calculateScore(text, pattern, *start, *start + pattern.size(), marks);
    }

    template <typename Text>
    ds::Option<std::int32_t> matchTerm(Text text, const HistoryTerm& term, Characters pattern, const Workspace& work, Marks* marks) noexcept {
      switch (term.kind) {
      case HistoryTermKind::fuzzy:
        return fuzzyMatch(text, pattern, work, marks);
      case HistoryTermKind::exact:
        return exactMatch(text, pattern, false, term.ranks_prefix, marks);
      case HistoryTermKind::exact_boundary:
        return exactMatch(text, pattern, true, false, marks);
      case HistoryTermKind::prefix:
        return prefixMatch(text, pattern, marks);
      case HistoryTermKind::suffix:
        return suffixMatch(text, pattern, marks);
      case HistoryTermKind::equal:
        return equalMatch(text, pattern, marks);
      }

      return ds::none;
    }

    // A loop the compiler vectorizes.
    bool isAscii(std::string_view text) noexcept {
      constexpr unsigned char high_bit = 0x80;
      unsigned char seen = 0;

      for (const auto byte : text) {
        seen |= static_cast<unsigned char>(byte);
      }

      return (seen & high_bit) == 0;
    }

    // The keys a term compares a decoded command's characters by: without diacritics when it
    // normalizes, then folded unless it is case sensitive.
    enum class KeyKind : std::uint8_t {
      none,
      exact,
      folded,
      unaccented,
      unaccented_folded,
    };

    constexpr KeyKind keyKind(const HistoryTerm& term) noexcept {
      if (term.normalize) {
        return term.case_sensitive ? KeyKind::unaccented : KeyKind::unaccented_folded;
      }

      return term.case_sensitive ? KeyKind::exact : KeyKind::folded;
    }

    // What one call matches its terms against: the command's bytes, or its characters decoded
    // into the arena with the keys of the term matched last.
    struct Subject {
      std::span<const char> bytes;
      bool ascii = true;
      bool fast = true;
      std::span<const std::uint32_t> characters;
      std::span<const std::uint8_t> classes;
      std::span<std::uint32_t> keys;
      KeyKind current = KeyKind::none;
    };

    // The decoded command's keys for `kind`; terms with the same case and diacritics rules
    // share them.
    RuneText keysFor(Subject& subject, KeyKind kind) noexcept {
      if (kind != subject.current) {
        const bool unaccented = kind == KeyKind::unaccented || kind == KeyKind::unaccented_folded;
        const bool folded = kind == KeyKind::folded || kind == KeyKind::unaccented_folded;

        for (std::size_t index = 0; index < subject.characters.size(); ++index) {
          const auto character = subject.characters[index];
          const auto key = unaccented ? history_text::unaccent(character) : character;

          subject.keys[index] = folded ? history_text::fold(key).character : key;
        }

        subject.current = kind;
      }

      return {.keys = subject.keys, .classes = subject.classes};
    }

    ds::Option<std::int32_t> matchOn(Subject& subject, const HistoryPattern& pattern, const HistoryTerm& term, const Workspace& work, Marks* marks) noexcept {
      auto* sink = term.inverse ? nullptr : marks;
      const auto characters = pattern.characters(term);

      if (subject.ascii) {
        return matchTerm(ByteText{.bytes = subject.bytes, .fold = !term.case_sensitive, .vector = subject.fast}, term, characters, work, sink);
      }

      return matchTerm(keysFor(subject, keyKind(term)), term, characters, work, sink);
    }

    // A fuzzy term that must match finds its characters in order or the command is no match:
    // looking for that in every such term first rejects a command before any term pays for its
    // matrix. An ASCII command's only, whose search needs nothing decoded.
    bool missesATerm(const Subject& subject, const HistoryPattern& pattern) noexcept {
      const auto terms = pattern.terms();

      if (!subject.ascii || terms.size() < 2) {
        return false;
      }

      for (std::size_t index = 0; index < terms.size(); ++index) {
        const auto& term = terms[index];
        const bool alone = !term.or_next && (index == 0 || !terms[index - 1].or_next);
        const bool required = alone && !term.inverse && term.kind == HistoryTermKind::fuzzy;

        if (required && !inOrder(ByteText{.bytes = subject.bytes, .fold = !term.case_sensitive, .vector = subject.fast}, pattern.characters(term))) {
          return true;
        }
      }

      return false;
    }

    // One group of alternatives: the first term that matches gives the group its score, and an
    // inverse term that does not match lets it match with none.
    ds::Option<std::int32_t> matchGroup(Subject& subject, const HistoryPattern& pattern, std::span<const HistoryTerm> group, const Workspace& work, Marks* marks) noexcept {
      bool unmatched_inverse = false;

      for (const auto& term : group) {
        const auto result = matchOn(subject, pattern, term, work, marks);

        if (result && !term.inverse) {
          return *result;
        }

        unmatched_inverse = unmatched_inverse || (!result && term.inverse);
      }

      if (unmatched_inverse) {
        return 0;
      }

      return ds::none;
    }

    // Where the group of alternatives that starts at `index` ends.
    std::size_t groupEnd(std::span<const HistoryTerm> terms, std::size_t index) noexcept {
      while (index + 1 < terms.size() && terms[index].or_next) {
        ++index;
      }

      return index + 1;
    }

    // A text without what lies past `limit` bytes.
    std::string_view upTo(std::string_view text, std::size_t limit) noexcept {
      text.remove_suffix(text.size() - std::min(text.size(), limit));
      return text;
    }

  }

  // The arena, as one call of historyMatch uses it.
  struct HistoryMatchScratch {
    HistoryMatchArena& arena;

    ds::Option<std::uint32_t> match(const HistoryPattern& pattern, std::string_view command, HistoryMatchRanges* ranges, bool floor) noexcept;

  private:
    std::size_t decode(std::string_view command) noexcept;
    Workspace workspace(bool floor) noexcept;
  };

  // Writes what a match covers into the caller's ranges.
  struct HistoryMatchWriter {
    static void clear(HistoryMatchRanges& ranges) noexcept;
    static void write(HistoryMatchRanges& ranges, std::span<HistoryMatchRange> marks, std::string_view command, bool ascii) noexcept;
  };

  HistoryMatchArena::HistoryMatchArena(HistorySearchPath path) noexcept
      : path_(path) {}

  std::span<const HistoryMatchRange> HistoryMatchRanges::view() const noexcept {
    return ranges_.view().first(count_);
  }

  bool HistoryMatchRanges::truncated() const noexcept {
    return truncated_;
  }

  void HistoryMatchWriter::clear(HistoryMatchRanges& ranges) noexcept {
    ranges.count_ = 0;
    ranges.truncated_ = false;
  }

  void HistoryMatchWriter::write(HistoryMatchRanges& ranges, std::span<HistoryMatchRange> marks, std::string_view command, bool ascii) noexcept {
    clear(ranges);
    std::ranges::sort(marks, {}, &HistoryMatchRange::begin);

    // Joined while they are character indices; a decoded command's become byte offsets in one
    // walk over its UTF-8, as both ends only grow.
    std::size_t joined = 0;

    for (const auto& mark : marks) {
      if (joined != 0 && mark.begin <= marks[joined - 1].end) {
        marks[joined - 1].end = std::max(marks[joined - 1].end, mark.end);
      } else {
        marks[joined++] = mark;
      }
    }

    std::size_t character = 0;
    auto rest = command;

    const auto offset_of = [&](std::uint32_t index) {
      while (character < index && !rest.empty()) {
        rest.remove_prefix(history_text::decode(rest).bytes);
        ++character;
      }

      return static_cast<std::uint32_t>(command.size() - rest.size());
    };

    for (const auto& mark : marks.first(joined)) {
      if (ranges.count_ == HistoryMatchRanges::capacity) {
        ranges.truncated_ = true;
        return;
      }

      const auto begin = ascii ? mark.begin : offset_of(mark.begin);
      const auto end = ascii ? mark.end : offset_of(mark.end);

      ranges.ranges_.atMut(ranges.count_++) = {.begin = begin, .end = end};
    }
  }

  std::size_t HistoryMatchScratch::decode(std::string_view command) noexcept {
    std::size_t count = 0;

    for (; !command.empty() && count < HistoryMatchArena::max_characters; ++count) {
      const auto decoded = history_text::decode(command);

      arena.characters_.atMut(count) = decoded.character;
      arena.classes_.atMut(count) = static_cast<std::uint8_t>(history_text::classOf(decoded.character));
      command.remove_prefix(decoded.bytes);
    }

    return count;
  }

  Workspace HistoryMatchScratch::workspace(bool floor) noexcept {
    return {
        .bonuses = arena.bonuses_.viewMut(),
        .scores = arena.scores_.viewMut(),
        .runs = arena.runs_.viewMut(),
        .row_first = arena.row_first_.viewMut(),
        .row_last = arena.row_last_.viewMut(),
        .row_cells = arena.row_cells_.viewMut(),
        .fast = arena.path_ == HistorySearchPath::fast,
        .floor = floor,
    };
  }

  ds::Option<std::uint32_t> HistoryMatchScratch::match(const HistoryPattern& pattern, std::string_view command, HistoryMatchRanges* ranges, bool floor) noexcept {
    if (ranges != nullptr) {
      HistoryMatchWriter::clear(*ranges);
    }

    if (pattern.empty()) {
      return 0U;
    }

    // Offsets are 32 bits: a command past them is matched on what they reach.
    command = upTo(command, std::numeric_limits<std::uint32_t>::max());

    Subject subject{.bytes = std::span{command}, .ascii = isAscii(command), .fast = arena.path_ == HistorySearchPath::fast};

    if (!subject.ascii) {
      const auto count = decode(command);

      subject.characters = arena.characters_.view().first(count);
      subject.classes = arena.classes_.view().first(count);
      subject.keys = arena.keys_.viewMut().first(count);
    }

    if (missesATerm(subject, pattern)) {
      return ds::none;
    }

    const auto work = workspace(floor);
    const auto terms = pattern.terms();
    Marks marks{arena.marks_.viewMut()};
    auto* sink = ranges == nullptr ? nullptr : &marks;
    std::int64_t total = 0;

    // The terms are groups of alternatives that must all match.
    for (std::size_t index = 0; index < terms.size();) {
      const auto end = groupEnd(terms, index);
      const auto score = matchGroup(subject, pattern, terms.subspan(index, end - index), work, sink);

      if (!score) {
        return ds::none;
      }

      total += *score;
      index = end;
    }

    if (ranges != nullptr) {
      HistoryMatchWriter::write(*ranges, marks.marked(), command, subject.ascii);
    }

    return static_cast<std::uint32_t>(std::max<std::int64_t>(total, 0));
  }

  ds::Option<std::uint32_t> historyMatch(const HistoryPattern& pattern, std::string_view command, HistoryMatchArena& arena, HistoryMatchRanges* ranges) noexcept {
    return HistoryMatchScratch{arena}.match(pattern, command, ranges, true);
  }

  ds::Option<std::uint32_t> historyMatchWithoutFloor(const HistoryPattern& pattern, std::string_view command, HistoryMatchArena& arena) noexcept {
    return HistoryMatchScratch{arena}.match(pattern, command, nullptr, false);
  }

}
