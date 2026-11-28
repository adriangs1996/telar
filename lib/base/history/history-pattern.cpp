module telar.base.history;

import std;
import telar.base.ds;
import :text;

// A query into a pattern, with fzf's extended search syntax (src/pattern.go, parseTerms).
namespace telar::runtime {

  namespace {

    using Characters = std::span<const std::uint32_t>;

    bool startsWith(Characters text, std::uint32_t character) noexcept {
      return !text.empty() && text.front() == character;
    }

    bool endsWith(Characters text, std::uint32_t character) noexcept {
      return !text.empty() && text.back() == character;
    }

    // The query's characters, decoded, `\ ` a space inside a term, handed to `term` one term at
    // a time as spaces separate them.
    template <typename Term>
    void splitTerms(std::string_view query, Term term) noexcept {
      ds::Array<std::uint32_t, HistoryPattern::max_characters> characters{};
      std::size_t count = 0;

      while (!query.empty()) {
        const auto decoded = history_text::decode(query);

        query.remove_prefix(decoded.bytes);
        if (decoded.character == ' ') {
          term(characters.view().first(count));
          count = 0;
          continue;
        }

        auto character = decoded.character;

        if (character == '\\' && query.starts_with(' ')) {
          character = ' ';
          query.remove_prefix(1);
        }

        if (count < characters.size()) {
          characters.atMut(count++) = character;
        }
      }

      term(characters.view().first(count));
    }

    // The term `text` asks for, by the operators around it, which it loses: `!` inverts, `$`
    // anchors the end, `'` quotes, `^` anchors the start.
    HistoryTerm termOf(Characters& text, bool fuzzy) noexcept {
      HistoryTerm term{.kind = fuzzy ? HistoryTermKind::fuzzy : HistoryTermKind::exact, .ranks_prefix = !fuzzy};

      if (startsWith(text, '!')) {
        term = {.kind = HistoryTermKind::exact, .inverse = true};
        text = text.subspan(1);
      }

      if ((text.size() != 1 || text.front() != '$') && endsWith(text, '$')) {
        term.kind = HistoryTermKind::suffix;
        term.ranks_prefix = false;
        text = text.first(text.size() - 1);
      }

      if (text.size() > 2 && startsWith(text, '\'') && endsWith(text, '\'')) {
        term.kind = HistoryTermKind::exact_boundary;
        text = text.subspan(1, text.size() - 2);
      } else if (startsWith(text, '\'')) {
        // Flips what a plain term would be.
        term.kind = fuzzy && !term.inverse ? HistoryTermKind::exact : HistoryTermKind::fuzzy;
        text = text.subspan(1);
      } else if (startsWith(text, '^')) {
        term.kind = term.kind == HistoryTermKind::suffix ? HistoryTermKind::equal : HistoryTermKind::prefix;
        text = text.subspan(1);
      } else {
        return term;
      }

      term.ranks_prefix = false;
      return term;
    }

    void parseExtended(HistoryPattern& pattern, std::string_view query, HistoryMatchMode mode) noexcept {
      const bool fuzzy = mode == HistoryMatchMode::fuzzy;
      // After a `|`, the next term is an alternative of the one before it.
      bool join = false;
      bool after_bar = false;

      splitTerms(query, [&](Characters text) {
        if (text.empty()) {
          return;
        }

        if (!pattern.empty() && !after_bar && text.size() == 1 && text.front() == '|') {
          join = true;
          after_bar = true;
          return;
        }

        after_bar = false;

        const auto term = termOf(text, fuzzy);

        if (text.empty()) {
          return;
        }

        HistoryPatternBuilder::add(pattern, text, term, true, join);
        join = false;
      });
    }

    // The whole query as one term of `kind`, spaces and all.
    void parseWhole(HistoryPattern& pattern, std::string_view query, HistoryTermKind kind, bool smart_case) noexcept {
      ds::Array<std::uint32_t, HistoryPattern::max_characters> characters{};
      std::size_t count = 0;

      for (; !query.empty() && count < characters.size(); ++count) {
        const auto decoded = history_text::decode(query);

        characters.atMut(count) = decoded.character;
        query.remove_prefix(decoded.bytes);
      }

      HistoryPatternBuilder::add(pattern, characters.view().first(count), HistoryTerm{.kind = kind}, smart_case, false);
    }

  }

  void HistoryPatternBuilder::add(HistoryPattern& pattern, std::span<const std::uint32_t> text, HistoryTerm term, bool smart_case, bool join_previous) noexcept {
    const auto room = HistoryPattern::max_characters - pattern.character_count_;
    if (text.empty() || room == 0 || pattern.term_count_ == HistoryPattern::max_terms) {
      return;
    }

    text = text.first(std::min(text.size(), room));
    term.case_sensitive = smart_case && std::ranges::any_of(text, [](std::uint32_t character) {
      return history_text::fold(character).upper;
    });

    term.normalize = std::ranges::none_of(text, [](std::uint32_t character) {
      return history_text::unaccent(character) != character;
    });

    term.or_next = false;
    term.offset = pattern.character_count_;
    term.length = static_cast<std::uint16_t>(text.size());

    for (const auto character : text) {
      pattern.characters_.atMut(pattern.character_count_++) = term.case_sensitive ? character : history_text::fold(character).character;
    }

    if (join_previous && pattern.term_count_ != 0) {
      pattern.terms_.atMut(pattern.term_count_ - 1).or_next = true;
    }

    pattern.terms_.atMut(pattern.term_count_++) = term;
  }

  void HistoryPatternBuilder::literal(HistoryPattern& pattern, std::string_view query) noexcept {
    pattern = HistoryPattern{};
    parseWhole(pattern, query, HistoryTermKind::fuzzy, false);
  }

  HistoryPattern::HistoryPattern(std::string_view query, HistoryMatchMode mode) noexcept {
    switch (mode) {
    case HistoryMatchMode::fuzzy:
    case HistoryMatchMode::substring:
      parseExtended(*this, query, mode);
      break;
    case HistoryMatchMode::prefix:
      parseWhole(*this, query, HistoryTermKind::prefix, true);
      break;
    case HistoryMatchMode::exact:
      parseWhole(*this, query, HistoryTermKind::exact, true);
      break;
    }
  }

  bool HistoryPattern::ranks() const noexcept {
    return std::ranges::any_of(terms(), [](const HistoryTerm& term) {
      return !term.inverse;
    });
  }

}
