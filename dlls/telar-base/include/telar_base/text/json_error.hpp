#pragma once

#include <exception>

namespace telar {

  class JsonError final : public std::exception {
  public:
    const char *what() const noexcept override {
      return "Invalid JSON record";
    }
  };

}
