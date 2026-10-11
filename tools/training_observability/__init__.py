"""Training observability sidecar (CPU/disk only, read-only on marathon artifacts).

Never imports tools.training_supervisor; never touches the GPU lock, models or Godot.
"""
