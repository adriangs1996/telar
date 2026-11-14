module telar.wire.graphics;

import std;
import telar.wire.vocabulary;

// The owned header declares these in the global module, so their definitions belong to it too.
extern "C++" {
namespace telar {

  void GraphicsSharedImage::validate() const {
    validateSharedImageName(name);
  }

}
}
