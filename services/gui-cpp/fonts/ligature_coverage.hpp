#pragma once

#include "ligature_role.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include <string_view>

namespace telar::gui::fonts {

class LigatureCoverage {
public:
  static constexpr std::size_t ascii_count = 128;

  explicit LigatureCoverage(FT_Face face, hb_font_t *font);
  [[nodiscard]] LigatureRole role(std::string_view text) const noexcept;
  [[nodiscard]] bool joins() const noexcept;
  [[nodiscard]] std::uint16_t reach() const noexcept;

private:
  struct SetDeleter {
    void operator()(hb_set_t *set) const noexcept;
  };

  using OwnedSet = std::unique_ptr<hb_set_t, SetDeleter>;

  [[nodiscard]] static OwnedSet createSet();
  [[nodiscard]] static std::uint16_t maximumContext(FT_Face face);

  std::array<LigatureRole, ascii_count> ascii_{};
  OwnedSet input_;
  OwnedSet context_;
  std::uint16_t reach_ = 0;
};

}
