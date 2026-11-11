/// Cloud hazard assessment: the STRICT JSON mode of the
/// cloud vision channel (project-lead spec, 2026-11-09),
/// built for the things local YOLO cannot see -- stairs,
/// curbs, pits and tactile paving -- and as a second
/// opinion on people and vehicles. (Its automatic walking
/// scan was deleted in M2 section 3.3; the hazard task
/// itself remains on the proxy and in the client for the
/// manual path. The same strict-JSON discipline carries
/// the section 3.3 crossing_info / detour modes below.)
///
/// Wire format (validated identically on the client here
/// and on the FC proxy; anything nonconforming collapses to
/// the all-unknown assessment, never to prose):
///   type:            stairs_up | stairs_down | curb |
///                    tactile_paving | pedestrian | vehicle |
///                    bicycle | pole | pit | unknown
///   direction:       left | center | right | unknown
///   distance_level:  immediate | near | far | unknown
///   confidence:      0..1
///   path_status:     { suggested_action: forward |
///                      shift_left | shift_right | stop,
///                      summary: at most 15 characters }
///
/// Rules that bind every consumer:
/// - unclear input is unknown, never a guess;
/// - the cloud's suggested shift is ADVISORY ONLY: whether
///   a direction is spoken is decided locally by the
///   three-condition avoidance rule, never by this payload;
/// - `summary` is model free text: it is validated for
///   shape and may be shown in logs, but it is NEVER spoken
///   (all speech is generated from the enums by templates);
/// - stairs, curbs and pits never yield a step direction,
///   whatever the payload suggests.
library;

import 'cloud_vision.dart';

/// Outcome of one hazard-mode call: either a strictly
/// parsed [HazardAssessment] or the same failure vocabulary
/// the scene mode uses.
class HazardScanOutcome {
  final HazardAssessment? assessment;
  final CloudVisionFailure? failure;
  const HazardScanOutcome.ok(HazardAssessment a)
      : assessment = a,
        failure = null;
  const HazardScanOutcome.failed(CloudVisionFailure f)
      : assessment = null,
        failure = f;
  bool get ok => failure == null && assessment != null;
}

enum HazardType {
  stairsUp,
  stairsDown,
  curb,
  tactilePaving,
  pedestrian,
  vehicle,
  bicycle,
  pole,
  pit,
  unknown,
}

enum HazardDirection { left, center, right, unknown }

enum HazardDistanceLevel { immediate, near, far, unknown }

enum HazardSuggestedAction { forward, shiftLeft, shiftRight, stop }

const Map<String, HazardType> _typeByWire = <String, HazardType>{
  'stairs_up': HazardType.stairsUp,
  'stairs_down': HazardType.stairsDown,
  'curb': HazardType.curb,
  'tactile_paving': HazardType.tactilePaving,
  'pedestrian': HazardType.pedestrian,
  'vehicle': HazardType.vehicle,
  'bicycle': HazardType.bicycle,
  'pole': HazardType.pole,
  'pit': HazardType.pit,
  'unknown': HazardType.unknown,
};

const Map<String, HazardDirection> _directionByWire = <String, HazardDirection>{
  'left': HazardDirection.left,
  'center': HazardDirection.center,
  'right': HazardDirection.right,
  'unknown': HazardDirection.unknown,
};

const Map<String, HazardDistanceLevel> _distanceByWire =
    <String, HazardDistanceLevel>{
  'immediate': HazardDistanceLevel.immediate,
  'near': HazardDistanceLevel.near,
  'far': HazardDistanceLevel.far,
  'unknown': HazardDistanceLevel.unknown,
};

const Map<String, HazardSuggestedAction> _actionByWire =
    <String, HazardSuggestedAction>{
  'forward': HazardSuggestedAction.forward,
  'shift_left': HazardSuggestedAction.shiftLeft,
  'shift_right': HazardSuggestedAction.shiftRight,
  'stop': HazardSuggestedAction.stop,
};

