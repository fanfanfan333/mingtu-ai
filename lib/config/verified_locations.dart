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
/// STATUS: the registry holds the two demo-route points the user
/// provided on site on 2026-11-09 （校门口 start + 图书馆
/// destination). IMPORTANT: these coordinates were PROVIDED BY
/// THE USER ON SITE -- they have NOT been field-walk verified
/// （未实地步行验证）: nobody has walked the route checking them
/// yet, so treat them as demo-grade, not surveyed-grade.
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

/// Id of the demo route's start point. The navigation starter
/// refuses to start a demo navigation when the user's current
/// position is more than 300 m from this point ("你不在演示路线
/// 附近"), because the demo coordinates are only meaningful
/// near the route they describe.
const String demoStartLocationId = 'school-gate';

/// The registry. The two entries below were provided by the user
/// on site (2026-11-09) as longitude,latitude pairs in GCJ-02;
/// they are recorded verbatim (longitude 120.x, latitude 37.x)
/// and, like every entry here, are NEVER run through the
/// WGS-84 -> GCJ-02 conversion. 用户现场提供，未实地步行验证。
const List<VerifiedLocation> verifiedLocations = <VerifiedLocation>[
  // 演示起点：校门口。用户现场提供（120.441723, 37.724409，
  // 经度,纬度，GCJ-02），未实地步行验证。
  VerifiedLocation(
    id: demoStartLocationId,
    name: '校门口',
    aliases: <String>['学校大门', '校门', '大门'],
    pointGcj02: GeoPoint(latitude: 37.724409, longitude: 120.441723),
  ),
  // 演示目的地：图书馆。用户现场提供（120.443212, 37.723667，
  // 经度，纬度，GCJ-02），未实地步行验证。
  VerifiedLocation(
    id: 'library',
    name: '图书馆',
    pointGcj02: GeoPoint(latitude: 37.723667, longitude: 120.443212),
  ),
];

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
