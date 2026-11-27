module telar.base.text.pattern;

import std;
import telar.base.ds;
import telar.base.history;

namespace telar::runtime {

  namespace {

    constexpr std::uint16_t no_node = std::numeric_limits<std::uint16_t>::max();
    constexpr unsigned set_word_bits = 64;
    constexpr std::uint32_t first_non_ascii = 0x80;
    // Past Unicode's last character, where a byte that starts no character goes.
    constexpr std::uint32_t outside = 0x110000;
    constexpr std::uint32_t last_character = outside - 1;
    // A class range at most this wide has the folding of each of its characters added; a wider
    // one, that of its ends.
    constexpr std::uint32_t folded_range_span = 1024;

    [[nodiscard]] constexpr char lower(char byte) noexcept {
      return byte >= 'A' && byte <= 'Z' ? static_cast<char>(byte - 'A' + 'a') : byte;
    }

    [[nodiscard]] constexpr bool wordByte(char byte) noexcept {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_';
    }

    [[nodiscard]] constexpr bool digit(char byte) noexcept {
      return byte >= '0' && byte <= '9';
    }

    // One character of UTF-8 and its bytes. A byte that starts no character, or starts one cut
    // short or written too long, is a character of its own past Unicode's last.
    struct Character {
      std::uint32_t value = 0;
      std::size_t bytes = 1;
    };

    [[nodiscard]] Character decode(std::string_view text, std::size_t offset) noexcept {
      constexpr unsigned continuation_mask = 0xc0U;
      constexpr unsigned continuation_bits = 0x80U;
      constexpr unsigned continuation_payload = 0x3fU;
      constexpr unsigned continuation_shift = 6U;
      constexpr std::uint32_t first_surrogate = 0xd800;
      constexpr std::uint32_t last_surrogate = 0xdfff;

      // The lead bits of each length of sequence, the bits of the character it carries, and the
      // first character past what that length holds, which a shorter one could have written.
      struct Sequence {
        unsigned lead_mask;
        unsigned lead_bits;
        unsigned payload;
        std::uint32_t minimum;
      };

      constexpr ds::Array<Sequence, 4> sequences{
          {
              {.lead_mask = 0x80, .lead_bits = 0x00, .payload = 0x7f, .minimum = 0},
              {.lead_mask = 0xe0, .lead_bits = 0xc0, .payload = 0x1f, .minimum = 0x80},
              {.lead_mask = 0xf0, .lead_bits = 0xe0, .payload = 0x0f, .minimum = 0x800},
              {.lead_mask = 0xf8, .lead_bits = 0xf0, .payload = 0x07, .minimum = 0x10000},
          },
      };

      const auto lead = static_cast<unsigned char>(text[offset]);
      const std::uint32_t lone = outside + lead;
      std::size_t length = 0;

      for (const auto& sequence : sequences) {
        ++length;
        if ((lead & sequence.lead_mask) != sequence.lead_bits) {
          continue;
        }

        std::uint32_t value = lead & sequence.payload;

        for (std::size_t index = 1; index < length; ++index) {
          if (offset + index >= text.size() || (static_cast<unsigned char>(text[offset + index]) & continuation_mask) != continuation_bits) {
            return {.value = lone};
          }

          value = (value << continuation_shift) | (static_cast<unsigned char>(text[offset + index]) & continuation_payload);
        }

        if (value < sequence.minimum || value > last_character || (value >= first_surrogate && value <= last_surrogate)) {
          return {.value = lone};
        }

        return {.value = value, .bytes = length};
      }

      return {.value = lone};
    }

    // The first byte UTF-8 writes `value` with.
    [[nodiscard]] constexpr unsigned leadByte(std::uint32_t value) noexcept {
      constexpr std::uint32_t two_bytes = 0x800;
      constexpr std::uint32_t three_bytes = 0x10000;
      constexpr unsigned two_lead = 0xc0;
      constexpr unsigned three_lead = 0xe0;
      constexpr unsigned four_lead = 0xf0;
      constexpr unsigned two_shift = 6;
      constexpr unsigned three_shift = 12;
      constexpr unsigned four_shift = 18;

      if (value < first_non_ascii) {
        return value;
      }

      if (value < two_bytes) {
        return two_lead | (value >> two_shift);
      }

      return value < three_bytes ? three_lead | (value >> three_shift) : four_lead | (value >> four_shift);
    }

