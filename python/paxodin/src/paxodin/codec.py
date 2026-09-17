"""Encoding envelopes as frames.

The wire format lives in Python, not in the native bridge, so it can version
independently of the ABI. It is length-delimited, fixed byte order, explicitly
tagged, and stamped with both the configuration and the profile fingerprint --
so a peer running a different capacity profile is refused rather than allowed to
misread a value.

Nothing here uses :mod:`pickle` or any format that can execute on decode. A frame
is data from an untrusted peer, and every field is validated against this build's
limits before it can reach the core.
"""

from __future__ import annotations

import struct
from typing import Final, NamedTuple

from paxodin import _decode, _native
from paxodin.errors import InvalidArgument, UnsupportedKind
from paxodin.models import CellState, EntryKind, Envelope, LogEntry, MessageKind

MAGIC: Final = b"PXDN"
WIRE_VERSION: Final = 1

# Big-endian throughout: a fixed byte order costs nothing and removes a whole
# class of "works on my cluster" failures.
_HEADER: Final = struct.Struct(
    ">4sHQQ"  # magic, wire version, profile fingerprint, configuration id
    "HH"  # sender, recipient
    "BBBB"  # kind, scope, cell state, more
    "QQQQQQQQQQ"  # ballot slot vote first last rejected promised decided trim_id trim_slot
    "I"  # count
    "BI"  # entry kind, entry length
)
HEADER_SIZE: Final = _HEADER.size


class _Header(NamedTuple):
    """The unpacked frame header, in wire order."""

    magic: bytes
    version: int
    fingerprint: int
    configuration_id: int
    sender: int
    recipient: int
    kind: int
    scope: int
    cell_state: int
    more: int
    ballot: int
    slot: int
    vote: int
    first: int
    last: int
    rejected: int
    promised: int
    decided_through: int
    trim_id: int
    trim_slot: int
    range_count: int
    entry_kind: int
    entry_length: int


#: A frame can never exceed the header plus one maximum payload.
MAX_FRAME_SIZE: Final = HEADER_SIZE + _native.MAX_VALUE_BYTES

_VALID_MESSAGE_KINDS: Final = frozenset(int(kind) for kind in MessageKind)
_VALID_ENTRY_KINDS: Final = frozenset(int(kind) for kind in EntryKind)
_VALID_CELL_STATES: Final = frozenset(int(state) for state in CellState)


def encode(envelope: Envelope) -> bytes:
    """Encode one envelope as a frame.

    Args:
        envelope: The message to send.

    Returns:
        The frame, ready to hand to a transport.

    Raises:
        InvalidArgument: If the payload exceeds this build's profile.
    """
    flat = _decode.flatten(envelope.message)
    body = flat.entry.body
    if len(body) > _native.MAX_VALUE_BYTES:
        raise InvalidArgument(supplied=len(body), limit=_native.MAX_VALUE_BYTES)
    header = _HEADER.pack(
        MAGIC,
        WIRE_VERSION,
        _native.PROFILE.fingerprint,
        envelope.configuration_id,
        envelope.sender,
        envelope.recipient,
        flat.kind,
        flat.scope,
        flat.cell_state,
        flat.more,
        flat.ballot,
        flat.slot,
        flat.vote,
        flat.first,
        flat.last,
        flat.rejected,
        flat.promised,
        flat.decided_through,
        flat.trim_id,
        flat.trim_slot,
        flat.range_count,
        int(flat.entry.kind),
        len(body),
    )
    return header + body


def _validate_frame(frame: bytes) -> _Header:
    """Unpack a frame's header and reject anything malformed.

    A frame arrives from a peer, so nothing in it is trusted. The size, the
    version, the profile fingerprint, both node ids and every enum tag are
    checked here, because the core asserts on values a validated decoder would
    never produce.

    Args:
        frame: The bytes a transport delivered.

    Returns:
        The unpacked header fields.

    Raises:
        InvalidArgument: If the frame is malformed, truncated, oversized, from
            another wire version, or from an incompatible capacity profile.
        UnsupportedKind: If a tag is not one this version defines.
    """
    if len(frame) < HEADER_SIZE:
        raise InvalidArgument(size=len(frame), minimum=HEADER_SIZE)
    if len(frame) > MAX_FRAME_SIZE:
        raise InvalidArgument(size=len(frame), maximum=MAX_FRAME_SIZE)
    header = _Header._make(_HEADER.unpack_from(frame))

    if header.magic != MAGIC:
        raise InvalidArgument(magic=header.magic)
    if header.version != WIRE_VERSION:
        raise InvalidArgument(wire_version=header.version, supported=WIRE_VERSION)
    if header.fingerprint != _native.PROFILE.fingerprint:
        # Same wire version, different capacities: a value this peer considers
        # valid may not fit, and a slot it considers in-window may not be.
        raise InvalidArgument(
            peer_profile=header.fingerprint, local_profile=_native.PROFILE.fingerprint
        )
    if header.sender == 0 or header.recipient == 0:
        raise InvalidArgument(sender=header.sender, recipient=header.recipient)
    if header.kind not in _VALID_MESSAGE_KINDS or header.kind == int(MessageKind.NONE):
        raise UnsupportedKind(message_kind=header.kind)
    if header.entry_kind not in _VALID_ENTRY_KINDS:
        raise UnsupportedKind(entry_kind=header.entry_kind)
    if header.cell_state not in _VALID_CELL_STATES:
        raise UnsupportedKind(cell_state=header.cell_state)
    if header.scope > 1:
        raise UnsupportedKind(scope=header.scope)
    if header.entry_length > _native.MAX_VALUE_BYTES:
        raise InvalidArgument(entry_length=header.entry_length, limit=_native.MAX_VALUE_BYTES)
    if len(frame) != HEADER_SIZE + header.entry_length:
        raise InvalidArgument(size=len(frame), declared=HEADER_SIZE + header.entry_length)
    return header


def decode(frame: bytes) -> Envelope:
    """Decode one frame, validating every field.

    Args:
        frame: The bytes a transport delivered.

    Returns:
        The decoded envelope.

    Raises:
        InvalidArgument: If the frame is malformed or incompatible.
        UnsupportedKind: If a tag is not one this version defines.
    """
    header = _validate_frame(frame)
    flat = _decode.Flat(
        kind=header.kind,
        ballot=header.ballot,
        slot=header.slot,
        vote=header.vote,
        first=header.first,
        last=header.last,
        rejected=header.rejected,
        promised=header.promised,
        decided_through=header.decided_through,
        trim_id=header.trim_id,
        trim_slot=header.trim_slot,
        range_count=header.range_count,
        scope=header.scope,
        cell_state=header.cell_state,
        more=header.more,
        entry=LogEntry(kind=EntryKind(header.entry_kind), body=frame[HEADER_SIZE:]),
    )
    return Envelope(
        configuration_id=header.configuration_id,
        sender=header.sender,
        recipient=header.recipient,
        message=_decode.unflatten(flat),
    )
