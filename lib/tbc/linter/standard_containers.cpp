#include "standard_containers.hpp"

#include <clang/AST/ASTContext.h>
#include <clang/AST/TypeLoc.h>
#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/SourceManager.h>
#include <llvm/ADT/SmallVector.h>
#include <llvm/Support/MemoryBuffer.h>

#include <algorithm>
#include <array>
#include <system_error>

namespace tbc_lint {
  namespace {
    struct replacement {
      llvm::StringLiteral standard;
      llvm::StringLiteral telar;
    };

    constexpr std::array<replacement, 9> replacements{{
        {.standard = "vector", .telar = "Vec"},
        {.standard = "array", .telar = "Array"},
        {.standard = "optional", .telar = "Option"},
        {.standard = "basic_string", .telar = "String"},
        {.standard = "string", .telar = "String"},
        {.standard = "map", .telar = "Map"},
        {.standard = "unordered_map", .telar = "Map"},
        {.standard = "function", .telar = "Function"},
        {.standard = "move_only_function", .telar = "Function"},
    }};

    // The telar::ds container a standard declaration's name stands for, if it is one.
    const replacement* replacementOf(const clang::NamedDecl& declaration) {
      const auto* context = declaration.getDeclContext()->getRedeclContext();

      for (const auto* inline_space = llvm::dyn_cast<clang::NamespaceDecl>(context); inline_space != nullptr && inline_space->isInlineNamespace(); inline_space = llvm::dyn_cast<clang::NamespaceDecl>(context)) {
        context = inline_space->getParent()->getRedeclContext();
      }

      const auto* name_space = llvm::dyn_cast<clang::NamespaceDecl>(context);
      if (name_space == nullptr || !name_space->getParent()->getRedeclContext()->isTranslationUnit() || name_space->getName() != "std" || declaration.getIdentifier() == nullptr) {
        return nullptr;
      }

      const auto name = declaration.getName();
      const auto found = std::ranges::find(replacements, name, &replacement::standard);

      return found == replacements.end() ? nullptr : &*found;
    }
  }

  llvm::Expected<std::vector<std::string>> container_allowlist::read(llvm::StringRef path) {
    auto buffer = llvm::MemoryBuffer::getFile(path, /*IsText=*/true);
    if (!buffer) {
      return llvm::createStringError(buffer.getError(), "cannot read " + path + ": " + buffer.getError().message());
    }

    std::vector<std::string> result;
    llvm::SmallVector<llvm::StringRef, 128> lines;

    (*buffer)->getBuffer().split(lines, '\n');
    for (std::size_t index = 0; index < lines.size(); ++index) {
      const auto line = lines[index].trim();
      if (line.empty() || line.starts_with("#")) {
        continue;
      }

      if (line.starts_with("/")) {
        return llvm::createStringError(std::make_error_code(std::errc::invalid_argument), path + ":" + llvm::Twine(index + 1) + ": '" + line + "' is not a path from the repository root");
      }

      result.push_back(line.str());
    }

    return result;
  }

  container_allowlist::container_allowlist(const std::vector<std::string>& folders) {
    for (const auto& path : folders) {
      folders_.push_back({.path = "/" + path});
    }
  }

  container_allowlist::folder* container_allowlist::match(llvm::StringRef file) {
    // A folder ends in a slash and holds every file below it; any other entry is one file.
    for (auto& folder : folders_) {
      if (llvm::StringRef(folder.path).ends_with("/") ? file.contains(folder.path) : file.ends_with(folder.path)) {
        return &folder;
      }
    }

    return nullptr;
  }

  bool container_allowlist::allowed(llvm::StringRef file) {
    const std::scoped_lock lock(mutex_);
    auto* folder = match(file);
    if (folder == nullptr) {
      return false;
    }

    folder->used = true;
    if (unit_events != nullptr) {
      unit_events->push_back("used " + file.str());
    }

    return true;
  }

  void container_allowlist::seen(llvm::StringRef file) {
    const std::scoped_lock lock(mutex_);

    if (auto* folder = match(file)) {
      folder->seen = true;
      if (unit_events != nullptr) {
        unit_events->push_back("seen " + file.str());
      }
    }
  }

  void container_allowlist::replay(llvm::StringRef event) {
    const auto [kind, file] = event.split(' ');
    const std::scoped_lock lock(mutex_);
    auto* folder = match(file);
    if (folder == nullptr) {
      return;
    }

    if (kind == "used") {
      folder->used = true;
    } else if (kind == "seen") {
      folder->seen = true;
    }
  }

