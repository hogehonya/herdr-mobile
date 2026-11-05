import '../../../data/acp/background/background_work.dart';
import '../../../data/words/plural.dart';
import '../../../l10n/app_localizations.dart';
import '../../render/visible_text.dart';

/// Words for background work. Pure: every sentence the strip, the bar, the
/// status line, the toast and the sheet say comes from here, so the words for
/// each state live in one place.

/// `bash`, `terminal`, `subagent`: the kind of [task] as a word in a meta line.
String kindWord(BackgroundKind kind) => switch (kind) {
  BackgroundKind.shell => 'bash',
  BackgroundKind.terminal => 'terminal',
  BackgroundKind.eval => 'eval',
  BackgroundKind.workflow => 'workflow',
  BackgroundKind.monitor => 'monitor',
  BackgroundKind.agent => 'subagent',
  BackgroundKind.other => 'job',
};

/// `1 job`, `2 jobs`, `3 subagents`: [tasks] counted as given. Shells, evals,
/// terminals and anything else are all jobs to the person; only a set that is
/// all subagents is counted as subagents.
String nounPhrase(Iterable<BackgroundTask> tasks, [AppLocalizations? l10n]) {
  final list = tasks.toList();
  final allAgents = list.isNotEmpty && list.every((t) => t.kind == BackgroundKind.agent);
  if (allAgents) return l10n?.messageSubagentCount(list.length) ?? countOf(list.length, 'subagent');
  return l10n?.messageJobCount(list.length) ?? countOf(list.length, 'job');
}

/// The one running task's id (`bg_6`), shortened in the middle past
/// [maxLength]; `2 jobs` for several; null when nothing is known to run.
/// What `Waiting for ...` and `Waiting · ...` name.
String? waitingSubject(BackgroundWork work, {int maxLength = 24, AppLocalizations? l10n}) {
  final running = work.running;
  if (running.isEmpty) return null;
  if (running.length > 1) return nounPhrase(running, l10n);
  return shorten(visibleText(running.single.id).trim(), maxLength);
}

/// [text] cut in the middle to [max] characters (`bg_loooo…ng_6`), so the end
/// of an id, which tells ids apart, stays.
String shorten(String text, int max) {
  if (text.length <= max || max < 3) return text;
  final head = (max - 1) ~/ 2 + (max - 1) % 2;
  final tail = (max - 1) - head;
  return '${_cut(text, head)}\u2026${text.substring(text.length - tail)}';
}

String _cut(String text, int end) {
  if (end <= 0) return '';
  // Not between the two halves of a surrogate pair.
  final unit = text.codeUnitAt(end - 1);
  return text.substring(0, unit >= 0xD800 && unit <= 0xDBFF ? end - 1 : end);
}

/// `Waiting for bg_6`, `Waiting for 2 jobs`, `Waiting for jobs`.
String waitingSentence(BackgroundWork work, [AppLocalizations? l10n]) {
  final subject = waitingSubject(work, l10n: l10n);
  if (subject == null) return l10n?.messageWaitingForJobs ?? 'Waiting for jobs';
  return l10n?.messageWaitingFor(subject) ?? 'Waiting for $subject';
}

/// `omp continues by itself when it finishes`: the consequence line of the
/// strip. Null when finishing does not start a turn (Codex).
String? wakeLine(BackgroundWork work, [AppLocalizations? l10n]) {
  if (!work.wakes) return null;
  final who = work.wakeLabel ?? (l10n?.uiTheAgent ?? 'The agent');
  return work.runningCount > 1
      ? (l10n?.messageContinuesByItselfWhenOneFinishes(who) ?? '$who continues by itself when one finishes')
      : (l10n?.messageContinuesByItselfWhenItFinishes(who) ?? '$who continues by itself when it finishes');
}

/// The consequence sentence of the sheet, said once: `omp continues by itself
/// when a job finishes.` Null for an agent that does not.
String? wakeSentence(BackgroundWork work, [AppLocalizations? l10n]) {
  if (!work.wakes) return null;
  final who = work.wakeLabel ?? (l10n?.uiTheAgent ?? 'The agent');
  return l10n?.messageContinuesByItselfWhenAJobFinishes(who) ?? '$who continues by itself when a job finishes.';
}

/// What the strip says: one or two lines, or null when it takes no room.
class StripText {
  const StripText(this.primary, [this.secondary]);

  final String primary;

  /// The consequence, in the waiting state only.
  final String? secondary;

  @override
  bool operator ==(Object other) => other is StripText && other.primary == primary && other.secondary == secondary;

  @override
  int get hashCode => Object.hash(primary, secondary);
}

