"""D0 target-quality and closed-loop distribution diagnostics.

Read-only investigation into why corrected-target retraining succeeds
offline but not closed-loop: continuation/target bias vs covariate shift.
No weight updates, no new training corpus, no Fog labels, no RL.
"""

from python_jev.diagnose.collect import DIAG_VERSION, SETS

__all__ = ["DIAG_VERSION", "SETS"]
