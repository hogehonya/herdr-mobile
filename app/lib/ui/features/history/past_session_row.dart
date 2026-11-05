import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/past_session.dart';
import '../../../l10n/app_localizations.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../render/visible_text.dart';
import '../../../data/words/elapsed.dart';
import '../files/file_format.dart' show groupDigits;

/// `Untitled session`, or the agent's title.
String pastSessionTitle(PastSession s, {AppLocalizations? words}) {
  final title = s.title;
  return title == null ? words?.uiUntitledSession ?? 'Untitled session' : visibleText(title);
}

/// `No messages`, `1 message`, `14 messages`, `12,480 messages`; empty when the
/// agent does not say.
String messageCountLabel(int? count, {AppLocalizations? words}) => switch (count) {
  null => '',
  <= 0 => words?.uiNoMessages ?? 'No messages',
  1 => words?.message1Message ?? '1 message',
  final n => words?.messageMessages(groupDigits(n)) ?? '${groupDigits(n)} messages',
};

/// `2 h ago · 14 messages`: when it last changed and how long it is, whichever
/// the agent reports.
String pastSessionDetail(PastSession s, DateTime now, {AppLocalizations? words}) => [
  if (s.updatedAt case final at?) formatAgo(at, now),
  messageCountLabel(s.messageCount, words: words),
].where((p) => p.isNotEmpty).join(' · ');

/// One session an agent remembers: its title, the folder it ran in, when it
/// last changed. The whole row is the tap target.
///
/// [open] means a keeper on this machine holds it already: the row says
/// `Open` and [onTap] shows that session. [busy] means it is being reopened:
/// a spinner, and no taps. A null [onTap] is a row that cannot be reopened.
class PastSessionRow extends StatelessWidget {
  const PastSessionRow({
    super.key,
    required this.session,
    required this.now,
    required this.onTap,
    this.open = false,
    this.busy = false,
  });

  final PastSession session;

  /// What "2 h ago" counts from.
  final DateTime now;
  final VoidCallback? onTap;
  final bool open;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final folder = visibleText(cwdTail(session.cwd));
    final detail = pastSessionDetail(session, now, words: context.l10n);
    return ListRow(
      title: pastSessionTitle(session, words: context.l10n),
      subtitle: folder.isEmpty ? null : folder,
      subtitle2: detail.isEmpty ? null : detail,
      onTap: busy ? null : onTap,
      trailing: busy
          ? const BusySpinner(size: IconSize.bar)
          : open
          ? Text(context.l10n.uiOpen, style: Type.labelStrong.copyWith(color: ds.accentText))
          : onTap == null
          ? null
          : Icon(LucideIcons.chevronRight, size: IconSize.row, color: ds.textTertiary),
    );
  }
}
