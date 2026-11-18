#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdint>

import std;
import telar.testing;
import telar.cli.command_limit;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar::runtime::cli;

  namespace {

    // Expected values and error names of the CLI's integer parser for each text.
    template <typename Parse>
    std::string outcome(Parse parse) {
      try {
        return std::to_string(parse());
      } catch (const std::invalid_argument& error) {
        return error.what();
      }
    }

    void parsesIntegers() {
      check(outcome([] {
        return parseUnsigned<std::uint32_t>("+42");
      }) == "InvalidCharacter");

      check(outcome([] {
        return parseInt<std::uint32_t>("+42");
      }) == "42");

      check(outcome([] {
        return parseInt<std::uint32_t>("-0");
      }) == "0");

      check(outcome([] {
        return parseInt<std::uint32_t>("-1");
      }) == "Overflow");

      check(outcome([] {
        return parseUnsigned<std::uint32_t>("1__0");
      }) == "10");

      check(outcome([] {
        return parseUnsigned<std::uint32_t>("_1");
      }) == "InvalidCharacter");

      check(outcome([] {
        return parseUnsigned<std::uint32_t>("1_");
      }) == "InvalidCharacter");

      check(outcome([] {
        return parseInt<std::int32_t>("+_1");
      }) == "InvalidCharacter");

      check(outcome([] {
        return parseInt<std::int32_t>("-");
      }) == "InvalidCharacter");

      check(outcome([] {
        return parseUnsigned<std::uint32_t>("");
      }) == "InvalidCharacter");

      check(outcome([] {
        return parseUnsigned<std::uint32_t>(" 1");
      }) == "InvalidCharacter");

      check(outcome([] {
        return parseUnsigned<std::uint32_t>("4294967295");
      }) == "4294967295");

      check(outcome([] {
        return parseUnsigned<std::uint32_t>("4294967296");
      }) == "Overflow");

      check(outcome([] {
        return parseInt<std::int32_t>("-2147483648");
      }) == "-2147483648");

      check(outcome([] {
        return parseInt<std::int32_t>("-2147483649");
      }) == "Overflow");

      check(outcome([] {
        return parseInt<std::int32_t>("2147483648");
      }) == "Overflow");

      check(outcome([] {
        return parseUnsigned<std::uint64_t>("18446744073709551616");
      }) == "Overflow");

      check(outcome([] {
        return parseUnsigned<std::uint32_t>("0x10");
      }) == "InvalidCharacter");
    }

    void mapsErrors() {
      check(outcome([] {
        return number<std::uint16_t>("70000", "InvalidIndex");
      }) == "InvalidIndex");

      check(outcome([] {
        return signedNumber<std::int32_t>("x", "InvalidScrollDelta");
      }) == "InvalidScrollDelta");

      check(outcome([] {
        return positive("0", "InvalidTarget");
      }) == "InvalidTarget");

      check(!maybeUnsigned("-1"));
    }

    void walksWords() {
      std::array<const char*, 3> words{"--socket", "path", "--json"};
      Cursor cursor{{const_cast<char* const*>(words.data()), words.size()}};

      check(cursor.next() == "--socket");
      check(cursor.take("MissingSocketPath") == "path");
      check(cursor.rest().size() == 1);
      check(cursor.next() == "--json");
      check(outcome([&] {
        return cursor.take("MissingSocketPath").size();
      }) == "MissingSocketPath");
    }

    // A word picks the protocol value at its position among the names; any other word is the
    // command's usage error, never a value past the enum's last.
    void choiceMapsWords() {
      constexpr std::array<std::string_view, 4> directions{"left", "right", "up", "down"};

      check(choice<telar::PaneDirection, 4>("down", "InvalidPaneDirection", directions) == telar::PaneDirection::down);
      check(choice<telar::PaneDirection, 4>("left", "InvalidPaneDirection", directions) == telar::PaneDirection::left);
      check(outcome([&] {
        return static_cast<int>(choice<telar::PaneDirection, 4>("sideways", "InvalidPaneDirection", directions));
      }) == "InvalidPaneDirection");
    }

  }

  const telar::testing::Case case_parses_integers{"arguments.parses_integers", parsesIntegers};
  const telar::testing::Case case_maps_errors{"arguments.maps_errors", mapsErrors};
  const telar::testing::Case case_walks_words{"arguments.walks_words", walksWords};
  const telar::testing::Case case_choice_maps_words{"arguments.choice_maps_words", choiceMapsWords};

}
