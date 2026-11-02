#pragma once

extern "C" {
#include <native/font.h>
}

#include <algorithm>
#include <cstring>
#include <span>

namespace telar::gui::fonts {

using FontMatch = telar_font_match;
using FontVariation = telar_font_variation;

[[nodiscard]] inline bool sameFontMatch(const FontMatch &left, const FontMatch &right) noexcept {
  return left.face_index == right.face_index && std::strncmp(std::span{left.path}.data(), std::span{right.path}.data(), sizeof(left.path)) == 0 && std::strncmp(std::span{left.postscript}.data(), std::span{right.postscript}.data(), sizeof(left.postscript)) == 0 && left.variation.count == right.variation.count && std::ranges::equal(left.variation.tags, right.variation.tags) && std::ranges::equal(left.variation.values, right.variation.values);
}

}