  bool container_allowlist::reportStale(llvm::raw_ostream& output, bool errors, llvm::StringRef path) const {
    const std::scoped_lock lock(mutex_);
    bool stale = false;

    for (const auto& folder : folders_) {
      if (folder.seen && !folder.used) {
        output << path << ": " << (errors ? "error" : "warning") << ": '" << llvm::StringRef(folder.path).drop_front() << "' uses no container telar::ds replaces; remove it from the allowlist [tbc-standard-container]\n";
        stale = true;
      }
    }

    return stale;
  }

  standard_container_check::standard_container_check(bool errors, checked_definitions& checked, container_allowlist& allowlist)
      : errors_(errors),
        checked_(checked),
        allowlist_(allowlist) {}

  void standard_container_check::registerMatchers(clang::ast_matchers::MatchFinder& finder) {
    using namespace clang::ast_matchers;

    finder.addMatcher(translationUnitDecl().bind("unit"), this);
    finder.addMatcher(typeLoc(unless(isExpansionInSystemHeader()), loc(templateSpecializationType())).bind("type"), this);
    finder.addMatcher(typeLoc(unless(isExpansionInSystemHeader()), loc(typedefType())).bind("type"), this);
    // What `import std;` exports, it exports through using-declarations, so a name such as std::string
    // is spelled through one.
    finder.addMatcher(typeLoc(unless(isExpansionInSystemHeader()), loc(usingType())).bind("type"), this);
    finder.addMatcher(typeLoc(unless(isExpansionInSystemHeader()), loc(constantArrayType())).bind("type"), this);
    // The traversal steps from a qualified type, as `const std::vector<int>`, to the type it qualifies
    // without offering it to the matchers, so the qualified one is matched and unwrapped.
    finder.addMatcher(typeLoc(unless(isExpansionInSystemHeader()), loc(qualType(hasLocalQualifiers()))).bind("type"), this);
  }

  void standard_container_check::run(const clang::ast_matchers::MatchFinder::MatchResult& result) {
    const auto& sources = result.Context->getSourceManager();

    if (result.Nodes.getNodeAs<clang::TranslationUnitDecl>("unit") != nullptr) {
      reported_.clear();
      if (sources.getFileEntryRefForID(sources.getMainFileID())) {
        allowlist_.seen(llvm::StringRef(checked_definitions::place(sources, sources.getLocForStartOfFile(sources.getMainFileID()))).rsplit(':').first);
      }

      return;
    }

    const auto* matched = result.Nodes.getNodeAs<clang::TypeLoc>("type");
    if (matched == nullptr) {
      return;
    }

    const clang::TypeLoc unqualified = matched->getUnqualifiedLoc();
    const auto* type = &unqualified;

    const replacement* found = nullptr;
    std::string spelled;

    if (const auto specialization = type->getAs<clang::TemplateSpecializationTypeLoc>()) {
      const auto* pattern = specialization.getTypePtr()->getTemplateName().getAsTemplateDecl();

      found = pattern == nullptr ? nullptr : replacementOf(*pattern);
      spelled = found == nullptr ? "" : "std::" + found->standard.str();
    } else if (const auto alias = type->getAs<clang::TypedefTypeLoc>()) {
      const auto* declaration = alias.getTypePtr()->getDecl();

      found = replacementOf(*declaration);
      spelled = found == nullptr ? "" : "std::" + declaration->getName().str();
    } else if (const auto used = type->getAs<clang::UsingTypeLoc>()) {
      if (const auto* declaration = llvm::dyn_cast<clang::NamedDecl>(used.getTypePtr()->getDecl()->getTargetDecl())) {
        found = replacementOf(*declaration);
        spelled = found == nullptr ? "" : "std::" + declaration->getName().str();
      }
    } else if (type->getAs<clang::ConstantArrayTypeLoc>()) {
      static constexpr replacement array{.standard = "", .telar = "Array"};

      found = &array;
      spelled = "a C array";
    }

    if (found == nullptr) {
      return;
    }

    const auto location = sources.getExpansionLoc(type->getBeginLoc());
    if (location.isInvalid() || !reported_.insert(location.getRawEncoding()).second) {
      return;
    }

    const auto place = checked_definitions::place(sources, location);
    if (allowlist_.allowed(llvm::StringRef(place).rsplit(':').first)) {
      return;
    }

    if (!sources.isInMainFile(location) && !checked_.claim("container:" + place)) {
      return;
    }

    auto& diagnostics = result.Context->getDiagnostics();
    const auto id = diagnostics.getCustomDiagID(errors_ ? clang::DiagnosticsEngine::Error : clang::DiagnosticsEngine::Warning, "%0 is not used in telar code; use telar::ds::%1, whose accessors follow the rules tbc checks [tbc-standard-container]");

    diagnostics.Report(location, id) << spelled << found->telar.str();
  }
}
