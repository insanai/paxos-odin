"""Loading and calling the Odin shared library.

This module is private. It owns every ``ctypes`` declaration in the package, so
no other module reasons about the C ABI and each signature is declared exactly
once. Nothing here is part of the public API.

The library is loaded from package data with :mod:`importlib.resources`. When the
package is installed as a zip the resource is extracted to a real file first, and
that file must outlive the loaded library, so the :class:`contextlib.ExitStack`
below is deliberately never closed.
"""

from __future__ import annotations

import ctypes
import os
import sys
from contextlib import ExitStack
from importlib.resources import as_file, files
from typing import TYPE_CHECKING, ClassVar, Final

if TYPE_CHECKING:
    from pathlib import Path

#: Bumped whenever a C ABI signature or struct layout changes.
EXPECTED_ABI_VERSION: Final = 1

MAX_MEMBERS: Final = 7

OK: Final = 0
E_INVALID_ARGUMENT: Final = 1
E_NULL_POINTER: Final = 2
E_ABI_MISMATCH: Final = 3
E_OUT_OF_MEMORY: Final = 4
E_HANDLE_CLOSED: Final = 5
E_WRONG_PROCESS: Final = 6
E_REENTRANT: Final = 7
E_POISONED: Final = 8
E_BATCH_PENDING: Final = 9
E_NO_BATCH: Final = 10
E_STALE_TOKEN: Final = 11
E_FOREIGN_TOKEN: Final = 12
E_BATCH_FINISHED: Final = 13
E_WRITES_UNCONFIRMED: Final = 14
E_WRITES_NOT_COPIED: Final = 15
E_BUFFER_TOO_SMALL: Final = 16
E_RANGE: Final = 17
E_VALUE_TOO_LARGE: Final = 18
E_UNSUPPORTED_KIND: Final = 19
E_UNSUPPORTED_CAPABILITY: Final = 20
E_REPLAY_ACTIVE: Final = 21
E_REPLAY_NOT_ACTIVE: Final = 22

#: Protocol statuses are the core's Error enum offset by this base.
CORE_STATUS_BASE: Final = 1000

MAX_VALUE_BYTES: Final = 1024
MAX_METADATA_BYTES: Final = 256

_RESOURCES = ExitStack()


class CStopSign(ctypes.Structure):
    """Mirrors ``C_Stop_Sign`` in ``native/types.odin``."""

    _fields_: ClassVar = [
        ("configuration_id", ctypes.c_uint64),
        ("member_count", ctypes.c_uint32),
        ("metadata_length", ctypes.c_uint32),
        ("members", ctypes.c_uint16 * MAX_MEMBERS),
        ("metadata", ctypes.c_uint8 * MAX_METADATA_BYTES),
    ]


class CEntry(ctypes.Structure):
    """Mirrors ``C_Entry``: a command, an internal no-op, or a stop sign."""

    _fields_: ClassVar = [
        ("kind", ctypes.c_uint8),
        ("pad", ctypes.c_uint8 * 3),
        ("length", ctypes.c_uint32),
        ("body", ctypes.c_uint8 * MAX_VALUE_BYTES),
        ("stop", CStopSign),
    ]


class CWrite(ctypes.Structure):
    """Mirrors ``C_Write``: one durable record the host must journal."""

    _fields_: ClassVar = [
        ("kind", ctypes.c_uint8),
        ("pad", ctypes.c_uint8 * 3),
        ("flags", ctypes.c_uint32),
        ("ballot", ctypes.c_uint64),
        ("slot", ctypes.c_uint64),
        ("trim_id", ctypes.c_uint64),
        ("trim_slot", ctypes.c_uint64),
        ("entry", CEntry),
    ]


class CEnvelope(ctypes.Structure):
    """Mirrors ``C_Envelope``: all nine message variants in one shape."""

    _fields_: ClassVar = [
        ("configuration_id", ctypes.c_uint64),
        ("ballot", ctypes.c_uint64),
        ("slot", ctypes.c_uint64),
        ("vote", ctypes.c_uint64),
        ("first", ctypes.c_uint64),
        ("last", ctypes.c_uint64),
        ("rejected", ctypes.c_uint64),
        ("promised", ctypes.c_uint64),
        ("decided_through", ctypes.c_uint64),
        ("trim_id", ctypes.c_uint64),
        ("trim_slot", ctypes.c_uint64),
        ("kind", ctypes.c_uint32),
        ("count", ctypes.c_uint32),
        ("sender", ctypes.c_uint16),
        ("recipient", ctypes.c_uint16),
        ("scope", ctypes.c_uint8),
        ("cell_state", ctypes.c_uint8),
        ("more", ctypes.c_uint8),
        ("pad", ctypes.c_uint8),
        ("entry", CEntry),
    ]


