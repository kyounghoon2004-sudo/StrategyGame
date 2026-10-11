# Visible-conversation synthetic commander games

Sources and output remain isolated from existing code-policy packages and running jobs.
The initial evidence is the six current-mission DeepSeek/Freebuff wins; earlier SFT,
survivor/growth and RL-v8 data are read-only contrasts.

```powershell
python -m tools.sft_synth_v1.analyze
python -m tools.sft_synth_v1.snapshot
python -u -m tools.sft_synth_v1.campaign --stage pilot --windows 5
python -m tools.sft_synth_v1.validate --stage pilot
python -m tools.sft_synth_v1.report
```

The pilot tests four hypotheses on the same five new seeds in BASIC / SPEARHEAD /
fixed / 10v10 / RED. The seed range is 8940001–8940005. Only a generator with
4/5 audited wins is eligible in that cell. The exported cell has a maximum of ten
won games and 300 rows. Full calls and native Godot records are preserved even
when rows are excluded.

`policy.decide(messages, policy_name, resident_memory)` cannot read the extra
`state` field or native game record. The immutable opening and newest turn delta
provide current displayed unit facts. Intermediate folds contain the game's
BATTLE DIGEST; they are not fresh packets or conversation resets. Enemy troop
bands stay bands. No hints or generated options are inserted into the input.

`snapshot.py` copies the teacher's frozen gameplay implementation and removes
both copies of its focus-fire hint before game emission. Gameplay/mission/GX
semantics are retained. Assets and checkpoints are runtime read-only references.
The runtime has its own script cache, userdata directory, episode files, arenas,
proxy, CPU Hands log directory and output. Hands are only the unused legacy
mount's boot requirement; there is no GPU inference or training.

The owned HTTP endpoint uses the established `RL_POLICY` handshake for the
commander mount but serves deterministic code. It answers the unused legacy
opening with `{}`; that mount logs an unused initial-plan fault, while the actual
commander's independently audited `strict_fault` must be empty. Such legacy log
lines do not make a commander game invalid.

Before any launch check Windows collector processes and `netstat`. The runner
refuses occupied proxy/Hands ports. Default owned slot 2 uses arena 30–34,
proxy 8098 and CPU Hands 11462. Do not change other collectors' slots or files.
Write `artifacts/brain_pipeline_v1/sft_synth_v1/STOP` for a graceful stop; running
games finish. Emergency-stop the owned collector's entire process tree, using
the verified PID in `<stage>/collector.pid`.

Optional `--speed 20` uses Godot's built-in time-scale flag. It is admitted only
after an identical seeded normal-speed game has exactly equal resident messages,
played replies, all native actions/snapshots, mission outcome and HQ/unit totals.
That comparison is in `timing_parity.json`. Failed wiring/parser probes are
preserved in rejected directories and contribute no training rows.

The pilot is not the completed 480-cell coverage project. No SFT training,
student-model evaluation, paid teacher call, or promotion is performed. The
10–20% direct-teacher mixture remains a separate prerequisite: source teacher
prompts contain a hint, so they are not silently rewritten and admitted.

The first screened-fire profile passed 4/5 but failed independent replication
(3/5); its initial wins are revoked rather than retained on the strength of the
earlier batch. A size-10 gate never admits winners at other sizes. The second
source, `policy_v2.py`, derives `cohesive_focus` from the teacher's one-fist plan:
one shared field target is maintained until destroyed or an immediate HQ threat
changes the strategy. It is independently tested on fresh seeds in `repair/`.

Final pilot results: main games 45, wins 23. Mass-focus replication failed 1/5,
screened-fire replication failed 3/5, paired attacks won 3/5, defensive anvil
won 1/5 and cohesive focus won 2/5. No generator survived; `sft_rows.json` is
empty. The 23 winning trajectories remain in the rejected-winner candidate
file with their exact messages/completions. They are not admitted SFT data.
