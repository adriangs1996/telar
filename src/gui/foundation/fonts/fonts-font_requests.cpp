module telar.gui.foundation.fonts;

import std;

import telar.gui.foundation.core;
import telar.gui.foundation.text;

namespace telar::gui::inline foundation::inline fonts {

  bool FontCoverage::covers(const Face& face, std::string_view text) {
    while (!text.empty()) {
      const auto length = Utf8Scalar::sequenceLength(static_cast<unsigned char>(text.front()));
      if (length == 0 || length > Utf8Scalar::leading_masks.size() || length > text.size()) {
        throw std::invalid_argument{"InvalidFontCoverageUtf8"};
      }

      const auto codepoint = Utf8Scalar::decode(text.substr(0, length));
      if (!isSelectorOrJoiner(codepoint) && !face.covers(static_cast<char32_t>(codepoint))) {
        return false;
      }

      text.remove_prefix(length);
    }

    return true;
  }

  bool FontCoverage::isSelectorOrJoiner(std::uint32_t codepoint) noexcept {
    constexpr std::uint32_t non_joiner = 0x200c;
    constexpr std::uint32_t joiner = 0x200d;
    constexpr std::uint32_t first_selector = 0xfe00;
    constexpr std::uint32_t last_selector = 0xfe0f;
    constexpr std::uint32_t first_extended_selector = 0xe0100;
    constexpr std::uint32_t last_extended_selector = 0xe01ef;

    return codepoint == non_joiner || codepoint == joiner || (codepoint >= first_selector && codepoint <= last_selector) || (codepoint >= first_extended_selector && codepoint <= last_extended_selector);
  }

  std::optional<FontQuery> FontQuery::create(std::string_view text) {
    if (text.size() > maximum_bytes) {
      return std::nullopt;
    }

    FontQuery query;

    std::ranges::copy(text, query.text_.begin());
    query.text_length_ = static_cast<std::uint8_t>(text.size());
    while (!text.empty()) {
      const auto length = Utf8Scalar::sequenceLength(static_cast<unsigned char>(text.front()));
      if (length == 0 || length > Utf8Scalar::leading_masks.size() || length > text.size()) {
        throw std::invalid_argument{"InvalidFontQueryUtf8"};
      }

      const auto scalar = text.substr(0, length);
      if (!FontCoverage::isSelectorOrJoiner(Utf8Scalar::decode(scalar))) {
        std::ranges::copy(scalar, query.codepoints_.begin() + query.query_length_);
        query.query_length_ = static_cast<std::uint8_t>(query.query_length_ + length);
      }

      text.remove_prefix(length);
    }

    return query.query_length_ == 0 ? std::nullopt : std::optional{query};
  }

  std::string_view FontQuery::text() const noexcept {
    return {text_.data(), text_length_};
  }

  const char* FontQuery::codepoints() const noexcept {
    return codepoints_.data();
  }

  void FontRequests::request(std::string_view text) {
    if (text.starts_with(placeholder_prefix) || misses_.contains(text) || queued(text)) {
      return;
    }

    const auto query = FontQuery::create(text);
    if (!query) {
      misses_.remember(text);
      return;
    }

    if (count_ == pending_.size()) {
      turned_away_ = true;
      return;
    }

    pending_[(head_ + count_) % pending_.size()] = *query;
    ++count_;
  }

  std::optional<FontQuery> FontRequests::take() {
    if (in_flight_ || count_ == 0) {
      return std::nullopt;
    }

    in_flight_ = pending_[head_];
    head_ = (head_ + 1) % pending_.size();
    --count_;

    return in_flight_;
  }

  bool FontRequests::finish(const FontQuery& query, bool changed) {
    if (in_flight_ && in_flight_->text() == query.text()) {
      in_flight_.reset();
    }

    if (changed) {
      retries_ = 0;
    } else {
      misses_.remember(query.text());
    }

    if (turned_away_ && count_ == 0 && !in_flight_) {
      turned_away_ = false;
      if (retries_ < maximum_retries) {
        ++retries_;
        return true;
      }
    }

    return changed;
  }

  bool FontRequests::Misses::contains(std::string_view text) const {
    const auto hash = digest(text);
    const auto entries = bucket(hash);

    return std::ranges::find(entries, hash) != entries.end();
  }

  void FontRequests::Misses::remember(std::string_view text) {
    const auto hash = digest(text);
    auto entries = bucket(hash);

    for (auto& entry : entries) {
      if (entry == hash) {
        return;
      }

      if (entry == 0) {
        entry = hash;
        return;
      }
    }

    auto& next = next_[hash % sets];

    entries[next] = hash;
    next = (next + 1) % ways;
  }

  std::uint64_t FontRequests::Misses::digest(std::string_view text) {
    return static_cast<std::uint64_t>(std::hash<std::string_view>{}(text)) | std::uint64_t{1};
  }

  std::span<std::uint64_t> FontRequests::Misses::bucket(std::uint64_t hash) noexcept {
    return std::span{hashes_}.subspan((hash % sets) * ways, ways);
  }

  std::span<const std::uint64_t> FontRequests::Misses::bucket(std::uint64_t hash) const noexcept {
    return std::span{hashes_}.subspan((hash % sets) * ways, ways);
  }

  bool FontRequests::queued(std::string_view text) const {
    if (in_flight_ && in_flight_->text() == text) {
      return true;
    }

    for (std::size_t offset = 0; offset < count_; ++offset) {
      if (pending_[(head_ + offset) % pending_.size()].text() == text) {
        return true;
      }
    }

    return false;
  }

}
