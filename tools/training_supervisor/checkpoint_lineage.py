"""Checkpoint lineage metadata — metadata only, no real checkpoints.

Concept (metadata support only):

    immutable B0 (base model)
      -> champion C0
      -> candidate T1 (trained from C0)
           promote -> C1 (C0 becomes HISTORICAL, never overwritten)
           reject  -> T1 becomes REJECTED, C0 retained unchanged

Status vocabulary: CANDIDATE, CHAMPION, REJECTED, HISTORICAL.

Invariants enforced here:
- At most one CHAMPION record at any time.
- CHAMPION records are immutable once written; a new champion is created
  as a new record (append-only lineage).
- A CANDIDATE may transition to CHAMPION or REJECTED; nothing else.
- HISTORICAL is set automatically on the previous champion when a new
  champion is recorded.
- No file paths are created or modified by this module.
"""
from __future__ import annotations

import hashlib
import json
import time
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional

STATUS_CANDIDATE = "CANDIDATE"
STATUS_CHAMPION = "CHAMPION"
STATUS_REJECTED = "REJECTED"
STATUS_HISTORICAL = "HISTORICAL"

CANDIDATE_STATUSES = (STATUS_CANDIDATE, STATUS_CHAMPION, STATUS_REJECTED,
                      STATUS_HISTORICAL)

BASE_KIND = "BASE"
CHAMPION_KIND = "CHAMPION"
CANDIDATE_KIND = "CANDIDATE"

_LINEAGE_SCHEMA_VERSION = 1


def _utcnow_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z"


def record_hash(record: Dict[str, Any]) -> str:
    """Stable content hash for a lineage record (canonical JSON, sorted)."""
    canonical = json.dumps(record, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


@dataclass
class LineageRecord:
    """One checkpoint/adaptor identity in the lineage metadata."""

    checkpoint_id: str
    kind: str                      # BASE | CHAMPION | CANDIDATE
    status: str = STATUS_CANDIDATE
    parent_champion_id: Optional[str] = None
    base_model_id: str = ""
    base_revision: str = ""
    iteration: int = 0
    created_at: str = field(default_factory=_utcnow_iso)
    artifact_path: Optional[str] = None       # metadata only; may be null
    artifact_hash: Optional[str] = None       # "hash when available"
    hash_algorithm: Optional[str] = None
    evaluation_ref: Optional[str] = None      # evaluation_id reference
    promotion_reason: Optional[str] = None
    rejection_reason: Optional[str] = None
    extra: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: Dict[str, Any]) -> "LineageRecord":
        return cls(
            checkpoint_id=d["checkpoint_id"],
            kind=d["kind"],
            status=d.get("status", STATUS_CANDIDATE),
            parent_champion_id=d.get("parent_champion_id"),
            base_model_id=d.get("base_model_id", ""),
            base_revision=d.get("base_revision", ""),
            iteration=int(d.get("iteration", 0)),
            created_at=d.get("created_at") or _utcnow_iso(),
            artifact_path=d.get("artifact_path"),
            artifact_hash=d.get("artifact_hash"),
            hash_algorithm=d.get("hash_algorithm"),
            evaluation_ref=d.get("evaluation_ref"),
            promotion_reason=d.get("promotion_reason"),
            rejection_reason=d.get("rejection_reason"),
            extra=dict(d.get("extra") or {}),
        )