class CCommitted(ctypes.Structure):
    """Mirrors ``C_Committed``: one entry released in slot order."""

    _fields_: ClassVar = [
        ("slot", ctypes.c_uint64),
        ("flags", ctypes.c_uint32),
        ("pad", ctypes.c_uint32),
        ("entry", CEntry),
    ]


class CRequest(ctypes.Structure):
    """Mirrors ``C_Request``: history a peer asked for below the memory floor."""

    _fields_: ClassVar = [
        ("kind", ctypes.c_uint32),
        ("peer", ctypes.c_uint16),
        ("pad", ctypes.c_uint16),
        ("first", ctypes.c_uint64),
        ("count", ctypes.c_uint32),
        ("pad2", ctypes.c_uint32),
    ]


class CToken(ctypes.Structure):
    """Mirrors ``C_Token``: a batch identity bound to a handle lifetime."""

    _fields_: ClassVar = [
        ("epoch", ctypes.c_uint64),
        ("generation", ctypes.c_uint64),
    ]


class CReport(ctypes.Structure):
    """Mirrors ``C_Report``: what a transition produced and where it has got to."""

    _fields_: ClassVar = [
        ("epoch", ctypes.c_uint64),
        ("generation", ctypes.c_uint64),
        ("assigned_slot", ctypes.c_uint64),
        ("status", ctypes.c_int32),
        ("phase", ctypes.c_uint32),
        ("write_count", ctypes.c_uint32),
        ("writes_copied_through", ctypes.c_uint32),
        ("message_count", ctypes.c_uint32),
        ("committed_count", ctypes.c_uint32),
        ("request_count", ctypes.c_uint32),
        ("assigned_count", ctypes.c_uint32),
        ("requires_barrier", ctypes.c_uint32),
        ("pad", ctypes.c_uint32),
    ]


class CState(ctypes.Structure):
    """Mirrors ``C_State``: a read-only view gathered in one call."""

    _fields_: ClassVar = [
        ("configuration_id", ctypes.c_uint64),
        ("ballot", ctypes.c_uint64),
        ("decided_through", ctypes.c_uint64),
        ("memory_floor", ctypes.c_uint64),
        ("leader_base", ctypes.c_uint64),
        ("frontier", ctypes.c_uint64),
        ("stop_slot", ctypes.c_uint64),
        ("trim_id", ctypes.c_uint64),
        ("trim_slot", ctypes.c_uint64),
        ("node_id", ctypes.c_uint16),
        ("leader", ctypes.c_uint16),
        ("has_leader", ctypes.c_uint8),
        ("role", ctypes.c_uint8),
        ("sealed", ctypes.c_uint8),
        ("voting_member", ctypes.c_uint8),
        ("campaign_enabled", ctypes.c_uint8),
        ("leader_caught_up", ctypes.c_uint8),
        ("pad", ctypes.c_uint8 * 2),
        ("resubmits_dropped", ctypes.c_uint32),
    ]


