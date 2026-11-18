/// The "where do you want to go?" conversation (step 2).
///
/// Pure pieces of the voice-first flow: the question text,
/// spoken-answer resolution (a verified registry entry OR any place the
/// user names -- see [resolveSpokenDestination]), and the re-ask /
/// give-up texts. Resolution NEVER invents a place: an empty, negated,
/// interrogative or unusable answer is null, and the app asks again
/// instead of guessing.
///
/// History: this layer used to resolve ONLY the two coordinates the
/// repository happened to contain, and the re-ask text listed them
/// ("目前可以导航到：校门口、图书馆"), which is why the app felt like it
/// could only go to fixed places. The destination is now whatever the
/// user says; the registry only decides which NAME to show.
library;

import '../config/verified_locations.dart';
import 'voice_commands.dart';

/// The question the app asks right after startup.
const String destinationAskText = '你要去哪里？请说出目的地。';

const List<String> _politePrefixes = <String>[
  '我想去',
  '我要去',
  '想去',
  '要去',
  '带我去',
  '去',
  '到',
];

/// Resolve a spoken answer to a verified location, or null.
///
/// Tries the raw transcript first, then with a polite prefix
/// ("去…", "带我去…") and trailing punctuation stripped, and
/// finally any answer that merely CONTAINS a registered name
/// or alias ("我想去图书馆看书" still means the library).
///
/// Kept for the registry-backed flows (and its tests); the free-
/// destination question uses [resolveSpokenDestination].
VerifiedLocation? resolveDestinationAnswer(
  String raw, {
  List<VerifiedLocation> registry = verifiedLocations,
}) {
  final String cleaned =
      raw.trim().replaceAll(RegExp(r'[。！？!?\s]+$'), '').trim();
  if (cleaned.isEmpty) return null;
  final VerifiedLocation? direct =
      findVerifiedLocation(cleaned, registry: registry);
  if (direct != null) return direct;
  for (final String prefix in _politePrefixes) {
    if (cleaned.startsWith(prefix) && cleaned.length > prefix.length) {
      final VerifiedLocation? hit = findVerifiedLocation(
        cleaned.substring(prefix.length).trim(),
        registry: registry,
      );
      if (hit != null) return hit;
    }
  }
  for (final VerifiedLocation loc in registry) {
    if (cleaned.contains(loc.name)) return loc;
    for (final String alias in loc.aliases) {
      if (alias.isNotEmpty && cleaned.contains(alias)) return loc;
    }
  }
  return null;
}

/// 把用户说的目的地说成一个地点名。命中注册表返回注册表里的名字，
/// 否则原样返回清洗后的说法。空/超长/控制字符（以及否定句、问句）
/// 返回 null。
///
/// This is the free-destination replacement for
/// [resolveDestinationAnswer]: 「药店」 is a perfectly good answer even
/// though nothing in the repository mentions medicine, and the nearby
/// search is what turns the word into a real coordinate. The registry is
/// consulted FIRST only so that a name the app already knows keeps its
/// canonical spelling (「学校大门」 → 校门口).
///
/// The cleaning (polite prefixes, trailing punctuation/fillers, negation,
/// question, length and control-character checks) lives in
/// `voice_commands.dart` so the command layer and this dialogue cannot
/// disagree about what counts as a place.
String? resolveSpokenDestination(
  String raw, {
  List<VerifiedLocation> registry = verifiedLocations,
}) {
  final String? phrase = sanitizeSpokenDestination(raw);
  if (phrase == null) return null;
  final VerifiedLocation? hit =
      findVerifiedLocation(phrase, registry: registry);
  if (hit != null) return hit.name;
  return phrase;
}

/// Re-ask after an unusable answer (never a guess).
///
/// No longer lists the repository's two entries: the destination is not
/// a menu any more, and reciting "校门口、图书馆" taught the user that
/// those were the only options. The example is a place the app does NOT
/// ship, so the sentence demonstrates the new freedom.
String destinationNotFoundText() =>
    '没有听清你要去哪里。请再说一次，比如说“带我去药店”。';

/// After too many unanswered attempts the app stops asking --
/// it does not keep interrogating a blind user -- and leaves
/// the standing voice command available instead.
String destinationGiveUpText() =>
    '先停止询问。你可以随时说“带我去药店”，让我开始导航。';
