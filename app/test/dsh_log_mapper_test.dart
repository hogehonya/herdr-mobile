import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/observed/dsh_log_mapper.dart';

// The mirror the dsh-herdr plugin writes, as captured on a real dsh 0.2.0-rc.2
// (see test/fixtures/dsh_logs/): the header, the person's messages and the
// injected ones the plugin already dropped, each step's reasoning, text and
// tool calls, their results, the plan, the title and the turn's end. The
// plugin's own tests cover what it leaves out.

const _dir = 'test/fixtures/dsh_logs';

List<String> _lines(String name) {
  final lines = File('$_dir/$name.jsonl').readAsLinesSync();
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

AgentSessionState _feed(DshLogMapper mapper, Iterable<String> lines, [AgentSessionState? from]) {
  var s = from ?? const AgentSessionState('s');
  for (final line in lines) {
    for (final u in mapper.map(line)) {
      s = s.apply(u);
    }
  }
  return s;
}

(AgentSessionState, DshLogMapper) _run(String name) {
  final mapper = DshLogMapper();
  return (_feed(mapper, _lines(name)), mapper);
}

List<TranscriptMessage> _messages(AgentSessionState s, [MessageRole? role]) => [
  for (final i in s.items)
    if (i is TranscriptMessage && (role == null || i.role == role)) i,
];

List<String> _texts(AgentSessionState s, MessageRole role) => [for (final m in _messages(s, role)) m.text];

List<ToolCall> _tools(AgentSessionState s) => s.toolCalls.toList();

String _text(ToolCall c) => [
  for (final x in c.content)
    if (x is ToolContentBlock && x.block is TextBlock) (x.block as TextBlock).text,
].join('\n');

void main() {
  group('a turn', () {
    test('shows the person, the answer and the title dsh gave it', () {
      final (s, mapper) = _run('basic_turn');

      expect(_texts(s, MessageRole.user), ['say ok']);
      expect(_texts(s, MessageRole.agent), ['ok']);
      expect(mapper.turnEnded, isTrue);
      expect(mapper.openToolCalls, isEmpty);
    });

    test('a mirror fed twice changes nothing', () {
      final lines = _lines('tool_turn');
      final mapper = DshLogMapper();
      final once = _feed(mapper, lines);
      final twice = _feed(mapper, lines, once);

      expect(_messages(twice).length, _messages(once).length);
      expect(_tools(twice).length, _tools(once).length);
    });
  });

  group('tools', () {
    test('a call is a row with what it works on, and its result fills it', () {
      final (s, mapper) = _run('tool_turn');

      final calls = _tools(s);
      expect(calls, isNotEmpty);
      for (final c in calls) {
        expect(c.status, isNot(ToolStatus.inProgress), reason: 'every captured call finished');
        expect(mapper.openToolCalls, isNot(contains(c.toolCallId)));
      }
      final bash = calls.firstWhere((c) => c.name == 'bash');
      expect(bash.kind, ToolKind.execute);
      expect(_text(bash), isNotEmpty);
    });

    test('an edit carries the change it made', () {
      final (s, _) = _run('tool_turn');
      final edit = _tools(s).firstWhere((c) => c.name == 'edit');

      expect(edit.kind, ToolKind.edit);
      expect(edit.content.whereType<ToolDiff>(), isNotEmpty);
      expect(edit.locations.map((l) => l.path), isNotEmpty);
    });

    test('a todo write is the plan', () {
      final (s, _) = _run('tool_turn');

      expect(s.plan, isNotEmpty);
      expect(s.plan.map((e) => e.content), isNotEmpty);
    });

    test('a result whose call was not seen still shows as a finished row', () {
      final mapper = DshLogMapper();
      final s = _feed(mapper, [
        jsonEncode({
          'type': 'tool/result',
          'seq': 1,
          'time': 1,
          'data': {
            'turn': 1,
            'step': 1,
            'message': {
              'role': 'tool',
              'toolCallId': 'call_1',
              'content': [
                {'type': 'text', 'text': 'hi'},
              ],
            },
          },
        }),
      ]);

      final call = _tools(s).single;
      expect(call.toolCallId, 'call_1');
      expect(call.status, ToolStatus.completed);
      expect(_text(call), 'hi');
    });
  });

  group('how a turn ends', () {
    test('an error says what failed and leaves nothing open', () {
      final (s, mapper) = _run('error_turn');

      expect(_texts(s, MessageRole.agent).any((t) => t.startsWith('The turn failed: 429')), isTrue);
      expect(mapper.turnEnded, isTrue);
      expect(mapper.openToolCalls, isEmpty);
    });

    test('an interrupted turn cancels the calls that never answered', () {
      final mapper = DshLogMapper();
      final s = _feed(mapper, [
        jsonEncode({
          'type': 'tool/call',
          'seq': 1,
          'time': 1,
          'data': {'turn': 1, 'step': 1, 'callId': 'call_1', 'name': 'bash', 'arguments': '{"command":"sleep 9"}'},
        }),
        jsonEncode({
          'type': 'turn/end',
          'seq': 2,
          'time': 2,
          'data': {
            'turn': 1,
            'reason': {'kind': 'interrupted'},
          },
        }),
      ]);

      expect(_tools(s).single.status, ToolStatus.cancelled);
      expect(mapper.openToolCalls, isEmpty);
      expect(mapper.turnEnded, isTrue);
      expect(_texts(s, MessageRole.agent), contains('Interrupted'));
    });
  });

  group('what it refuses', () {
    test('a line that is not the mirror is nothing, not an error', () {
      final mapper = DshLogMapper();
      for (final line in ['', 'not json', '[]', '{"type":42}', '{"type":"request/header","seq":1,"data":{}}']) {
        expect(mapper.map(line), isEmpty, reason: line);
      }
    });

    test('a shape that does not fit is dropped, not thrown', () {
      final mapper = DshLogMapper();
      expect(mapper.map('{"type":"assistant/message","seq":1,"data":{"message":"nope"}}'), isEmpty);
      expect(mapper.map('{"type":"tool/call","seq":2,"data":{"arguments":"{bad json"}}'), isEmpty);
    });

    test('the injected instructions dsh records are not messages', () {
      final mapper = DshLogMapper();
      final updates = mapper.map(
        jsonEncode({
          'type': 'user/message',
          'seq': 1,
          'data': {
            'id': 'x',
            'content': [
              {'type': 'text', 'text': 'instructions'},
            ],
            'source': {'kind': 'agent-instructions'},
          },
        }),
      );

      expect(updates, isEmpty);
    });
  });
}
