import 'dart:convert';

import '../acp/acp_models.dart';
import '../acp/background/background_work.dart' show BackgroundTask;
import 'log_mapping.dart';
import 'observed_contracts.dart';

/// Maps the lines of a dsh chat mirror (`~/.dsh/herdr/<session>/<pane>.jsonl`,
/// written by the dsh-herdr plugin) to the updates `AgentSessionState.apply`
/// understands.
///
/// The file is the session as dsh recorded it, reduced by the plugin to the
/// events a chat shows (captured in `test/fixtures/dsh_logs/`):
///
/// * `herdr/mirror` — the header: pane, herdr session, dsh session, pid, cwd.
/// * `user/message` — one message of the person (`data.id`, `data.content`).
///   dsh also records the text it injects (instructions, runtime context, the
///   skill catalog) as such; the plugin drops those, so every one here is the
///   person's.
/// * `agent/inbox/spliced` — a message the person added while the agent worked
///   (`data.inserted`): it becomes a message too, and starts a turn.
/// * `assistant/message` — one step of the agent: `reasoning` and `text` blocks
///   and the `tool-call` blocks it asked for.
/// * `tool/call` / `tool/result` — the same calls and what they printed
///   (`data.message.content`, `isError`).
/// * `turn/start` / `turn/end` (`data.reason.kind`: `completed`, `error`,
///   `interrupted`) — the turn's bounds; an error names what failed.
/// * `todo/write` — the agent's plan, whole.
/// * `session/title` — the title dsh gave the session.
/// * `compaction/start` / `compaction/end` — earlier messages summarised.
/// * `command/run` / `command/done` — a command the person typed (the plugin
///   sends them; the chat leaves them to the terminal).
///
/// Idempotent: a line is mapped once (by its `seq`, else a hash of the line),
/// messages and calls are keyed by their dsh ids, so the same file fed twice
/// changes nothing.
class DshLogMapper implements SessionLogMapper {
  static const _titleChars = 120;

  final _seen = <String>{};

  /// Tool call ids that already have a row: dsh names a call twice (its step's
  /// `tool-call` block and a `tool/call` event), and the block can come after
  /// the result, which must not put the row back to "running".
  final _started = <String>{};

  /// Calls that started and have no result yet, by call id.
  final _open = <String, _Call>{};

  /// Call ids in the order they started, for cancelling at a turn's end.
  final _order = <String>[];

  var _turnEnded = false;
  var _titled = false;

  @override
  PendingAsk? get pendingAsk => null; // dsh asks in the terminal, not through a tool

  @override
  ProposedPlan? get proposedPlan => null;

  @override
  Set<String> get openToolCalls => Set.unmodifiable(_open.keys);

  @override
  List<SubagentInfo> get subagents => const []; // a dsh subagent reads as its tool row

  @override
  List<BackgroundTask> get backgroundTasks => const [];

  @override
  bool get turnEnded => _turnEnded && _open.isEmpty;

  @override
  void reset() {
    _seen.clear();
    _started.clear();
    _open.clear();
    _order.clear();
    _turnEnded = false;
    _titled = false;
  }

