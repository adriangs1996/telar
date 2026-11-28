module telar.wire.graphics;

import std;
import telar.wire.vocabulary;

namespace telar {

  void GraphicsSharedImage::validate() const {
    validateSharedImageName(name);
  }

}
