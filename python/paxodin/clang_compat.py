#!/usr/bin/env python3
"""Normalize Odin's legacy quoted init/fini arguments before invoking clang.

Odin dev-2026-09 moved to posix_spawn but retained shell quotes inside -Wl
arguments. Upstream fixed this in 085af86dac72a04cc20189e3204edfc1ab069fa9.
Unquoted arguments from newer compilers pass through unchanged.
"""

import os
import sys


def main() -> None:
    """Preserve all linker arguments except the three known obsolete quotes."""
    replacements = {
        "-Wl,-init,'__odin_entry_point'": "-Wl,-init,__odin_entry_point",
        "-Wl,-init,'_odin_entry_point'": "-Wl,-init,_odin_entry_point",
        "-Wl,-fini,'_odin_exit_point'": "-Wl,-fini,_odin_exit_point",
    }
    clang = os.environ["PAXODIN_REAL_CLANG"]
    args = [replacements.get(arg, arg) for arg in sys.argv[1:]]
    os.execv(clang, [clang, *args])  # noqa: S606 - exact compiler selected by build hook


if __name__ == "__main__":
    main()