    // The buffers of the thread that searches without its own.
    struct [[tbc::shared]] ThreadScratch {
      std::unique_ptr<PatternScratch> scratch;
    };

    PatternScratch* threadScratch() noexcept {
// A thread that exits frees its buffers.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wexit-time-destructors"
      thread_local ThreadScratch local;
#pragma clang diagnostic pop

      if (local.scratch == nullptr) {
        local.scratch.reset(new (std::nothrow) PatternScratch{}); // NOLINT(cppcoreguidelines-owning-memory): a thread's buffers without an exception find() cannot let through
      }

      return local.scratch.get();
    }

  }

  // Reads a regular expression into a tree of nodes, then writes the program a Pattern runs.
  // Its buffers are fixed: a pattern of at most maximum_pattern_bytes never needs more nodes than
  // twice its bytes. It lives on the heap while it compiles, and the pattern keeps only what the
  // program took.
  class PatternCompiler {
  public:
    PatternCompiler(PatternOptions options, std::string_view source) noexcept
        : options_(options),
          source_(source) {}

    void compileRegex() {
      const auto root = alternation(0);

      if (at_ != source_.size()) {
        throw PatternError{"unmatched )"};
      }

      emit(root);
      static_cast<void>(push({.op = Pattern::Op::match}));
      firstBytes();
    }

    // The text as it is, a character after another, to be matched in either case.
    void compileLiteral() {
      for (std::size_t at = 0; at < source_.size();) {
        const auto read = decode(source_, at);

        static_cast<void>(push({.op = Pattern::Op::character, .value = folded(read.value)}));
        at += read.bytes;
      }

      static_cast<void>(push({.op = Pattern::Op::match}));
      firstBytes();
    }

    void store(Pattern::Program& program) const noexcept {
      program.instructions = program_;
      program.instruction_count = program_size_;
      program.ranges = ranges_;
      program.sets = sets_;
      program.first = first_;
      program.any_first = any_first_;
    }

  private:
    enum class Kind : std::uint8_t {
      character,
      any,
      set,
      line_start,
      line_end,
      boundary,
      not_boundary,
      concat,
      alternate,
      repeat,
    };

    struct Node {
      Kind kind = Kind::concat;
      // The character, folded, or the set.
      std::uint32_t value = 0;
      std::uint16_t first = no_node;
      std::uint16_t next = no_node;
      std::uint16_t minimum = 0;
      std::uint16_t maximum = 0;
      bool unbounded = false;
      bool greedy = true;
    };

    static constexpr std::size_t maximum_nodes = (2 * Pattern::maximum_pattern_bytes) + 2;

    [[nodiscard]] std::uint32_t folded(std::uint32_t character) const noexcept {
      if (character > last_character) {
        return character;
      }

      return options_.ignore_case ? historyFold(character) : character;
    }

    [[nodiscard]] bool folds() const noexcept {
      return options_.ignore_case;
    }

    // ---- reading ---------------------------------------------------------------------------

    [[nodiscard]] bool more() const noexcept {
      return at_ < source_.size();
    }

    [[nodiscard]] char peek() const noexcept {
      return source_[at_];
    }

    std::uint16_t node(Node value) {
      if (nodes_count_ == maximum_nodes) {
        throw PatternError{"pattern too large"};
      }

      nodes_.atMut(nodes_count_) = value;
      return static_cast<std::uint16_t>(nodes_count_++);
    }

    // The children of a node being read, linked as they come.
    struct Children {
      std::uint16_t first = no_node;
      std::uint16_t last = no_node;
    };

    void append(Children& children, std::uint16_t child) noexcept {
      if (children.first == no_node) {
        children.first = child;
      } else {
        nodes_.atMut(children.last).next = child;
      }

      children.last = child;
    }

    std::uint16_t alternation(std::size_t depth) { // NOLINT(misc-no-recursion): groups nest at most maximum_depth deep
      if (depth > Pattern::maximum_depth) {
        throw PatternError{"groups nested too deep"};
      }

      const auto first = sequence(depth);

      if (!more() || peek() != '|') {
        return first;
      }

      Children alternatives;

      append(alternatives, first);
      while (more() && peek() == '|') {
        ++at_;
        append(alternatives, sequence(depth));
      }

      return node({.kind = Kind::alternate, .first = alternatives.first});
    }

