module;
#include <concepts>
#include <exception>
#include <cstdio>
#include <string>
#include <variant>
#include <vector>
#include <bit>

#include <cstddef>
#include <cstdint>
#include <span>
#include <array>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include <string_view>
#include "../platform/font.h"
#include <algorithm>
#include <cstring>
#include <optional>
#include <chrono>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include <freetype/ftimage.h>
#include <freetype/ftmm.h>
#include <freetype/ftoutln.h>
#include <freetype/ftsizes.h>
#include <freetype/ftsynth.h>
#include <freetype/fttypes.h>
#include <hb-ft.h>
#include <utility>

module telar.gui.fonts.face;




import telar.gui.terminal.font_grid;
import telar.gui.terminal.copy_mode;
import telar.base.diagnostics;
import telar.client.protocol;

#include "platform/font.h"

namespace telar::gui::fonts {
namespace {

constexpr std::size_t maximum_collection_faces = 256;
constexpr double variation_unit = 65536;

struct VariationDeleter {
  FT_Library library = nullptr;

  void operator()(FT_MM_Var *master) const noexcept {
    FT_Done_MM_Var(library, master);
  }
};

std::unique_ptr<FT_MM_Var, VariationDeleter> variationMaster(FT_Library library, FT_Face face) {
  FT_MM_Var *master = nullptr;
  if (FT_Get_MM_Var(face, &master) != 0) {
    throw std::runtime_error{"FontVariationUnavailable"};
  }

  std::unique_ptr<FT_MM_Var, VariationDeleter> result{master, {.library = library}};
  if (master->num_axis > telar_font_max_axes) {
    throw std::runtime_error{"FontVariationTooLarge"};
  }

  return result;
}

}

Face::Face(std::span<const std::uint8_t> bytes, const FontMatch &match) {
  if (bytes.empty() || bytes.size() > telar_font_max_bytes || bytes.size() > static_cast<std::size_t>(std::numeric_limits<FT_Long>::max())) {
    throw std::invalid_argument{"InvalidFontData"};
  }

  FT_Library library = nullptr;
  if (FT_Init_FreeType(&library) != 0) {
    throw std::runtime_error{"FreeTypeInitFailed"};
  }

  library_.reset(library);
  selectFace(bytes, match);
  if (FT_Select_Charmap(face_.get(), FT_ENCODING_UNICODE) != 0) {
    throw std::runtime_error{"UnicodeCharmapUnavailable"};
  }

  applyVariation(match.variation);
}

void Face::initializeShaping() {
  if (shaping_buffer_) {
    return;
  }

  decltype(shaping_font_) font{hb_ft_font_create_referenced(face_.get())};
  if (!font || font.get() == hb_font_get_empty()) {
    throw std::runtime_error{"ShapingFontInitFailed"};
  }

  decltype(shaping_buffer_) buffer{hb_buffer_create()};
  if (!buffer || hb_buffer_allocation_successful(buffer.get()) == 0) {
    throw std::runtime_error{"ShapingBufferInitFailed"};
  }

  shaping_font_ = std::move(font);
  shaping_buffer_ = std::move(buffer);
}

Face::~Face() = default;

bool Face::monochrome() const noexcept {
  return FT_IS_SCALABLE(face_.get()) != 0 && FT_HAS_COLOR(face_.get()) == 0;
}

void Face::LibraryDeleter::operator()(FT_Library library) const noexcept {
  FT_Done_FreeType(library);
}

void Face::FaceDeleter::operator()(FT_Face face) const noexcept {
  FT_Done_Face(face);
}

void Face::ShapingFontDeleter::operator()(hb_font_t *font) const noexcept {
  hb_font_destroy(font);
}

void Face::ShapingBufferDeleter::operator()(hb_buffer_t *buffer) const noexcept {
  hb_buffer_destroy(buffer);
}

void Face::SizeDeleter::operator()(FT_Size size) const noexcept {
  FT_Done_Size(size);
}

void Face::selectFace(std::span<const std::uint8_t> bytes, const FontMatch &match) {
  FT_Face initial = nullptr;
  const auto length = static_cast<FT_Long>(bytes.size());
  if (FT_New_Memory_Face(library_.get(), bytes.data(), length, std::max(0, match.face_index), &initial) != 0) {
    throw std::runtime_error{"FontInitFailed"};
  }

  face_.reset(initial);
  const auto postscript = std::span{match.postscript};
  const auto name_length = static_cast<std::size_t>(std::ranges::find(postscript, '\0') - postscript.begin());
  if (name_length == postscript.size()) {
    throw std::invalid_argument{"InvalidFontPostscriptName"};
  }

  const std::string_view requested{postscript.data(), name_length};
  if (match.face_index >= 0 || requested.empty()) {
    return;
  }

  const auto count = face_->num_faces;
  if (count < 1 || std::cmp_greater(count, maximum_collection_faces)) {
    throw std::runtime_error{"FontCollectionTooLarge"};
  }

  for (FT_Long index = 0; index < count; ++index) {
    if (index != 0) {
      FT_Face candidate = nullptr;
      if (FT_New_Memory_Face(library_.get(), bytes.data(), length, index, &candidate) != 0) {
        throw std::runtime_error{"FontInitFailed"};
      }

      face_.reset(candidate);
    }

    const auto *name = FT_Get_Postscript_Name(face_.get());
    if (name != nullptr && requested == name) {
      return;
    }
  }

  throw std::runtime_error{"FontFaceNotFound"};
}

void Face::applyVariation(const FontVariation &variation) {
  if (variation.count == 0) {
    return;
  }

  if (variation.count > telar_font_max_axes) {
    throw std::invalid_argument{"FontVariationTooLarge"};
  }

  const auto master = variationMaster(library_.get(), face_.get());
  const auto axes = std::span{master->axis, master->num_axis};
  std::array<FT_Fixed, telar_font_max_axes> coordinates{};
  for (std::size_t index = 0; index < axes.size(); ++index) {
    coordinates[index] = axes[index].def;
  }

  for (std::size_t index = 0; index < variation.count; ++index) {
    const auto found = std::ranges::find_if(axes, [&](const FT_Var_Axis &axis) {
      return axis.tag == variation.tags[index];
    });
    if (found == axes.end()) {
      throw std::invalid_argument{"FontVariationAxisMissing"};
    }

    const auto fixed = static_cast<double>(variation.values[index]) * variation_unit;
    if (!std::isfinite(fixed) || fixed < static_cast<double>(found->minimum) || fixed > static_cast<double>(found->maximum)) {
      throw std::invalid_argument{"FontVariationOutOfRange"};
    }

    coordinates[static_cast<std::size_t>(found - axes.begin())] = static_cast<FT_Fixed>(std::round(fixed));
  }

  if (FT_Set_Var_Design_Coordinates(face_.get(), master->num_axis, coordinates.data()) != 0) {
    throw std::runtime_error{"FontVariationFailed"};
  }
}

FontVariation Face::variation() const {
  if (FT_HAS_MULTIPLE_MASTERS(face_.get()) == 0) {
    return {};
  }

  const auto master = variationMaster(library_.get(), face_.get());
  std::array<FT_Fixed, telar_font_max_axes> coordinates{};
  if (FT_Get_Var_Design_Coordinates(face_.get(), master->num_axis, coordinates.data()) != 0) {
    throw std::runtime_error{"FontVariationFailed"};
  }

  FontVariation result{};
  result.count = master->num_axis;
  for (std::size_t index = 0; index < master->num_axis; ++index) {
    result.tags[index] = static_cast<std::uint32_t>(master->axis[index].tag);
    result.values[index] = static_cast<float>(static_cast<double>(coordinates[index]) / variation_unit);
  }

  return result;
}

Face::OwnedSize Face::createSize(std::uint16_t pixel_height) {
  FT_Size handle = nullptr;
  if (FT_New_Size(face_.get(), &handle) != 0) {
    throw std::runtime_error{"FontSizeFailed"};
  }

  OwnedSize candidate{handle};
  auto *previous = face_->size;
  if (FT_Activate_Size(handle) != 0 || FT_Set_Pixel_Sizes(face_.get(), 0, pixel_height) != 0) {
    if (FT_Activate_Size(previous) != 0) {
      active_height_ = 0;
    }

    throw std::runtime_error{"FontSizeFailed"};
  }

  return candidate;
}

void Face::selectSize(std::uint16_t pixel_height) {
  if (pixel_height == 0) {
    throw std::invalid_argument{"InvalidPixelHeight"};
  }

  if (pixel_height == active_height_) {
    return;
  }

  auto *found = std::ranges::find(sizes_, pixel_height, &SizeEntry::height);
  if (found == sizes_.end()) {
    auto candidate = createSize(pixel_height);
    found = sizes_.begin() + static_cast<std::ptrdiff_t>(next_size_slot_);
    *found = {.height = pixel_height, .handle = std::move(candidate)};
    next_size_slot_ = (next_size_slot_ + 1) % sizes_.size();
  }

  if (FT_Activate_Size(found->handle.get()) != 0) {
    throw std::runtime_error{"FontSizeFailed"};
  }

  active_height_ = pixel_height;
  if (shaping_font_) {
    hb_ft_font_changed(shaping_font_.get());
  }
}

FontMetrics Face::metrics(std::uint16_t pixel_height) {
  selectSize(pixel_height);
  const auto &metrics = face_->size->metrics;
  const auto advance = std::max(1, FontMetrics::roundFixed(metrics.max_advance));
  if (std::cmp_greater(advance, std::numeric_limits<std::uint16_t>::max())) {
    throw std::out_of_range{"FontMetricOutOfRange"};
  }

  const glyphs::BoxStroke stroke{.units_per_em = face_->units_per_EM, .underline_thickness = face_->underline_thickness};

  return {.ascender = FontMetrics::roundFixed(metrics.ascender), .line_height = static_cast<std::uint32_t>(std::max(1, FontMetrics::roundFixed(metrics.height))), .maximum_advance = static_cast<std::uint16_t>(advance), .box_stroke = stroke.pixels(pixel_height)};
}

const LigatureCoverage &Face::ligatures() {
  if (!ligatures_) {
    initializeShaping();
    ligatures_.emplace(face_.get(), shaping_font_.get());
  }

  return *ligatures_;
}

ShapedRunView Face::shape(std::string_view text, std::uint16_t pixel_height) {
  if (text.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
    throw std::length_error{"ShapingTextTooLarge"};
  }

  validateUtf8(text);
  selectSize(pixel_height);
  initializeShaping();
  auto *buffer = shaping_buffer_.get();
  hb_buffer_reset(buffer);
  hb_buffer_add_utf8(buffer, text.data(), static_cast<int>(text.size()), 0, static_cast<int>(text.size()));
  if (hb_buffer_allocation_successful(buffer) == 0) {
    throw std::runtime_error{"ShapingFailed"};
  }

  hb_buffer_guess_segment_properties(buffer);
  hb_shape(shaping_font_.get(), buffer, nullptr, 0);
  unsigned int glyph_count = 0;
  unsigned int position_count = 0;
  const auto *glyphs = hb_buffer_get_glyph_infos(buffer, &glyph_count);
  const auto *positions = hb_buffer_get_glyph_positions(buffer, &position_count);
  if (hb_buffer_allocation_successful(buffer) == 0 || glyph_count != position_count || (glyph_count != 0 && (glyphs == nullptr || positions == nullptr))) {
    throw std::runtime_error{"ShapingFailed"};
  }

  return {{glyphs, glyph_count}, {positions, position_count}, hb_buffer_get_direction(buffer) == HB_DIRECTION_RTL};
}

GlyphBitmapView Face::rasterize(GlyphRasterRequest request) {
  selectSize(request.pixel_height);
  if (FT_Load_Glyph(face_.get(), request.index, FT_LOAD_DEFAULT) != 0) {
    throw std::runtime_error{"GlyphLoadFailed"};
  }

  auto *slot = face_->glyph;
  if (request.style.bold) {
    FT_GlyphSlot_Embolden(slot);
  }

  if (request.style.italic) {
    FT_GlyphSlot_Oblique(slot);
  }

  if (request.thicken_strength != 0 && slot->format == FT_GLYPH_FORMAT_OUTLINE) {
    // A bounded half-pixel dilation changes ink, not advances or the terminal grid.
    constexpr FT_Pos maximum_thickening = 32;
    constexpr unsigned maximum_strength = std::numeric_limits<std::uint8_t>::max();
    const auto strength = static_cast<FT_Pos>((request.thicken_strength * maximum_thickening + maximum_strength / 2) / maximum_strength);
    if (FT_Outline_EmboldenXY(&slot->outline, strength, strength) != 0) {
      throw std::runtime_error{"GlyphThickeningFailed"};
    }

    FT_Outline_Translate(&slot->outline, -strength / 2, -strength / 2);
  }

  if (FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL) != 0) {
    throw std::runtime_error{"GlyphRenderFailed"};
  }

