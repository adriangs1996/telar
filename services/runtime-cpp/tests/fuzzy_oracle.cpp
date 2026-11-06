#include "paths/fuzzy_match.hpp"

using namespace telar;
using namespace telar::runtime;

extern "C" std::uint64_t fuzzy_score(const char *path, std::size_t path_length, const char *query, std::size_t query_length, std::uint16_t *positions) {
  static SystemAllocator memory;
  static FuzzyMatch matcher{memory};
  const std::string_view path_text{path, path_length};
  const std::string_view query_text{query, query_length};
  const auto score = matcher.score(path_text, query_text);
  const auto highlighted = matcher.score(path_text, query_text, {positions, query_length});
  if (score != highlighted) {
    return std::uint64_t{2} << 32;
  }

  return score ? (std::uint64_t{1} << 32) | static_cast<std::uint32_t>(*score) : 0;
}