    std::uint16_t sequence(std::size_t depth) { // NOLINT(misc-no-recursion): through alternation
      Children items;

      while (more() && peek() != '|' && peek() != ')') {
        append(items, repeated(depth));
      }

      return node({.kind = Kind::concat, .first = items.first});
    }

    std::uint16_t repeated(std::size_t depth) { // NOLINT(misc-no-recursion): through alternation
      const auto item = atom(depth);

      if (!more()) {
        return item;
      }

      Node repeat{.kind = Kind::repeat};

      switch (peek()) {
      case '*':
        repeat.unbounded = true;
        ++at_;
        break;
      case '+':
        repeat.minimum = 1;
        repeat.unbounded = true;
        ++at_;
        break;
      case '?':
        repeat.maximum = 1;
        ++at_;
        break;
      case '{':
        if (!counted(repeat)) {
          return item;
        }

        break;
      default:
        return item;
      }

      // An assertion takes no character: repeating it says nothing.
      const auto kind = nodes_[item].kind;
      if (kind == Kind::line_start || kind == Kind::line_end || kind == Kind::boundary || kind == Kind::not_boundary) {
        throw PatternError{"nothing to repeat"};
      }

      if (more() && peek() == '?') {
        repeat.greedy = false;
        ++at_;
      }

      if (more() && (peek() == '*' || peek() == '+' || peek() == '?' || peek() == '{')) {
        throw PatternError{"a quantifier follows another"};
      }

      repeat.first = item;
      return node(repeat);
    }

    // `{m}`, `{m,}` or `{m,n}` at the cursor into `repeat`; false, the cursor kept, when the
    // brace starts none, which makes it a literal.
    bool counted(Node& repeat) {
      constexpr std::size_t decimal = 10;
      auto cursor = at_ + 1;
      const auto number = [&](std::uint16_t& value) {
        const auto begin = cursor;
        std::size_t read = 0;

        while (cursor < source_.size() && digit(source_[cursor])) {
          read = (read * decimal) + static_cast<std::size_t>(source_[cursor] - '0');
          if (read > Pattern::maximum_repeat) {
            throw PatternError{"repetition count too large"};
          }

          ++cursor;
        }

        value = static_cast<std::uint16_t>(read);
        return cursor != begin;
      };

      if (!number(repeat.minimum)) {
        return false;
      }

      if (cursor < source_.size() && source_[cursor] == '}') {
        repeat.maximum = repeat.minimum;
      } else if (cursor < source_.size() && source_[cursor] == ',') {
        ++cursor;
        repeat.unbounded = !number(repeat.maximum);
        if (cursor >= source_.size() || source_[cursor] != '}') {
          return false;
        }
      } else {
        return false;
      }

      if (!repeat.unbounded && repeat.maximum < repeat.minimum) {
        throw PatternError{"repetition range out of order"};
      }

      at_ = cursor + 1;
      return true;
    }

    std::uint16_t atom(std::size_t depth) { // NOLINT(misc-no-recursion): through alternation
      switch (peek()) {
      case '(': {
        ++at_;
        if (source_.substr(at_).starts_with("?:")) {
          at_ += 2;
        }

        const auto group = alternation(depth + 1);

        if (!more() || peek() != ')') {
          throw PatternError{"unmatched ("};
        }

        ++at_;
        return group;
      }
      case '[':
        ++at_;
        return bracket();
      case '.':
        ++at_;
        return node({.kind = Kind::any});
      case '^':
        ++at_;
        return node({.kind = Kind::line_start});
      case '$':
        ++at_;
        return node({.kind = Kind::line_end});
      case '\\':
        ++at_;
        return escape();
      case '*':
      case '+':
      case '?':
        throw PatternError{"nothing to repeat"};
      default:
        return literal(character());
      }
    }

    // The character at the cursor, read whole.
    std::uint32_t character() noexcept {
      const auto read = decode(source_, at_);

      at_ += read.bytes;
      return read.value;
    }

    std::uint16_t literal(std::uint32_t value) {
      return node({.kind = Kind::character, .value = folded(value)});
    }

