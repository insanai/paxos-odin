"""Build the Odin shared library that ctypes loads at import time.

There is no C or C++ in this project: the bridge is Odin, and the Odin compiler
emits the shared library directly. This hook therefore invokes `odin build`
rather than delegating to a C build system.

Two source layouts are supported. In a checkout the core is the repository's own
`src/`, two directories up. In a source distribution the core has been staged
into `native/core/src/` so that an installed sdist never reaches outside itself.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path
from typing import Any

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

#: Where the core sources are staged so an installed sdist never reaches outside
#: itself. A wheel built from the sdist must not require ../../src to exist.
STAGED_CORE = Path("native") / "core"

# The wheel's CPU floor. `x86-64-v2` is Odin's own default; it is passed
# explicitly so the floor is recorded in the build log rather than inherited.
# Never `native` -- that is for bench/, and would produce an unshippable wheel.
MICROARCH = os.environ.get("PAXODIN_MICROARCH", "x86-64-v2")

LIB_STEM = "_paxodin"
ENFORCED_STEM = "_paxodin_enforced"


def _library_suffix() -> str:
    if sys.platform == "darwin":
        return ".dylib"
    if sys.platform == "win32":
        return ".dll"
    return ".so"


def _platform_tag() -> str:
    return sysconfig.get_platform().replace("-", "_").replace(".", "_")


class OdinBuildHook(BuildHookInterface):
    """Compile `native/` into the package directory before the wheel is assembled."""

    PLUGIN_NAME = "custom"

    def _core_collection(self) -> Path:
        """Return the directory that holds the core's `src/`, for -collection:paxos."""
        root = Path(self.root)
        staged = root / "native" / "core"
        if (staged / "src").is_dir():
            return staged
        repo = root.parents[1]
        if (repo / "src" / "paxos.odin").is_file():
            return repo
        message = (
            f"Cannot find the paxos-odin core. Looked for {staged / 'src'} (staged "
            f"sdist layout) and {repo / 'src'} (repository layout).\n"
            "Hint: build from a checkout of paxos-odin, or from an sdist produced by "
            "`uv build --sdist`, which stages the core into native/core/."
        )
        raise RuntimeError(message)

    def _odin(self) -> str:
        odin = os.environ.get("ODIN", "odin")
        resolved = shutil.which(odin)
        if resolved is None:
            message = (
                f"The Odin compiler ({odin!r}) is not on PATH.\n"
                "Hint: install Odin dev-2026-09 or newer, or set ODIN=/path/to/odin. "
                "Wheel users never need Odin; only source builds do."
            )
            raise RuntimeError(message)
        return resolved

    def _compile(self, *, out: Path, enforced: bool) -> None:
        command = [
            self._odin(),
            "build",
            str(Path(self.root) / "native"),
            "-build-mode:shared",
            "-reloc-mode:pic",
            f"-collection:paxos={self._core_collection()}",
            "-o:speed",
            f"-microarch:{MICROARCH}",
            f"-out:{out}",
        ]
        if enforced:
            command.append("-define:PAXODIN_GATE_ENFORCED=true")
        self.app.display_info(f"paxodin: {' '.join(command)}")
        subprocess.run(command, check=True)

    def _stage_core(self) -> None:
        """Copy the exact core revision into the sdist.

        The editable project compiles against the repository's own `src/`. A
        source distribution cannot, so the same revision is copied in with a
        manifest naming it. There is never a second editable copy of the
        algorithm -- only a frozen one inside a release artifact.
        """
        root = Path(self.root)
        source = root.parents[1] / "src"
        if not (source / "paxos.odin").is_file():
            return  # already a staged sdist; nothing to copy
        destination = root / STAGED_CORE / "src"
        if destination.exists():
            shutil.rmtree(destination)
        destination.mkdir(parents=True)
        for odin in sorted(source.glob("*.odin")):
            shutil.copy2(odin, destination / odin.name)
        licence = root.parents[1] / "LICENSE"
        if licence.is_file():
            shutil.copy2(licence, root / STAGED_CORE / "LICENSE.core")
        revision = subprocess.run(
            ["git", "-C", str(root.parents[1]), "rev-parse", "HEAD"],
            check=False,
            capture_output=True,
            text=True,
        ).stdout.strip()
        manifest = "\n".join(
            [
                "# paxos-odin core staged into this source distribution.",
                f"revision: {revision or 'unknown'}",
                f"files: {len(list(destination.glob('*.odin')))}",
                *(f"  src/{path.name}" for path in sorted(destination.glob("*.odin"))),
            ]
        )
        (root / STAGED_CORE / "MANIFEST.txt").write_text(manifest + "\n", encoding="utf-8")

    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        """Stage the core for an sdist, or compile the library for a wheel."""
        if self.target_name == "sdist":
            self._stage_core()
            return
        package = Path(self.root) / "src" / "paxodin"
        suffix = _library_suffix()

        self._compile(out=package / f"{LIB_STEM}{suffix}", enforced=False)

        want_enforced = version == "editable" or os.environ.get("PAXODIN_BUILD_ENFORCED") == "1"
        if want_enforced:
            self._compile(out=package / f"{ENFORCED_STEM}{suffix}", enforced=True)

        build_data["pure_python"] = False
        build_data["infer_tag"] = False
        build_data["tag"] = f"py3-none-{_platform_tag()}"
        build_data.setdefault("artifacts", []).extend(
            [f"src/paxodin/{LIB_STEM}{suffix}", f"src/paxodin/{ENFORCED_STEM}{suffix}"]
        )
