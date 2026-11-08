#include "support.hpp"

// CASE: gui.history_shallow_wire_copy
// PAIR: gui.history_wire_ownership
// SOURCE: src/gui-cpp/history/browser.cppm :: HistoryPageStorage::append
// STATUS: pending
// CONTRACT: Copying a collection of string_view descriptors does not copy wire-backed text.
// SCENARIO: Model omitting the real owning-copy step; returning the descriptors must fail.
tbc::view<std::vector<std::string_view>, tbc::lt::a> historyShallowWireCopy() {
  const std::string wire{"decoded command"};
  const std::array<std::string_view, 1> decoded{wire};
  return {decoded.begin(), decoded.end()}; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: gui.history_owned_wire_copy
// PAIR: gui.history_wire_ownership
// SOURCE: src/gui-cpp/history/browser.cppm :: HistoryPageStorage::append
// STATUS: pending
// CONTRACT: HistoryPageStorage copies decoded text into its own strings.
// SCENARIO: The returned page is independent of local wire and view-descriptor buffers.
spec::history_page historyOwnedWireCopy() {
  const std::string wire{"decoded command"};
  const std::array<std::string_view, 1> decoded{wire};
  return spec::history_page{decoded};
}

// END CASE

// CASE: gui.history_swap_new_owner_dies
// PAIR: gui.history_exchange
// SOURCE: src/gui-cpp/history/browser.cppm :: exchangeWith / rows
// STATUS: pending
// CONTRACT: Swapping row vectors transfers allocation ownership without moving their elements.
// SCENARIO: The old view follows its storage into the temporary page and dies with that page.
void historySwapNewOwnerDies(tbc::view<spec::history_page &> page) {
  const auto rows = page.rows();
  {
    spec::history_page replacement{std::span<const std::string_view>{}};
    page.exchangeWith(replacement);
  } // expected-error [tbc-invalidated-borrow]
  spec::observe(rows);
}

// END CASE

// CASE: gui.history_swap_live_owner
// PAIR: gui.history_exchange
// SOURCE: src/gui-cpp/history/browser.cppm :: exchangeWith / rows
// STATUS: pending
// CONTRACT: The row allocation survives a compatible swap while its new owner remains alive.
// SCENARIO: Read the old span before either page is destroyed; do not reject the swap itself.
void historySwapLiveOwner(tbc::view<spec::history_page &> page) {
  spec::history_page replacement{std::span<const std::string_view>{}};
  const auto rows = page.rows();
  page.exchangeWith(replacement);
  spec::observe(rows);
}

// END CASE
