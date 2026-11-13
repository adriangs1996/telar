module;

#include <cstdint>
#include <cstddef>
#include <freetype/freetype.h>
#include <hb.h>
#include <freetype/tttables.h>
#include <hb-ot.h>

module telar.gui.fonts.face;

import std;

import telar.gui.core.unicode_scalar;



namespace telar::gui::fonts {
namespace {

LigatureRole lookupRole(const hb_set_t *input, const hb_set_t *context, hb_codepoint_t codepoint) noexcept {
  if (hb_set_has(input, codepoint) != 0) {
    return LigatureRole::input;
  }

  return hb_set_has(context, codepoint) != 0 ? LigatureRole::context : LigatureRole::none;
}

}

void LigatureCoverage::SetDeleter::operator()(hb_set_t *set) const noexcept {
  hb_set_destroy(set);
}

LigatureCoverage::OwnedSet LigatureCoverage::createSet() {
  OwnedSet set{hb_set_create()};
  if (!set || hb_set_allocation_successful(set.get()) == 0) {
    throw std::bad_alloc{};
  }

  return set;
}

std::uint16_t LigatureCoverage::maximumContext(FT_Face face) {
  const auto *table = static_cast<const TT_OS2 *>(FT_Get_Sfnt_Table(face, FT_SFNT_OS2));
  constexpr std::uint16_t first_context_version = 2;
  constexpr auto missing_version = std::numeric_limits<std::uint16_t>::max();
  if (table == nullptr || table->version == missing_version || table->version < first_context_version) {
    return 0;
  }

  return table->usMaxContext;
}

LigatureCoverage::LigatureCoverage(FT_Face face, hb_font_t *font) {
  constexpr std::array features{HB_TAG('l', 'i', 'g', 'a'), HB_TAG('c', 'l', 'i', 'g'), HB_TAG('c', 'a', 'l', 't'), HB_TAG('r', 'l', 'i', 'g'), HB_TAG('r', 'c', 'l', 't'), hb_tag_t{0}};
  constexpr auto substitutions = HB_TAG('G', 'S', 'U', 'B');
  auto *layout = hb_font_get_face(font);
  const auto lookups = createSet();
  hb_ot_layout_collect_lookups(layout, substitutions, nullptr, nullptr, features.data(), lookups.get());
  if (hb_set_is_empty(lookups.get()) != 0) {
    return;
  }

  const auto input_glyphs = createSet();
  const auto context_glyphs = createSet();
  hb_codepoint_t lookup = HB_SET_VALUE_INVALID;
  while (hb_set_next(lookups.get(), &lookup) != 0) {
    hb_ot_layout_lookup_collect_glyphs(layout, substitutions, lookup, context_glyphs.get(), input_glyphs.get(), context_glyphs.get(), nullptr);
  }

  const std::unique_ptr<hb_map_t, decltype(&hb_map_destroy)> mapping{hb_map_create(), hb_map_destroy};
  if (!mapping) {
    throw std::bad_alloc{};
  }
  const auto unicodes = createSet();
  hb_face_collect_nominal_glyph_mapping(layout, mapping.get(), unicodes.get());
  input_ = createSet();
  context_ = createSet();
  hb_codepoint_t codepoint = HB_SET_VALUE_INVALID;
  while (hb_set_next(unicodes.get(), &codepoint) != 0) {
    const auto glyph = hb_map_get(mapping.get(), codepoint);
    const auto found = lookupRole(input_glyphs.get(), context_glyphs.get(), glyph);
    if (found == LigatureRole::none) {
      continue;
    }

    hb_set_add(found == LigatureRole::input ? input_.get() : context_.get(), codepoint);
    if (codepoint < ascii_count) {
      ascii_[codepoint] = found;
    }
  }

  for (const auto *set : {lookups.get(), input_glyphs.get(), context_glyphs.get(), unicodes.get(), input_.get(), context_.get()}) {
    if (hb_set_allocation_successful(set) == 0) {
      throw std::bad_alloc{};
    }
  }

  if (hb_map_allocation_successful(mapping.get()) == 0) {
    throw std::bad_alloc{};
  }

  if (hb_set_is_empty(input_.get()) != 0) {
    ascii_ = {};
    input_.reset();
    context_.reset();
    return;
  }

  reach_ = maximumContext(face);
}

LigatureRole LigatureCoverage::role(std::string_view text) const noexcept {
  if (text.size() == 1 && static_cast<unsigned char>(text.front()) < ascii_count) {
    return ascii_[static_cast<unsigned char>(text.front())];
  }

  if (!input_) {
    return LigatureRole::none;
  }

  auto strongest = LigatureRole::none;
  try {
    while (!text.empty()) {
      const auto length = Utf8Scalar::sequenceLength(static_cast<unsigned char>(text.front()));
      if (length == 0 || length > text.size()) {
        return LigatureRole::none;
      }

      const auto codepoint = Utf8Scalar::decode(text.substr(0, length));
      const auto current = lookupRole(input_.get(), context_.get(), codepoint);
      if (current == LigatureRole::none) {
        return current;
      }

      strongest = std::max(strongest, current);
      text.remove_prefix(length);
    }
  } catch (const std::exception &) {
    return LigatureRole::none;
  }

  return strongest;
}

bool LigatureCoverage::joins() const noexcept {
  return input_ != nullptr;
}

std::uint16_t LigatureCoverage::reach() const noexcept {
  return reach_;
}

}
