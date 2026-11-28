#pragma once

#include "meta_model.hpp"

#include <clang/AST/ASTConsumer.h>

#include <memory>

namespace telar::qt_moc {

  std::unique_ptr<clang::ASTConsumer> createExtractorConsumer(UnitMeta& output);

}