class CheckpointLineage:
    """Append-only lineage metadata store (in-memory; persisted by RunState)."""

    def __init__(self, records: Optional[List[LineageRecord]] = None) -> None:
        self._records: List[LineageRecord] = list(records or [])

    # ------------------------------------------------------------------
    # queries
    # ------------------------------------------------------------------
    def records(self) -> List[LineageRecord]:
        return list(self._records)

    def champion(self) -> Optional[LineageRecord]:
        for r in self._records:
            if r.status == STATUS_CHAMPION:
                return r
        return None

    def get(self, checkpoint_id: str) -> Optional[LineageRecord]:
        for r in self._records:
            if r.checkpoint_id == checkpoint_id:
                return r
        return None

    # ------------------------------------------------------------------
    # creation (metadata only)
    # ------------------------------------------------------------------
    def register_base(self, checkpoint_id: str, base_model_id: str,
                      base_revision: str,
                      artifact_path: Optional[str] = None) -> LineageRecord:
        if self.get(checkpoint_id) is not None:
            raise ValueError(f"checkpoint id already registered: {checkpoint_id!r}")
        rec = LineageRecord(
            checkpoint_id=checkpoint_id,
            kind=BASE_KIND,
            status=STATUS_CHAMPION,  # B0 is the immutable starting champion
            base_model_id=base_model_id,
            base_revision=base_revision,
            iteration=0,
            artifact_path=artifact_path,
        )
        self._records.append(rec)
        return rec

    def register_candidate(self, checkpoint_id: str, iteration: int,
                           parent_champion_id: Optional[str] = None,
                           evaluation_ref: Optional[str] = None,
                           artifact_path: Optional[str] = None,
                           artifact_hash: Optional[str] = None,
                           hash_algorithm: Optional[str] = "sha256",
                           ) -> LineageRecord:
        if self.get(checkpoint_id) is not None:
            raise ValueError(f"checkpoint id already registered: {checkpoint_id!r}")
        champion = self.champion()
        if parent_champion_id is None:
            parent_champion_id = champion.checkpoint_id if champion else None
        if parent_champion_id is not None and self.get(parent_champion_id) is None:
            raise ValueError(f"unknown parent champion: {parent_champion_id!r}")
        rec = LineageRecord(
            checkpoint_id=checkpoint_id,
            kind=CANDIDATE_KIND,
            status=STATUS_CANDIDATE,
            parent_champion_id=parent_champion_id,
            base_model_id=(self.get(parent_champion_id).base_model_id
                           if parent_champion_id else ""),
            base_revision=(self.get(parent_champion_id).base_revision
                           if parent_champion_id else ""),
            iteration=iteration,
            artifact_path=artifact_path,
            artifact_hash=artifact_hash,
            hash_algorithm=hash_algorithm,
            evaluation_ref=evaluation_ref,
        )
        self._records.append(rec)
        return rec

    # ------------------------------------------------------------------
    # transactional promotion / rejection
    # ------------------------------------------------------------------
    def promote(self, checkpoint_id: str, evaluation_ref: Optional[str],
                reason: str = "") -> Dict[str, Any]:
        """Transactionally promote a CANDIDATE to CHAMPION.

        Returns a two-phase commit plan: ``validate()`` must be re-run on
        the applied state; ``rollback`` inverts the change if the caller's
        persistence fails, keeping promotion idempotent/transactional.
        """
        rec = self.get(checkpoint_id)
        if rec is None:
            raise ValueError(f"unknown candidate: {checkpoint_id!r}")
        if rec.status != STATUS_CANDIDATE:
            raise ValueError(
                f"only CANDIDATE records can be promoted; {checkpoint_id!r} "
                f"is {rec.status}")
        previous = self.champion()
        if previous is not None and previous.checkpoint_id == checkpoint_id:
            raise ValueError("candidate already champion")

        applied = {
            "candidate_prev_status": rec.status,
            "candidate_new_status": STATUS_CHAMPION,
            "candidate_prev_evaluation_ref": rec.evaluation_ref,
            "candidate_new_evaluation_ref": evaluation_ref,
            "previous_champion_id": previous.checkpoint_id if previous else None,
            "previous_champion_prev_status": (previous.status if previous else None),
            "previous_champion_new_status": (STATUS_HISTORICAL if previous else None),
        }
        rec.status = STATUS_CHAMPION
        rec.kind = CHAMPION_KIND
        rec.evaluation_ref = evaluation_ref
        rec.promotion_reason = reason
        if previous is not None:
            previous.status = STATUS_HISTORICAL
        return {"applied": applied, "rollback": self._rollback_plan(applied)}

    def _rollback_plan(self, applied: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "checkpoint_id": None,  # resolved at rollback time
            "restore_candidate_status": applied["candidate_prev_status"],
            "restore_candidate_evaluation_ref": applied["candidate_prev_evaluation_ref"],
            "restore_previous_champion_status": applied["previous_champion_prev_status"],
        }

    def rollback_last_promotion(self, checkpoint_id: str) -> None:
        """Invert a promotion (used when persistence of the new state fails)."""
        rec = self.get(checkpoint_id)
        if rec is None or rec.status != STATUS_CHAMPION:
            return
        rec.status = STATUS_CANDIDATE
        rec.kind = CANDIDATE_KIND
        prev_champ_id = rec.parent_champion_id
        if prev_champ_id:
            prev = self.get(prev_champ_id)
            if prev is not None and prev.status == STATUS_HISTORICAL:
                prev.status = STATUS_CHAMPION

    def reject(self, checkpoint_id: str, reason: str = "") -> None:
        """Reject a CANDIDATE; the champion is retained unchanged."""
        rec = self.get(checkpoint_id)
        if rec is None:
            raise ValueError(f"unknown candidate: {checkpoint_id!r}")
        if rec.status != STATUS_CANDIDATE:
            raise ValueError(
                f"only CANDIDATE records can be rejected; {checkpoint_id!r} "
                f"is {rec.status}")
        rec.status = STATUS_REJECTED
        rec.rejection_reason = reason

    # ------------------------------------------------------------------
    # validation + persistence helpers
    # ------------------------------------------------------------------
    def validate(self) -> List[str]:
        """Return a list of invariant violations (empty list == valid)."""
        problems: List[str] = []
        champions = [r for r in self._records if r.status == STATUS_CHAMPION]
        if len(champions) > 1:
            problems.append(
                f"multiple champions: {[r.checkpoint_id for r in champions]}")
        for r in self._records:
            if r.status not in CANDIDATE_STATUSES:
                problems.append(f"{r.checkpoint_id}: illegal status {r.status!r}")
        ids = [r.checkpoint_id for r in self._records]
        if len(ids) != len(set(ids)):
            problems.append("duplicate checkpoint ids in lineage")
        return problems

    def to_state(self) -> List[Dict[str, Any]]:
        return [r.to_dict() for r in self._records]

    @classmethod
    def from_state(cls, data: List[Dict[str, Any]]) -> "CheckpointLineage":
        return cls([LineageRecord.from_dict(d) for d in (data or [])])
