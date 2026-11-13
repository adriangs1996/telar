#pragma once

#include "telar_base/text/decimal.hpp"
#include <concepts>
#include <limits>
#include <optional>
#include <string_view>

namespace telar::runtime {

  struct KittyControlField {
    char key;
    std::string_view value;
  };

  class KittyControlFields {
  public:
    explicit KittyControlFields(std::string_view control) noexcept
        : remaining_(control) {}

    std::optional<KittyControlField> next() noexcept {
      if (remaining_.empty()) {
        return std::nullopt;
      }

      const auto comma = remaining_.find(',');
      const auto field = remaining_.substr(0, comma);

      remaining_ = comma == std::string_view::npos ? std::string_view{} : remaining_.substr(comma + 1);
      if (field.size() < 3 || field.find('=') != 1 || (comma != std::string_view::npos && remaining_.empty())) {
        valid_ = false;
        remaining_ = {};
        return std::nullopt;
      }

      return KittyControlField{field.front(), field.substr(2)};
    }

    bool valid() const noexcept {
      return valid_;
    }

  private:
    std::string_view remaining_;
    bool valid_ = true;
  };

  template <std::unsigned_integral Number>
  std::optional<Number> kittyUnsigned(std::string_view text) noexcept {
    return unsignedDecimal<Number>(text);
  }

}
