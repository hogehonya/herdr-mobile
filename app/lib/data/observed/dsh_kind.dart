import 'dsh_locator.dart';
import 'dsh_log_mapper.dart';
import 'observed_kind.dart';

/// dsh (the DeepSeek harness): its pane's chat comes from the plain JSONL the
/// dsh-herdr plugin mirrors the session to, at a path the app derives from the
/// pane (herdr cannot carry a dsh session reference; see [DshLocator]). dsh has
/// no question tool and asks through the terminal, and its subagents read as
/// tool rows, so the kind has no [ObservedKind.ask] and no subagent logs.
final dshKind = ObservedKind(id: 'dsh', label: 'dsh', newMapper: DshLogMapper.new, locator: const DshLocator());