class HazardAssessment {
  final HazardType type;
  final HazardDirection direction;
  final HazardDistanceLevel distanceLevel;
  final double confidence;
  final HazardSuggestedAction suggestedAction;

  /// Model free text, shape-validated only. NEVER spoken.
  final String summary;

  /// False when the payload did not conform and this is the
  /// collapsed all-unknown assessment.
  final bool parsed;

  const HazardAssessment({
    required this.type,
    required this.direction,
    required this.distanceLevel,
    required this.confidence,
    required this.suggestedAction,
    required this.summary,
    required this.parsed,
  });

  static const HazardAssessment unknown = HazardAssessment(
    type: HazardType.unknown,
    direction: HazardDirection.unknown,
    distanceLevel: HazardDistanceLevel.unknown,
    confidence: 0,
    suggestedAction: HazardSuggestedAction.stop,
    summary: '',
    parsed: false,
  );
}

/// Strictly parse one hazard payload (the proxy's structured
/// response body, already JSON-decoded). ANY deviation --
/// missing keys, unknown enum values, wrong shapes, a
/// summary over 15 characters -- collapses the whole thing
/// to [HazardAssessment.unknown]: a partly-trusted hazard
/// payload is worse than none.
HazardAssessment parseHazardAssessment(Object? decoded) {
  if (decoded is! Map) return HazardAssessment.unknown;
  if (decoded['parsed'] != true) return HazardAssessment.unknown;
  final Object? typeRaw = decoded['type'];
  final Object? dirRaw = decoded['direction'];
  final Object? distRaw = decoded['distance_level'];
  final Object? confRaw = decoded['confidence'];
  final Object? pathRaw = decoded['path_status'];
  if (typeRaw is! String || !_typeByWire.containsKey(typeRaw)) {
    return HazardAssessment.unknown;
  }
  if (dirRaw is! String || !_directionByWire.containsKey(dirRaw)) {
    return HazardAssessment.unknown;
  }
  if (distRaw is! String || !_distanceByWire.containsKey(distRaw)) {
    return HazardAssessment.unknown;
  }
  if (confRaw is! num || confRaw.isNaN || confRaw.isInfinite) {
    return HazardAssessment.unknown;
  }
  if (pathRaw is! Map) return HazardAssessment.unknown;
  final Object? actionRaw = pathRaw['suggested_action'];
  final Object? summaryRaw = pathRaw['summary'];
  if (actionRaw is! String || !_actionByWire.containsKey(actionRaw)) {
    return HazardAssessment.unknown;
  }
  if (summaryRaw is! String || summaryRaw.runes.length > 15) {
    return HazardAssessment.unknown;
  }
  return HazardAssessment(
    type: _typeByWire[typeRaw]!,
    direction: _directionByWire[dirRaw]!,
    distanceLevel: _distanceByWire[distRaw]!,
    confidence: confRaw.toDouble().clamp(0.0, 1.0),
    suggestedAction: _actionByWire[actionRaw]!,
    summary: summaryRaw,
    parsed: true,
  );
}

/// The pinned hazard prompt. The FC proxy pins the same
/// text server-side (the client's copy is replaced there);
/// it contains the word "json" as the upstream requires,
/// fixes every field and enum, and orders unknown answers
/// whenever the frame is unclear.
const String cloudHazardPrompt = '只输出一个 json 对象，不要输出任何其他文字：'
    '{"type": 类型, "direction": 方位, "distance_level": 远近, '
    '"confidence": 0到1的小数, "path_status": '
    '{"suggested_action": 建议, "summary": "15字以内的概括"}}。'
    '类型只能是：stairs_up、stairs_down、curb、tactile_paving、'
    'pedestrian、vehicle、bicycle、pole、pit、unknown。'
    '方位只能是：left、center、right、unknown。'
    '远近只能是：immediate、near、far、unknown。'
    '建议只能是：forward、shift_left、shift_right、stop。'
    '看不清或拿不准时，相应字段一律填 unknown。'
    '不要做任何通行判断，不要输出 json 以外的任何内容。';