    // The character `\escaped` stands for outside a shorthand and an assertion: a control, or
    // anything but a letter or a digit as itself.
    std::uint32_t escapedCharacter() {
      const auto escaped = peek();

      switch (escaped) {
      case 't':
        ++at_;
        return '\t';
      case 'n':
        ++at_;
        return '\n';
      case 'r':
        ++at_;
        return '\r';
      default:
        if (wordByte(escaped)) {
          throw PatternError{"unknown escape"};
        }

        return character();
      }
    }

    std::uint16_t escape() {
      if (!more()) {
        throw PatternError{"pattern ends in \\"};
      }

      const auto escaped = peek();

      switch (escaped) {
      case 'd':
      case 'D':
      case 'w':
      case 'W':
      case 's':
      case 'S': {
        ++at_;
        const auto index = beginSet(escaped >= 'A' && escaped <= 'Z');

        shorthand(lower(escaped));
        return node({.kind = Kind::set, .value = index});
      }
      case 'b':
        ++at_;
        return node({.kind = Kind::boundary});
      case 'B':
        ++at_;
        return node({.kind = Kind::not_boundary});
      default:
        return literal(escapedCharacter());
      }
    }

    // A character of a class at the cursor, an escaped one too; none for a shorthand, whose
    // characters join the class at once.
    ds::Option<std::uint32_t> bracketMember() {
      if (peek() != '\\') {
        return character();
      }

      ++at_;
      if (!more()) {
        throw PatternError{"pattern ends in \\"};
      }

      const auto escaped = peek();
      if (escaped == 'd' || escaped == 'w' || escaped == 's') {
        ++at_;
        shorthand(escaped);
        return ds::none;
      }

      return escapedCharacter();
    }

    // `[...]` after its opening bracket.
    std::uint16_t bracket() {
      const bool negate = more() && peek() == '^';

      if (negate) {
        ++at_;
      }

      const auto index = beginSet(negate);
      // A `]` first is one of the class's characters.
      bool first = true;

      while (more() && (peek() != ']' || first)) {
        first = false;
        const auto low = bracketMember();
        if (!low) {
          continue;
        }

        auto high = *low;

        if (at_ + 1 < source_.size() && peek() == '-' && source_[at_ + 1] != ']') {
          ++at_;
          const auto end = bracketMember();
          if (!end || *end < *low) {
            throw PatternError{"class range out of order"};
          }

          high = *end;
        }

        include(*low, high);
      }

      if (!more()) {
        throw PatternError{"unmatched ["};
      }

      ++at_;
      return node({.kind = Kind::set, .value = index});
    }

    std::uint32_t beginSet(bool negated) {
      if (sets_size_ == Pattern::maximum_classes) {
        throw PatternError{"too many classes"};
      }

      sets_.atMut(sets_size_) = {.first_range = static_cast<std::uint16_t>(ranges_size_), .negated = negated};
      return static_cast<std::uint32_t>(sets_size_++);
    }

    // Adds [first, last] to the class begun last, joined to the range added before it when the
    // two touch.
    void addRange(std::uint32_t first, std::uint32_t last) { // NOLINT(bugprone-easily-swappable-parameters): a range's two ends, in order
      auto& set = sets_.atMut(sets_size_ - 1);

      if (set.range_count != 0) {
        auto& previous = ranges_.atMut(ranges_size_ - 1);
        if (first >= previous.first && first <= previous.last + 1) {
          previous.last = std::max(previous.last, last);
          return;
        }
      }

      if (ranges_size_ == Pattern::maximum_class_ranges) {
        throw PatternError{"classes too large"};
      }

      ranges_.atMut(ranges_size_++) = {.first = first, .last = last};
      ++set.range_count;
    }

    // [first, last] in the class, and what its characters fold to, since the text is matched
    // folded.
    void include(std::uint32_t first, std::uint32_t last) { // NOLINT(bugprone-easily-swappable-parameters): a range's two ends, in order
      addRange(first, last);
      if (!folds()) {
        return;
      }

      if (last - first < folded_range_span) {
        for (auto value = first; value <= last; ++value) {
          if (const auto image = folded(value); image != value) {
            addRange(image, image);
          }
        }

        return;
      }

      const auto low = folded(first);
      const auto high = folded(last);

      if ((low != first || high != last) && low <= high) {
        addRange(low, high);
      }
    }

