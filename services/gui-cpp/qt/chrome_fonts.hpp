#pragma once

#include "core/memory.hpp"
#include "fonts/face.hpp"
#include "fonts/font_role.hpp"
#include <cstdint>
#include <memory>
#include <string_view>

namespace telar::gui::qt {

class ChromeFonts {
public:
  ChromeFonts();
  [[nodiscard]] fonts::Face &face(bool emphasized) noexcept;
  [[nodiscard]] fonts::Face &face(fonts::FontRole role);
  [[nodiscard]] bool covers(std::string_view text, bool emphasized) const;
  [[nodiscard]] static std::shared_ptr<ChromeFonts> shared();

private:
  SystemAllocator memory_;
  Vector<std::uint8_t, SystemAllocator> regular_bytes_;
  Vector<std::uint8_t, SystemAllocator> emphasized_bytes_;
  fonts::Face regular_;
  fonts::Face emphasized_;
};

}