/// Caution speech for a ground hazard from a scan, or null
/// when the assessment carries nothing the scan announces.
/// Steps / curbs / pits NEVER produce a direction here,
/// whatever the cloud suggested. Every text carries the
/// cloud-vision disclaimer.
String? hazardGroundSpeech(HazardAssessment a) {
  if (!a.parsed) return null;
  // A far-away ground hazard is not announced yet; later
  // scans re-check as the user approaches.
  if (a.distanceLevel == HazardDistanceLevel.far) return null;
  final String? lead = switch (a.type) {
    HazardType.stairsUp => '小心上台阶。',
    HazardType.stairsDown => '小心下台阶。',
    HazardType.curb => '前方有路沿，请停下。',
    HazardType.pit => '前方有坑洼，请停下。',
    _ => null,
  };
  if (lead == null) return null;
  return '$lead提醒：$cloudVisionDisclaimer';
}

/// Info speech when a scan identifies tactile paving. It
/// reports the identification ONLY: whether the paving is
/// clear is a separate judgement this payload cannot make,
/// and no direction is derived from it.
String? hazardPavingSpeech(HazardAssessment a) {
  if (!a.parsed || a.type != HazardType.tactilePaving) return null;
  return '识别到前方有盲道，是否畅通无法确认，请以盲杖探测为准。'
      '提醒：$cloudVisionDisclaimer';
}

/// A short enum-only description, used when a manual
/// "看看前面" request joined an in-flight hazard cycle and
/// is answered by that cycle's single request (the merged
/// request rule): the user still gets a spoken answer, built
/// from templates, never from model prose.
String hazardDescriptionSpeech(HazardAssessment a) {
  if (!a.parsed || a.type == HazardType.unknown) {
    return '云端视觉辅助：前方情况不确定。提醒：$cloudVisionDisclaimer';
  }
  final String typeName = switch (a.type) {
    HazardType.stairsUp => '上台阶',
    HazardType.stairsDown => '下台阶',
    HazardType.curb => '路沿',
    HazardType.tactilePaving => '盲道',
    HazardType.pedestrian => '行人',
    HazardType.vehicle => '车辆',
    HazardType.bicycle => '自行车',
    HazardType.pole => '杆子',
    HazardType.pit => '坑洼',
    HazardType.unknown => '未知目标',
  };
  final String dirName = switch (a.direction) {
    HazardDirection.left => '左侧',
    HazardDirection.center => '正前方',
    HazardDirection.right => '右侧',
    HazardDirection.unknown => '前方',
  };
  final String distName = switch (a.distanceLevel) {
    HazardDistanceLevel.immediate => '很近处',
    HazardDistanceLevel.near => '较近处',
    HazardDistanceLevel.far => '较远处',
    HazardDistanceLevel.unknown => '',
  };
  return '云端视觉辅助：$dirName$distName有$typeName。'
      '提醒：$cloudVisionDisclaimer';
}

/// Fixed downgrade speech for the cloud-vision channel
/// (new-client / old-FC compatibility rule, 2026-11-09):
/// whenever a hazard scan cannot produce a trustworthy
/// assessment -- the FC still runs the pre-hazard build and
/// answers in the old scene shape, the response shape is
/// not recognised, or the request itself failed -- the user
/// hears exactly this sentence. It is a fixed local text;
/// no server string is ever copied into it.
const String cloudVisionDowngradeSpeech = '云端识图暂不可用，请慢行。';

/// Announce-once + rate limit for
/// [cloudVisionDowngradeSpeech]. A cloud path that keeps
/// failing (for example against an old FC deployment) must
/// tell the user ONCE that cloud vision is unavailable and
/// then stay quiet for [announceCooldown]; without the gate,
/// a repeating trigger would repeat the sentence forever.
/// A successful call resets the gate, so the next failure
/// episode may speak once again.
class CloudVisionDowngradeGate {
  final Duration announceCooldown;

