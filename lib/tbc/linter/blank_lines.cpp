#include "blank_lines.hpp"

#include <clang/AST/ASTContext.h>
#include <clang/AST/Decl.h>
#include <clang/AST/DeclCXX.h>
#include <clang/AST/Expr.h>
#include <clang/AST/Stmt.h>
#include <clang/Basic/Diagnostic.h>
#include <llvm/ADT/SmallPtrSet.h>
#include <llvm/ADT/SmallString.h>
#include <llvm/ADT/SmallVector.h>
#include <llvm/Support/Error.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/MemoryBuffer.h>

#include <algorithm>

namespace tbc_lint {
  namespace {
    // Case and goto labels wrap the statement that follows them.
    const clang::Stmt& unlabeled(const clang::Stmt& statement) {
      const auto* current = &statement;

      while (true) {
        if (const auto* branch = llvm::dyn_cast<clang::SwitchCase>(current)) {
          current = branch->getSubStmt();
        } else if (const auto* label = llvm::dyn_cast<clang::LabelStmt>(current)) {
          current = label->getSubStmt();
        } else {
          return *current;
        }
      }
    }

    // A declaration the author wrote. A statement macro that expands to a declaration, such as a trace
    // scope, reads as a statement where it is used, so it starts no run of declarations.
    const clang::DeclStmt* declaration(const clang::Stmt& statement) {
      const auto* declarations = llvm::dyn_cast<clang::DeclStmt>(&unlabeled(statement));
      if (declarations == nullptr || declarations->decl_begin() == declarations->decl_end()) {
        return nullptr;
      }

      if ((*declarations->decl_begin())->getLocation().isMacroID()) {
        return nullptr;
      }

      return declarations;
    }

    bool refersTo(const clang::Stmt* statement, const llvm::SmallPtrSetImpl<const clang::Decl*>& declared) {
      if (statement == nullptr) {
        return false;
      }

      if (const auto* reference = llvm::dyn_cast<clang::DeclRefExpr>(statement)) {
        if (declared.contains(reference->getDecl())) {
          return true;
        }
      }

      return std::ranges::any_of(statement->children(), [&](const clang::Stmt* child) {
        return refersTo(child, declared);
      });
    }

    // An if that checks a variable the declaration right above it introduces stays attached to it.
    bool checksDeclared(const clang::DeclStmt& declarations, const clang::Stmt& next) {
      const auto* branch = llvm::dyn_cast<clang::IfStmt>(&next);
      if (branch == nullptr) {
        return false;
      }

      llvm::SmallPtrSet<const clang::Decl*, 4> declared;

      for (const auto* declaration : declarations.decls()) {
        declared.insert(declaration);
        if (const auto* bindings = llvm::dyn_cast<clang::DecompositionDecl>(declaration)) {
          for (const auto* binding : bindings->bindings()) {
            declared.insert(binding);
          }
        }
      }

      return refersTo(branch->getInit(), declared) || refersTo(branch->getConditionVariableDeclStmt(), declared) || refersTo(branch->getCond(), declared);
    }

    std::size_t lineStart(llvm::StringRef text, std::size_t offset) {
      const auto newline = text.take_front(offset).rfind('\n');

      return newline == llvm::StringRef::npos ? 0 : newline + 1;
    }

    bool blank(llvm::StringRef line) {
      return line.trim(" \t\r\f\v").empty();
    }
  }

  bool blank_line_fixes::claim(llvm::StringRef path, unsigned offset) {
    const std::scoped_lock lock(mutex_);
    const bool first = insertions_[path].insert(offset).second;

    if (first && unit_claims != nullptr) {
      unit_claims->push_back(std::to_string(offset) + " " + path.str());
    }

    return first;
  }

  void blank_line_fixes::replay(llvm::StringRef claim) {
    const auto [offset, path] = claim.split(' ');
    unsigned insertion = 0;
    if (offset.getAsInteger(10, insertion)) {
      return;
    }

    const std::scoped_lock lock(mutex_);

    insertions_[path].insert(insertion);
  }