class CConfig(ctypes.Structure):
    """Mirrors ``C_Config``: everything needed to start or restore a node."""

    _fields_: ClassVar = [
        ("configuration_id", ctypes.c_uint64),
        ("members", ctypes.c_uint16 * MAX_MEMBERS),
        ("member_count", ctypes.c_uint32),
        ("read_quorum", ctypes.c_uint32),
        ("write_quorum", ctypes.c_uint32),
        ("election_timeout_ticks", ctypes.c_uint32),
        ("heartbeat_interval_ticks", ctypes.c_uint32),
        ("resend_interval_ticks", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("node_id", ctypes.c_uint16),
        ("priority", ctypes.c_uint8),
        ("pad", ctypes.c_uint8),
    ]


class CProfile(ctypes.Structure):
    """Mirrors ``Profile`` in ``native/bridge.odin``."""

    _fields_: ClassVar = [
        ("abi_version", ctypes.c_uint32),
        ("max_members", ctypes.c_uint32),
        ("window_slots", ctypes.c_uint32),
        ("chunk_slots", ctypes.c_uint32),
        ("max_value_bytes", ctypes.c_uint32),
        ("max_metadata_bytes", ctypes.c_uint32),
        ("max_writes_per_batch", ctypes.c_uint32),
        ("max_messages_per_batch", ctypes.c_uint32),
        ("max_committed_per_batch", ctypes.c_uint32),
        ("max_requests_per_batch", ctypes.c_uint32),
        ("sizeof_entry", ctypes.c_uint32),
        ("sizeof_write", ctypes.c_uint32),
        ("sizeof_envelope", ctypes.c_uint32),
        ("sizeof_committed", ctypes.c_uint32),
        ("sizeof_request", ctypes.c_uint32),
        ("sizeof_token", ctypes.c_uint32),
        ("sizeof_report", ctypes.c_uint32),
        ("sizeof_state", ctypes.c_uint32),
        ("sizeof_config", ctypes.c_uint32),
        ("gate_enforced", ctypes.c_uint32),
        ("node_bytes", ctypes.c_uint64),
        ("effects_bytes", ctypes.c_uint64),
        ("capabilities", ctypes.c_uint64),
        ("fingerprint", ctypes.c_uint64),
    ]


_HANDLE = ctypes.c_void_p
_U32P = ctypes.POINTER(ctypes.c_uint32)
_U64P = ctypes.POINTER(ctypes.c_uint64)
_TOKENP = ctypes.POINTER(CToken)
_REPORTP = ctypes.POINTER(CReport)

# Every signature is declared explicitly. ctypes defaults an undeclared return
# type to int, which truncates a pointer on 64-bit platforms; nothing is left to
# inference.
_SIGNATURES: Final = (
    ("paxodin_abi_version", ctypes.c_uint32, ()),
    ("paxodin_capabilities", ctypes.c_uint64, ()),
    ("paxodin_profile_fingerprint", ctypes.c_uint64, ()),
    ("paxodin_status_count", ctypes.c_uint32, ()),
    ("paxodin_profile", ctypes.c_int32, (ctypes.POINTER(CProfile),)),
    ("paxodin_core_version", ctypes.c_int32, (ctypes.c_char_p, ctypes.c_uint32, _U32P)),
    ("paxodin_explain", ctypes.c_int32, (ctypes.c_int32, ctypes.c_char_p, ctypes.c_uint32, _U32P)),
    ("paxodin_node_open", ctypes.c_int32, (ctypes.POINTER(CConfig), ctypes.POINTER(_HANDLE))),
    (
        "paxodin_node_open_continue_at",
        ctypes.c_int32,
        (
            ctypes.POINTER(CConfig),
            ctypes.c_uint64,
            ctypes.c_uint64,
            ctypes.c_uint64,
            ctypes.POINTER(_HANDLE),
        ),
    ),
    (
        "paxodin_node_open_for_replay",
        ctypes.c_int32,
        (ctypes.POINTER(CConfig), ctypes.POINTER(_HANDLE)),
    ),
    ("paxodin_node_close", ctypes.c_int32, (_HANDLE, _U32P)),
    ("paxodin_replay_apply", ctypes.c_int32, (_HANDLE, ctypes.POINTER(CWrite))),
    ("paxodin_replay_restore", ctypes.c_int32, (_HANDLE, ctypes.c_uint64)),
    ("paxodin_replay_abort", ctypes.c_int32, (_HANDLE,)),
    ("paxodin_begin_campaign", ctypes.c_int32, (_HANDLE, _TOKENP, _REPORTP)),
    ("paxodin_begin_tick", ctypes.c_int32, (_HANDLE, _TOKENP, _REPORTP)),
    (
        "paxodin_begin_propose",
        ctypes.c_int32,
        (_HANDLE, ctypes.POINTER(CEntry), _TOKENP, _REPORTP),
    ),
    (
        "paxodin_begin_propose_batch",
        ctypes.c_int32,
        (_HANDLE, ctypes.POINTER(CEntry), ctypes.c_uint32, _TOKENP, _REPORTP),
    ),
    (
        "paxodin_begin_step",
        ctypes.c_int32,
        (_HANDLE, ctypes.POINTER(CEnvelope), _TOKENP, _REPORTP),
    ),
    ("paxodin_begin_reconnected", ctypes.c_int32, (_HANDLE, ctypes.c_uint16, _TOKENP, _REPORTP)),
    (
        "paxodin_begin_request_catch_up",
        ctypes.c_int32,
        (_HANDLE, ctypes.c_uint16, ctypes.c_uint64, _TOKENP, _REPORTP),
    ),
    (
        "paxodin_begin_install_chosen_trim",
        ctypes.c_int32,
        (_HANDLE, ctypes.c_uint64, ctypes.c_uint64, _TOKENP, _REPORTP),
    ),
    ("paxodin_batch_report", ctypes.c_int32, (_HANDLE, _TOKENP, _REPORTP)),
    (
        "paxodin_copy_writes",
        ctypes.c_int32,
        (_HANDLE, _TOKENP, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(CWrite), _U32P),
    ),
    ("paxodin_confirm", ctypes.c_int32, (_HANDLE, _TOKENP)),
    (
        "paxodin_copy_messages",
        ctypes.c_int32,
        (_HANDLE, _TOKENP, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(CEnvelope), _U32P),
    ),
    (
        "paxodin_copy_committed",
        ctypes.c_int32,
        (_HANDLE, _TOKENP, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(CCommitted), _U32P),
    ),
    (
        "paxodin_copy_requests",
        ctypes.c_int32,
        (_HANDLE, _TOKENP, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(CRequest), _U32P),
    ),
    (
        "paxodin_copy_assigned_slots",
        ctypes.c_int32,
        (_HANDLE, _TOKENP, ctypes.c_uint32, ctypes.c_uint32, _U64P, _U32P),
    ),
    ("paxodin_finish", ctypes.c_int32, (_HANDLE, _TOKENP)),
    ("paxodin_state", ctypes.c_int32, (_HANDLE, ctypes.POINTER(CState))),
    ("paxodin_advance_memory_floor", ctypes.c_int32, (_HANDLE, ctypes.c_uint64)),
    ("paxodin_set_campaign_enabled", ctypes.c_int32, (_HANDLE, ctypes.c_uint32)),
    ("paxodin_decided_span", ctypes.c_int32, (_HANDLE, ctypes.c_uint64, _U64P)),
    (
        "paxodin_read_decided",
        ctypes.c_int32,
        (
            _HANDLE,
            ctypes.c_uint64,
            ctypes.c_uint32,
            ctypes.POINTER(CCommitted),
            _U32P,
            _U64P,
        ),
    ),
    (
        "paxodin_committed_at",
        ctypes.c_int32,
        (_HANDLE, ctypes.c_uint64, ctypes.POINTER(CEntry), _U32P),
    ),
)

#: Struct sizes the library reports, checked against this module's mirrors.
_SIZE_CHECKS: Final = (
    ("sizeof_entry", CEntry),
    ("sizeof_write", CWrite),
    ("sizeof_envelope", CEnvelope),
    ("sizeof_committed", CCommitted),
    ("sizeof_request", CRequest),
    ("sizeof_token", CToken),
    ("sizeof_report", CReport),
    ("sizeof_state", CState),
    ("sizeof_config", CConfig),
)


def _library_filename() -> str:
    """Return the shared library to load, honouring ``PAXODIN_LIB``.

    Returns:
        The file name of the release library, or of the ``.Enforced`` twin when
        ``PAXODIN_LIB=enforced``. The twin is a test artifact: it compiles the
        core's own durability gate in, so an ordering bug terminates the process
        instead of returning a status.
    """
    stem = "_paxodin_enforced" if os.environ.get("PAXODIN_LIB") == "enforced" else "_paxodin"
    if sys.platform == "darwin":
        return f"{stem}.dylib"
    if sys.platform == "win32":
        return f"{stem}.dll"
    return f"{stem}.so"


def _locate() -> Path:
    """Extract (if needed) and return the path of the bundled shared library.

    Returns:
        A real filesystem path that stays valid for the lifetime of the process.

    Raises:
        OSError: If the library is not present in the installed package.
    """
    name = _library_filename()
    resource = files("paxodin") / name
    try:
        return _RESOURCES.enter_context(as_file(resource))
    except (FileNotFoundError, ModuleNotFoundError) as exc:
        message = (
            f"paxodin could not find its native library {name!r} for {sys.platform}.\n"
            "Hint: install a wheel built for this platform, or build from source "
            "with the Odin compiler available."
        )
        raise OSError(message) from exc


def _bind(library: ctypes.CDLL) -> None:
    """Declare every signature explicitly.

    Args:
        library: The freshly loaded shared library.

    Raises:
        OSError: If the library is missing a symbol this package requires.
    """
    for name, restype, argtypes in _SIGNATURES:
        try:
            function = getattr(library, name)
        except AttributeError as exc:
            message = (
                f"paxodin native library is missing {name!r}.\n"
                "Hint: the Python package and the shared library came from "
                "different builds; reinstall so they match."
            )
            raise OSError(message) from exc
        function.restype = restype
        function.argtypes = list(argtypes)


def _verify(library: ctypes.CDLL, path: Path) -> CProfile:
    """Refuse a library whose ABI or layout differs from this module's mirrors.

    A layout disagreement corrupts silently, so it is checked once at import
    rather than discovered as a wrong field value later.

    Args:
        library: The bound library.
        path: Where it was loaded from, for the error message.

    Returns:
        The library's capacity profile.

    Raises:
        OSError: On an ABI version or struct layout mismatch.
    """
    found = library.paxodin_abi_version()
    if found != EXPECTED_ABI_VERSION:
        message = (
            f"paxodin ABI mismatch: {path} reports version {found}, this package "
            f"requires {EXPECTED_ABI_VERSION}.\n"
            "Hint: reinstall paxodin so the Python package and its native library "
            "come from one build. Never mix them across revisions."
        )
        raise OSError(message)
    profile = CProfile()
    library.paxodin_profile(ctypes.byref(profile))
    drift = [
        f"{field}: library says {getattr(profile, field)}, Python says {ctypes.sizeof(struct)}"
        for field, struct in _SIZE_CHECKS
        if getattr(profile, field) != ctypes.sizeof(struct)
    ]
    if drift:
        joined = "\n  ".join(drift)
        message = (
            f"paxodin struct layout mismatch in {path}:\n  {joined}\n"
            "Hint: the header and the ctypes mirrors disagree. Reinstall from one "
            "build; never edit one side alone."
        )
        raise OSError(message)
    return profile


def _load() -> tuple[ctypes.CDLL, CProfile]:
    """Load, bind and verify the library.

    Returns:
        The library and its verified profile.
    """
    path = _locate()
    library = ctypes.CDLL(str(path))
    _bind(library)
    return library, _verify(library, path)


LIB, PROFILE = _load()
LIBRARY_NAME: Final = _library_filename()


def _read_text(call: object, *args: object) -> str:
    """Probe for the required length, then copy. Both steps are idempotent.

    Args:
        call: The bound ABI function whose last three parameters are the buffer,
            its capacity, and an out-parameter for the required length.
        *args: Leading arguments to pass through.

    Returns:
        The decoded text, or an empty string if the call reports no text.
    """
    needed = ctypes.c_uint32()
    call(*args, None, 0, ctypes.byref(needed))  # type: ignore[operator]
    if needed.value == 0:
        return ""
    buffer = ctypes.create_string_buffer(needed.value + 1)
    status = call(*args, buffer, needed.value + 1, ctypes.byref(needed))  # type: ignore[operator]
    if status != OK:
        return ""
    return buffer.value.decode("utf-8")


def core_version() -> str:
    """Return the version of the Odin core this library was built from.

    Returns:
        A version string such as ``"0.2.0"``, independent of the package version.
    """
    return _read_text(LIB.paxodin_core_version)


def explain(status: int) -> str:
    """Return the explanation and ``Hint:`` line for a status code.

    Protocol statuses are explained by the core's own table in
    ``src/errors.odin``, which an Odin test enumerates. Sourcing the text from
    there is what keeps this package from carrying a copy that can drift.

    Args:
        status: A bridge or protocol status code.

    Returns:
        The multi-line explanation, or an empty string for an unknown code.
    """
    return _read_text(LIB.paxodin_explain, status)


def status_count() -> int:
    """Return how many protocol status codes the core defines.

    Returns:
        The count, so a caller can enumerate every status without hardcoding a
        number that drifts when the core gains an error.
    """
    return int(LIB.paxodin_status_count())


def capabilities() -> int:
    """Return the capability bits this library was built with.

    Returns:
        A bitmask. A feature whose contract and negative tests do not exist yet
        reports its bit clear and refuses the call, rather than half-working.
    """
    return int(LIB.paxodin_capabilities())
