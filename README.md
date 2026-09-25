# Categorization-of-Lengths-in-the-Rhesus-Monkey-Macaca-Mulatta-with-a-Three-Category-System
MATLAB + Psychtoolbox behavioral task suite for the Merchant Lab rig: center-out length categorization and center-in hold training, run from one operator console, with joystick input and TDT Synapse/RZ2 reward and event markers over UDP.

Authors: 
Erick Castro & Paola Castillo 

Requirements: 
MATLAB R2016b and Psychtoolbox 3.0.15

Computer 1 (computer1_synapse/, Windows): UDP bridge between Synapse and
the task computer for reward delivery and event markers, plus the analog
joystick relay that streams RZ2 ADC samples to Computer 2 (port 8831,
batched one datagram per cycle with a monotonic sample index).

Computer 2 (computer2_linux/, Linux + Psychtoolbox): center-out length
categorization and center-in hold training, the operator console, the
stimulus/sequence builders, and the trajectory export. offrig_mocks/ allows
running the task logic off the rig.

The task writes trajectories, not derived kinematics: filtering, resampling
and the velocity/acceleration measures all happen offline in the EDA
notebooks (one for a single session, one across sessions), which also fit
the psychometric and chronometric functions; a third notebook builds the
RNN-ready dataset from the same outputs/ tree. New sessions start with
retries and requeue OFF, so each stimulus gets exactly one deliberate answer;
both are console checkboxes for training sessions.

Conventions: files and classes in PascalCase, local functions in camelCase.
Bar-length stimulus definitions are isolated in ConfigBarLengths.m so the
physical bar sizes can be changed in one place.

The RZ2 analog joystick link that spans both machines (setup, what to watch
during a session, known open items, and the debugging chronology behind the
current constants) is documented in centerTask_v10.00/RZ2_JOYSTICK.md.

v8.24: trial_data_*.csv gains four trailing columns, CatAtRight, CatAtUp,
CatAtLeft and CatAtDown -- the category (1 Short, 2 Mid, 3 Long) of the target
drawn at each cardinal position on that attempt, 0 where none was drawn. This
exports the per-trial target layout, so a direction bias can be separated from
a category bias offline and PrevTrialDirection becomes interpretable. Earlier
columns keep their positions; files from v8.23 and before simply lack the four.

v10.00: restores those four columns. The v8.25 rewrite of CenterOutTask.m dropped
them, so trial_data_*.csv files written by v8.25, v8.26 and v9 lack them too;
readers must treat CatAt* as optional. In v10.00 they still trail SessionMode,
and TakeoffTime_s (added in v9) stays right after TotalTime_s.

v8.24 also restores sessionMode 'alternate' segments of configurable length
(orgParams.alternateBlocks2cat/3cat, the console's "Alternate: blocks/segment"
fields). The v8.23 refactor removed the two defaults and the engine logic while
the console kept reading them, so CenterConsole failed to construct with
"Reference to non-existent field 'alternateBlocks2cat'" and the window came up
half-built. With 1/1 (the default) the schedule is the strict one-block
alternation v8.23 hardcoded.

Post-v10.00: trial_data_*.csv gains two more trailing columns, StimToRuleDelay_ms
and BarToTargetDelay_ms -- the session's configured working-memory delays
(orgParams.delayStimToRule / .barToTargetDelay, console "Delay: bar -> cue" /
"Delay: cue -> targets"), converted to ms and repeated on every row. Both were
already available once per session in params_*.mat but invisible to the
psychometric-analysis side, which only reads trial_data_*.csv; files from
before this change lack the two columns, so readers must treat them as
optional. Default 0 means that delay/state was inactive.
