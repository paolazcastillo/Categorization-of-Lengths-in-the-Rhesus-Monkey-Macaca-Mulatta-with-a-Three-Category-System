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
stimulus/sequence builders, and the trajectory and kinematics pipeline.
offrig_mocks/ allows running the task logic off the rig.

Conventions: files and classes in PascalCase, local functions in camelCase.
Bar-length stimulus definitions are isolated in ConfigBarLengths.m so the
physical bar sizes can be changed in one place.