  bool blank_line_fixes::apply(llvm::raw_ostream& errors) const {
    const std::scoped_lock lock(mutex_);
    bool applied = true;

    for (const auto& file : insertions_) {
      auto buffer = llvm::MemoryBuffer::getFile(file.getKey(), /*IsText=*/false, /*RequiresNullTerminator=*/false);
      if (!buffer) {
        errors << "tbc-lint: cannot read " << file.getKey() << ": " << buffer.getError().message() << '\n';
        applied = false;
        continue;
      }

      const auto text = (*buffer)->getBuffer();
      llvm::SmallVector<unsigned, 16> offsets(file.getValue().begin(), file.getValue().end());

      std::ranges::sort(offsets);

      // Every insertion starts a line. Anything else means the file changed after it was analyzed.
      const auto stale = std::ranges::any_of(offsets, [&](unsigned offset) {
        return offset > text.size() || (offset != 0 && text[offset - 1] != '\n');
      });

      if (stale) {
        errors << "tbc-lint: " << file.getKey() << " changed while it was checked; run the fix again\n";
        applied = false;
        continue;
      }

      std::string fixed;

      fixed.reserve(text.size() + offsets.size());
      std::size_t copied = 0;

      for (const auto offset : offsets) {
        fixed.append(text.substr(copied, offset - copied));
        fixed.push_back('\n');
        copied = offset;
      }

      fixed.append(text.substr(copied));

      auto written = llvm::writeToOutput(file.getKey(), [&](llvm::raw_ostream& output) {
        output << fixed;
        return llvm::Error::success();
      });

      if (written) {
        errors << "tbc-lint: cannot write " << file.getKey() << ": " << llvm::toString(std::move(written)) << '\n';
        applied = false;
      }
    }

    return applied;
  }

  blank_line_check::blank_line_check(blank_line_fixes& fixes, bool errors, const std::string& header_filter)
      : fixes_(fixes),
        errors_(errors),
        header_filter_(header_filter),
        filter_headers_(!header_filter.empty()) {}

  void blank_line_check::registerMatchers(clang::ast_matchers::MatchFinder& finder) {
    using namespace clang::ast_matchers;

    // Templates are checked once, as written, not once per instantiation.
    finder.addMatcher(
        compoundStmt(
            unless(isExpansionInSystemHeader()),
            unless(isInTemplateInstantiation())
        )
            .bind("block"),
        this
    );
  }

  void blank_line_check::run(const clang::ast_matchers::MatchFinder::MatchResult& result) {
    const auto* block = result.Nodes.getNodeAs<clang::CompoundStmt>("block");
    if (block == nullptr || block->size() < 2) {
      return;
    }

    const auto& sources = *result.SourceManager;
    const auto open = block->getLBracLoc();
    if (open.isInvalid() || open.isMacroID() || !selected(sources.getFileID(open), sources)) {
      return;
    }

    context_ = result.Context;
    const clang::Stmt* previous = nullptr;

    for (const auto* statement : block->body()) {
      if (previous != nullptr) {
        inspect(*previous, *statement, sources);
      }

      previous = statement;
    }
  }

