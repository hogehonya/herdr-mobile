import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/agent_coverage.dart';

// The guard against an agent update that adds a kind of tool call or item: the
// schemas the installed agents ship (tool/sync-agent-schemas.sh) must be covered
// by app/lib/data/observed/agent_coverage.dart, and so must everything the
// captured logs contain. When this fails after a sync, a kind is new: add it to
// the table (map it, show it generically, or say why it is ignored) and capture
// a real log of it. Do not delete the failing line to make it pass.

const _schemas = 'test/fixtures/schemas';

/// The `tool <Name>` / `item <name>` lines of a synced schema file.
Set<String> _kinds(String file, String key) => {
  for (final l in File('$_schemas/$file').readAsLinesSync())
    if (l.startsWith('$key ')) l.substring(key.length + 1).trim(),
};

/// The SDK names the file-tool types by their job.
const _claudeAliases = {'FileEdit': 'Edit', 'FileRead': 'Read', 'FileWrite': 'Write'};

String _pascal(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

void main() {
  group('Claude Code', () {
    test('every tool of the installed SDK schema is in the coverage table', () {
      final sdk = {for (final t in _kinds('claude-tools.txt', 'tool')) _claudeAliases[t] ?? t};
      final missing = sdk.where((t) => !claudeToolCoverage.containsKey(t)).toList()..sort();
      expect(missing, isEmpty, reason: 'new Claude Code tools: add them to claudeToolCoverage');
    });

    test('every tool call in the captured logs is in the coverage table', () {
      final seen = <String>{};
      for (final f in Directory('test/fixtures/claude_logs').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.jsonl')) continue;
        for (final l in f.readAsLinesSync()) {
          final d = jsonDecode(l);
          final content = d is Map && d['message'] is Map ? (d['message'] as Map)['content'] : null;
          if (content is! List) continue;
          for (final b in content) {
            if (b is Map && b['type'] == 'tool_use' && b['name'] is String) seen.add(b['name'] as String);
          }
        }
      }
      expect(seen, isNotEmpty);
      expect(seen.where((t) => !t.startsWith('mcp__') && !claudeToolCoverage.containsKey(t)), isEmpty);
    });

    test('no row of the table names a tool that no longer exists', () {
      final sdk = {for (final t in _kinds('claude-tools.txt', 'tool')) _claudeAliases[t] ?? t};
      // Tools of the build that the SDK schema does not list are marked as such in the table.
      final stale = [
        for (final MapEntry(:key) in claudeToolCoverage.entries)
          if (!sdk.contains(key) &&
              !const {'Skill', 'ToolSearch', 'SendMessage', 'ListAgents', 'KillShell', 'BashOutput'}.contains(key))
            key,
      ];
      expect(stale, isEmpty, reason: 'remove them from claudeToolCoverage (the agent dropped them)');
    });
  });

  group('dsh', () {
    test('every event and tool in the captured mirrors is in the coverage tables', () {
      final events = <String>{};
      final tools = <String>{};
      for (final f in Directory('test/fixtures/dsh_logs').listSync().whereType<File>()) {
        if (!f.path.endsWith('.jsonl')) continue;
        for (final l in f.readAsLinesSync()) {
          final d = jsonDecode(l);
          if (d is! Map) continue;
          final type = d['type'];
          if (type is! String) continue;
          events.add(type);
          final data = d['data'];
          if (type == 'tool/call' && data is Map && data['name'] is String) tools.add(data['name'] as String);
          if (type == 'assistant/message' && data is Map) {
            final message = data['message'];
            final content = message is Map ? message['content'] : null;
            if (content is List) {
              for (final b in content) {
                if (b is Map && b['type'] == 'tool-call' && b['name'] is String) tools.add(b['name'] as String);
              }
            }
          }
        }
      }
      expect(events, isNotEmpty);
      expect(
        events.where((e) => !dshEventCoverage.containsKey(e)),
        isEmpty,
        reason: 'new dsh events: add them to dshEventCoverage',
      );
      expect(
        tools.where((t) => !dshToolCoverage.containsKey(t)),
        isEmpty,
        reason: 'new dsh tools: add them to dshToolCoverage',
      );
    });

    test('the table is exactly the set of events dsh-herdr writes', () {
      // dsh-herdr's CHAT_EVENT_TYPES (lib/chatlog.js) plus the header line: a
      // new event on that side has to be decided about here.
      const written = {
        'herdr/mirror',
        'user/message',
        'assistant/message',
        'tool/call',
        'tool/result',
        'turn/start',
        'turn/end',
        'step/start',
        'todo/write',
        'session/title',
        'agent/inbox/spliced',
        'compaction/start',
        'compaction/end',
        'command/run',
        'command/done',
      };
      expect(dshEventCoverage.keys.toSet().difference(written), isEmpty, reason: 'the mirror never writes these');
      expect(
        written.difference(dshEventCoverage.keys.toSet()),
        isEmpty,
        reason: 'a written event is not decided about',
      );
    });
  });

  group('Codex', () {
    test('every item type of the installed protocol schema is in the coverage table', () {
      final items = _kinds('codex-items.txt', 'item').map(_pascal).toSet();
      final missing = items.where((t) => !codexItemCoverage.containsKey(t)).toList()..sort();
      expect(missing, isEmpty, reason: 'new Codex item types: add them to codexItemCoverage');
    });

    test('every item and function call in the captured rollouts is in the coverage tables', () {
      final items = <String>{};
      final functions = <String>{};
      for (final f in Directory('test/fixtures/codex_logs').listSync().whereType<File>()) {
        for (final l in f.readAsLinesSync()) {
          final d = jsonDecode(l) as Map;
          final p = d['payload'];
          if (p is! Map) continue;
          if (d['type'] == 'event_msg' && p['type'] == 'item_completed') {
            items.add((p['item'] as Map)['type'] as String);
          }
          if (d['type'] == 'response_item' && p['type'] == 'function_call') functions.add(p['name'] as String);
        }
      }
      expect(items.where((t) => !codexItemCoverage.containsKey(t)), isEmpty);
      expect(functions.where((t) => !codexFunctionCoverage.containsKey(t)), isEmpty);
    });

    test('no row of the table names an item type that no longer exists', () {
      final items = _kinds('codex-items.txt', 'item').map(_pascal).toSet();
      expect([
        for (final t in codexItemCoverage.keys)
          if (!items.contains(t)) t,
      ], isEmpty);
    });
  });
}
