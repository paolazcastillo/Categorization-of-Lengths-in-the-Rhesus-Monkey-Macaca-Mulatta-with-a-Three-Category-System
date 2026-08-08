function cfg = ConfigSession()
% CONFIGSESSION  Central configuration for session bookkeeping.
%
%   Returns a struct with the subjects/projects allowed to start a session.
%   No database/network connection is involved; session ids are generated
%   locally (see CenterConsole.m).

% --- Subjects / projects allowed to start a session ----------------------
cfg.validProject = 'CategorizationTask';

% Two subject populations run this task, picked with the console's "Subject
% type" popup (CenterConsole.buildSessionPanel), which swaps the Subject
% control accordingly. Monkeys are named and chosen from this list; human
% participants are only ever identified by an anonymous number the operator
% types in, so nothing identifying reaches a filename or a data file.
cfg.validMonkeys = {'Romina', 'Sissu'};

% Human participant ids are built as <prefix>-<number> from the number typed
% into the console's "Participant #" box, PX-1, PX-7, PX-23. Typed rather
% than picked from a generated list because recruitment does not run in
% order: a participant who cancels leaves a gap, a pilot session may need an
% id far outside the planned range, and a fixed list would either run out
% mid-study or have to be edited here before every session. The console
% still rejects anything that is not a positive whole number, so the id
% cannot pick up a typo or a decimal.
cfg.humanIdPrefix = 'PX';

% What selecting a human participant automatically switches OFF, on top of
% the ordinary defaults in ConfigOrgParams.m (which stay in force for
% monkeys). Applied by CenterConsole.subjectTypeSelect_Callback; both are
% still checkboxes in the console, so an operator can override either one
% for a particular session; these only decide what is checked the moment
% the subject type changes.
%
%   humanUseRetries : the correction procedure (a failed stimulus is shown
%       again, reshuffled, up to maxStimAttempts times). It exists to TRAIN
%       an animal that cannot be instructed. A human participant is
%       instructed once beforehand and then gives one deliberate answer per
%       stimulus, so repeating what they just got wrong teaches them the
%       length-colour mapping mid-session; it contaminates the very
%       measurement the session is for.
%   humanUseRequeue : the clean, un-reshuffled repeat of a (bar length,
%       position) combination whose outcome was ambiguous (see
%       CenterOutTask.m's EP.REWARD/EP.ERROR_FB). With no retries there is
%       nothing to disambiguate (every trial IS its combination's clean
%       first attempt) so requeueing would only stretch a session that
%       has to fit in one sitting with a participant who is not coming back
%       tomorrow.
% Note there is no separate setting here for what the stop quota counts:
% that follows humanUseRetries. Switching retries off also switches the
% quota from correct trials to presentations (CenterConsole's
% retriesToggle_Callback), which is what stops a participant who finds the
% task hard from sitting there longest; every combination is shown the
% same number of times, an error costs that slot, and performance is the
% percentage correct over a fixed set. See ConfigOrgParams.quotaByPresentations.
% That rule is Center-Out's: a Center-In session always runs to its target
% number of rewarded holds, human or monkey, since it is a training task with
% no design grid to keep balanced (see CenterInTask.m).
cfg.humanUseRetries = false;
cfg.humanUseRequeue = false;
end