  void blank_line_check::onEndOfTranslationUnit() {
    if (context_ == nullptr) {
      return;
    }

    // An invalid unit has an incomplete AST, so its statements are not what the author wrote.
    auto& diagnostics = context_->getDiagnostics();
    if (diagnostics.hasErrorOccurred()) {
      gaps_.clear();
    }

    const auto& sources = context_->getSourceManager();
    const auto severity = errors_ ? clang::DiagnosticsEngine::Error : clang::DiagnosticsEngine::Warning;
    const auto after_block = diagnostics.getCustomDiagID(severity, "missing blank line after a statement that ends on its own closing brace [tbc-blank-line-after-block]");
    const auto after_declarations = diagnostics.getCustomDiagID(severity, "missing blank line between the declarations above and this statement [tbc-blank-line-after-declarations]");
    llvm::DenseMap<clang::FileID, std::string> paths;

    for (const auto& gap : gaps_) {
      auto& path = paths[gap.file];
      if (path.empty()) {
        const auto entry = sources.getFileEntryRefForID(gap.file);
        if (!entry) {
          continue;
        }

        llvm::SmallString<256> real;

        path = llvm::sys::fs::real_path(entry->getName(), real) ? std::string(entry->getName()) : std::string(real);
      }

      if (!fixes_.claim(path, gap.insertion)) {
        continue;
      }

      const auto insertion = sources.getComposedLoc(gap.file, gap.insertion);

      diagnostics.Report(gap.statement, gap.kind == rule::after_block ? after_block : after_declarations)
          << clang::FixItHint::CreateInsertion(insertion, "\n");
    }

    gaps_.clear();
    selected_.clear();
    context_ = nullptr;
  }

  bool blank_line_check::selected(clang::FileID file, const clang::SourceManager& sources) {
    const auto [cached, inserted] = selected_.try_emplace(file, false);
    if (!inserted) {
      return cached->second;
    }

    if (file == sources.getMainFileID()) {
      cached->second = true;
    } else if (filter_headers_) {
      const auto entry = sources.getFileEntryRefForID(file);

      cached->second = entry && !sources.isInSystemHeader(sources.getLocForStartOfFile(file)) && header_filter_.match(entry->getName());
    }

    return cached->second;
  }

  void blank_line_check::inspect(const clang::Stmt& previous, const clang::Stmt& next, const clang::SourceManager& sources) {
    // A case label already separates what comes before it.
    if (llvm::isa<clang::SwitchCase>(next)) {
      return;
    }

    const auto begin = sources.getExpansionLoc(previous.getBeginLoc());
    const auto end = sources.getExpansionRange(previous.getEndLoc()).getEnd();
    const auto statement = sources.getExpansionLoc(next.getBeginLoc());
    if (begin.isInvalid() || end.isInvalid() || statement.isInvalid()) {
      return;
    }

    const auto [file, end_offset] = sources.getDecomposedLoc(end);
    const auto [next_file, next_offset] = sources.getDecomposedLoc(statement);
    if (file != next_file || sources.getFileID(begin) != file || next_offset <= end_offset) {
      return;
    }

    const auto* declarations = declaration(previous);
    if (declarations != nullptr && checksDeclared(*declarations, unlabeled(next))) {
      return;
    }

    bool invalid = false;
    const auto text = sources.getBufferData(file, &invalid);
    if (invalid || next_offset > text.size()) {
      return;
    }

    // The previous statement closes a block when its last line starts with the closing brace.
    const auto last_line = lineStart(text, end_offset);
    const auto closes = sources.getFileOffset(begin) < last_line && text.substr(last_line).ltrim(" \t").starts_with("}");
    const auto declares = declarations != nullptr && declaration(next) == nullptr;
    if (!closes && !declares) {
      return;
    }

    // Two statements on one line, or a line continued by a backslash, cannot take a blank line between them.
    const auto line_end = text.find('\n', end_offset);
    if (line_end == llvm::StringRef::npos || line_end >= next_offset || text.take_front(line_end).rtrim('\r').ends_with("\\")) {
      return;
    }

    // Whole lines between the two statements, such as comments; any blank one already separates them.
    auto between = text.slice(line_end + 1, lineStart(text, next_offset));

    while (!between.empty()) {
      const auto [line, rest] = between.split('\n');
      if (blank(line)) {
        return;
      }

      between = rest;
    }

    gaps_.push_back(gap{
        .statement = statement,
        .file = file,
        .insertion = static_cast<unsigned>(line_end + 1),
        .kind = closes ? rule::after_block : rule::after_declarations,
    });
  }
}