  DateTime? _lastAnnouncedAt;

  CloudVisionDowngradeGate({
    this.announceCooldown = const Duration(seconds: 60),
  });

  /// True when the downgrade sentence may be spoken at
  /// [now]; records the announcement when it returns true.
  bool shouldAnnounce(DateTime now) {
    final DateTime? last = _lastAnnouncedAt;
    if (last != null && now.difference(last) < announceCooldown) {
      return false;
    }
    _lastAnnouncedAt = now;
    return true;
  }

  /// A scan succeeded: the next failure is a new episode
  /// and may be announced once again.
  void noteSuccess() {
    _lastAnnouncedAt = null;
  }
}

/// Exponential backoff for cloud-vision 429s (project-lead
/// rule): the first 429 may be announced ONCE; afterwards
/// the scan stays silent and waits 30 s, 60 s, 120 s ...
/// (capped), while local YOLO keeps working. A success
/// resets the policy completely.
class VisionRateBackoff {
  static const Duration baseDelay = Duration(seconds: 30);
  static const Duration maxDelay = Duration(minutes: 4);

  DateTime? _blockedUntil;
  int _strikes = 0;
  bool _announced = false;

  bool allow(DateTime now) =>
      _blockedUntil == null || !now.isBefore(_blockedUntil!);

  /// Record a 429 at [now]; returns true when this one may
  /// be announced (the first since the last success).
  bool onRateLimited(DateTime now) {
    _strikes += 1;
    int factor = 1 << (_strikes - 1);
    if (factor > 16) factor = 16;
    Duration delay = baseDelay * factor;
    if (delay > maxDelay) delay = maxDelay;
    _blockedUntil = now.add(delay);
    if (_announced) return false;
    _announced = true;
    return true;
  }

  void onSuccess() {
    _blockedUntil = null;
    _strikes = 0;
    _announced = false;
  }

  DateTime? get blockedUntil => _blockedUntil;
  int get strikes => _strikes;
}

/// What can start a cloud-vision request (M2 section
/// 3.3). Exactly three starters exist:
/// - [crossingStop]: the AUTOMATIC crossing trigger --
///   the user has stopped at the start of a crossing
///   step; one frame goes out with task=crossing_info;
/// - [pathBlocked]: the AUTOMATIC blockage trigger --
///   a confirmed static obstacle has blocked the forward
///   channel for a while and the user has stopped; one
///   frame goes out with task=detour;
/// - [manual]: the user's own explicit request (voice
///   "看看前面" or the assist button), the scene-mode
///   on-demand flow.
///
/// History: this enum used to carry `periodic` (an
/// 8-second walking-scan timer) and `yoloHazard` (a
/// per-alert automatic hazard frame). Section 3.3
/// deleted BOTH automatic hazard starters: automatic
/// cloud calls now happen only at the two event
/// triggers above, under the CloudAutoTriggerBudget.
/// The old cycle-merging coordinator went with them --
/// its merge-into-one-request discipline is superseded
/// by the budget's single shared in-flight slot (see
/// cloud_trigger_policy.dart): any starter arriving
/// while a request is in flight is dropped, never
/// merged into a second call.
enum VisionTrigger { crossingStop, pathBlocked, manual }

enum CrossingLight { red, green, yellow, none, unknown }

const Map<String, CrossingLight> _lightByWire = <String, CrossingLight>{
  'red': CrossingLight.red,
  'green': CrossingLight.green,
  'yellow': CrossingLight.yellow,
  'none': CrossingLight.none,
  'unknown': CrossingLight.unknown,
};

/// One crossing_info answer, strictly parsed. The light
/// state is REFERENCE data only: the spoken form (see
/// [crossingSpeechText]) reports what the light LOOKS
/// like and always carries the reference-only caveat;
/// it never grants or implies passage.
class CrossingInfo {
  final CrossingLight light;

