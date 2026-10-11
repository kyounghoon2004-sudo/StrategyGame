"""Unit test verifying the generated mass corpus V1."""
from __future__ import annotations

import json
from pathlib import Path
import pytest

from tools.training_supervisor import reward_contract as RC

PROJ = Path(__file__).resolve().parent.parent.parent.parent
CORPUS_FILE = PROJ / "artifacts" / "contract_sft_v1" / "dataset" / "mass_corpus_v1.jsonl"


def test_mass_corpus_exists_and_count():
    assert CORPUS_FILE.exists(), f"Corpus file missing: {CORPUS_FILE}"
    lines = [line.strip() for line in CORPUS_FILE.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert len(lines) == 40, f"Expected exactly 40 rows, found {len(lines)}"


def test_mass_corpus_variants_and_coherence():
    variants_by_scen = {}
    with open(CORPUS_FILE, encoding="utf-8") as f:
        for idx, line in enumerate(f):
            row = json.loads(line)
            sc_id = row["scenario_id"]
            vid = row["variant_id"]
            plan = row["plan"]

            variants_by_scen.setdefault(sc_id, []).append(vid)

            # Contract checks
            assert "objective" in plan and len(plan["objective"]) > 0
            assert "phases" in plan and 2 <= len(plan["phases"]) <= 4
            assert plan["phases"][-1]["next"] == "END"

            # Coherence check
            doc, dups, err = RC._parse_direct(json.dumps(plan))
            assert not err, f"Parse error in row {idx} ({sc_id} {vid}): {err}"
            coh = RC.coherence_check(doc, dups.paths)
            assert not coh, f"Coherence violations in row {idx} ({sc_id} {vid}): {coh}"

    assert len(variants_by_scen) == 8, f"Expected 8 scenarios, found {len(variants_by_scen)}"
    for sc_id, vids in variants_by_scen.items():
        assert sorted(vids) == ["V1", "V2", "V3", "V4", "V5"], f"Scenario {sc_id} has unexpected variants: {vids}"
