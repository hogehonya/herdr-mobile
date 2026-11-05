import '../../../data/words/elapsed.dart';
import '../../../l10n/app_localizations.dart';

/// The link strip's note over a saved copy, in every state but live:
/// `Showing the copy saved today at 14:02. Nothing here can be answered.` A copy is
/// never live and answers nothing (requests come only with a live attach).
/// [words] is the language it is said in; English without it (a caller outside
/// the widget tree).
String savedCopyNotice(DateTime asOf, DateTime now, {AppLocalizations? words}) {
  final when = formatWhen(asOf, now, sentence: true);
  return words == null
      ? 'Showing the copy saved $when. Nothing here can be answered.'
      : words.messageShowingTheCopySaved(when);
}
