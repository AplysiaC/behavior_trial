# Sequence Transfer Task (STT) Bpod protocol

## Unified shaping-to-training protocol

Use [`stt_all.m`](./stt_all.m) for the shaping-to-training progression. Start it with `start_protocol('stt_all',subject_id,...)`; the MATLAB prompt lets you choose shaping or train. If you choose shaping, select the starting stage (1, 2, 3, or 4). With the default `advance_mode = 'performance'`, stage changes are decided **once at session end** and take effect in the **next session**: shaping 1 → 2 → 3 → 4 → training A. This treats one Bpod session per rat as one training day.

The daily progression criterion is **rewarded counted trials / counted trials that day ≥ 95%**. Shaping 1 requires at least **200 counted trials**; shaping 2, 3, and 4 each require at least **100 counted trials** in that day's session. The fraction uses all counted trials in that session, not a recent window or trials pooled across days. Settings `performance_min_trials_stage1`, `performance_min_trials_later`, and `performance_threshold` can change these defaults. If the minimum or the threshold is not met, the next session repeats the same stage.

In shaping 1, entry into `WaitForFirstPoke` (the state that turns on the `MidC` light) starts a counted trial. A run with no `MidC` poke times out after the default 30 s and counts as an unrewarded trial. In shaping 2–4, a counted trial begins only after the `MidC` start poke; a no-start timeout does not enter the performance denominator. `stage_trial_number` records the running denominator for each trial. The final `stage_performance` is computed at session end and saved with the session data. The first training session uses sequence A; A-to-B selection remains governed by the training settings. In `test=1` mode, Bpod does not persist the next-stage settings, so select the stage manually when starting a new test session.

### Four-poke task in `stt_all.m`

The first poke is always `MidC` at coordinate `(0,0)`. The other six task ports are `BotL=(-1,-1)`, `MidL=(-2,0)`, `TopL=(-1,1)`, `TopR=(1,1)`, `MidR=(2,0)`, and `BotR=(1,-1)`. These are task-design coordinates; verify the physical port layout on the rig. `BotC` is a separate water port and is **not** one of the four sequence pokes.

| Condition | Four sequence pokes | Three displacement vectors |
| --- | --- | --- |
| A | `MidC → BotL → MidL → TopR` | `(-1,-1), (-1,1), (3,1)` |
| B1 similar | `MidC → BotL → TopL → MidR` | `(-1,-1), (0,2), (3,-1)` |
| B2 y-axis mirror | `MidC → BotR → MidR → TopL` | `(1,-1), (1,1), (-3,1)` |
| B3 different | `MidC → TopL → BotR → MidR` | `(-1,1), (2,-2), (1,1)` |

The A and B1 inputs are **three displacement vectors** accumulated from `(0,0)`; B2 reflects the resulting A port positions across the y-axis. For B3, the user supplied **three absolute target-port coordinates**, not displacement vectors. All three B3 peripheral ports differ from A's. For `stt_all.m`, shaping stage 1 teaches `MidC`; stage 2 adds `BotL`; stage 3 adds `MidL`; stage 4 adds `TopR`. After the final sequence poke, the rat must visit `BotC` to trigger water. In training, all four sequence LEDs illuminate initially and turn off in order after each correct poke. A wrong port restarts the sequence in the same state-machine run; errors at steps 2–4 are recorded. The session prompt offers A only, B only, or A-to-B switching, with B1/B2/B3 chosen separately.

The rest of this README describes the **older standalone** [`stt.m`](./stt.m) training protocol. Its three-poke sequences are unchanged; start `stt_all` for the four-poke design above. Its trial-counting rule does not apply to shaping 1 in `stt_all.m`.

[`stt.m`](./stt.m) implements a three-poke sequence task for rats. Every sequence begins at the center port (`MidC`). After the three sequence pokes, the rat must poke the separate reward port (`BotC`) to receive water. The port assignments and timings below are provisional and must be checked against the physical rig.

## Sequences

| Condition | Required sequence | Reward path |
| --- | --- | --- |
| A | `MidC → TopR → BotR` | `MidC → TopR → BotR → BotC` |
| B1 | `MidC → MidR → MidL` | `MidC → MidR → MidL → BotC` |
| B2 | `MidC → TopR → MidR` | `MidC → TopR → MidR → BotC` |
| B3 | `MidC → TopL → BotL` | `MidC → TopL → BotL → BotC` |

B1 differs from A at both the second and third ports. B2 shares A's first two ports and changes the third. B3 is A's left–right mirror. The protocol validates these relationships when settings are loaded.

## Trial flow

For condition A:

```text
WaitForFirstPoke: MidC, TopR, and BotR LEDs on
  MidC in → StartInterval: MidC LED off; TopR and BotR remain on
  0.1–0.2 s → WaitForSecondPoke
  TopR in → SecondPoke: TopR LED off; BotR remains on
  0.1 s → WaitForThirdPoke
  BotR in → ThirdPoke: sequence LEDs off
  0.01 s → WaitForRewardPort: BotC LED on
  BotC in → RewardDelivery: valve 1 opens once
  ITI (0.5–1.5 s) → next state-machine run
```