  @override
  List<SessionUpdate> map(String line) {
    if (line.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on Object {
      return const [];
    }
    if (decoded is! Map<String, dynamic>) return const [];
    final type = decoded['type'];
    if (type is! String) return const [];
    final seq = decoded['seq'];
    if (!_seen.add(seq is int ? 's$seq' : 'h${fnv(line)}')) return const [];
    try {
      return _line(type, decoded, line);
    } on Object {
      return const [];
    }
  }

  List<SessionUpdate> _line(String type, Json e, String line) {
    final data = e['data'];
    final d = data is Map<String, dynamic> ? data : const <String, dynamic>{};
    switch (type) {
      case 'user/message':
        return _user(d);
      case 'agent/inbox/spliced':
        return _spliced(d);
      case 'assistant/message':
        return _assistant(d);
      case 'tool/call':
        return _toolCall(d);
      case 'tool/result':
        return _toolResult(d);
      case 'turn/start':
        _turnEnded = false;
        return const [];
      case 'turn/end':
        return _turnEnd(d);
      case 'todo/write':
        return _plan(d['todos']);
      case 'session/title':
        final title = d['title'];
        if (title is! String || title.trim().isEmpty) return const [];
        _titled = true;
        return [SessionInfoUpdate(hasTitle: true, title: cutText(title.trim(), 120), hasUpdatedAt: false)];
      case 'compaction/end':
        return [messageUpsert(MessageRole.agent, 'compaction:${e['seq']}', 'Earlier messages were summarised')];
      default:
        // step/start, compaction/start and command/* are in the file for
        // completeness; nothing on the phone shows them (see dshEventCoverage).
        return const [];
    }
  }

  // -- messages ----------------------------------------------------------------

  List<SessionUpdate> _user(Json d) {
    // The plugin drops the text dsh injects; a mirror from an older plugin may
    // still carry it, and it is not a message of the person either way.
    final source = d['source'];
    final kind = source is Map ? source['kind'] : null;
    if (kind != null && kind != 'user') return const [];
    final text = _contentText(d['content']);
    if (text.trim().isEmpty) return const [];
    final id = _id(d['id']) ?? 'user:${fnv(text)}';
    _turnEnded = false;
    final out = <SessionUpdate>[userMessageUpsert(id, text, const [])];
    if (!_titled) {
      _titled = true;
      out.add(SessionInfoUpdate(hasTitle: true, title: cutText(firstLine(text.trim()), 80), hasUpdatedAt: false));
    }
    return out;
  }

  List<SessionUpdate> _spliced(Json d) {
    final inserted = d['inserted'];
    if (inserted is! List) return const [];
    return [
      for (final m in inserted)
        if (m is Map<String, dynamic>) ..._user(m),
    ];
  }

  List<SessionUpdate> _assistant(Json d) {
    final message = d['message'];
    if (message is! Map<String, dynamic>) return const [];
    final content = message['content'];
    if (content is! List) return const [];
    final msgId = _id(message['id']) ?? 'step:${d['turn']}:${d['step']}';
    final out = <SessionUpdate>[];
    for (var i = 0; i < content.length; i++) {
      final b = content[i];
      if (b is! Map<String, dynamic>) continue;
      final id = '$msgId:$i';
      switch (b['type']) {
        case 'reasoning':
          final t = b['text'];
          if (t is String && t.trim().isNotEmpty) out.add(messageUpsert(MessageRole.thought, id, t));
        case 'text':
          final t = b['text'];
          if (t is String && t.trim().isNotEmpty) out.add(messageUpsert(MessageRole.agent, id, t));
        case 'tool-call':
          // The block's own id is the call id the result names.
          out.addAll(_start(_id(b['id']) ?? id, b['name'], b['arguments']));
      }
    }
    return out;
  }

  // -- tools -------------------------------------------------------------------

  /// A call announced both in its step's `tool-call` block and as `tool/call`:
  /// the same id twice replaces nothing visible.
  List<SessionUpdate> _toolCall(Json d) {
    final id = _id(d['callId']);
    if (id == null) return const [];
    return _start(id, d['name'], d['arguments']);
  }

  List<SessionUpdate> _start(String id, Object? nameValue, Object? argumentsValue) {
    if (!_started.add(id)) return const [];
    final name = nameValue is String && nameValue.isNotEmpty ? nameValue : 'tool';
    final input = _input(argumentsValue);
    if (!_open.containsKey(id)) _order.add(id);
    _open[id] = _Call(name, input);
    _turnEnded = false;
    return [
      ToolCallStart(
        ToolCall(
          toolCallId: id,
          name: name,
          title: _titleOf(name, input),
          kind: _kindOf(name),
          status: ToolStatus.inProgress,
          rawInput: input == null ? null : capJson(input),
          content: _diffs(name, input),
          locations: _locations(name, input),
        ),
      ),
    ];
  }

  List<SessionUpdate> _toolResult(Json d) {
    final message = d['message'];
    if (message is! Map<String, dynamic>) return const [];
    final id = _id(message['toolCallId']);
    if (id == null) return const [];
    final open = _open.remove(id);
    if (open != null) _order.remove(id);
    final isError = message['isError'] == true;
    final text = _contentText(message['content']);
    // A patch replaces the content whole: the diff the call started with is
    // sent again beside what it printed.
    final content = <ToolContent>[
      if (open != null && !isError) ..._diffs(open.name, open.input),
      if (text.isNotEmpty) ToolContentBlock(TextBlock(capText(text))),
    ];
    final fields = <String, Object?>{
      'toolCallId': id,
      if (open == null) ...{'name': 'tool', 'title': 'tool', 'kind': kindWire(ToolKind.other)},
      'status': (isError ? ToolStatus.failed : ToolStatus.completed).name,
      if (content.isNotEmpty) 'content': [for (final c in content) c.toJson()],
      if (text.isNotEmpty) 'rawOutput': capText(text),
    };
    return [ToolCallPatchUpdate(ToolCallPatch(id, fields))];
  }

  List<SessionUpdate> _turnEnd(Json d) {
    _turnEnded = true;
    final reason = d['reason'];
    final kind = reason is Map ? reason['kind'] : null;
    final out = <SessionUpdate>[];
    if (kind == 'error') {
      final error = reason is Map ? reason['error'] : null;
      final message = error is Map ? error['message'] : null;
      final text = message is String && message.trim().isNotEmpty ? 'The turn failed: $message' : 'The turn failed.';
      out.add(messageUpsert(MessageRole.agent, 'turn:${d['turn']}:error', text));
    } else if (kind == 'interrupted' || kind == 'aborted' || kind == 'cancelled') {
      out.add(messageUpsert(MessageRole.agent, 'turn:${d['turn']}:interrupted', 'Interrupted'));
    }
    if (kind != 'completed') {
      // Nothing will report these calls' results.
      for (final id in _order) {
        out.add(cancelledPatch(id));
      }
      _open.clear();
      _order.clear();
    }
    return out;
  }

  static List<SessionUpdate> _plan(Object? todos) {
    if (todos is! List) return const [];
    final entries = <PlanEntry>[];
    for (final t in todos) {
      if (t is! Map) continue;
      final content = t['content'];
      if (content is! String || content.trim().isEmpty) continue;
      entries.add(PlanEntry(content: cutText(content.trim(), 300), status: _planStatus(t['status'])));
    }
    if (entries.isEmpty) return const [];
    return [PlanUpdate(entries)];
  }

  static PlanStatus _planStatus(Object? wire) => switch (wire) {
    'in_progress' => PlanStatus.inProgress,
    'completed' => PlanStatus.completed,
    'cancelled' => PlanStatus.cancelled,
    _ => PlanStatus.pending,
  };

  // -- shapes ------------------------------------------------------------------

  static String? _id(Object? v) => v is String && v.isNotEmpty ? v : null;

  /// A tool call's arguments: dsh writes them as a JSON string.
  static Json? _input(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is! String || v.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(v);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  /// The text of `content` blocks (a picture keeps its `[image]` line).
  static String _contentText(Object? content) {
    if (content is String) return content;
    if (content is! List) return '';
    final parts = <String>[];
    for (final b in content) {
      if (b is! Map) continue;
      switch (b['type']) {
        case 'text':
          if (b['text'] is String) parts.add(b['text'] as String);
        case 'image':
          parts.add('[image]');
      }
    }
    return parts.join('\n');
  }

  static List<ToolContent> _diffs(String name, Json? input) {
    String? str(String key) {
      final v = input?[key];
      return v is String ? v : null;
    }

    switch (name) {
      case 'write':
        final path = str('file_path');
        final content = str('content');
        if (path == null || content == null) return const [];
        return [ToolDiff(path: path, newText: capText(content))];
      case 'edit':
        final path = str('file_path');
        final oldText = str('old_string');
        final newText = str('new_string');
        if (path == null || oldText == null || newText == null) return const [];
        return [ToolDiff(path: path, oldText: capText(oldText), newText: capText(newText))];
      default:
        return const [];
    }
  }

  static List<ToolLocation> _locations(String name, Json? input) {
    if (!const {'read', 'write', 'edit', 'read_image', 'list'}.contains(name)) return const [];
    final path = input?['file_path'] ?? input?['path'];
    return path is String && path.isNotEmpty ? [ToolLocation(path: path)] : const [];
  }

  static ToolKind _kindOf(String name) => switch (name) {
    'bash' || 'job_output' || 'job_kill' || 'job_list' => ToolKind.execute,
    'read' || 'read_image' || 'list' || 'list_agents' => ToolKind.read,
    'write' || 'edit' => ToolKind.edit,
    'grep' || 'glob' || 'web_search' => ToolKind.search,
    'web_fetch' => ToolKind.fetch,
    'todo_write' || 'create_goal' || 'update_goal' || 'get_goal' => ToolKind.think,
    _ => ToolKind.other,
  };

  /// The line a row shows: what the agent said it was doing, else the tool and
  /// its subject.
  static String _titleOf(String name, Json? input) {
    String? str(String key) {
      final v = input?[key];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    String name_(String? path) => path == null ? name : path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;
    switch (name) {
      case 'bash':
        final d = str('description');
        if (d != null) return cutText(firstLine(d), _titleChars);
        final c = str('command');
        if (c != null) return cutText(firstLine(c), _titleChars);
      case 'read' || 'read_image' || 'write' || 'edit':
        return cutText('${_verb(name)} ${name_(str('file_path'))}', _titleChars);
      case 'grep':
        final p = str('pattern');
        if (p != null) return cutText('Search $p', _titleChars);
      case 'glob':
        final p = str('pattern');
        if (p != null) return cutText('Find $p', _titleChars);
      case 'web_fetch':
        final u = str('url');
        if (u != null) return cutText(u, _titleChars);
      case 'web_search':
        final q = input?['queries'];
        final first = q is List && q.isNotEmpty ? q.first : null;
        if (first is String) return cutText(first, _titleChars);
      case 'skill':
        final n = str('name');
        if (n != null) return cutText('Skill $n', _titleChars);
      case 'todo_write':
        return 'Plan';
      case 'job_output' || 'job_kill':
        final j = str('job_id');
        if (j != null) return cutText('${name == 'job_kill' ? 'Stop' : 'Read'} $j', _titleChars);
      case 'job_list':
        return 'Jobs';
      case 'subagent' || 'subagent_fork':
        final d = str('description');
        if (d != null) return cutText(d, _titleChars);
      case 'send_message':
        final a = str('agent_id');
        if (a != null) return cutText('Message ${cutText(a, 24)}', _titleChars);
      case 'interrupt_agent':
        final a = str('agent_id');
        if (a != null) return cutText('Interrupt ${cutText(a, 24)}', _titleChars);
      case 'list_agents':
        return 'Agents';
      case 'workflow':
        final meta = input?['meta'];
        final n = meta is Map ? meta['name'] : null;
        if (n is String && n.isNotEmpty) return cutText('Workflow $n', _titleChars);
        return 'Workflow';
      case 'create_goal' || 'update_goal':
        final o = str('objective');
        if (o != null) return cutText(firstLine(o), _titleChars);
      case 'get_goal':
        return 'Goal';
    }
    final subject = str('file_path') ?? str('path') ?? str('pattern') ?? str('url') ?? str('description');
    return subject == null ? cutText(name, _titleChars) : cutText('$name ${name_(subject)}', _titleChars);
  }

  static String _verb(String name) => switch (name) {
    'read' => 'Read',
    'read_image' => 'Viewed',
    'write' => 'Write',
    'edit' => 'Edit',
    _ => name,
  };
}

/// A call that started and has no result yet.
class _Call {
  const _Call(this.name, this.input);

  final String name;
  final Json? input;
}
