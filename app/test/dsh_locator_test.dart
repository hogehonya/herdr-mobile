import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/observed/dsh_locator.dart';
import 'package:herdr_mobile/data/observed/session_log_locator.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

// dsh-herdr writes ~/.dsh/herdr/<herdr session>/<pane>.jsonl and herdr cannot
// carry a dsh session reference (only its own integrations may), so the app
// derives that path from the pane it already knows.

Pane _pane({String id = 'w5:pJ', String agent = 'dsh'}) => Pane(
  id: id,
  workspaceId: 'w5',
  tabId: 'w5:t1',
  focused: false,
  cwd: '/home/dev/repos/app',
  title: '',
  agent: agent,
  status: AgentStatus.idle,
);

RemoteFiles _files(FakeFs fs) => RemoteFiles(FakeTransport()..fs = fs);

void main() {
  group('the path', () {
    test('is the mirror of the pane, under the herdr session the machine uses', () {
      expect(
        DshLocator.logPath(session: 'default', paneId: 'w5:pJ', home: '/home/dev'),
        '/home/dev/.dsh/herdr/default/w5-pJ.jsonl',
      );
      expect(
        DshLocator.logPath(session: 'work', paneId: 'wE:p1', home: '/home/dev/'),
        '/home/dev/.dsh/herdr/work/wE-p1.jsonl',
      );
    });

    test('sanitizes like the plugin: one segment, no leading dot, nothing unsafe', () {
      expect(
        DshLocator.logPath(session: 'my session', paneId: 'w1:p2', home: '/h'),
        '/h/.dsh/herdr/my-session/w1-p2.jsonl',
      );
      // A session name with nothing safe left falls back to the default folder, like the plugin.
      expect(DshLocator.logPath(session: '../..', paneId: 'w1:p2', home: '/h'), '/h/.dsh/herdr/default/w1-p2.jsonl');
      expect(DshLocator.logPath(session: '', paneId: 'w1:p2', home: '/h'), '/h/.dsh/herdr/default/w1-p2.jsonl');
      expect(DshLocator.logPath(session: 'default', paneId: '..', home: '/h'), isNull);
      expect(DshLocator.logPath(session: 'default', paneId: '', home: '/h'), isNull);
    });

    test('is a path the follower accepts', () {
      final path = DshLocator.logPath(session: 'default', paneId: 'w5:pJ', home: '/home/dev')!;
      expect(isReadableLogPath(path), isTrue);
    });
  });

  group('locating', () {
    const locator = DshLocator();

    test('a pane of another agent is not looked at', () {
      expect(locator.mayLocate(_pane(agent: 'claude')), isFalse);
      expect(locator.mayLocate(_pane()), isTrue);
    });

    test('the file is the chat, and its absence is "not yet"', () async {
      final fs = FakeFs()..addFile('/home/dev/.dsh/herdr/default/w5-pJ.jsonl', '{}\n');
      final found = await locator.locateWith(_files(fs), _pane(), session: 'default');
      expect((found as Located).path, '/home/dev/.dsh/herdr/default/w5-pJ.jsonl');

      // The folder exists (another pane wrote) but not this pane's file.
      final fs2 = FakeFs()..addFile('/home/dev/.dsh/herdr/default/w9:p9.jsonl', '{}\n');
      expect(await locator.locateWith(_files(fs2), _pane(), session: 'default'), isA<NotYet>());
    });

    test('a named session reads its own folder', () async {
      final fs = FakeFs()..addFile('/home/dev/.dsh/herdr/work/w5-pJ.jsonl', '{}\n');
      expect(
        (await locator.locateWith(_files(fs), _pane(), session: 'work') as Located).path,
        '/home/dev/.dsh/herdr/work/w5-pJ.jsonl',
      );
      expect(await locator.locateWith(_files(fs), _pane(), session: 'default'), isA<NotYet>());
    });

    test('a folder where a file should be is not a chat', () async {
      final fs = FakeFs()..addDir('/home/dev/.dsh/herdr/default/w5-pJ.jsonl');
      expect(await locator.locateWith(_files(fs), _pane(), session: 'default'), isA<NotYet>());
    });

    test('a machine the plugin never wrote on says what to install', () async {
      final found = await locator.locateWith(_files(FakeFs()), _pane(), session: 'default');
      expect(found, isA<Unlinked>());
      expect((found as Unlinked).why, contains('dsh-herdr'));
    });

    test('a link that dropped is not an answer', () async {
      final fs = FakeFs()..fail = RemoteFileException(RemoteFileErrorKind.network, 'gone');
      expect(locator.locateWith(_files(fs), _pane(), session: 'default'), throwsA(isA<RemoteFileException>()));
    });

    test('a pane that cannot name a segment has no chat', () async {
      expect(await locator.locateWith(_files(FakeFs()), _pane(id: ''), session: 'default'), isA<Unlinked>());
    });
  });
}
