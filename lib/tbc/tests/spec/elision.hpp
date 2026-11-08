#ifndef TBC_TEST_ELISION_HPP
#define TBC_TEST_ELISION_HPP

#include "system_library.hpp"

#include <string>

namespace elision {
  // Declared without contracts, as a project header shares methods whose bodies live in one source.
  class registry {
  public:
    [[nodiscard]] const std::string &label() const;
    [[nodiscard]] const std::string &name() const;
    [[nodiscard]] const std::string &pick(const std::string &fallback) const;

  private:
    std::string name_;
  };

  class painted_item : public library::item {
  public:
    library::node *update(library::node *previous) override;
  };
}

#endif
