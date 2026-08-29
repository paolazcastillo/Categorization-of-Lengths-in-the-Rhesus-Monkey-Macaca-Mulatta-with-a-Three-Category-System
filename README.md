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
notebook, which also fits the psychometric and chronometric functions. New
sessions start with retries and requeue OFF, so each stimulus gets exactly
one deliberate answer; both are console checkboxes for training sessions.

Conventions: files and classes in PascalCase, local functions in camelCase.
Bar-length stimulus definitions are isolated in ConfigBarLengths.m so the
physical bar sizes can be changed in one place.

The RZ2 analog joystick link that spans both machines (setup, what to watch
during a session, known open items, and the debugging chronology behind the
current constants) is documented in centerTask_v8.20/RZ2_JOYSTICK.md.
