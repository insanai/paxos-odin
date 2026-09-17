"""The exception hierarchy.

Every error explains itself. Following the project's Odin convention, a message
names the context, the cause and a ``Hint:`` with the corrective action -- and
the hint text comes from the native library, which reads the core's own
explanation table. This package deliberately keeps no second copy of that text,
because a duplicate is a copy that can drift.
"""

from __future__ import annotations

from typing import Any, Final

from paxodin import _native

BANNER_WIDTH: Final = 80


def _split(text: str) -> tuple[str, str, str]:
    """Split a native explanation block into its title, cause and hint.

    Args:
        text: The block returned by the native explain call.

    Returns:
        A ``(title, cause, hint)`` triple. Any part may be empty.
    """
    title = ""
    cause_lines: list[str] = []
    hint_lines: list[str] = []
    in_hint = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("--"):
            title = line.strip("- ").strip()
            continue
        if line.startswith("Hint:"):
            in_hint = True
            hint_lines.append(line.removeprefix("Hint:").strip())
        elif in_hint:
            hint_lines.append(line)
        else:
            cause_lines.append(line)
    return title, " ".join(cause_lines), " ".join(hint_lines)


def _title_of(name: str) -> str:
    """Turn ``NotLeader`` into ``NOT LEADER``, the way the Odin table spells it."""
    words: list[str] = []
    current = ""
    for char in name:
        if char.isupper() and current:
            words.append(current)
            current = char
        else:
            current += char
    words.append(current)
    return " ".join(words).upper()


class PaxodinError(Exception):
    """Base class for every error this package raises.

    Every error renders in the same three-part shape the Odin core uses for
    its own, so a Python traceback reads like an Odin diagnostic::

        -- NOT LEADER ------------------------------------------------------------------

        This node has not completed phase one for its current ballot.
          leader = 2
        Hint: Route to current_leader() or wait for a successful campaign.

    The title names the situation, the cause says what happened with the values
    that matter, and the hint says what to do about it. An error never only
    states what failed. Hint text for a protocol error comes from the core's own
    table; this package keeps no copy that could drift.

    Where a standard exception already means the right thing, the subclass
    inherits it too: a ``CommitTimeout`` is a ``TimeoutError``, a ``ValueTooLarge``
    is a ``ValueError``, a ``StorageError`` is an ``OSError``. Code that already
    handles the builtin keeps working; code that wants the detail asks for it.

    Attributes:
        code: The stable status code, usable in logs and comparisons.
        title: The banner text.
        message: A one-sentence statement of what went wrong.
        hint: The corrective action, never an apology.
        context: Structured detail a caller can act on programmatically.
    """

    code: int = -1
    title: str = ""
    default_message: str = ""
    default_hint: str = ""

    def __init__(
        self,
        message: str = "",
        *,
        hint: str = "",
        code: int | None = None,
        **context: Any,  # noqa: ANN401
    ) -> None:
        """Build an error that states the cause and the recovery.

        Args:
            message: The cause. Defaults to the native explanation.
            hint: The corrective action. Defaults to the native hint.
            code: Overrides the class status code.
            **context: Structured detail attached to the exception.
        """
        if code is not None:
            self.code = code
        native_title, native_cause, native_hint = _split(_native.explain(self.code))
        self.title = self.title or native_title or _title_of(self.__class__.__name__)
        self.message = message or native_cause or self.default_message
        self.hint = hint or native_hint or self.default_hint
        self.context = context
        super().__init__(self.render())

    def render(self) -> str:
        """Render the Elm-style block: banner, cause, values, hint.

        Returns:
            The multi-line text ``str(exc)`` returns.
        """
        lines = [f"-- {self.title} ".ljust(BANNER_WIDTH, "-"), "", self.message]
        lines.extend(f"  {key} = {value!r}" for key, value in self.context.items())
        if self.hint:
            lines.append(f"Hint: {self.hint}")
        return "\n".join(lines)

    def __str__(self) -> str:
        """Return the rendered block."""
        return self.render()


class UsageError(PaxodinError):
    """The caller used the API in a way that cannot be right."""

    default_message = "The call does not fit the API's contract."
    default_hint = (
        "Read the exception's type and context; this is a programming error, not a "
        "cluster condition."
    )


class InvalidArgument(UsageError, ValueError):
    """An argument is outside the range this profile accepts."""

    code = _native.E_INVALID_ARGUMENT


class ValueTooLarge(UsageError, ValueError):
    """The command exceeds the compiled profile. No proposal was admitted."""

    code = _native.E_VALUE_TOO_LARGE


class UnsupportedKind(UsageError, ValueError):
    """An enum tag is not one this ABI version defines."""

    code = _native.E_UNSUPPORTED_KIND


