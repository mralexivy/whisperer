#!/usr/bin/env python3
"""Regression tests for sparse-head label IDs and alignments."""

import unittest
from unittest.mock import patch

import build_wispr_corpus as bwc
from common import MERGE2ID, REPL_VOCAB


class ReplacementLabelTests(unittest.TestCase):
    def test_gtransform_id_matches_vocab(self):
        with patch.object(bwc, "apply_gtransform", return_value="walked"):
            label = bwc._try_gtransform_repl("walk", "walked")
        self.assertEqual(REPL_VOCAB[label], "PLURAL")

    def test_literal_id_matches_vocab(self):
        with patch.object(bwc, "REPL_VOCAB", ["NONE", "PLURAL", "glean"]), \
             patch.object(bwc, "REPL_LITERALS", ["glean"]):
            label = bwc._try_literal_repl("glean")
            self.assertEqual(label, 2)


class MergeLabelTests(unittest.TestCase):
    def align(self, raw, target):
        ex, _, _, _ = bwc.wispr_align_pair(raw, target, "en", "test", {})
        self.assertIsNotNone(ex)
        return ex

    def test_merge_space(self):
        ex = self.align("note book", "notebook")
        self.assertEqual(ex.merge[0], MERGE2ID["MERGE_SPACE"])

    def test_merge_hyphen(self):
        ex = self.align("well known", "well-known")
        self.assertEqual(ex.merge[0], MERGE2ID["MERGE_HYPHEN"])

    def test_split(self):
        ex = self.align("notebook", "note book")
        self.assertEqual(ex.merge[0], MERGE2ID["SPLIT"])

    def test_unrelated_one_to_two_is_not_split(self):
        ex, masks, _, _ = bwc.wispr_align_pair(
            "hello", "good morning", "en", "test", {}
        )
        self.assertIsNone(ex)
        self.assertEqual(masks["merge_label_missing_1to2"], 1)


if __name__ == "__main__":
    unittest.main()
