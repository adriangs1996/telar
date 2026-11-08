#ifndef TBC_DETAIL_ATTRIBUTES_HPP
#define TBC_DETAIL_ATTRIBUTES_HPP

#if defined(__clang__)
#define TBC_DETAIL_LIFETIME_BOUND [[clang::lifetimebound]]
#else
#define TBC_DETAIL_LIFETIME_BOUND
#endif

#endif
