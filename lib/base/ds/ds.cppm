module;
#include "telar_base/ds/containers.hpp"
#include "telar_base/ds/values.hpp"

export module telar.base.ds;

// The containers live in textual headers, so that headers which cannot import a module, as the
// allocator's and the Qt and Objective-C++ ones, use them too; importers reach them through these
// declarations.
export namespace telar::ds {
  using telar::ds::Array;
  using telar::ds::Box;
  using telar::ds::Cell;
  using telar::ds::format;
  using telar::ds::formatTo;
  using telar::ds::Function;
  using telar::ds::get;
  using telar::ds::Hash;
  using telar::ds::makeBox;
  using telar::ds::Map;
  using telar::ds::None;
  using telar::ds::none;
  using telar::ds::Option;
  using telar::ds::String;
  using telar::ds::StringAppender;
  using telar::ds::toArray;
  using telar::ds::Vec;
  using telar::ds::operator==;
  using telar::ds::operator<=>;
}
