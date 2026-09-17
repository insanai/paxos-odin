"""Every exception explains itself the way the Odin core's errors do.

The Odin suite enumerates the `Error` enum and fails on any value without a
title, a cause and a `Hint:`. This does the same for every Python exception
class, so an error can never be added that only says what failed.
"""

import inspect

import pytest

from paxodin import errors

CLASSES = [
    cls
    for _, cls in inspect.getmembers(errors, inspect.isclass)
    if issubclass(cls, errors.PaxodinError) and cls is not errors.PaxodinError
]


def build(cls):
    """Construct any error class with plausible arguments."""
    signature = inspect.signature(cls.__init__)
    kwargs = {}
    for name, parameter in signature.parameters.items():
        if name in ("self", "message", "hint", "code", "context"):
            continue
        if parameter.kind is parameter.VAR_KEYWORD:
            continue
        if parameter.default is parameter.empty:
            kwargs[name] = 1.5 if "timeout" in name or name == "supplied" else "state/node-1"
    return cls(**kwargs)


@pytest.mark.parametrize("cls", CLASSES, ids=lambda cls: cls.__name__)
def test_every_error_has_a_title_a_cause_and_a_hint(cls):
    error = build(cls)
    text = str(error)
    banner = text.splitlines()[0]
    assert banner.startswith("-- ") and banner.endswith("-"), banner
    assert len(banner) == errors.BANNER_WIDTH, banner
    assert error.message and error.message != cls.__name__, cls
    assert error.hint, f"{cls.__name__} offers no recovery"
    assert "Hint:" in text


def test_the_block_matches_the_odin_shape():
    error = errors.NotLeader(leader=2)
    lines = str(error).splitlines()
    assert lines[0] == "-- NOT LEADER ".ljust(errors.BANNER_WIDTH, "-")
    assert lines[1] == ""
    assert lines[2] == "This node has not completed phase one for its current ballot."
    assert lines[3] == "  leader = 2"
    assert lines[4].startswith("Hint: ")


@pytest.mark.parametrize(
    ("cls", "builtin"),
    [
        (errors.CommitTimeout, TimeoutError),
        (errors.ValueTooLarge, ValueError),
        (errors.InvalidTimeout, ValueError),
        (errors.StorageError, OSError),
        (errors.HandleClosed, RuntimeError),
    ],
)
def test_errors_are_also_the_builtin_a_caller_expects(cls, builtin):
    assert issubclass(cls, builtin)


def test_title_is_derived_from_the_class_name_when_native_has_none():
    assert errors._title_of("ProposalLost") == "PROPOSAL LOST"
    assert errors._title_of("JournalNotOpen") == "JOURNAL NOT OPEN"
