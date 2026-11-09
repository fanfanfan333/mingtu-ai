/// Human-verified campus destination registry for Mingtu AI.
///
/// Real voice navigation may ONLY go to destinations listed here.
/// Every entry must be verified by a person on site, with its
/// coordinates read from Amap at the location itself. Coordinates
/// here are **GCJ-02** (the Amap datum) -- they are used as-is and
/// never pass through the WGS-84 -> GCJ-02 conversion, which exists
/// solely for platform GPS fixes (see core/coordinate_convert.dart).
///
/// There is deliberately NO free-form destination search and NO
/// geocoding in this app: an unlisted destination is reported as
/// not configured, never guessed.
///
/// STATUS: the registry is currently EMPTY. No campus location has
/// been verified on site yet, so real navigation currently always
/// announces "目的地未配置" and does not start. Adding an entry is a
/// human field-work task, not a code change to improvise here.
library;

import '../modules/map_navigation.dart';

class VerifiedLocation {
  /// Stable id, e.g. 'library'.
  final String id;

  /// Spoken/display name, e.g. '图书馆'.
  final String name;

  /// Extra spoken aliases users may say.
  final List<String> aliases;

  /// GCJ-02 coordinates, verified on site. Never WGS-84.
  final GeoPoint pointGcj02;

  const VerifiedLocation({
    required this.id,
    required this.name,
    required this.pointGcj02,
    this.aliases = const [],
  });

  bool matches(String spoken) {
    final String q = spoken.trim();
    return q == name || aliases.contains(q);
  }
}

/// The registry. EMPTY by design until field verification happens.
const List<VerifiedLocation> verifiedLocations = <VerifiedLocation>[];

/// Find a verified destination by spoken name/alias, or null. The
/// [registry] parameter exists so tests can exercise the lookup
/// with fixture entries without touching the real (empty) list.
VerifiedLocation? findVerifiedLocation(
  String spoken, {
  List<VerifiedLocation> registry = verifiedLocations,
}) {
  for (final VerifiedLocation loc in registry) {
    if (loc.matches(spoken)) return loc;
  }
  return null;
}
