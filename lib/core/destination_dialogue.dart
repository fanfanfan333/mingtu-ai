/// The "where do you want to go?" conversation (step 2).
///
/// Pure pieces of the voice-first flow: the question text,
/// spoken-answer resolution against the verified registry
/// (with the polite prefixes a person actually says stripped
/// first), and the re-ask / give-up texts. Resolution NEVER
/// invents a place: an unmatched answer is null, and the app
/// asks again instead of guessing.
library;

import '../config/verified_locations.dart';

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

/// Names of every destination the user can currently pick,
/// for the re-ask text.
String destinationChoicesText({
  List<VerifiedLocation> registry = verifiedLocations,
}) =>
    registry.map((VerifiedLocation l) => l.name).join('、');

/// Re-ask after an unmatched answer (never a guess).
String destinationNotFoundText({
  List<VerifiedLocation> registry = verifiedLocations,
}) =>
    '没有找到这个地点。目前可以导航到：${destinationChoicesText(registry: registry)}。'
    '请再说一次你要去哪里。';

/// After too many unmatched answers the app stops asking --
/// it does not keep interrogating a blind user -- and leaves
/// the standing voice command available instead.
String destinationGiveUpText({
  List<VerifiedLocation> registry = verifiedLocations,
}) =>
    '先停止询问。你可以随时说“去${registry.isEmpty ? '图书馆' : registry.first.name}”，'
    '让我开始导航。';
