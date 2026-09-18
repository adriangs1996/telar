import sys
from pathlib import Path
sys.path.insert(0, '/Users/adriangonzalez/sandbox/telar/tools')
import terminal_bench_fixture as fixture
fixture.PAYLOAD_BYTES = 8 * 1024 * 1024
fixture.LIFETIME_SECONDS = 180
fixture.Fixture(Path('/private/tmp/tgb-p2-followup/raw/diagnostic-repeat-candidate/fixture')).run()
