# RZ2 analog joystick link (Computer 1 <-> Computer 2)

Operational notes for the `inputSource = 'rz2adc'` path: the analog joystick
sampled on Computer 1 through TDT Synapse and relayed to Computer 2 over UDP.
The per-decision rationale lives in the source comments; this file is the
cross-machine picture, the install steps, and the debugging chronology that
does not belong in any single file.

Everything below was folded into the main task tree on 2026-08-26. The
standalone `Computadora1/` and `Computadora2/` hand-off folders that carried
these fixes are gone -- the files they contained now live in `centerTask/`
and `centerTask/computer1_synapse/`.

## Where the files live

| Side | Folder | Entry point |
|---|---|---|
| Computer 1 (Windows, Synapse) | `centerTask/computer1_synapse/` | `categTaskCommunication.m` (the GUI's **Run** button) |
| Computer 2 (Linux, Psychtoolbox) | `centerTask/` | `CenterOutTask.m` / `CenterInTask.m` |

Diagnostics, added with these fixes:

- `centerTask/DiagnoseRZ2Cursor.m` -- Computer 2. Cursor-only harness: no
  targets, no trials, no reward. Calls the exact same
  `SetupRZ2Joystick` / `FlushRZ2Joystick` / `ReadRZ2Joystick` /
  `CleanupRZ2Joystick` chain the real task uses, so what it shows is what the
  task sees minus every other confound. Live vx/vy plot in a separate MATLAB
  figure, and a full per-frame CSV/MAT export on exit.
- `centerTask/computer1_synapse/VerifyWidxWidy.m` -- Computer 1. Four checks
  (EXISTS / LIVE / RATE / CROSS-CHECK) on the SerStore write-index tag before
  trusting `WRITE_IDX_TAG_X/Y` in `InitJoystickRelay.m`.
- `centerTask/computer1_synapse/ProbeJoystickBuffers.m` -- Computer 1. Lists
  every parameter each gizmo exposes and handshake-tests the scalar ones to
  find a live write index.

## Installing / after pulling changes

Both machines: **close and reopen the MATLAB session** after copying files.
MATLAB does not reload functions it already has cached, so without a restart
you keep running the old code even though the file on disk is current.

On Computer 1 this means the MATLAB session running the `categTaskCommunication`
GUI. On Computer 2, the one running the task.

## Running order

1. Computer 1: Synapse in **Preview** or **Record**.
2. Computer 1: `categTaskCommunication` -> **Run**.
3. Computer 2: start the task (or `DiagnoseRZ2Cursor()`).

The relay on Computer 1 only steps after it receives `rz2RelayEnable=1;` over
UDP, which Computer 2 sends at startup via `SetRZ2RelayEnable.m`. If Computer 1
is not already running at step 3, the enable message goes out to nobody and you
get 0 datagrams -- indistinguishable from a real fault. `DiagnoseRZ2Cursor.m`
sends the same enable itself, and clears it on exit.

Make sure nothing else holds port **8831** (joystick stream) or **8830** (relay
enable) while a session runs.

## What to watch

Computer 1's console, every ~5 s:

- `write-index: backlog ~N samples (~X ms behind head)` -- should be small and
  **steady**, not growing.
- `nHeadBehind: N` -- the write head read behind the read cursor. A few are
  normal jitter; a steady trickle means the read pacing is outrunning the
  writer.
- `nBackwardRecal: N` -- only meaningful on the legacy fallback path.
- `sendErrorCount: N` -- samples read from SerStore that never left the
  machine. Should stay 0. If it ever prints, `OutputBufferSize` in
  `InitJoystickRelay.m` is the number to raise.
- `[REWARD CLAMP]` -- a reward duration outside 1-1000 ms arrived over UDP.
  Should never appear.
- `[loop diag] loopHz=...` -- the whole Computer-1 loop's cycle rate. This caps
  how often the relay can read and send, no matter how fast the relay step
  itself is.

Computer 2, via `DiagnoseRZ2Cursor.m`:

- **preBacklog** / receive buffer occupancy growing without bound = a queue
  that is not draining.
- **LAG estimate** -- directly answers "how old is what I am looking at". It
  should stay small and should **not** drift upward over a session.

## Known open items

**`downsample` is a Synapse runtime parameter.** It is 26 on this rig, which is
what makes the APICh1X/APICh2Y buffers write at ~952 Hz. It can reset to 1 when
Synapse restarts, which sends the write rate to ~26,000 Hz and makes
`rz2SampleRateHz = 952` wrong again. Worth confirming at the start of a session,
or pinning it in the circuit.

**`WRITE_FS` on Computer 1 is still 1017.** `InitJoystickRelay.m` sets
`state.WRITE_FS = 1017`, from before the rate was measured directly. Computer 2's
`rz2SampleRateHz` was corrected to 952; this was deliberately left alone because
in write-index mode `WRITE_FS` no longer drives the read at all. It does still
scale the `~X ms behind head` figure in the 5-second log (reads ~6% low) and it
would matter if the relay ever fell back to the legacy diff-peak path. Same for
`ASSUMED_FS = 1017` in `VerifyWidxWidy.m`.

**The write-index fallback does not actually work as its comment claims.**
`InitJoystickRelay.m` documents that the reader "degrades to legacy pacing
automatically" when a tag cannot be read. That is false on this rig:
SynapseAPI's `getParameterValue` does not throw for a nonexistent tag, so
`idxOk` never goes false, `widxFellBack` never fires, and the relay silently
anchors to a bogus value and reads 0 new samples forever, with no warning. If
`WRITE_IDX_TAG_X/Y` is ever repointed, add an explicit existence check (via
`getParameterInfo`) in `readWriteIndex()` inside `StepJoystickRelay.m` rather
than relying on a caught exception.

## Debugging chronology

Kept because each entry records what was *ruled out*, with evidence, not just
what was changed.

### 2026-08-21 -- making the silent paths visible

`CleanupRZ2Joystick.m` had three places that failed silently: an early return
when `rz2` was empty, a non-struct `ud` branch that printed nothing, and a bare
`catch`. A session that printed no RZ2 summary at all, despite `inputSource`
being confirmed `rz2adc`, was indistinguishable from the function never being
reached. All three now say which one happened. `nDatagrams` (raw datagrams, as
opposed to samples) was added to the UserData counters at the same time.

### 2026-08-22 -- buffers, and what was ruled out

A session logged `nSkipped` jumping ~97,100 samples in a single frame, exactly
coincident with a matching jump in computed LAG: real data loss, not a
computation bug.

- Receive side: `InputBufferSize` 262144 -> 4 MB. At ~29 bytes/sample the old
  buffer held ~9,000 samples -- an order of magnitude under that burst.
- Drain rate: `maxSamplesPerDrain` 256 -> 2048. With the burst now buffered
  rather than lost, draining at 256/frame would still take ~6.3 s to clear
  (~0.8 s at 2048).
- Send side: `OutputBufferSize` 65536 -> 1 MB -> 4 MB, matched to the receive
  side. 65536 held ~2,260 samples queued -- less than `MAX_READ_PER_CYCLE`.
- `sendErrorWarned` (bool, warn once per session, then silence forever) became
  `sendErrorCount` + `lastSendErrorAt`: counts every failure and re-warns every
  5 s while it is still happening.
- A reward-duration clamp on Computer 1, since `pause(rewDuration/1000)` shares
  the loop with the relay step and trusted whatever `eval()` set.
- `ProbeJoystickBuffers(syn, waitSec)`: one shared handshake wait for all
  candidates instead of one per parameter. `waitSec=60` would otherwise have
  taken hours instead of a minute.

### 2026-08-25 -- the ~95 second jump

Found by crossing both machines' logs against `DiagnoseRZ2Cursor` CSVs from two
sessions.

Ruled out with evidence: reward (`[REWARD CLAMP]` appeared 0 times), send buffer
(`sendErrorCount` 0), and data loss (at the exact frame of the jump, `nDatagrams`
and `nSamples` advanced normally, +19 and +179 -- nothing was lost, the *index*
lied).

The cause was in `StepJoystickRelay.m`'s accepted-recalibration block:

```matlab
absIdx = absIdx + mod(newIdxX - curIdxX, BUF_SIZE)
```

Correct only when the correction moves the cursor **forward**. When a
recalibration pulls it **backward** (the read cursor had over-run the write
head), the subtraction is negative and `mod()` wraps it to nearly a full lap of
the ring: a -2,912 sample correction became a +97,088 sample jump.

```
97,088 / 1017 Hz = 95.47 s        (observed: -95.53 s)
```

That is why the jump was always ~95 s and never any other value -- it is
`BUF_SIZE`, not a variable stall. And why it was sporadic: it needed a
recalibration to be *accepted* (1 of 21 that session) **and** to point backward.

Fixed with a new local `circDelta()` -- a signed version of `circDist()`, which
discards sign on purpose for its tolerance check. Forward corrections add as
before. Backward corrections hold `absIdx` (Computer 2 needs it monotonic) but
do not jump, bounding the residual error to `|delta|` (~2.9 s) instead of ~95 s,
and now warn plus increment `nBackwardRecal`. The same class of bug in the
write-index read path was fixed the same way, clamped to 0 and counted as
`nHeadBehind`.

### 2026-08-25 (b) -- the linear ~2 second drift

With the jump fixed: 0 jumps over 5 s, `nBackwardRecal: 1` (a bounded 1,207
sample retreat). But lag climbed **linearly** at 3.3 ms/s -- from -0.07 s at
t=0 to +0.33 s at t=130 s, extrapolating to ~2 s at 11 minutes.

`READ_FS = N_READ * RELAY_HZ = 6 * 169 = 1014 Hz` sits deliberately below the
writer so the reader can never lap it. That 3 samples/s deficit is harmless
*only if* periodic recalibration closes it every 10 s. On this rig it did not:
`Recal_ok = 0/11`, every one rejected by the tolerance guard (correctly -- they
proposed indices ~3,300 samples from the prediction). With the correction never
landing, the deficit accumulated all session.

Rejected fix: changing `rz2SampleRateHz` to 1014 so the arithmetic closes. The
lag is **real** -- the relay genuinely delivers fewer samples than are written,
and the cursor genuinely shows old data. Dividing by 1014 would make `lagSec`
read ~0 without changing anything on screen: hiding the problem, not fixing it.
`SetupRZ2Joystick.m` already carried a comment warning against exactly this.

Applied instead: `RELAY_HZ` 169 -> 169.4 (`READ_FS` 1014 -> 1016.4 Hz), cutting
the deficit from 3 to 0.6 samples/s -- ~5x less drift, ~0.4 s at 11 minutes.
Deliberately not 169.5 (exactly 1017): zero margin would let ordinary jitter put
the reader ahead of the writer.

A mitigation, not a fix. The drift exists because recalibration fails.

### 2026-08-25 (c) -- the write rate was never 1017 Hz

With the index finally readable through the API (it surfaces under the literal
name `'???'` -- the tag reached the API without a resolved label), the write rate
was measured directly for the first time: **952.11 Hz** over 30 s.

1017 Hz had been inferred from the Storage Rate that JoyX/JoyY and NPro2 display
in Synapse. Those are *different gizmos* with their own decimation.
APICh1X/APICh2Y run `APIStreamer1Ch.rcx` off the PZ5's ~25 kHz stream divided by
their own `downsample` parameter (26 on this rig) -- that is what sets this
buffer's write rate. Undecimated it wrote at ~26,000 Hz.

This explains everything that had been chased up to that point:

- Recalibrations rejected 11 of 11: the prediction advanced at 1017 Hz against a
  different reality, so the search window never contained the real head.
- Initial X vs Y indices differing by up to 64,000 (they should be nearly
  identical -- same circuit, same clock): diff-peak was returning noise.
- The linear lag drift, and the `nBackwardRecal` event.

Changes: `WRITE_IDX_TAG_X/Y` set to `'???'` (write-index mode on), which retires
the whole diff-peak apparatus -- no prediction, no tolerance, no periodic
recalibration, no startup calibration that can go wrong. `WRITE_FS` / `READ_FS` /
`RECAL_*` remain only for the fallback path. And on Computer 2,
`rz2SampleRateHz` 1017 -> 952, since it converts index to time: at 1017 every
trajectory timestamp was stretched by ~7%.
