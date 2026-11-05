import 'package:flutter/widgets.dart';
import 'package:herdr_mobile/l10n/app_localizations.dart';
import 'package:herdr_mobile/l10n/app_localizations_en.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/session_launcher.dart';
import '../../../data/services/herdr_api.dart';
import '../../../data/words/error_words.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// Most working directories offered as one-tap suggestions.
const maxRecentFolders = 8;

final _control = RegExp(r'[\x00-\x1f\x7f]');

/// Null when [folder] is something herdr can open: an absolute path, `~`, or
/// `~/...`. No control characters: `~` paths are typed into a shell.
String? folderError(String? folder, {AppLocalizations? l10n}) {
  final words = l10n ?? AppLocalizationsEn();
  final v = folder?.trim() ?? '';
  if (v.isEmpty) return words.uiChooseAFolder;
  if (_control.hasMatch(v)) return words.uiNoLineBreaksOrControlCharacters;
  if (!v.startsWith('/') && !isHomeFolder(v)) return words.uiStartWithOr;
  return null;
}

/// Working directories already in use on the machine, for one-tap reuse:
/// distinct absolute paths, those of agents first.
List<String> recentFolders(Snapshot snapshot, {int max = maxRecentFolders}) {
  final seen = <String>{};
  final out = <String>[];
  void add(Pane p) {
    final cwd = p.cwd;
    if (cwd == null || !cwd.startsWith('/') || cwd == '/' || _control.hasMatch(cwd)) return;
    if (out.length < max && seen.add(cwd)) out.add(cwd);
  }

  for (final p in snapshot.panes) {
    if (p.isAgent) add(p);
  }
  for (final p in snapshot.panes) {
    if (!p.isAgent) add(p);
  }
  return out;
}

class NewSessionError {
  const NewSessionError(this.title, this.message);

  final String title;
  final String message;
}

/// Where a launch went wrong, in words for the person.
NewSessionError describeLaunchFailure(
  Object error,
  MachineConnection machine,
  String folder, {
  AppLocalizations? l10n,
}) {
  final words = l10n ?? AppLocalizationsEn();
  final name = machine.profile.label;
  final version = machine.snapshot.version;
  return switch (error) {
    HerdrUnsupportedException() => NewSessionError(
      words.uiNotSupportedByThisHerdr,
      words.messageHerdrOnCanTCreateWorkspaces(version.isEmpty ? '' : ' $version', name),
    ),
    FolderNotFoundException() => NewSessionError(words.uiFolderNotFound, words.messageDoesnTExistOn(folder, name)),
    _ => NewSessionError(words.uiCouldnTStartTheSession, describeError(error, machine: name)),
  };
}

/// What a start that stays on the board says: what started, where, with a way
/// to open it. It replaces a toast still showing from the start before, so
/// launching several in a row never queues them.
void showStartedToast(
  Toaster toaster, {
  required String message,
  required String openLabel,
  required VoidCallback onOpen,
}) => toaster.show(message, kind: ToastKind.success, action: ToastAction(openLabel, onOpen));
