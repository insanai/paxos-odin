"""Identity, capacities and explanation text at the native boundary.

These run twice: once against the shipped .Host_Managed library and once against
the .Enforced twin, which compiles the core's own durability gate in.
"""

import json
import os
import subprocess
import sys
from importlib.metadata import version

import pytest

import paxodin
from paxodin import _native


def test_abi_version_matches_the_loaded_library():
    assert _native.LIB.paxodin_abi_version() == paxodin.abi_version()


def test_core_version_is_reported_separately_from_the_package_version():
    assert paxodin.core_version() == "0.2.0"
    assert paxodin.__version__ == version("paxodin")


def test_profile_reports_the_compiled_capacities():
    profile = paxodin.profile()
    assert profile.max_members == 7
    assert profile.window_slots == 256
    assert profile.chunk_slots == 64
    assert profile.max_value_bytes == 1024
    assert profile.max_metadata_bytes == 256


def test_window_is_a_power_of_two():
    window = paxodin.profile().window_slots
    assert window > 0
    assert window & (window - 1) == 0


def test_chunk_fits_inside_the_window():
    profile = paxodin.profile()
    assert 1 <= profile.chunk_slots <= profile.window_slots


def test_batch_capacities_match_the_core_formulas():
    # These mirror the capacity formulas on Effects. A caller that sizes a
    # buffer from them never sees a short-buffer status.
    profile = paxodin.profile()
    assert profile.max_writes_per_batch == 2 * profile.chunk_slots + 1
    assert profile.max_messages_per_batch == (
        profile.max_members * profile.chunk_slots + 2 * profile.max_members + 1
    )
    assert profile.max_committed_per_batch == profile.window_slots + 1
    assert profile.max_requests_per_batch == profile.max_members


def test_profile_is_frozen():
    profile = paxodin.profile()
    with pytest.raises((AttributeError, TypeError)):
        profile.max_members = 9


def test_static_footprint_is_bounded_and_reported():
    profile = paxodin.profile()
    assert 0 < profile.node_bytes < 4 * 1024 * 1024
    assert 0 < profile.effects_bytes < profile.node_bytes


def test_gate_flag_identifies_which_library_is_loaded():
    expected = os.environ.get("PAXODIN_LIB") == "enforced"
    assert paxodin.profile().gate_enforced is expected


def test_fingerprint_is_stable_and_not_degenerate():
    assert paxodin.profile().fingerprint == paxodin.profile().fingerprint
    assert paxodin.profile().fingerprint != 0


def test_capabilities_omit_features_without_contracts():
    # A capability ships only once its wrapper contract and negative tests
    # exist; until then the bit stays clear and the call is refused.
    caps = paxodin.capabilities()
    assert caps & (1 << 0)  # replicated log
    assert caps & (1 << 1)  # replay
    assert caps & (1 << 2)  # trim anchor
    assert not caps & (1 << 3)  # reconfiguration
    assert not caps & (1 << 4)  # rotating ownership


@pytest.mark.parametrize("ordinal", range(1, 43))
def test_every_protocol_error_explains_problem_and_recovery(ordinal):
    # Mirrors test_every_error_explains_problem_and_recovery in
    # tests/test_errors.odin: an error never only states what failed.
    status = _native.CORE_STATUS_BASE + ordinal
    text = paxodin.explain(status)
    assert text, f"status {status} has no explanation"
    assert "Hint:" in text, f"status {status} explains itself but offers no recovery"


@pytest.mark.parametrize("status", range(1, 23))
def test_every_bridge_status_explains_problem_and_recovery(status):
    text = paxodin.explain(status)
    assert text, f"bridge status {status} has no explanation"
    assert "Hint:" in text, f"bridge status {status} offers no recovery"


def test_status_count_covers_every_explained_code():
    count = paxodin.status_count()
    assert paxodin.explain(_native.CORE_STATUS_BASE + count - 1)
    assert paxodin.explain(_native.CORE_STATUS_BASE + count) == ""


def test_success_has_an_explanation_but_needs_no_hint():
    assert paxodin.explain(0).strip() == "No error."


def test_unknown_status_returns_empty_rather_than_guessing():
    assert paxodin.explain(99_999) == ""
    assert paxodin.explain(-1) == ""


def test_explanation_probe_then_copy_is_stable():
    status = _native.CORE_STATUS_BASE + 21
    text = paxodin.explain(status)
    assert len(text) > 64
    assert text == paxodin.explain(status)


def test_both_libraries_agree_on_every_explanation():
    """The .Enforced twin differs only in the gate, never in reported behaviour."""
    other = "enforced" if os.environ.get("PAXODIN_LIB") != "enforced" else ""
    script = (
        "import json, paxodin;"
        "from paxodin import _native;"
        "print(json.dumps([paxodin.explain(c) for c in range(0, 1100)]))"
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, "PAXODIN_LIB": other},
    )
    assert json.loads(result.stdout) == [paxodin.explain(c) for c in range(1100)]


def test_both_libraries_report_the_same_fingerprint():
    other = "enforced" if os.environ.get("PAXODIN_LIB") != "enforced" else ""
    script = "import paxodin; print(paxodin.profile().fingerprint)"
    result = subprocess.run(
        [sys.executable, "-c", script],
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, "PAXODIN_LIB": other},
    )
    assert int(result.stdout.strip()) == paxodin.profile().fingerprint