The three sequence LEDs initially illuminate together, but only the expected port advances the state machine. A wrong poke enters `Violation` for 0.2 s, then restarts the sequence at `WaitForFirstPoke` within the same state-machine run. By default, leaving `MidC` early during `StartInterval` retries the first step; leaving the second port early during `SecondPoke` retries the second step. These early exits are configurable. Waiting too long for a required poke leads to `TrialTimeOut → ITI → exit` without reward. No error sound is currently configured.

## Behavioral trial and error definitions

A **behavioral trial starts only after the first `MidC` poke** in a state-machine run. Any subsequent interruption, restart, or timeout belongs to that one behavioral trial. If the first `MidC` poke never occurs, the run is saved as `no_start` and does not increment the A/B behavioral trial counters. Bpod's `n_done_trials` counts state-machine runs and can therefore exceed `counted_trials`.

`restart_count` counts all visits to `Violation`, including wrong pokes before trial initiation and at the reward port. `error_count` has a narrower definition: it counts a wrong-port poke during step 2 or step 3, including the brief interval immediately before that step. Early port withdrawal, a wrong poke while awaiting the first port, a wrong poke at the reward port, and timeouts do not increment `error_count`. `viol` indicates whether `error_count > 0`. `clean_hit` means a rewarded run with no restarts. `a_consistent_error` marks a step-2 or step-3 error in B that matches A's port for that step.

## Session modes and switching

Each start of the protocol prompts in the MATLAB Command Window:

```text
1 = A only
2 = B only (then choose B1, B2, or B3)
3 = A then B after N behavioral A trials (choose B and N)
```

For mode 3, if `N = 5`, the first five **initiated behavioral trials** use A and the sixth uses the selected B condition. An A trial counts toward the switch even if it is interrupted or times out after `MidC`. Runs without `MidC` do not count. Interactive A/B counters reset at the start of each session; previous-day A trials are not added automatically. For noninteractive use, set `prompt_session = false`, choose `run_mode = 'A_only'`, `'B_only'`, or `'switch'`, and set `a_trial_count` for switch mode through the loaded settings.

## Main default settings

| Setting | Default | Purpose |
| --- | --- | --- |
| `T_first` | 30 s | Wait for `MidC` |
| `T_start_min/max` | 0.1–0.2 s | Jitter after `MidC` |
| `T_second`, `T_third` | 10 s each | Wait for sequence steps 2 and 3 |
| `T_second_hold` | 0.1 s | Hold after step 2 |
| `T_release` | 0.01 s | Transition after step 3 |
| `T_reward` | 10 s | Wait for `BotC` |
| `T_error` | 0.2 s | Violation state |
| `ITI_min/max` | 0.5–1.5 s | Intertrial interval |
| `reward_ul` | 5 µL | Target water volume |

The valve-open duration comes from `GetValveTimes(reward_ul,1)` using the active Bpod calibration. The code assumes valve 1 delivers water at `BotC`; verify the valve and port mapping before using the physical rig.

## How this file communicates with Bpod

`start_protocol('stt',...)` loads the `stt` class. The `sys.dispatchObj` runner calls `useSettings` once, then repeats this cycle:

1. `prepareNextTrial` selects A or B, generates timing jitter, and resets trial fields.
2. `generateSM` builds a Bpod state matrix with input transitions (`MidCIn`, `OtherIn`, `BotCIn`, timer expiry) and outputs (port LEDs and `ValveState`).
3. The runner calls `SendStateMatrix` and `RunStateMachine`. Bpod controls the LEDs and valve and returns timestamped events and visited states.
4. The runner parses those events and calls `trialCompleted`, which computes the outcome, behavioral counts, error counts, poke events, latencies, and any A-to-B switch.
5. The runner invokes `saveTrial`; saving depends on the session mode.

The MATLAB Command Window prints session mode and target sequence for each state-machine run. With a properly calibrated physical rig, visible outputs are the port LEDs and one water delivery after a correct sequence plus `BotC` poke. The saved trial fields include `trial_started`, `trial_number`, `counted_trials`, `trial_phase`, `target_sequence`, `outcome`, `hit`, `reward`, `error_count`, `error_poke_ports/steps`, `restart_count`, `wrong_poke_ports/steps`, `poke_times/types`, and `step_latency`.

**Test mode does not save trial or session data:** `start_protocol(...,'test',1)` uses the no-op `sys.SaveLoad` class. A non-test session requires the repository's database-backed Bpod setup; its `SaveLoadDB` implementation handles persistence. The file itself does not write a CSV or MAT file. Check the laboratory's database and export procedure before collecting real data.

## Computer simulation

Start the eight-port emulator in a terminal, then run in MATLAB:

```matlab
cd('C:\Users\Jacques\Desktop\desk\Phd\behavior_trial\bpod-auto')
start_bpod('port','zmq://127.0.0.1:11258','use_db',0)
start_protocol('stt','JLI-T-0001','test',1,'video_trigger',0)
```

In the emulator, verify the initial three LEDs, sequential LED extinction, a same-run restart after a wrong poke, reward only after `BotC`, and timeout behavior. Syntax and event-count checks do not replace a full emulator run or physical-rig validation.
