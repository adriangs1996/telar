#ifndef TBC_LINTER_PIPELINE_HPP
#define TBC_LINTER_PIPELINE_HPP

#include "blank_lines.hpp"
#include "checked_definitions.hpp"
#include "const_overloads.hpp"
#include "interface_bodies.hpp"
#include "lifetime_analysis.hpp"
#include "standard_containers.hpp"

#include <clang/AST/ASTConsumer.h>
#include <clang/ASTMatchers/ASTMatchFinder.h>
#include <llvm/ADT/StringRef.h>
#include <llvm/ADT/StringSwitch.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace tbc_lint {
  enum class checker_kind : std::uint8_t {
    lifetime,
    bounds,
    blank_lines,
    interface_bodies,
    standard_containers,
  };

  inline std::optional<checker_kind> checkerNamed(llvm::StringRef name) {
    return llvm::StringSwitch<std::optional<checker_kind>>(name)
        .Case("lifetime", checker_kind::lifetime)
        .Case("bounds", checker_kind::bounds)
        .Case("blank-lines", checker_kind::blank_lines)
        .Case("interface-bodies", checker_kind::interface_bodies)
        .Case("standard-containers", checker_kind::standard_containers)
        .Default(std::nullopt);
  }

  struct pipeline_settings {
    bool lifetime = true;
    bool bounds = false;
    bool blank_lines = false;
    bool interface_bodies = false;
    bool standard_containers = false;
    bool errors = false;
    std::string header_filter;
    blank_line_fixes* fixes = nullptr;
    interface_modules* interfaces = nullptr;
    checked_definitions* checked = nullptr;
    container_allowlist* containers = nullptr;
  };

  // Owns the AST matchers and per-TU analysis state for one translation unit, shared between the
  // standalone tbc-lint driver and the Clang compiler plugin.
  class unit_pipeline {
  public:
    explicit unit_pipeline(pipeline_settings settings);
    ~unit_pipeline();

    unit_pipeline(const unit_pipeline&) = delete;
    unit_pipeline& operator=(const unit_pipeline&) = delete;
    unit_pipeline(unit_pipeline&&) = delete;
    unit_pipeline& operator=(unit_pipeline&&) = delete;

    [[nodiscard]] std::unique_ptr<clang::ASTConsumer> createConsumer();

  private:
    class borrow_check;

    pipeline_settings settings_;
    clang::ast_matchers::MatchFinder finder_;
    std::unique_ptr<borrow_check> borrows_;
    std::optional<const_overload_check> overloads_;
    std::optional<blank_line_check> blank_lines_;
    std::optional<standard_container_check> containers_;
    bool has_matchers_ = false;
  };
}

#endif
