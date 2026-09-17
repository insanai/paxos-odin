#!/usr/bin/env python3
"""Tests for benchmark evidence handling; no compilers or dependencies required."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from matched_compare import bootstrap_ratio, fingerprint, observation, summarize


class EvidenceTests(unittest.TestCase):
    def test_paired_ratio_direction(self):
        result = bootstrap_ratio([100]*9, [80]*9)
        self.assertEqual(result['median'], .8)
        self.assertEqual(result['ci95'], [.8,.8])

    def test_fingerprint_detects_dirty_source(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory)/'a.odin'
            p.write_text('package example')
            first = fingerprint([Path(directory)])
            p.write_text('package changed')
            self.assertNotEqual(first, fingerprint([Path(directory)]))

    def test_missing_validation_fails_closed(self):
        with self.assertRaises(RuntimeError):
            observation([sys.executable,'-c','print(\'{"ns_total":1}\')'])

    def test_subprocess_failure_is_not_a_sample(self):
        with self.assertRaises(RuntimeError):
            observation([sys.executable,'-c','raise SystemExit(9)'])

    def test_summary_retains_distribution(self):
        self.assertEqual(summarize([9,1,5,3,7])['median'],5)


if __name__ == '__main__':unittest.main()
