module;
#include "kitty_cursor.hpp"
#include "media_budget.hpp"
#include "png_decoder.hpp"
#include "query_resources.hpp"
#include "temporary_path.hpp"

export module telar.runtime.graphics.kitty;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::runtime {
using telar::runtime::DisplayCells;
using telar::runtime::GraphicsChildFile;
using telar::runtime::GraphicsQueryResources;
using telar::runtime::GraphicsTemporaryPath;
using telar::runtime::ImageDisplayRequest;
using telar::runtime::KittyCommandScanner;
using telar::runtime::KittyCommandView;
using telar::runtime::KittyControlField;
using telar::runtime::KittyControlFields;
using telar::runtime::KittyCursor;
using telar::runtime::KittyFraming;
using telar::runtime::MappedImages;
using telar::runtime::MediaAllocator;
using telar::runtime::MediaBudget;
using telar::runtime::MediaUsage;
using telar::runtime::decodePngImage;
using telar::runtime::displayCells;
using telar::runtime::installPngDecoder;
using telar::runtime::kittyUnsigned;
using telar::runtime::saturatedDimension;
using telar::runtime::scaledDimension;
}