class UnsupportedCapability(UsageError):
    """This build omits the feature. A capability ships only with its tests."""

    code = _native.E_UNSUPPORTED_CAPABILITY


class HandleClosed(UsageError, RuntimeError):
    """The node is closed. A closed handle is never reopened."""

    code = _native.E_HANDLE_CLOSED


class ForkedHandle(UsageError):
    """A native handle does not survive ``fork()``."""

    code = _native.E_WRONG_PROCESS


class ReentrantCall(UsageError, RuntimeError):
    """An adapter called back into the node that is driving it."""

    code = _native.E_REENTRANT


class BatchError(PaxodinError):
    """The pending-batch contract was not followed."""

    default_message = "A pending batch was driven out of order."
    default_hint = (
        "Copy the writes, persist and sync, confirm, read the outputs, then finish -- in "
        "that order."
    )


class BatchPending(BatchError):
    """A previous batch has not been discharged, so no transition may begin."""

    code = _native.E_BATCH_PENDING


class NoBatch(BatchError):
    """There is no pending batch on this node."""

    code = _native.E_NO_BATCH


class StaleToken(BatchError):
    """This token names a batch a later transition superseded."""

    code = _native.E_STALE_TOKEN


class ForeignToken(BatchError):
    """This token belongs to another handle, or one since closed."""

    code = _native.E_FOREIGN_TOKEN


class BatchFinished(BatchError):
    """The batch was released; its native effects are gone."""

    code = _native.E_BATCH_FINISHED


class WritesUnconfirmed(BatchError):
    """Outputs were read, or the batch released, before its writes were durable."""

    code = _native.E_WRITES_UNCONFIRMED


class AbandonedBatch(WritesUnconfirmed):
    """A batch was left holding writes that were never confirmed durable.

    The records were handed out but never acknowledged, so the node cannot tell
    which of them reached stable storage. Resuming would risk acting on a
    promise or a vote that a crash could revert.
    """

    def __init__(self, **context: Any) -> None:  # noqa: ANN401
        """Explain what was abandoned and how to recover.

        Args:
            **context: Structured detail to attach.
        """
        super().__init__(
            "left a batch holding writes that were never confirmed durable",
            hint=(
                "Call persisted() after the journal sync, or close the node and "
                "replay its journal. Never confirm a write that failed."
            ),
            **context,
        )


class WritesNotCopied(BatchError):
    """Confirmation was requested for records the host never received."""

    code = _native.E_WRITES_NOT_COPIED


class ReplayActive(BatchError):
    """This node is replaying a journal; transitions are not yet legal."""

    code = _native.E_REPLAY_ACTIVE


class ReplayNotActive(BatchError):
    """This node is live; replay applies only to one opened for it."""

    code = _native.E_REPLAY_NOT_ACTIVE


class ProtocolError(PaxodinError):
    """The core refused the operation. The node is intact."""

    default_message = "The consensus engine refused the operation; the node is unchanged."
    default_hint = "Inspect the status code and the node's state before retrying."


class NotLeader(ProtocolError):
    """This participant is a follower; no forwarding is performed."""

    code = _native.CORE_STATUS_BASE + 19


class LeaderCatchingUp(ProtocolError):
    """The leader has not yet delivered every inherited slot."""

    code = _native.CORE_STATUS_BASE + 20


class WindowFull(ProtocolError):
    """The window cannot advance until released entries are durably consumed."""

    code = _native.CORE_STATUS_BASE + 21


class LogSealed(ProtocolError):
    """A stop sign is pending or decided; this configuration takes no more."""

    code = _native.CORE_STATUS_BASE + 37


class ConfigurationMismatch(ProtocolError):
    """The envelope belongs to another configuration. Nothing changed."""

    code = _native.CORE_STATUS_BASE + 18


class Trimmed(ProtocolError):
    """The requested slots fell below the memory floor; read retained history."""

    code = _native.CORE_STATUS_BASE + 42


class CampaignDisabled(ProtocolError):
    """This voter is configured never to start elections."""

    code = _native.CORE_STATUS_BASE + 29


class NativeError(PaxodinError):
    """A native failure with no more specific class."""

    default_message = (
        "The native library reported a failure this package has no specific class for."
    )
    default_hint = "Report the status code with the output of paxodin.core_version()."


class OutOfMemory(NativeError):
    """The bridge could not allocate a node or its replay scratch."""

    code = _native.E_OUT_OF_MEMORY


class Poisoned(NativeError):
    """An invariant failed; the node is unusable rather than falsely recovered."""

    code = _native.E_POISONED


