import 'dart:async';

import 'package:herdr_mobile/l10n/app_localizations.dart';
import 'package:herdr_mobile/l10n/app_localizations_en.dart';
import 'package:herdr_mobile/ui/core/kit.dart' show Dwell;

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/services/herdr_api.dart';
import '../../../data/services/herdr_transport.dart';

/// Renames and closes things on one machine. Every method returns null when it
/// worked and a sentence for the person when it did not, and refreshes the
/// machine either way so the lists show what is really there.
class MachineActions {
  MachineActions(this.machine, {AppLocalizations? l10n}) : _l10n = l10n;

  final MachineConnection machine;

  /// Null only in tests and other callers outside the widget tree: English
  /// then, as the sheets' own fallback.
  final AppLocalizations? _l10n;

  AppLocalizations get words => _l10n ?? AppLocalizationsEn();

  Future<String?> renameWorkspace(String workspaceId, String label) =>
      _run(() => machine.api.renameWorkspace(workspaceId, label));

  Future<String?> renamePane(String paneId, String label) => _run(() => machine.api.renamePane(paneId, label));

  /// Already gone counts as closed: that is what the person wanted.
  Future<String?> closeWorkspace(String workspaceId) =>
      _run(() => machine.api.closeWorkspace(workspaceId), goneIsFine: true);

  Future<String?> closePane(String paneId) => _run(() => machine.api.closePane(paneId), goneIsFine: true);

  /// Removes the linked worktree that [workspace] is: its folder goes, its
  /// branch stays. Never forced: a checkout with uncommitted changes is
  /// refused by git and nothing is deleted. herdr's own refusal
  /// (`dirty_worktree_requires_force`, measured on 0.9.3) tells the reader to
  /// pass `--force`, which this app has no way to do, so it is said otherwise.
  Future<String?> removeWorktree(Workspace workspace) async {
    final error = await _run(() async {
      try {
        await machine.api.removeWorktree(workspace.id);
      } on HerdrApiException catch (e) {
        if (e.code == 'dirty_worktree_requires_force') {
          throw HerdrApiException(e.code, words.uiItHasUncommittedChangesNothingWasRemoved);
        }
        rethrow;
      }
    });
    if (error == null) return null;
    return error.trim().isEmpty ? words.uiItMayHaveUncommittedChangesNothingWasRemoved : error;
  }

  /// Adds a tab to [workspace], in the folder its first pane is in.
  Future<({String? error, String? paneId})> newTab(Workspace workspace) async {
    String? paneId;
    final error = await _run(() async {
      paneId = (await machine.api.createTab(workspaceId: workspace.id, cwd: _folderOf(workspace))).rootPaneId;
    });
    return (error: error, paneId: error == null ? paneId : null);
  }

  /// Where the workspace is working: the cwd of its first pane that has one.
  String? _folderOf(Workspace workspace) {
    final snap = machine.snapshot;
    for (final tab in snap.tabsOf(workspace.id)) {
      for (final pane in snap.panesOf(tab.id)) {
        final cwd = pane.cwd;
        if (cwd != null && cwd.startsWith('/')) return cwd;
      }
    }
    return null;
  }

  Future<String?> _run(Future<void> Function() call, {bool goneIsFine = false}) async {
    String? problem;
    try {
      await call();
    } on HerdrUnsupportedException {
      final v = machine.snapshot.version;
      problem = words.messageHerdrOnCanTDoThis(v.isEmpty ? '' : ' $v', machine.profile.label);
    } on HerdrApiException catch (e) {
      if (e.isNotFound) {
        problem = goneIsFine ? null : words.uiItWasAlreadyClosedOnTheMachine;
      } else {
        problem = e.message;
      }
    } on HerdrTransportException catch (e) {
      problem = e.message;
    } on TimeoutException {
      problem = words.uiTheMachineDidnTAnswerInTime;
    }
    try {
      await machine.refresh().timeout(Dwell.refreshTimeout);
    } on Exception {
      // Offline or slow: events bring the lists up to date when it returns.
    }
    return problem;
  }
}
