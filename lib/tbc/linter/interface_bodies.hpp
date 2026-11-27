#ifndef TBC_LINTER_INTERFACE_BODIES_HPP
#define TBC_LINTER_INTERFACE_BODIES_HPP

#include <clang/AST/ASTConsumer.h>
#include <llvm/ADT/StringMap.h>
#include <llvm/ADT/StringSet.h>
#include <llvm/Support/Error.h>
#include <llvm/Support/raw_ostream.h>

#include <mutex>
#include <string>
#include <vector>

namespace tbc_lint {
  // Reads the modules allowed to keep function bodies in their interfaces: one module name per line,
  // where blank lines and lines that start with # are ignored.
  llvm::Expected<llvm::StringSet<>> readInterfaceAllowlist(llvm::StringRef path);

  // The allowlist and what the units checked in parallel found about each module they saw.
  class interface_modules {
  public:
    explicit interface_modules(llvm::StringSet<> allowed);

    [[nodiscard]] bool allowed(llvm::StringRef module) const;

    // Counts the bodies one interface unit of a module keeps.
    void record(llvm::StringRef module, unsigned bodies);

    // Counts again what a unit recorded in an earlier run whose report is replayed, `<bodies>
    // <module>`, so that a module's entry is judged by all its interface units.
    void replay(llvm::StringRef record);

    // What the unit the calling thread checks records, which its stamp keeps; a unit is checked on
    // one thread from start to end.
    static inline thread_local std::vector<std::string>* unit_records = nullptr;

    // Reports each allowed module that every one of its checked interface units keeps free of bodies,
    // so that its entry can be removed. Returns whether there was one.
    bool reportStale(llvm::raw_ostream& output, bool errors, llvm::StringRef allowlist) const;

  private:
    llvm::StringSet<> allowed_;
    mutable std::mutex mutex_;
    llvm::StringMap<unsigned> bodies_;
  };

  // Reports the function bodies of a module interface unit: an interface carries declarations, and its
  // bodies belong to an implementation unit, so that changing one recompiles that unit and not every
  // importer. Constexpr and consteval functions, whose bodies importers evaluate, the hot paths marked
  // [[tbc::hot_path]] and the templates over a caller's type marked [[tbc::generic]] may stay.
  class interface_body_check final : public clang::ASTConsumer {
  public:
    interface_body_check(interface_modules& modules, bool errors);

    void HandleTranslationUnit(clang::ASTContext& context) override;

  private:
    interface_modules& modules_;
    bool errors_;
  };
}

#endif