  /// Model-reported countdown, seconds, already range-
  /// checked to 0..99 by the parser; null when the
  /// model gave none (or an unusable one collapsed the
  /// whole answer to [CrossingInfo.unknown]).
  final int? countdownS;

  /// Whether a crosswalk is visible in the frame. Data
  /// only; no speech is derived from it in M2.
  final bool crosswalkVisible;

  /// False when the payload did not conform and this is
  /// the collapsed all-unknown answer.
  final bool parsed;

  const CrossingInfo({
    required this.light,
    required this.countdownS,
    required this.crosswalkVisible,
    required this.parsed,
  });

  static const CrossingInfo unknown = CrossingInfo(
    light: CrossingLight.unknown,
    countdownS: null,
    crosswalkVisible: false,
    parsed: false,
  );
}

/// Strictly parse one crossing_info payload. Same
/// discipline as [parseHazardAssessment]: ANY deviation
/// -- a missing key, an out-of-domain light, a countdown
/// that is not an integer in 0..99 (a JSON boolean is
/// not an integer), a non-boolean crosswalk flag --
/// collapses the whole answer to [CrossingInfo.unknown].
CrossingInfo parseCrossingInfo(Object? decoded) {
  if (decoded is! Map) return CrossingInfo.unknown;
  if (decoded['parsed'] != true) return CrossingInfo.unknown;
  final Object? lightRaw = decoded['light'];
  if (lightRaw is! String || !_lightByWire.containsKey(lightRaw)) {
    return CrossingInfo.unknown;
  }
  final Object? countdownRaw = decoded['countdown_s'];
  int? countdown;
  if (countdownRaw != null) {
    if (countdownRaw is! int || countdownRaw < 0 || countdownRaw > 99) {
      return CrossingInfo.unknown;
    }
    countdown = countdownRaw;
  }
  final Object? crosswalkRaw = decoded['crosswalk_visible'];
  if (crosswalkRaw is! bool) return CrossingInfo.unknown;
  return CrossingInfo(
    light: _lightByWire[lightRaw]!,
    countdownS: countdown,
    crosswalkVisible: crosswalkRaw,
    parsed: true,
  );
}

/// The pinned crossing prompt. The FC proxy pins the
/// same text server-side (the client's copy is replaced
/// there); it fixes every field and orders unknown
/// answers whenever the frame is unclear.
const String cloudCrossingPrompt = '只输出一个 json 对象，不要输出任何其他文字：'
    '{"light": 信号灯, "countdown_s": 倒计时秒数或null, '
    '"crosswalk_visible": true或false}。'
    '信号灯只能是：red、green、yellow、none、unknown。'
    '倒计时只能是0到99的整数，看不到倒计时就填 null。'
    'crosswalk_visible 表示画面中是否能看到人行横道。'
    '看不清或拿不准时，light 一律填 unknown。'
    '不要做任何通行判断，不要输出 json 以外的任何内容。';

/// Reference-only speech for a parsed crossing answer,
/// or null when the answer carries nothing speakable
/// (unparsed / light unknown -- the caller announces
/// the fixed downgrade sentence instead). Every form
/// states what the light LOOKS like, folds a countdown
/// in as reference data only, and carries the
/// reference-only caveat plus the instruction to confirm
/// by the user's own familiar means. No form grants or
/// implies passage, and none is derived from model
/// prose: the light word comes from the enum alone.
String? crossingSpeechText(CrossingInfo info) {
  if (!info.parsed || info.light == CrossingLight.unknown) return null;
  final String lead = switch (info.light) {
    CrossingLight.red => '信号灯看起来是红灯',
    CrossingLight.green => '信号灯看起来是绿灯',
    CrossingLight.yellow => '信号灯看起来是黄灯',
    CrossingLight.none => '画面里没有看到信号灯',
    CrossingLight.unknown => '',
  };
  // A countdown rides along as reference data -- except
  // with light=none, where "no light seen" and a live
  // countdown would contradict each other in one breath;
  // the countdown claim is dropped, never the caveat.
  final String countdown = info.countdownS == null ||
          info.light == CrossingLight.none
      ? ''
      : '，倒计时约${info.countdownS}秒';
  return '$lead$countdown，仅供参考，请用你熟悉的方式确认。';
}

