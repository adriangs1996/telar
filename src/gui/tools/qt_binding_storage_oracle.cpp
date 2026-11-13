#include "inline_bindings.hpp"
#include <QtCore/qtypes.h>
#include <QtGui/private/qrhi_p.h>
#include <array>
#include <cstdint>
#include <exception>
#include <iostream>
#include <stdexcept>

namespace {

using Reference = QRhiBatchedBindings<std::uintptr_t>;
using Candidate = InlineBindings<std::uintptr_t>;

void compare(const Reference &reference, const Candidate &candidate) {
  if (reference.batches.size() != candidate.batches.size()) {
    throw std::runtime_error("Batch count differs");
  }

  for (qsizetype index = 0; index < reference.batches.size(); ++index) {
    const auto &left = reference.batches[index];
    const auto &right = candidate.batches[index];
    if (left.startBinding != right.startBinding || left.resources.size() != right.resources.size()) {
      throw std::runtime_error("Batch range differs");
    }

    for (qsizetype resource = 0; resource < left.resources.size(); ++resource) {
      if (left.resources[resource] != right.resources[resource]) {
        throw std::runtime_error("Resource differs");
      }
    }
  }
}

void checkState(Reference &reference, Candidate &candidate) {
  if (reference.finish() != candidate.finish()) {
    throw std::runtime_error("Finish result differs");
  }

  compare(reference, candidate);
  if (reference.finish() != candidate.finish()) {
    throw std::runtime_error("Repeated finish differs");
  }

  compare(reference, candidate);

  const auto reference_copy = reference;
  const auto candidate_copy = candidate;
  compare(reference_copy, candidate_copy);
  if (!(reference == reference_copy) || !(candidate == candidate_copy)) {
    throw std::runtime_error("Copy equality differs");
  }

  reference.clear();
  candidate.clear();

  compare(reference, candidate);
  compare(reference_copy, candidate_copy);

  constexpr int replacement_binding = 500;
  constexpr std::uintptr_t replacement_resource = 137;
  reference.feed(replacement_binding, replacement_resource);
  candidate.feed(replacement_binding, replacement_resource);
  reference.finish();
  candidate.finish();

  compare(reference, candidate);

  reference = reference_copy;
  candidate = candidate_copy;

  compare(reference, candidate);

  reference = Reference{};
  candidate = Candidate{};

  compare(reference, candidate);
}

void runOracle() {
  constexpr unsigned binding_count = 12;
  constexpr unsigned resource_stride = 31;
  constexpr unsigned subsets = 1U << binding_count;
  for (unsigned subset = 0; subset < subsets; ++subset) {
    Reference reference{};
    Candidate candidate{};
    for (unsigned slot = 0; slot < binding_count; ++slot) {
      if ((subset & (1U << slot)) == 0) {
        continue;
      }

      const auto resource = (static_cast<std::uintptr_t>(subset) * resource_stride) + slot;
      reference.feed(static_cast<int>(slot), resource);
      candidate.feed(static_cast<int>(slot), resource);

      compare(reference, candidate);
    }

    checkState(reference, candidate);
  }

  constexpr std::array counts{0, 1, 2, 3, 4, 5, 8, 16, 257};
  constexpr std::array strides{1, 2, 5};
  for (const auto count : counts) {
    for (const auto stride : strides) {
      Reference reference{};
      Candidate candidate{};
      for (int index = 0; index < count; ++index) {
        const auto resource = static_cast<std::uintptr_t>(index) + 1;
        reference.feed(index * stride, resource);
        candidate.feed(index * stride, resource);

        compare(reference, candidate);
      }

      checkState(reference, candidate);
    }
  }

  std::cout << "{\"cases\":" << subsets + (counts.size() * strides.size())
            << ",\"reference_size\":" << sizeof(Reference)
            << ",\"candidate_size\":" << sizeof(Candidate)
            << ",\"passed\":true}\n";
}

}

int main() {
  try {
    runOracle();
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
