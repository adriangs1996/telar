#pragma once

#include <exception>

namespace telar::gui {

class GraphicsResyncRequired final : public std::exception {
public:
  [[nodiscard]] const char *what() const noexcept override {
    return "GraphicsResyncRequired";
  }
};

}