/// The strip's words for [work] ([waiting]: the turn is over and the agent
/// waits on it; [turnRunning]: the model is running now):
///
/// | turn | tasks | words |
/// | --- | --- | --- |
/// | runs | n | `n running in background` |
/// | over, waits, wakes | n | the same, then the consequence |
/// | over, idle | n | `1 job running` |
/// | any | none known | `Background work · details unavailable` |
StripText? stripText(
  BackgroundWork work, {
  required bool waiting,
  required bool turnRunning,
  AppLocalizations? l10n,
}) {
  if (!work.hasRunning && !waiting) return null;
  final n = work.runningCount;
  if (n == 0) {
    return StripText(l10n?.messageBackgroundWorkDetailsUnavailable ?? 'Background work · details unavailable');
  }
  if (waiting || turnRunning) {
    return StripText(
      l10n?.messageRunningInBackground('$n') ?? '$n running in background',
      waiting ? wakeLine(work, l10n) : null,
    );
  }
  return StripText(l10n?.messageCountRunning(nounPhrase(work.running, l10n)) ?? '${nounPhrase(work.running)} running');
}

/// What a screen reader says for the strip: one node.
String stripSemantics(
  BackgroundWork work, {
  required bool waiting,
  required bool turnRunning,
  AppLocalizations? l10n,
}) {
  final text = stripText(work, waiting: waiting, turnRunning: turnRunning, l10n: l10n);
  if (text == null) return l10n?.uiBackgroundWork ?? 'Background work';
  final n = work.runningCount;
  final state = n == 0
      ? (l10n?.uiDetailsUnavailable ?? 'details unavailable')
      : (l10n?.messageCountRunning('$n') ?? '$n running');
  return [
    l10n?.uiBackgroundWork ?? 'Background work',
    state,
    ?text.secondary,
    l10n?.uiDoubleTapToOpen ?? 'double tap to open',
  ].join(', ');
}

/// The small chip of the bar in the compact layout: `2 jobs`; `Jobs` when the
/// count is unknown.
String chipLabel(BackgroundWork work, [AppLocalizations? l10n]) =>
    work.runningCount == 0 ? (l10n?.uiJobs ?? 'Jobs') : nounPhrase(work.running, l10n);

/// The toast after Stop, when the turn ended and tasks remain:
/// `Turn stopped · 1 job still running`. Null when nothing remains.
String? stoppedToast(BackgroundWork work, [AppLocalizations? l10n]) {
  if (!work.hasRunning) return null;
  if (work.runningCount == 0) {
    return l10n?.messageTurnStoppedJobsStillRunning ?? 'Turn stopped \u00b7 jobs still running';
  }
  return l10n?.messageTurnStoppedStillRunning(nounPhrase(work.running, l10n)) ??
      'Turn stopped \u00b7 ${nounPhrase(work.running)} still running';
}

/// `Stop` or `Ask to stop`: the label of a task's stop chip, which says what
/// it does (a message is not a kill). The agent's name is not in it: `Ask Claude
/// Code to stop` took most of a narrow row and the sheet already names the
/// agent ([stopSemantics] too).
String stopLabel(StopRoute route, String agentLabel, [AppLocalizations? l10n]) =>
    route == StopRoute.message ? (l10n?.uiAskToStop ?? 'Ask to stop') : (l10n?.uiStop ?? 'Stop');

/// What a screen reader says for a task's stop chip.
String stopSemantics(
  BackgroundTask task,
  String agentLabel, {
  required bool primed,
  AppLocalizations? l10n,
}) {
  final label = task.stop == StopRoute.message
      ? (l10n?.messageAskToStop(agentLabel) ?? 'Ask $agentLabel to stop')
      : (l10n?.uiStop ?? 'Stop');
  final id = visibleText(task.id);
  if (primed) {
    return l10n?.messageConfirmActivateAgainToConfirm(label, id) ?? 'Confirm: $label $id, activate again to confirm';
  }
  return l10n?.messageHoldToConfirm(label, id) ?? '$label $id, hold to confirm';
}

/// `Stopped 2 · 1 has no stop control`: what Stop all reports. [stopped] tasks
/// were asked or told to stop, [skipped] have no stop route.
String stopAllSummary({
  required int stopped,
  required int skipped,
  required bool asked,
  AppLocalizations? l10n,
}) {
  final head = asked
      ? (l10n?.messageAskedToStop('$stopped') ?? 'Asked to stop $stopped')
      : (l10n?.messageStoppedCount('$stopped') ?? 'Stopped $stopped');
  if (skipped == 0) return head;
  final noControl =
      l10n?.messageHasNoStopControl(skipped) ?? '$skipped ${skipped == 1 ? 'has' : 'have'} no stop control';
  return '$head \u00b7 $noControl';
}

/// How many finished tasks the sheet lists before `Show more`.
const finishedShown = 5;

/// Finished tasks as the sheet lists them: failed first, then newest first
/// (by the end, else the start, else the order they appeared in).
List<BackgroundTask> finishedOrder(List<BackgroundTask> finished) {
  final indexed = [for (var i = 0; i < finished.length; i++) (i, finished[i])];
  int when(BackgroundTask t) => (t.endedAt ?? t.startedAt)?.millisecondsSinceEpoch ?? 0;
  indexed.sort((a, b) {
    final failed = (b.$2.status == BackgroundStatus.failed ? 1 : 0) - (a.$2.status == BackgroundStatus.failed ? 1 : 0);
    if (failed != 0) return failed;
    final time = when(b.$2).compareTo(when(a.$2));
    return time != 0 ? time : b.$1.compareTo(a.$1);
  });
  return [for (final e in indexed) e.$2];
}
