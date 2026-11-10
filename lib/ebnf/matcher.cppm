module;

#include <cstddef>
#include <cstdint>

export module telar.ebnf.matcher;

import std;

export import telar.ebnf.parser;

// Interface: matcher.cppm
//
// A command spec is an EBNF grammar over the words of one command line. compile() turns
// it into an immutable BNF table at load time and throws on any error. The queries run an
// Earley recognizer whose terminals match whole words; they are noexcept, never allocate,
// and keep every item in a caller-owned match_scratch with fixed capacity.
export {
namespace ebnf {

  // Query limits. Exceeding one makes the query answer match_status::unknown.
  inline constexpr std::size_t max_words = 256;
  inline constexpr std::size_t max_items = 16384;
  inline constexpr std::size_t max_set_items = 1024;
  // One Earley set per word, plus one per character of a decomposed short-option cluster.
  inline constexpr std::size_t max_sets = 1024;

  // Compile limits. Exceeding one makes compile() throw std::length_error.
  inline constexpr std::size_t max_nonterminals = 4096;
  inline constexpr std::size_t max_terminals = 4096;
  inline constexpr std::size_t max_candidate_keys = 4096;
  inline constexpr std::size_t max_rhs_slots = 65535;

  enum class match_status : std::uint8_t {
    // Every word can start a valid command line.
    valid,
    // `word` is the first word that no derivation accepts.
    invalid,
    // A query limit was exceeded; nothing is known.
    unknown,
  };

  struct match_result {
    match_status status{match_status::unknown};
    // Index of the first rejected word; meaningful only for invalid.
    std::uint32_t word{0};
    // Candidates written by complete().
    std::uint32_t count{0};
    // complete() found more candidates than the output span holds.
    bool truncated{false};
  };

  enum class candidate_kind : std::uint8_t {
    // `prefix + text` is the word to insert.
    literal,
    // `text` names a provider the caller resolves; insert `prefix` before its values.
    provider,
  };

  // Views borrow the command_spec that produced them.
  struct candidate {
    candidate_kind kind{candidate_kind::literal};
    std::string_view prefix{};
    std::string_view text{};
    std::string_view description{};
  };

  class command_spec;

  // Per-thread query storage (about 140 KiB); allocate it once and reuse it for every query.
  class match_scratch {
    friend class command_spec;

    struct item {
      std::uint16_t slot;
      std::uint16_t origin;
    };

    struct seen_item {
      std::uint32_t key;
      std::uint32_t stamp;
    };

    struct staged_candidate {
      std::uint16_t key;
      std::uint16_t terminal;
      std::uint16_t value;
    };

    static constexpr std::size_t seen_capacity = max_set_items * 2;
    static_assert(std::has_single_bit(seen_capacity));

    std::array<item, max_items> items_{};
    std::array<std::uint32_t, max_sets + 1> set_begin_{};
    std::array<seen_item, seen_capacity> seen_{};
    std::array<std::uint32_t, max_nonterminals> predicted_{};
    std::array<std::uint32_t, max_candidate_keys> offered_{};
    std::array<staged_candidate, max_candidate_keys> staged_{};
    std::uint32_t size_{0};
    std::uint32_t set_size_{0};
    std::uint32_t set_count_{0};
    std::uint16_t last_set_{0};
    std::uint32_t stamp_{0};
    bool overflow_{false};

    // Stamps tell current entries from stale ones, so no table is cleared per set or query.
    inline auto nextStamp() noexcept -> std::uint32_t {
      if (stamp_ == std::numeric_limits<std::uint32_t>::max()) {
        seen_.fill({});
        predicted_.fill(0);
        offered_.fill(0);
        stamp_ = 0;
      }

      return ++stamp_;
    }

  public:
    // Items the last query stored; it shows how close a spec runs to max_items.
    [[nodiscard]] inline auto itemsUsed() const noexcept -> std::size_t {
      return size_;
    }
  };

  namespace detail {
    enum class terminal_kind : std::uint8_t {
      literal,
      // A dynamic terminal: any word that does not look like an option.
      operand,
      // `@any`: every word.
      any,
      // `@number`: one or more decimal digits.
      number,
      // `prefix ~ value`: one word made of a literal prefix and a value.
      glue,
    };

    struct text_ref {
      std::uint32_t offset{0};
      std::uint32_t size{0};
    };

    struct terminal_entry {
      text_ref text{};
      text_ref description{};
      std::uint32_t values_begin{0};
      std::uint16_t values_count{0};
      std::uint16_t key{0};
      terminal_kind kind{terminal_kind::literal};
    };

    struct value_entry {
      std::uint16_t terminal;
      std::uint16_t key;
    };

    // A right-hand-side slot holds a nonterminal id, a flagged terminal id, or the flagged
    // left-hand side that ends a production. An Earley item is a slot plus its origin.
    inline constexpr std::uint16_t terminal_flag = 0x4000;
    inline constexpr std::uint16_t end_flag = 0x8000;
    inline constexpr std::uint16_t id_mask = 0x3FFF;
    inline constexpr std::uint16_t no_value = 0xFFFF;
    inline constexpr auto kind_mask = static_cast<std::uint16_t>(terminal_flag | end_flag);

    static_assert(max_nonterminals <= id_mask + 1 && max_terminals <= id_mask + 1);
    static_assert(max_sets < std::numeric_limits<std::uint16_t>::max() && max_words < max_sets);

    constexpr auto isTerminal(std::uint16_t symbol) noexcept -> bool {
      return (symbol & kind_mask) == terminal_flag;
    }

    // The text after `start` bytes; the caller guarantees start <= text.size().
    constexpr auto suffix(std::string_view text, std::size_t start) noexcept -> std::string_view {
      return {text.data() + start, text.size() - start};
    }

    // An option-like word starts with `-` and is longer than a lone `-` (stdin, previous directory).
    constexpr auto looksLikeOption(std::string_view word) noexcept -> bool {
      return word.size() >= 2 && word[0] == '-';
    }

    constexpr auto isNumber(std::string_view word) noexcept -> bool {
      for (const auto character : word) {
        if (character < '0' || character > '9') {
          return false;
        }
      }

      return !word.empty();
    }

    // `-abc` may be the short options `-a -b -c`, or `-a` with the attached value `bc`.
    constexpr auto looksLikeCluster(std::string_view word) noexcept -> bool {
      return word.size() >= 3 && word[0] == '-' && word[1] != '-';
    }

    class spec_builder;
  }

  class command_spec {
    friend class detail::spec_builder;

    std::string pool_{};
    std::vector<std::uint16_t> rhs_{};
    std::vector<std::uint16_t> production_slots_{};
    std::vector<std::uint32_t> productions_begin_{};
    std::vector<std::uint8_t> nullable_{};
    std::vector<detail::terminal_entry> terminals_{};
    std::vector<detail::value_entry> values_{};
    std::uint16_t start_{0};

    command_spec() = default;

    [[nodiscard]] inline auto text(detail::text_ref ref) const noexcept -> std::string_view {
      return {pool_.data() + ref.offset, ref.size};
    }

    [[nodiscard]] inline auto matchesValue(const detail::terminal_entry &value, std::string_view rest) const noexcept -> bool {
      switch (value.kind) {
      case detail::terminal_kind::literal:
        return rest == text(value.text);
      case detail::terminal_kind::number:
        return detail::isNumber(rest);
      default:
        // The value follows the prefix inside one word, so it cannot be mistaken for an option.
        return !rest.empty();
      }
    }

    [[nodiscard]] inline auto matches(const detail::terminal_entry &terminal, std::string_view word) const noexcept -> bool {
      switch (terminal.kind) {
      case detail::terminal_kind::literal:
        return word == text(terminal.text);
      case detail::terminal_kind::operand:
        return !detail::looksLikeOption(word);
      case detail::terminal_kind::any:
        return true;
      case detail::terminal_kind::number:
        return detail::isNumber(word);
      case detail::terminal_kind::glue: {
        const auto prefix = text(terminal.text);

        if (!word.starts_with(prefix)) {
          return false;
        }

        const auto rest = detail::suffix(word, prefix.size());
        const auto end = terminal.values_begin + terminal.values_count;

        for (auto index = terminal.values_begin; index < end; ++index) {
          if (matchesValue(terminals_[values_[index].terminal], rest)) {
            return true;
          }
        }

        return false;
      }
      }

      return false;
    }

    // Adds an item to the set being filled unless it is already there.
    inline auto add(match_scratch &scratch, std::uint16_t slot, std::uint16_t origin) const noexcept -> void {
      if (scratch.set_size_ == max_set_items || scratch.size_ == max_items) {
        scratch.overflow_ = true;
        return;
      }

      const auto key = (std::uint32_t{slot} << 16U) | origin;
      const auto mask = static_cast<std::uint32_t>(match_scratch::seen_capacity - 1);
      auto bucket = (key * 2654435761U) >> 21U;

      static_assert(match_scratch::seen_capacity == (std::size_t{1} << 11U));

      while (true) {
        auto &seen = scratch.seen_[bucket];

        if (seen.stamp != scratch.stamp_) {
          seen = {.key = key, .stamp = scratch.stamp_};
          scratch.items_[scratch.size_] = {.slot = slot, .origin = origin};
          ++scratch.size_;
          ++scratch.set_size_;
          return;
        }

        if (seen.key == key) {
          return;
        }

        bucket = (bucket + 1) & mask;
      }
    }

    // Items are always added to the open set, the last one started.
    static auto openPosition(const match_scratch &scratch) noexcept -> std::uint16_t {
      return static_cast<std::uint16_t>(scratch.set_count_ - 1U);
    }

    inline auto predict(match_scratch &scratch, std::uint16_t nonterminal) const noexcept -> void {
      if (scratch.predicted_[nonterminal] == scratch.stamp_) {
        return;
      }

      scratch.predicted_[nonterminal] = scratch.stamp_;
      const auto begin = productions_begin_[nonterminal];
      const auto count = productions_begin_[nonterminal + 1U] - begin;

      if (scratch.set_size_ + count > max_set_items || scratch.size_ + count > max_items) {
        scratch.overflow_ = true;
        return;
      }

      // Only prediction reaches a production's first slot, and it runs once per nonterminal and
      // set, so these items are new and skip the duplicate table.
      const auto position = openPosition(scratch);

      for (std::uint32_t index = 0; index < count; ++index) {
        scratch.items_[scratch.size_ + index] = {.slot = production_slots_[begin + index], .origin = position};
      }

      scratch.size_ += count;
      scratch.set_size_ += count;
    }

    // Predicts and completes until the open set is closed. Nullable nonterminals are stepped
    // over when predicted (Aycock and Horspool), so empty completions need no pass.
    inline auto close(match_scratch &scratch) const noexcept -> void {
      const auto position = openPosition(scratch);

      for (auto index = scratch.set_begin_[position]; index < scratch.size_ && !scratch.overflow_; ++index) {
        const auto item = scratch.items_[index];
        const auto symbol = rhs_[item.slot];

        if ((symbol & detail::end_flag) != 0) {
          if (item.origin == position) {
            continue;
          }

          const auto lhs = static_cast<std::uint16_t>(symbol & detail::id_mask);
          const auto end = scratch.set_begin_[item.origin + 1U];

          for (auto waiting = scratch.set_begin_[item.origin]; waiting < end; ++waiting) {
            const auto parent = scratch.items_[waiting];

            if (rhs_[parent.slot] == lhs) {
              add(scratch, static_cast<std::uint16_t>(parent.slot + 1U), parent.origin);
            }
          }
        } else if ((symbol & detail::terminal_flag) == 0) {
          predict(scratch, symbol);

          if (nullable_[symbol] != 0) {
            add(scratch, static_cast<std::uint16_t>(item.slot + 1U), item.origin);
          }
        }
      }
    }

    // Starts the next set; its items run until the following set begins.
    inline auto openSet(match_scratch &scratch) const noexcept -> std::uint16_t {
      if (scratch.set_count_ == max_sets) {
        scratch.overflow_ = true;
        return static_cast<std::uint16_t>(max_sets - 1);
      }

      scratch.set_begin_[scratch.set_count_] = scratch.size_;
      scratch.set_begin_[scratch.set_count_ + 1U] = scratch.size_;
      scratch.set_size_ = 0;
      scratch.nextStamp();
      return static_cast<std::uint16_t>(scratch.set_count_++);
    }

    inline auto sealSet(match_scratch &scratch) const noexcept -> void {
      scratch.set_begin_[scratch.set_count_] = scratch.size_;
    }

    // Advances the items of a closed set over a terminal matching `word`, into the open set.
    // A flag split from a cluster matches literals only: it is never a value.
    inline auto scan(match_scratch &scratch, std::uint16_t from, std::string_view word, bool flag = false) const noexcept -> void {
      const auto end = scratch.set_begin_[from + 1U];

      for (auto index = scratch.set_begin_[from]; index < end; ++index) {
        const auto item = scratch.items_[index];
        const auto symbol = rhs_[item.slot];

        if (!detail::isTerminal(symbol)) {
          continue;
        }

        const auto &terminal = terminals_[symbol & detail::id_mask];

        if ((!flag || terminal.kind == detail::terminal_kind::literal) && matches(terminal, word)) {
          add(scratch, static_cast<std::uint16_t>(item.slot + 1U), item.origin);
        }
      }
    }

    // Fallback for a word no terminal matched whole: read `-abc` as getopt does, as the short
    // options `-a -b -c` where each may instead take the rest of the word as its value. Every
    // reading is kept, so the result may accept a few clusters getopt would reject.
    inline auto scanCluster(match_scratch &scratch, std::uint16_t from, std::string_view word) const noexcept -> std::uint16_t {
      // The set left open and empty by the whole-word scan receives the first flag.
      const auto first = openPosition(scratch);
      auto target = first;
      auto previous = from;
      std::size_t flags = 0;
      std::array<char, 2> flag{'-', '\0'};

      // Flags before the last character each end in a closed set, numbered consecutively.
      for (std::size_t index = 1; index + 1 < word.size(); ++index) {
        if (flags != 0) {
          target = openSet(scratch);
        }

        flag[1] = word[index];
        scan(scratch, previous, {flag.data(), flag.size()}, true);

        if (scratch.overflow_ || scratch.set_size_ == 0) {
          break;
        }

        close(scratch);
        sealSet(scratch);
        previous = target;
        ++flags;
        target = static_cast<std::uint16_t>(target + 1U);
      }

      if (scratch.overflow_ || flags == 0) {
        return target;
      }

      // Reuse the set a failed flag left open and empty; otherwise open the final one.
      const auto last = flags == word.size() - 2 ? openSet(scratch) : openPosition(scratch);

      if (flags == word.size() - 2) {
        flag[1] = word.back();
        scan(scratch, previous, {flag.data(), flag.size()}, true);
      }

      for (std::size_t step = 0; step < flags; ++step) {
        scan(scratch, static_cast<std::uint16_t>(first + step), detail::suffix(word, step + 2));
      }

      return last;
    }

    // Recognizes every word; on success the last set holds the items waiting after them.
    inline auto run(std::span<const std::string_view> words, match_scratch &scratch) const noexcept -> match_result {
      if (words.size() > max_words) {
        return {.status = match_status::unknown};
      }

      scratch.size_ = 0;
      scratch.set_count_ = 0;
      scratch.overflow_ = false;
      auto current = openSet(scratch);
      predict(scratch, start_);
      close(scratch);
      sealSet(scratch);

      for (std::size_t position = 0; position < words.size() && !scratch.overflow_; ++position) {
        const auto word = words[position];
        auto next = openSet(scratch);
        scan(scratch, current, word);

        if (scratch.set_size_ == 0 && !scratch.overflow_ && detail::looksLikeCluster(word)) {
          next = scanCluster(scratch, current, word);
        }

        if (scratch.overflow_) {
          break;
        }

        if (scratch.set_size_ == 0) {
          return {.status = match_status::invalid, .word = static_cast<std::uint32_t>(position)};
        }

        close(scratch);
        sealSet(scratch);
        current = next;
      }

      if (scratch.overflow_) {
        return {.status = match_status::unknown};
      }

      scratch.last_set_ = current;
      return {.status = match_status::valid};
    }

    inline auto stage(match_scratch &scratch, std::uint32_t &count, std::uint16_t key, std::uint16_t terminal, std::uint16_t value) const noexcept -> void {
      if (scratch.offered_[key] == scratch.stamp_) {
        return;
      }

      scratch.offered_[key] = scratch.stamp_;
      scratch.staged_[count] = {.key = key, .terminal = terminal, .value = value};
      ++count;
    }

    // Whether a value could still grow from `partial`; a glue's values sit inside one word.
    [[nodiscard]] inline auto offersValue(const detail::terminal_entry &value, std::string_view partial) const noexcept -> bool {
      switch (value.kind) {
      case detail::terminal_kind::literal:
        return text(value.text).starts_with(partial);
      case detail::terminal_kind::number:
        return partial.empty() || detail::isNumber(partial);
      default:
        return true;
      }
    }

    inline auto offer(match_scratch &scratch, std::uint32_t &count, std::uint16_t id, std::string_view partial) const noexcept -> void {
      const auto &terminal = terminals_[id];

      switch (terminal.kind) {
      case detail::terminal_kind::literal:
        if (text(terminal.text).starts_with(partial)) {
          stage(scratch, count, terminal.key, id, detail::no_value);
        }
        return;
      case detail::terminal_kind::operand:
        if (!detail::looksLikeOption(partial)) {
          stage(scratch, count, terminal.key, id, detail::no_value);
        }
        return;
      case detail::terminal_kind::any:
      case detail::terminal_kind::number:
        if (offersValue(terminal, partial)) {
          stage(scratch, count, terminal.key, id, detail::no_value);
        }
        return;
      case detail::terminal_kind::glue: {
        const auto prefix = text(terminal.text);

        if (partial.starts_with(prefix)) {
          const auto rest = detail::suffix(partial, prefix.size());
          const auto end = terminal.values_begin + terminal.values_count;

          for (auto index = terminal.values_begin; index < end; ++index) {
            if (offersValue(terminals_[values_[index].terminal], rest)) {
              stage(scratch, count, values_[index].key, id, static_cast<std::uint16_t>(index));
            }
          }
        } else if (prefix.starts_with(partial)) {
          stage(scratch, count, terminal.key, id, detail::no_value);
        }
        return;
      }
      }
    }

    [[nodiscard]] inline auto materialize(match_scratch::staged_candidate staged) const noexcept -> candidate {
      const auto &terminal = terminals_[staged.terminal];
      const auto &shown = staged.value == detail::no_value ? terminal : terminals_[values_[staged.value].terminal];
      const auto prefix = staged.value == detail::no_value ? std::string_view{} : text(terminal.text);
      const auto kind = shown.kind == detail::terminal_kind::literal || shown.kind == detail::terminal_kind::glue ? candidate_kind::literal : candidate_kind::provider;

      return {
          .kind = kind,
          .prefix = prefix,
          .text = text(shown.text),
          .description = text(shown.description),
      };
    }

  public:
    // Compiles a spec; the first rule is the start symbol. Throws std::invalid_argument on
    // syntax or semantic errors and std::length_error when a compile limit is exceeded.
    static auto compile(std::string_view source) -> command_spec;

    // Words are the command's arguments after its name, already unquoted. Returns the words'
    // status and writes the candidates valid for the next word, filtered by `partial`, without
    // duplicates and in grammar order.
    inline auto complete(std::span<const std::string_view> words, std::string_view partial, match_scratch &scratch, std::span<candidate> out) const noexcept -> match_result {
      auto result = run(words, scratch);

      if (result.status != match_status::valid) {
        return result;
      }

      scratch.nextStamp();
      std::uint32_t count = 0;
      const auto end = scratch.set_begin_[scratch.last_set_ + 1U];

      for (auto index = scratch.set_begin_[scratch.last_set_]; index < end; ++index) {
        const auto symbol = rhs_[scratch.items_[index].slot];

        if (detail::isTerminal(symbol)) {
          offer(scratch, count, static_cast<std::uint16_t>(symbol & detail::id_mask), partial);
        }
      }

      const auto staged = std::span{scratch.staged_}.first(count);
      std::ranges::sort(staged, {}, &match_scratch::staged_candidate::key);
      const auto written = std::min<std::size_t>(count, out.size());

      for (std::size_t index = 0; index < written; ++index) {
        out[index] = materialize(staged[index]);
      }

      result.count = static_cast<std::uint32_t>(written);
      result.truncated = written < count;
      return result;
    }

    // Reports the first word no derivation accepts. A valid result means the words are a
    // prefix of some command line, not necessarily a complete one.
    inline auto check(std::span<const std::string_view> words, match_scratch &scratch) const noexcept -> match_result {
      return run(words, scratch);
    }
  };

  namespace detail {
    class spec_builder {
      syntax_tree &tree_;
      command_spec spec_{};
      std::unordered_map<std::string_view, std::uint16_t> rules_{};
      std::vector<node_handle> rule_bodies_{};
      std::vector<std::vector<std::vector<std::uint16_t>>> productions_{};
      std::unordered_map<std::string, text_ref> interned_{};
      std::map<std::tuple<candidate_kind, std::uint32_t, std::uint32_t>, std::uint16_t> keys_{};

      static constexpr std::size_t max_value_depth = 16;

      [[noreturn]] static auto fail(const std::string &message) -> void {
        throw std::invalid_argument(message);
      }

      auto children(node_handle node) -> std::vector<node_handle> {
        auto result = std::vector<node_handle>{};

        for (auto child = tree_.getFirstChild(node); child != none_handle; child = tree_.getFirstSibling(child)) {
          result.push_back(child);
        }

        return result;
      }

      auto kind(node_handle node) -> node_kind {
        return *tree_.getKind(node);
      }

      auto nodeText(node_handle node) -> std::string_view {
        return *tree_.getText(node);
      }

      static auto decode(std::string_view raw) -> std::string {
        auto decoded = std::string{};
        decoded.reserve(raw.size());

        for (std::size_t index = 0; index < raw.size(); ++index) {
          if (raw[index] != '\\') {
            decoded.push_back(raw[index]);
            continue;
          }

          // The lexer accepts only complete escapes from this set.
          switch (raw[++index]) {
          case 'n':
            decoded.push_back('\n');
            break;
          case 't':
            decoded.push_back('\t');
            break;
          case 'r':
            decoded.push_back('\r');
            break;
          case 'f':
            decoded.push_back('\f');
            break;
          case 'b':
            decoded.push_back('\b');
            break;
          default:
            decoded.push_back(raw[index]);
            break;
          }
        }

        return decoded;
      }

      auto intern(std::string text) -> text_ref {
        if (const auto found = interned_.find(text); found != interned_.end()) {
          return found->second;
        }

        if (text.size() > std::numeric_limits<std::uint32_t>::max() - spec_.pool_.size()) {
          throw std::length_error("Command spec text exceeds 4 GiB");
        }

        const auto ref = text_ref{
            .offset = static_cast<std::uint32_t>(spec_.pool_.size()),
            .size = static_cast<std::uint32_t>(text.size()),
        };
        spec_.pool_ += text;
        interned_.emplace(std::move(text), ref);
        return ref;
      }

      auto newNonterminal() -> std::uint16_t {
        if (productions_.size() == max_nonterminals) {
          throw std::length_error("Command spec exceeds the nonterminal limit");
        }

        productions_.emplace_back();
        return static_cast<std::uint16_t>(productions_.size() - 1);
      }

      auto pushTerminal(terminal_entry entry) -> std::uint16_t {
        if (spec_.terminals_.size() == max_terminals) {
          throw std::length_error("Command spec exceeds the terminal limit");
        }

        spec_.terminals_.push_back(entry);
        return static_cast<std::uint16_t>(spec_.terminals_.size() - 1);
      }

      // A Literal or Dynamic node, with its optional Description child.
      auto addTerminal(node_handle node) -> std::uint16_t {
        auto entry = terminal_entry{};

        if (kind(node) == node_kind::Literal) {
          entry.kind = terminal_kind::literal;
          entry.text = intern(decode(nodeText(node)));
        } else {
          const auto name = nodeText(node);
          entry.kind = name == "any" ? terminal_kind::any : name == "number" ? terminal_kind::number : terminal_kind::operand;
          entry.text = intern(std::string{nodeText(node)});
        }

        if (const auto description = tree_.getFirstChild(node); description != none_handle) {
          entry.description = intern(decode(nodeText(description)));
        }

        return pushTerminal(entry);
      }

      auto ruleFor(node_handle reference) -> std::uint16_t {
        const auto found = rules_.find(nodeText(reference));

        if (found == rules_.end()) {
          fail("Undefined rule: " + std::string{nodeText(reference)});
        }

        return found->second;
      }

      auto collectValues(node_handle node, std::size_t depth) -> void {
        if (depth > max_value_depth) {
          fail("Glued values nest too deeply");
        }

        switch (kind(node)) {
        case node_kind::Literal:
        case node_kind::Dynamic: {
          const auto terminal = addTerminal(node);
          spec_.values_.push_back({.terminal = terminal, .key = 0});
          return;
        }
        case node_kind::Alternative:
          for (const auto child : children(node)) {
            collectValues(child, depth + 1);
          }
          return;
        case node_kind::Concatenation: {
          const auto parts = children(node);

          if (parts.size() != 1) {
            fail("A glued value must be one terminal, not a sequence");
          }

          collectValues(parts.front(), depth + 1);
          return;
        }
        case node_kind::Reference:
          collectValues(rule_bodies_[ruleFor(node)], depth + 1);
          return;
        default:
          fail("A glued value must be a literal, a dynamic terminal, or an alternation of them");
        }
      }

      auto addGlue(node_handle node) -> std::uint16_t {
        const auto prefix = tree_.getFirstChild(node);
        const auto value = tree_.getFirstSibling(prefix);

        if (kind(prefix) != node_kind::Literal) {
          fail("The left side of ~ must be a literal");
        }

        const auto values_begin = spec_.values_.size();
        collectValues(value, 0);

        if (spec_.values_.size() - values_begin > std::numeric_limits<std::uint16_t>::max()) {
          throw std::length_error("A glued value has too many alternatives");
        }

        auto entry = spec_.terminals_[addTerminal(prefix)];
        spec_.terminals_.pop_back();
        entry.kind = terminal_kind::glue;
        entry.values_begin = static_cast<std::uint32_t>(values_begin);
        entry.values_count = static_cast<std::uint16_t>(spec_.values_.size() - values_begin);
        return pushTerminal(entry);
      }

      auto terminalSymbol(std::uint16_t terminal) -> std::uint16_t {
        return static_cast<std::uint16_t>(terminal_flag | terminal);
      }

      // The symbols of one alternative; nested concatenations from parentheses are inlined.
      auto appendSequence(std::vector<std::uint16_t> &sequence, node_handle node) -> void {
        if (kind(node) == node_kind::Concatenation) {
          for (const auto child : children(node)) {
            appendSequence(sequence, child);
          }
          return;
        }

        sequence.push_back(symbolFor(node));
      }

      // One symbol sequence per alternative of `node`.
      auto sequencesOf(node_handle node) -> std::vector<std::vector<std::uint16_t>> {
        const auto alternatives = kind(node) == node_kind::Alternative ? children(node) : std::vector<node_handle>{node};
        auto sequences = std::vector<std::vector<std::uint16_t>>{};

        for (const auto alternative : alternatives) {
          auto sequence = std::vector<std::uint16_t>{};
          appendSequence(sequence, alternative);
          sequences.push_back(std::move(sequence));
        }

        return sequences;
      }

      // Sequences are built first: building them may add nonterminals and move productions_.
      auto emitAlternatives(std::uint16_t nonterminal, std::vector<std::vector<std::uint16_t>> sequences) -> void {
        for (auto &sequence : sequences) {
          productions_[nonterminal].push_back(std::move(sequence));
        }
      }

      // `{ a | b }` becomes N = ε | N a | N b. Left recursion keeps Earley sets linear.
      auto emitRepetition(std::uint16_t nonterminal, std::vector<std::vector<std::uint16_t>> sequences) -> void {
        for (auto &sequence : sequences) {
          sequence.insert(sequence.begin(), nonterminal);
        }

        emitAlternatives(nonterminal, std::move(sequences));
      }

      auto symbolFor(node_handle node) -> std::uint16_t {
        switch (kind(node)) {
        case node_kind::Literal:
        case node_kind::Dynamic:
          return terminalSymbol(addTerminal(node));
        case node_kind::Glue:
          return terminalSymbol(addGlue(node));
        case node_kind::Reference:
          return ruleFor(node);
        case node_kind::Alternative:
        case node_kind::Concatenation: {
          const auto nonterminal = newNonterminal();
          emitAlternatives(nonterminal, sequencesOf(node));
          return nonterminal;
        }
        case node_kind::Optional: {
          const auto nonterminal = newNonterminal();
          emitAlternatives(nonterminal, sequencesOf(tree_.getFirstChild(node)));
          productions_[nonterminal].emplace_back();
          return nonterminal;
        }
        case node_kind::ZeroOrMore: {
          const auto nonterminal = newNonterminal();
          productions_[nonterminal].emplace_back();
          emitRepetition(nonterminal, sequencesOf(tree_.getFirstChild(node)));
          return nonterminal;
        }
        case node_kind::OneOrMore: {
          // N = a | N a, sharing the symbols built for `a`.
          const auto nonterminal = newNonterminal();
          auto sequences = sequencesOf(tree_.getFirstChild(node));
          emitRepetition(nonterminal, sequences);
          emitAlternatives(nonterminal, std::move(sequences));
          return nonterminal;
        }
        case node_kind::Exception:
          fail("The exception operator - is not supported in command specs");
        default:
          fail("Unexpected node in a rule body");
        }
      }

      auto keyFor(candidate_kind candidate, text_ref prefix, text_ref text) -> std::uint16_t {
        const auto [found, inserted] = keys_.try_emplace({candidate, prefix.offset, text.offset}, static_cast<std::uint16_t>(keys_.size()));

        if (inserted && keys_.size() > max_candidate_keys) {
          throw std::length_error("Command spec exceeds the candidate limit");
        }

        return found->second;
      }

      static auto candidateKind(terminal_kind terminal) -> candidate_kind {
        return terminal == terminal_kind::literal || terminal == terminal_kind::glue ? candidate_kind::literal : candidate_kind::provider;
      }

      auto assignKeys(std::uint16_t id, std::vector<std::uint8_t> &done) -> void {
        if (done[id] != 0) {
          return;
        }

        done[id] = 1;
        auto &terminal = spec_.terminals_[id];
        terminal.key = keyFor(candidateKind(terminal.kind), {}, terminal.text);

        for (auto index = terminal.values_begin; index < terminal.values_begin + terminal.values_count; ++index) {
          auto &value = spec_.values_[index];
          value.key = keyFor(candidateKind(spec_.terminals_[value.terminal].kind), terminal.text, spec_.terminals_[value.terminal].text);
        }
      }

      // Candidate keys follow a depth-first walk from the start rule, which is grammar order.
      auto assignKeys() -> void {
        struct frame {
          std::uint16_t nonterminal;
          std::size_t production;
          std::size_t symbol;
        };

        auto visited = std::vector<std::uint8_t>(productions_.size());
        auto done = std::vector<std::uint8_t>(spec_.terminals_.size());
        auto stack = std::vector<frame>{{.nonterminal = spec_.start_, .production = 0, .symbol = 0}};
        visited[spec_.start_] = 1;

        while (!stack.empty()) {
          auto &top = stack.back();
          const auto &alternatives = productions_[top.nonterminal];

          if (top.production == alternatives.size()) {
            stack.pop_back();
            continue;
          }

          const auto &sequence = alternatives[top.production];

          if (top.symbol == sequence.size()) {
            ++top.production;
            top.symbol = 0;
            continue;
          }

          const auto symbol = sequence[top.symbol++];

          if ((symbol & terminal_flag) != 0) {
            assignKeys(static_cast<std::uint16_t>(symbol & id_mask), done);
          } else if (visited[symbol] == 0) {
            visited[symbol] = 1;
            stack.push_back({.nonterminal = symbol, .production = 0, .symbol = 0});
          }
        }

        // Unreachable terminals never reach a query; give them valid keys anyway.
        for (std::size_t id = 0; id < spec_.terminals_.size(); ++id) {
          assignKeys(static_cast<std::uint16_t>(id), done);
        }
      }

      auto computeNullable() -> void {
        spec_.nullable_.assign(productions_.size(), 0);
        auto changed = true;

        while (changed) {
          changed = false;

          for (std::size_t nonterminal = 0; nonterminal < productions_.size(); ++nonterminal) {
            if (spec_.nullable_[nonterminal] != 0) {
              continue;
            }

            for (const auto &sequence : productions_[nonterminal]) {
              const auto empty = std::ranges::all_of(sequence, [this](std::uint16_t symbol) {
                return (symbol & terminal_flag) == 0 && spec_.nullable_[symbol] != 0;
              });

              if (empty) {
                spec_.nullable_[nonterminal] = 1;
                changed = true;
                break;
              }
            }
          }
        }
      }

      auto flatten() -> void {
        for (std::size_t nonterminal = 0; nonterminal < productions_.size(); ++nonterminal) {
          spec_.productions_begin_.push_back(static_cast<std::uint32_t>(spec_.production_slots_.size()));

          for (const auto &sequence : productions_[nonterminal]) {
            if (spec_.rhs_.size() + sequence.size() + 1 > max_rhs_slots) {
              throw std::length_error("Command spec exceeds the grammar size limit");
            }

            spec_.production_slots_.push_back(static_cast<std::uint16_t>(spec_.rhs_.size()));
            spec_.rhs_.insert(spec_.rhs_.end(), sequence.begin(), sequence.end());
            spec_.rhs_.push_back(static_cast<std::uint16_t>(end_flag | nonterminal));
          }
        }

        spec_.productions_begin_.push_back(static_cast<std::uint32_t>(spec_.production_slots_.size()));
      }

    public:
      explicit spec_builder(syntax_tree &tree)
          : tree_(tree) {}

      auto build() -> command_spec {
        const auto rules = children(tree_.getRoot());

        if (rules.empty()) {
          fail("A command spec needs at least one rule");
        }

        for (const auto rule : rules) {
          const auto nonterminal = newNonterminal();

          if (!rules_.emplace(nodeText(rule), nonterminal).second) {
            fail("Duplicate rule: " + std::string{nodeText(rule)});
          }

          rule_bodies_.push_back(tree_.getFirstChild(rule));
        }

        for (std::size_t index = 0; index < rules.size(); ++index) {
          emitAlternatives(static_cast<std::uint16_t>(index), sequencesOf(rule_bodies_[index]));
        }

        spec_.start_ = 0;
        computeNullable();
        assignKeys();
        flatten();
        return std::move(spec_);
      }
    };
  }

  inline auto command_spec::compile(std::string_view source) -> command_spec {
    // The parser keeps its token buffer inline; keep it off the caller's stack.
    auto tokenizer = Lexer{};
    auto spec_parser = std::make_unique<parser<Lexer>>(tokenizer);
    auto tree = spec_parser->parse(source);
    return detail::spec_builder{tree}.build();
  }
}
}
