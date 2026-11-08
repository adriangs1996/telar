#include "tbc/lifetime.hpp"
#include "tbc/view.hpp"

#include <gtest/gtest.h>
#include <span>
#include <string_view>
#include <type_traits>

namespace {
  using text_a = tbc::view<std::string_view, tbc::lt::a>;
  using text_b = tbc::view<std::string_view, tbc::lt::b>;

  TEST(public_signature, preservesNativeViewTypes) {
    static_assert(std::is_same_v<text_a, std::string_view>);
    static_assert(std::is_same_v<tbc::view<std::span<const int>>, std::span<const int>>);
    EXPECT_EQ(sizeof(text_a), sizeof(std::string_view));
  }

  TEST(public_signature, leavesRegionRelationshipsToTheLinter) {
    static_assert(std::is_same_v<text_a, text_b>);
    const text_b second = "native value";
    const text_a first = second;
    EXPECT_EQ(first, second);
  }

  TEST(public_signature, supportsNativeReferences) {
    static_assert(std::is_same_v<tbc::view<int &, tbc::lt::a>, int &>);
    int value = 1;
    tbc::view<int &> reference = value;
    reference = 2;
    EXPECT_EQ(value, 2);
  }

  TEST(public_signature, distinguishesElisionFromExplicitRegionSyntax) {
    static_assert(std::is_same_v<tbc::view<std::string_view>, tbc::view<std::string_view, tbc::lt::elided>>);
    const tbc::view<std::string_view> text = "elided";
    EXPECT_EQ(text, "elided");
  }

  TEST(public_signature, canAnnotateAggregatesWithoutChangingTheirLayout) {
    struct record {
      tbc::view<std::string_view> text;
    };

    static_assert(std::is_same_v<tbc::view<record, tbc::lt::a>, record>);
    const record original{"borrowed contents"};
    const tbc::view<record, tbc::lt::a> copied = original;
    EXPECT_EQ(copied.text.data(), original.text.data());
  }

  TEST(public_signature, acceptsDescriptiveLifetimeTags) {
    struct request;
    using request_lifetime = tbc::lifetime<request>;
    static_assert(std::is_same_v<tbc::view<std::string_view, request_lifetime>, std::string_view>);
    const tbc::view<std::string_view, request_lifetime> text = "request";
    EXPECT_EQ(text, "request");
  }
}