    // The ASCII characters of `\d`, `\w` or `\s`, by its letter, into the class begun last.
    void shorthand(char letter) {
      switch (letter) {
      case 'd':
        addRange('0', '9');
        break;
      case 'w':
        addRange('0', '9');
        addRange('A', 'Z');
        addRange('_', '_');
        addRange('a', 'z');
        break;
      default:
        addRange('\t', '\r');
        addRange(' ', ' ');
        break;
      }
    }

    // ---- writing ---------------------------------------------------------------------------

    std::uint16_t push(Pattern::Instruction instruction) {
      if (program_size_ == Pattern::maximum_instructions) {
        throw PatternError{"pattern too large"};
      }

      program_.atMut(program_size_) = instruction;
      return static_cast<std::uint16_t>(program_size_++);
    }

    [[nodiscard]] std::uint16_t here() const noexcept {
      return static_cast<std::uint16_t>(program_size_);
    }

    Pattern::Instruction& at(std::uint16_t index) noexcept {
      return program_.atMut(index);
    }

    void emit(std::uint16_t index) { // NOLINT(misc-no-recursion): as deep as maximum_depth lets groups nest
      const auto current = nodes_[index];

      switch (current.kind) {
      case Kind::character:
        static_cast<void>(push({.op = Pattern::Op::character, .value = current.value}));
        break;
      case Kind::any:
        static_cast<void>(push({.op = Pattern::Op::any}));
        break;
      case Kind::set:
        static_cast<void>(push({.op = Pattern::Op::set, .value = current.value}));
        break;
      case Kind::line_start:
        static_cast<void>(push({.op = Pattern::Op::line_start}));
        break;
      case Kind::line_end:
        static_cast<void>(push({.op = Pattern::Op::line_end}));
        break;
      case Kind::boundary:
        static_cast<void>(push({.op = Pattern::Op::boundary}));
        break;
      case Kind::not_boundary:
        static_cast<void>(push({.op = Pattern::Op::not_boundary}));
        break;
      case Kind::concat:
        for (auto child = current.first; child != no_node; child = nodes_[child].next) {
          emit(child);
        }

        break;
      case Kind::alternate:
        alternate(current);
        break;
      case Kind::repeat:
        repeat(current);
        break;
      }
    }

    // Splits to each choice or the rest; each choice but the last jumps past the others. The
    // jumps wait for their target linked through it, the last one first.
    void alternate(const Node& alternatives) { // NOLINT(misc-no-recursion): through emit
      std::uint16_t exits = no_node;

      for (auto child = alternatives.first; child != no_node; child = nodes_[child].next) {
        if (nodes_[child].next == no_node) {
          emit(child);
          break;
        }

        const auto split = push({.op = Pattern::Op::split});

        at(split).x = here();
        emit(child);
        exits = push({.op = Pattern::Op::jump, .x = exits});
        at(split).y = here();
      }

      while (exits != no_node) {
        const auto previous = at(exits).x;

        at(exits).x = here();
        exits = previous;
      }
    }

    void repeat(const Node& repeat) { // NOLINT(misc-no-recursion): through emit
      for (std::uint16_t count = 0; count < repeat.minimum; ++count) {
        emit(repeat.first);
      }

      if (repeat.unbounded) {
        const auto loop = push({.op = Pattern::Op::split});

        emit(repeat.first);
        static_cast<void>(push({.op = Pattern::Op::jump, .x = loop}));
        branch(loop, static_cast<std::uint16_t>(loop + 1), here(), repeat.greedy);
        return;
      }

      ds::Array<std::uint16_t, Pattern::maximum_repeat> splits{};
      const auto optional = static_cast<std::size_t>(repeat.maximum - repeat.minimum);

      for (std::size_t count = 0; count < optional; ++count) {
        splits.atMut(count) = push({.op = Pattern::Op::split});
        emit(repeat.first);
      }

      // Each optional copy skips to the end, so a shorter match never has to try the rest.
      for (std::size_t count = 0; count < optional; ++count) {
        branch(splits[count], static_cast<std::uint16_t>(splits[count] + 1), here(), repeat.greedy);
      }
    }

