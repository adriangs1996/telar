#include <gtest/gtest.h>

TEST(ToolchainTest, Cpp23IsEnabled) {
  EXPECT_GT(__cplusplus, 202002L);
}