  const auto &bitmap = slot->bitmap;
  if (bitmap.width == 0 || bitmap.rows == 0) {
    return {.coverage = {}, .stride = 0, .width = bitmap.width, .height = bitmap.rows, .left = slot->bitmap_left, .top = slot->bitmap_top};
  }

  if (bitmap.pixel_mode != FT_PIXEL_MODE_GRAY || bitmap.buffer == nullptr) {
    throw std::runtime_error{"UnsupportedGlyphBitmap"};
  }

  const auto stride = static_cast<std::size_t>(std::abs(static_cast<std::int64_t>(bitmap.pitch)));
  if (bitmap.width > stride || (bitmap.rows != 0 && stride > std::numeric_limits<std::size_t>::max() / bitmap.rows)) {
    throw std::runtime_error{"InvalidGlyphBitmap"};
  }

  return {.coverage = {bitmap.buffer, stride * bitmap.rows}, .stride = stride, .width = bitmap.width, .height = bitmap.rows, .left = slot->bitmap_left, .top = slot->bitmap_top};
}

bool Face::covers(char32_t scalar) const noexcept {
  return FT_Get_Char_Index(face_.get(), static_cast<FT_ULong>(scalar)) != 0;
}

std::string_view Face::family() const noexcept {
  return face_->family_name != nullptr ? face_->family_name : "";
}

std::string_view Face::style() const noexcept {
  return face_->style_name != nullptr ? face_->style_name : "";
}

bool Face::fixedPitch() const noexcept {
  return FT_IS_FIXED_WIDTH(face_.get()) != 0;
}

}