    void branch(std::uint16_t split, std::uint16_t into, std::uint16_t past, bool greedy) noexcept {
      at(split).x = greedy ? into : past;
      at(split).y = greedy ? past : into;
    }

    void includeByte(unsigned value) noexcept {
      first_.atMut(value / set_word_bits) |= std::uint64_t{1} << (value % set_word_bits);
    }

    // The bytes a character of [first, last] can start with in the text.
    void includeStarts(std::uint32_t first, std::uint32_t last) noexcept { // NOLINT(bugprone-easily-swappable-parameters): a range's two ends, in order
      for (auto value = first; value <= std::min(last, first_non_ascii - 1); ++value) {
        includeByte(value);
      }

      if (last >= first_non_ascii) {
        for (auto lead = leadByte(std::max(first, first_non_ascii)); lead <= leadByte(std::min(last, last_character)); ++lead) {
          includeByte(lead);
        }
      }
    }

    // The bytes a match can start with, for the search to skip the others; any byte when a match
    // may take none, or when the case is ignored, since characters of other bytes fold to a
    // letter (K, the Kelvin sign, to k).
    void firstBytes() noexcept {
      ds::Array<bool, Pattern::maximum_instructions> visited{};
      std::size_t depth = 0;

      first_ = {};
      any_first_ = false;
      stack_.atMut(depth++) = 0;
      while (depth != 0) {
        const auto index = stack_[--depth];
        if (visited[index]) {
          continue;
        }

        visited.atMut(index) = true;
        const auto instruction = program_[index];
        const bool consumes = instruction.op == Pattern::Op::character || instruction.op == Pattern::Op::set;
        const bool negated = instruction.op == Pattern::Op::set && sets_[instruction.value].negated;

        if ((consumes && options_.ignore_case) || negated || instruction.op == Pattern::Op::any || instruction.op == Pattern::Op::match) {
          any_first_ = true;
          return;
        }

        if (consumes) {
          includeStartsOf(instruction);
        } else if (instruction.op == Pattern::Op::split) {
          stack_.atMut(depth++) = instruction.y;
          stack_.atMut(depth++) = instruction.x;
        } else if (instruction.op == Pattern::Op::jump) {
          stack_.atMut(depth++) = instruction.x;
        } else {
          // An assertion takes no byte: what follows it starts the match.
          stack_.atMut(depth++) = static_cast<std::uint16_t>(index + 1);
        }
      }
    }

    // The bytes the character or the class of `instruction` can start with.
    void includeStartsOf(const Pattern::Instruction& instruction) noexcept {
      if (instruction.op == Pattern::Op::character) {
        includeStarts(instruction.value, instruction.value);
        return;
      }

      const auto set = sets_[instruction.value];

      for (std::size_t index = set.first_range; index < std::size_t{set.first_range} + set.range_count; ++index) {
        const auto range = ranges_[index];

        includeStarts(range.first, range.last);
      }
    }

    PatternOptions options_;
    std::string_view source_;
    std::size_t at_ = 0;
    ds::Array<Node, maximum_nodes> nodes_{};
    std::size_t nodes_count_ = 0;
    ds::Array<Pattern::Instruction, Pattern::maximum_instructions> program_{};
    std::size_t program_size_ = 0;
    ds::Array<Pattern::Range, Pattern::maximum_class_ranges> ranges_{};
    std::size_t ranges_size_ = 0;
    ds::Array<Pattern::Set, Pattern::maximum_classes> sets_{};
    std::size_t sets_size_ = 0;
    Pattern::ByteSet first_{};
    bool any_first_ = true;
    ds::Array<std::uint16_t, (2 * Pattern::maximum_instructions) + 2> stack_{};
  };

  PatternError::PatternError(const char* reason) noexcept
      : reason_(reason) {}

  const char* PatternError::what() const noexcept {
    return reason_;
  }

  bool PatternThreads::holds(std::uint16_t program) const noexcept {
    const auto slot = index[program];

    return slot < count && programs[slot] == program;
  }

  void PatternThreads::add(std::uint16_t program, std::uint32_t start) noexcept { // NOLINT(bugprone-easily-swappable-parameters): an instruction, then the byte its thread began at
    index.atMut(program) = static_cast<std::uint16_t>(count);
    programs.atMut(count) = program;
    starts.atMut(count) = start;
    ++count;
  }