class ProposalLost(ProtocolError):
    """A different value was decided in the slot this command was admitted to.

    In single-leader mode there is no resubmission. If the leader loses its
    ballot after admitting a command, recovery can choose another value for that
    slot and the command is simply dropped. Reporting success here would be a
    lie, so the mismatch is raised instead.
    """

    code = -2

    def __init__(self, **context: Any) -> None:  # noqa: ANN401
        """Name the slot whose decision does not match what was submitted.

        Args:
            **context: Structured detail, typically ``slot`` and ``decided_kind``.
        """
        slot = context.get("slot")
        super().__init__(
            f"slot {slot} was decided with a different value than the one submitted",
            hint=(
                "The command was never chosen. Resubmit it behind an application "
                "command id; the SDK will not silently retry it into another slot."
            ),
            **context,
        )


class InvalidTimeout(UsageError, ValueError):
    """A timeout that cannot mean anything was supplied.

    A negative, NaN or infinite duration is rejected before it reaches native
    code, where it would otherwise become an unbounded wait.
    """

    code = -7

    def __init__(self, supplied: float) -> None:
        """Name the offending value.

        Args:
            supplied: The duration that was rejected.
        """
        super().__init__(
            f"a timeout must be finite and not negative, got {supplied!r}",
            hint="Pass a positive number of seconds measured on a monotonic clock.",
        )


class CommitTimeout(ProtocolError, TimeoutError):
    """The wait ended. This did not cancel anything.

    A timeout is not a rejection: peers may choose the value moments later.
    ``admitted`` reports whether the command entered a slot at all.
    """

    code = -3

    def __init__(self, **context: Any) -> None:  # noqa: ANN401
        """Say what is known, and what the timeout did not establish.

        Args:
            **context: Structured detail, typically ``admitted`` and ``slot``.
        """
        slot = context.get("slot")
        seconds = context.get("seconds")
        where = f"slot {slot}" if slot else "the command"
        window = f" within {seconds:g}s" if isinstance(seconds, (int, float)) else ""
        super().__init__(
            f"{where} was admitted, but its decision was not observed{window}",
            hint=(
                "Keep polling and inspect local history. A timeout does not cancel "
                "Paxos. Retry a command only behind an application command id and a "
                "deduplication policy."
            ),
            **context,
        )


class StorageError(PaxodinError, OSError):
    """Progress stopped with persistence uncertain.

    Reopen and replay the journal rather than guessing which writes landed.
    """

    default_message = "Storage failed and it is not known which writes reached stable media."
    default_hint = (
        "Reopen the node and replay its journal. Never confirm a write that may not have landed."
    )

    code = -4


class TransportError(PaxodinError, OSError):
    """An adapter could not move a frame. Retransmission tolerates duplicates."""

    default_message = "A frame could not be handed to the transport."
    default_hint = (
        "Nothing durable was rolled back; retransmission will repeat it. Check the "
        "adapter's connection."
    )

    code = -5


class JournalNotOpen(StorageError):
    """A journal was used before it was bound to a participant."""

    code = -8

    def __init__(self, path: object) -> None:
        """Name the journal that was used too early.

        Args:
            path: Where it lives.
        """
        super().__init__(
            f"journal at {path} was used before open()",
            hint="A Session opens its journal for you; a direct user calls open() first.",
        )


class JournalCorrupt(StorageError):
    """A complete record failed its checksum. This is corruption, not a tail."""

    code = -6


#: Status code to exception class. Codes absent here fall back by range.
_BY_CODE: dict[int, type[PaxodinError]] = {
    cls.code: cls
    for cls in (
        InvalidArgument,
        ValueTooLarge,
        UnsupportedKind,
        UnsupportedCapability,
        HandleClosed,
        ForkedHandle,
        ReentrantCall,
        BatchPending,
        NoBatch,
        StaleToken,
        ForeignToken,
        BatchFinished,
        WritesUnconfirmed,
        WritesNotCopied,
        ReplayActive,
        ReplayNotActive,
        NotLeader,
        LeaderCatchingUp,
        WindowFull,
        LogSealed,
        ConfigurationMismatch,
        Trimmed,
        CampaignDisabled,
        OutOfMemory,
        Poisoned,
    )
}


def exception_for(status: int, **context: Any) -> PaxodinError:  # noqa: ANN401
    """Build the exception that matches a status code.

    Args:
        status: A bridge or protocol status code.
        **context: Structured detail to attach.

    Returns:
        The most specific exception class for the code, or a generic
        ``ProtocolError`` / ``NativeError`` when none is registered.
    """
    cls = _BY_CODE.get(status)
    if cls is not None:
        return cls(**context)
    if status >= _native.CORE_STATUS_BASE:
        return ProtocolError(code=status, **context)
    return NativeError(code=status, **context)


def raise_for(status: int, **context: Any) -> None:  # noqa: ANN401
    """Raise if a native call reported failure.

    Args:
        status: The status a native call returned.
        **context: Structured detail to attach.

    Raises:
        PaxodinError: When ``status`` is not success.
    """
    if status != _native.OK:
        raise exception_for(status, **context)
