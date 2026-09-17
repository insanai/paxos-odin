"""The wire format: round trips, and refusing everything malformed."""

import contextlib

import pytest
from hypothesis import given
from hypothesis import strategies as st

from paxodin import _native, codec, errors
from paxodin.models import (
    Accept,
    Accepted,
    CellState,
    Commit,
    EntryKind,
    Envelope,
    Heartbeat,
    Learn,
    LogEntry,
    Nack,
    Prepare,
    PrepareScope,
    Promise,
    PromiseRange,
)


def envelope(message=None, **overrides):
    base = {"configuration_id": 1, "sender": 1, "recipient": 2}
    base.update(overrides)
    if message is None:
        message = Accept(ballot=16777217, slot=7, entry=LogEntry(EntryKind.COMMAND, b"payload"))
    return Envelope(message=message, **base)


ALL_KINDS = [
    Prepare(ballot=5, first=3, last=9, scope=PrepareScope.BOUNDED),
    Promise(
        ballot=5, slot=4, vote=3, state=CellState.VOTED, entry=LogEntry(EntryKind.COMMAND, b"v")
    ),
    PromiseRange(
        ballot=5,
        first=1,
        last=64,
        reported=12,
        more=True,
        decided_through=4,
        trim_id=11,
        trim_slot=2,
    ),
    Accept(ballot=5, slot=7, entry=LogEntry(EntryKind.COMMAND, b"payload")),
    Accepted(ballot=5, slot=7, decided_through=6),
    Commit(slot=7, entry=LogEntry(EntryKind.NOOP, b"")),
    Learn(from_slot=3, count=64),
    Nack(rejected=5, promised=6, slot=7, decided_through=4),
    Heartbeat(ballot=5, decided_through=4),
]


@pytest.mark.parametrize("message", ALL_KINDS, ids=lambda m: type(m).__name__)
def test_every_message_kind_round_trips(message):
    original = envelope(message)
    decoded = codec.decode(codec.encode(original))
    assert decoded == original
    assert type(decoded.message) is type(message)


def test_a_decoded_message_can_be_matched_on_its_class():
    decoded = codec.decode(
        codec.encode(envelope(Accept(ballot=1, slot=9, entry=LogEntry(EntryKind.COMMAND, b"x"))))
    )
    match decoded.message:
        case Accept(slot=slot):
            assert slot == 9
        case _:
            pytest.fail("expected an Accept")


def test_empty_payload_survives_the_round_trip():
    original = envelope(Accept(ballot=1, slot=1, entry=LogEntry(EntryKind.COMMAND, b"")))
    decoded = codec.decode(codec.encode(original))
    assert decoded.message.entry.kind is EntryKind.COMMAND
    assert decoded.message.entry.body == b""


def test_a_noop_stays_distinguishable_from_an_empty_command():
    noop = codec.decode(
        codec.encode(envelope(Commit(slot=1, entry=LogEntry(EntryKind.NOOP, b""))))
    )
    command = codec.decode(
        codec.encode(envelope(Commit(slot=1, entry=LogEntry(EntryKind.COMMAND, b""))))
    )
    assert noop.message.entry.kind is EntryKind.NOOP
    assert command.message.entry.kind is EntryKind.COMMAND


@given(st.binary(max_size=_native.MAX_VALUE_BYTES))
def test_any_payload_round_trips(payload):
    original = envelope(Accept(ballot=1, slot=1, entry=LogEntry(EntryKind.COMMAND, payload)))
    assert codec.decode(codec.encode(original)).message.entry.body == payload


@given(st.binary(max_size=64))
def test_arbitrary_bytes_never_crash_the_decoder(blob):
    # A frame arrives from a peer; nothing in it is trusted.
    with contextlib.suppress(errors.PaxodinError):
        codec.decode(blob)


def test_a_truncated_frame_is_refused():
    frame = codec.encode(envelope())
    with pytest.raises(errors.InvalidArgument):
        codec.decode(frame[:-1])


def test_an_oversized_frame_is_refused():
    with pytest.raises(errors.InvalidArgument):
        codec.decode(codec.encode(envelope()) + b"\x00" * codec.MAX_FRAME_SIZE)


def test_a_foreign_magic_is_refused():
    frame = bytearray(codec.encode(envelope()))
    frame[0:4] = b"XXXX"
    with pytest.raises(errors.InvalidArgument):
        codec.decode(bytes(frame))


def test_another_wire_version_is_refused():
    frame = bytearray(codec.encode(envelope()))
    frame[4:6] = (codec.WIRE_VERSION + 1).to_bytes(2, "big")
    with pytest.raises(errors.InvalidArgument):
        codec.decode(bytes(frame))


def test_a_different_capacity_profile_is_refused():
    # Same wire version, different capacities: a value that peer considers valid
    # may not fit, and a slot it considers in-window may not be.
    frame = bytearray(codec.encode(envelope()))
    frame[6:14] = (_native.PROFILE.fingerprint ^ 0xFF).to_bytes(8, "big")
    with pytest.raises(errors.InvalidArgument):
        codec.decode(bytes(frame))


def test_a_zero_node_id_is_refused():
    frame = bytearray(codec.encode(envelope()))
    frame[22:24] = (0).to_bytes(2, "big")
    with pytest.raises(errors.InvalidArgument):
        codec.decode(bytes(frame))


def test_an_unknown_message_kind_is_refused():
    frame = bytearray(codec.encode(envelope()))
    frame[26] = 200
    with pytest.raises(errors.UnsupportedKind):
        codec.decode(bytes(frame))


def test_a_declared_length_that_disagrees_with_the_frame_is_refused():
    frame = bytearray(codec.encode(envelope()))
    # entry_length is the last field of the header, not the tail of the frame.
    frame[codec.HEADER_SIZE - 4 : codec.HEADER_SIZE] = (999).to_bytes(4, "big")
    with pytest.raises(errors.InvalidArgument):
        codec.decode(bytes(frame))


def test_encoding_refuses_an_oversized_payload():
    too_big = LogEntry(EntryKind.COMMAND, b"x" * (_native.MAX_VALUE_BYTES + 1))
    with pytest.raises(errors.InvalidArgument):
        codec.encode(envelope(Accept(ballot=1, slot=1, entry=too_big)))


def test_frames_are_byte_order_stable():
    # A fixed byte order removes a whole class of "works on my cluster" bugs.
    frame = codec.encode(envelope(Heartbeat(ballot=0x0102030405060708, decided_through=0)))
    assert b"\x01\x02\x03\x04\x05\x06\x07\x08" in frame