  Pattern::Pattern() noexcept = default;

  Pattern::Pattern(std::string_view pattern, PatternOptions options)
      : options_(options),
        program_(std::make_unique<Program>()) {
    if (pattern.size() > maximum_pattern_bytes) {
      throw PatternError{"pattern too long"};
    }

    auto& program = *program_;

    // Text as it is, in its case: a search of the bytes, without the machine.
    if (!options.regex && !options.ignore_case) {
      std::ranges::copy(pattern, program.literal.dataMut());

      program.literal_size = pattern.size();
      program.literal_search = true;
      return;
    }

    // The compiler's tree is large, and lives only while it compiles.
    auto compiler = std::make_unique<PatternCompiler>(options, pattern);
    auto& compiling = *compiler;

    if (options.regex) {
      compiling.compileRegex();
    } else {
      compiling.compileLiteral();
    }

    compiling.store(program);
  }

  Pattern::Pattern(const Pattern& other)
      : options_(other.options_),
        program_(other.program_ == nullptr ? nullptr : std::make_unique<Program>(*other.program_)) {}

  Pattern& Pattern::operator=(const Pattern& other) {
    if (this != &other) {
      Pattern copy{other};

      *this = std::move(copy);
    }

    return *this;
  }

  Pattern::Pattern(Pattern&& other) noexcept = default;

  Pattern& Pattern::operator=(Pattern&& other) noexcept = default;

  Pattern::~Pattern() = default;

  ds::Option<PatternMatch> Pattern::find(std::string_view text, std::size_t from) const noexcept {
    if (program_ == nullptr || from > text.size()) {
      return ds::none;
    }

    if (program_->literal_search) {
      return findLiteral(text, from);
    }

    auto* scratch = threadScratch();

    return scratch == nullptr ? ds::none : findRegex(text, from, *scratch);
  }

  ds::Option<PatternMatch> Pattern::find(std::string_view text, std::size_t from, PatternScratch& scratch) const noexcept {
    if (program_ == nullptr || from > text.size()) {
      return ds::none;
    }

    return program_->literal_search ? findLiteral(text, from) : findRegex(text, from, scratch);
  }

  bool Pattern::matches(std::string_view text) const noexcept {
    return find(text).hasValue();
  }

  bool Pattern::empty() const noexcept {
    return program_ == nullptr;
  }

  const PatternOptions& Pattern::options() const noexcept {
    return options_;
  }

  ds::Option<PatternMatch> Pattern::findLiteral(std::string_view text, std::size_t from) const noexcept {
    const std::string_view needle{program_->literal.data(), program_->literal_size};

    const auto found = text.find(needle, from);

    return found == std::string_view::npos ? ds::none : ds::Option<PatternMatch>{PatternMatch{.begin = found, .end = found + needle.size()}};
  }

  std::uint32_t Pattern::folded(std::uint32_t character) const noexcept {
    if (character > last_character) {
      return character;
    }

    return options_.ignore_case ? historyFold(character) : character;
  }

  bool Pattern::inSet(std::uint32_t index, std::uint32_t character) const noexcept { // NOLINT(bugprone-easily-swappable-parameters): a class's number and a character
    const auto& set = program_->sets[index];
    const auto value = folded(character);
    const auto ranges = program_->ranges.view().subspan(set.first_range, set.range_count);
    const bool member = std::ranges::any_of(ranges, [value](const Range& range) {
      return value >= range.first && value <= range.last;
    });

    return member != set.negated;
  }

  bool Pattern::takes(const Instruction& instruction, std::uint32_t character) const noexcept {
    switch (instruction.op) {
    case Op::character:
      return folded(character) == instruction.value;
    case Op::any:
      return character != '\n';
    case Op::set:
      return inSet(instruction.value, character);
    case Op::split:
    case Op::jump:
    case Op::line_start:
    case Op::line_end:
    case Op::boundary:
    case Op::not_boundary:
    case Op::match:
      break;
    }

    return false;
  }

