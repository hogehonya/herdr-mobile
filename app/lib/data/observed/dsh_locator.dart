import '../models/herdr_models.dart';
import '../models/remote_file.dart';
import '../repositories/fleet_agent.dart';
import '../repositories/machine_connection.dart';
import '../services/remote_files.dart';
import 'session_log_locator.dart';

/// Finds the chat log of a dsh pane.
///
/// herdr only accepts a session reference from its own integrations, and of
/// those only `pi` and `omp` may name a path, so a dsh pane never has one. The
/// dsh-herdr plugin writes the pane's session as plain JSONL at a path the app
/// can derive from what it already knows:
///
///     ~/.dsh/herdr/<herdr session>/<pane id with ':' as '-'>.jsonl
///
/// (`~/.dsh/herdr/default/w5-pJ.jsonl` for the default session). The plugin
/// writes the header line as soon as the pane's agent starts, so a missing file
/// means "not yet", not "not installed"; the reason says which.
class DshLocator implements SessionLogLocator {
  const DshLocator();

  /// Shown verbatim: the plugin writes nothing at all on this machine.
  static const unlinkedWhy =
      'dsh-herdr is not writing on this machine, so the app cannot read this session. Add the dsh-herdr '
      'plugin to the dsh profile, then start a new session.';

  /// Shown verbatim: the plugin writes here, but not for this pane yet.
  static const notYetWhy =
      'dsh has not written this session yet. A session that was already running when the plugin was '
      'installed writes nothing until it restarts.';

  /// The plugin's folder under the home directory.
  static const folder = '.dsh/herdr';

  @override
  bool mayLocate(Pane pane) => FleetAgent.kindOf(pane) == 'dsh';

  @override
  Future<LogLocation> locate(MachineConnection machine, Pane pane) =>
      locateWith(machine.files, pane, session: machine.profile.session);

  /// [locate] with the parts it reads: the host's files, the pane and the herdr
  /// session the machine is set to.
  Future<LogLocation> locateWith(RemoteFiles files, Pane pane, {required String session}) async {
    final home = await files.home();
    final path = logPath(session: session, paneId: pane.id, home: home);
    if (path == null) return const Unlinked('This pane cannot have a chat log.');
    try {
      if ((await files.stat(path)).kind == RemoteEntryKind.file) return Located(path);
      return const NotYet(notYetWhy);
    } on RemoteFileException catch (e) {
      if (!_absent(e)) rethrow;
    }
    // No file. A machine the plugin has never written on is not going to have
    // one after this pane: say what to install, not "wait".
    try {
      final stat = await files.stat('$home/$folder');
      return stat.kind == RemoteEntryKind.dir ? const NotYet(notYetWhy) : const Unlinked(unlinkedWhy);
    } on RemoteFileException catch (e) {
      if (!_absent(e)) rethrow;
      return const Unlinked(unlinkedWhy);
    }
  }

  /// The mirror path of [paneId] on a machine in [session], or null when either
  /// part cannot be one path segment.
  ///
  /// The plugin sanitizes both the same way (dsh-herdr's `lib/chatlog.js`):
  /// every character outside `[A-Za-z0-9._-]` becomes `-`, and a leading `.` or
  /// `-` is dropped.
  static String? logPath({required String session, required String paneId, required String home}) {
    final sessionSegment = segment(session.isEmpty ? 'default' : session) ?? 'default';
    final paneSegment = segment(paneId.replaceAll(':', '-'));
    if (paneSegment == null) return null;
    final root = home.endsWith('/') ? home.substring(0, home.length - 1) : home;
    return '$root/$folder/$sessionSegment/$paneSegment.jsonl';
  }

  /// [value] as one safe path segment, or null when nothing is left of it.
  static String? segment(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-').replaceFirst(RegExp(r'^[.-]+'), '');
    if (safe.isEmpty) return null;
    return safe.length > 120 ? safe.substring(0, 120) : safe;
  }

  static bool _absent(RemoteFileException e) => switch (e.kind) {
    RemoteFileErrorKind.notFound || RemoteFileErrorKind.permission => true,
    _ => false,
  };
}
