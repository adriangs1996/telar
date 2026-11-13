#ifndef TBC_HOT_PATH_HPP
#define TBC_HOT_PATH_HPP

// A function marked TBC_HOT_PATH keeps its body in a module interface so that importers can inline it;
// tbc-lint's interface-bodies check reports every other body there. A non-template one must also be
// inline, because the body of a non-inline function never reaches an importer. On a class, it covers
// the bodies of all its members, as for a small template that stays one; on a variable, the lambdas
// that initialize it.
#if defined(__clang__)
#define TBC_HOT_PATH [[clang::annotate("tbc::hot_path")]]
#else
#define TBC_HOT_PATH
#endif

#endif