  bool Pattern::assertion(Op operation, std::string_view text, std::size_t position) noexcept {
    const bool before = position > 0 && wordByte(text[position - 1]);
    const bool after = position < text.size() && wordByte(text[position]);

    switch (operation) {
    case Op::line_start:
      return position == 0 || text[position - 1] == '\n';
    case Op::line_end:
      return position == text.size() || text[position] == '\n';
    case Op::boundary:
      return before != after;
    case Op::not_boundary:
      return before == after;
    case Op::character:
    case Op::any:
    case Op::set:
    case Op::split:
    case Op::jump:
    case Op::match:
      break;
    }

    return false;
  }

  void Pattern::follow(PatternThreads& threads, PatternStack& stack, Thread thread, std::string_view text, std::size_t position) const noexcept {
    const auto instructions = program_->instructions.view().first(program_->instruction_count);
    std::size_t depth = 0;

    stack.atMut(depth++) = thread.program;
    while (depth != 0) {
      const auto current = stack[--depth];
      if (threads.holds(current)) {
        continue;
      }

      threads.add(current, thread.start);
      const auto instruction = instructions[current];

      if (instruction.op == Op::jump) {
        stack.atMut(depth++) = instruction.x;
      } else if (instruction.op == Op::split) {
        // The preferred branch is followed first, so its threads come first in the list.
        stack.atMut(depth++) = instruction.y;
        stack.atMut(depth++) = instruction.x;
      } else if (assertion(instruction.op, text, position)) {
        stack.atMut(depth++) = static_cast<std::uint16_t>(current + 1);
      }
    }
  }

  Pattern::Step Pattern::step(const PatternThreads& current, PatternThreads& next, PatternStack& stack, std::string_view text, std::size_t position) const noexcept {
    if (current.count == 0) {
      return {};
    }

    const auto instructions = program_->instructions.view().first(program_->instruction_count);
    const bool more = position < text.size();
    const auto read = more ? decode(text, position) : Character{};
    Step result{.alive = true};

    next.count = 0;
    for (std::size_t thread = 0; thread < current.count; ++thread) {
      const auto program = current.programs[thread];
      const auto instruction = instructions[program];

      // The threads after this one are ones the match prefers less: they stop here.
      if (instruction.op == Op::match) {
        result.match = PatternMatch{.begin = current.starts[thread], .end = position};
        break;
      }

      if (more && takes(instruction, read.value)) {
        follow(next, stack, {.program = static_cast<std::uint16_t>(program + 1), .start = current.starts[thread]}, text, position + read.bytes);
      }
    }

    return result;
  }

  std::size_t Pattern::skip(std::string_view text, std::size_t position) const noexcept {
    while (position < text.size()) {
      const auto value = static_cast<unsigned char>(text[position]);
      if (((program_->first[value / set_word_bits] >> (value % set_word_bits)) & 1U) != 0) {
        break;
      }

      ++position;
    }

    return position;
  }

  std::size_t Pattern::begin(PatternThreads& threads, PatternStack& stack, std::string_view text, std::size_t position) const noexcept {
    // Nothing under way: the next match starts at a byte one can start with.
    if (threads.count == 0 && !program_->any_first) {
      position = skip(text, position);
      if (position >= text.size()) {
        return position;
      }
    }

    // A thread starts here, after every thread begun earlier, which a match prefers.
    follow(threads, stack, {.program = 0, .start = static_cast<std::uint32_t>(position)}, text, position);
    return position;
  }

  ds::Option<PatternMatch> Pattern::findRegex(std::string_view text, std::size_t from, PatternScratch& scratch) const noexcept {
    if (text.size() >= std::numeric_limits<std::uint32_t>::max()) {
      return ds::none;
    }

    auto& even = scratch.even_;
    auto& odd = scratch.odd_;
    auto& stack = scratch.stack_;
    ds::Option<PatternMatch> best;
    // The threads at this character are the odd list's after an odd number of steps.
    bool flipped = false;

    even.count = 0;
    for (auto position = from;;) {
      if (!best) {
        position = flipped ? begin(odd, stack, text, position) : begin(even, stack, text, position);
      }

      const auto moved = flipped ? step(odd, even, stack, text, position) : step(even, odd, stack, text, position);

      if (!moved.alive) {
        break;
      }

      if (moved.match) {
        best = moved.match;
      }

      flipped = !flipped;
      if (position >= text.size()) {
        break;
      }

      position += decode(text, position).bytes;
    }

    return best;
  }

}
