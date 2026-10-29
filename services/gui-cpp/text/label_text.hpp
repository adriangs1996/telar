#pragma once

#include "bounded_text.hpp"
#include <cstddef>

namespace telar::gui {

inline constexpr std::size_t label_text_capacity = 256;
using LabelText = BoundedText<label_text_capacity>;

}