/// Outcome of one crossing_info call: either a strictly
/// parsed [CrossingInfo] or the shared failure
/// vocabulary. Mirrors [HazardScanOutcome].
class CrossingScanOutcome {
  final CrossingInfo? info;
  final CloudVisionFailure? failure;
  const CrossingScanOutcome.ok(CrossingInfo i)
      : info = i,
        failure = null;
  const CrossingScanOutcome.failed(CloudVisionFailure f)
      : info = null,
        failure = f;
  bool get ok => failure == null && info != null;
}

enum DetourOpenSide { left, right, none, unknown }

const Map<String, DetourOpenSide> _sideByWire = <String, DetourOpenSide>{
  'left': DetourOpenSide.left,
  'right': DetourOpenSide.right,
  'none': DetourOpenSide.none,
  'unknown': DetourOpenSide.unknown,
};

/// One detour answer, strictly parsed. EVIDENCE ONLY:
/// [openSide] is one input the device may weigh later;
/// whether a step direction is spoken is decided
/// on-device by the avoidance advisor's three-condition
/// rule, never by this payload, and M2 wires no speech
/// to this answer at all (see the wiring layer).
class DetourInfo {
  final bool blocked;
  final DetourOpenSide openSide;

  /// False when the payload did not conform and this is
  /// the collapsed unknown-evidence answer. Its
  /// [blocked] is false BY CONSTRUCTION: an anomalous
  /// answer must never assert a blockage.
  final bool parsed;

  const DetourInfo({
    required this.blocked,
    required this.openSide,
    required this.parsed,
  });

  static const DetourInfo unknown = DetourInfo(
    blocked: false,
    openSide: DetourOpenSide.unknown,
    parsed: false,
  );
}

/// Strictly parse one detour payload; any deviation
/// (non-boolean blocked, out-of-domain side, missing
/// keys) collapses to [DetourInfo.unknown].
DetourInfo parseDetourInfo(Object? decoded) {
  if (decoded is! Map) return DetourInfo.unknown;
  if (decoded['parsed'] != true) return DetourInfo.unknown;
  final Object? blockedRaw = decoded['blocked'];
  if (blockedRaw is! bool) return DetourInfo.unknown;
  final Object? sideRaw = decoded['open_side'];
  if (sideRaw is! String || !_sideByWire.containsKey(sideRaw)) {
    return DetourInfo.unknown;
  }
  return DetourInfo(
    blocked: blockedRaw,
    openSide: _sideByWire[sideRaw]!,
    parsed: true,
  );
}

/// The pinned detour prompt. The FC proxy pins the
/// same text server-side.
const String cloudDetourPrompt = '只输出一个 json 对象，不要输出任何其他文字：'
    '{"blocked": true或false, "open_side": 开放侧}。'
    'blocked 表示正前方通道是否被障碍物堵住。'
    '开放侧只能是：left、right、none、unknown。'
    '看不清或拿不准时，open_side 一律填 unknown。'
    '不要做任何通行判断，不要输出 json 以外的任何内容。';

/// Outcome of one detour call. Mirrors
/// [HazardScanOutcome].
class DetourScanOutcome {
  final DetourInfo? info;
  final CloudVisionFailure? failure;
  const DetourScanOutcome.ok(DetourInfo i)
      : info = i,
        failure = null;
  const DetourScanOutcome.failed(CloudVisionFailure f)
      : info = null,
        failure = f;
  bool get ok => failure == null && info != null;
}
