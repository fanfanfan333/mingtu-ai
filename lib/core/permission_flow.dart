/// UI-A11Y S1 (UI-06): the all-voice permission flow as a
/// PURE state machine, plus every Chinese text it speaks.
///
/// The machine knows nothing about plugins, widgets or the
/// speech scheduler: it consumes outcomes and emits ordered
/// effects. The app layer (main.dart) executes the effects
/// in order -- speak through the SpeechScheduler (never a
/// semantics announcement), request through the
/// PermissionGateway seam, open the system settings through
/// the same seam -- and feeds results back. Every branch is
/// unit-tested against the literal texts below.
///
/// Step order is fixed: microphone -> foreground location
/// -> camera. The background-location / foreground-service
/// step exists in the model ONLY as a disabled seam
/// ([GuidePermission.backgroundLocationService]): it is
/// never part of the step list in this phase (ruling:
/// deferred), the gateway is never asked for it, and no
/// manifest permission backs it.
library;

/// One permission the flow can talk about.
enum GuidePermission {
  microphone,
  location,
  camera,

  /// DEFERRED seam (not a live step): background location /
  /// foreground service. Present so a later ruling can slot
  /// it in after [location] without reshaping the machine;
  /// [PermissionFlow.steps] never contains it in this
  /// phase, and the gateway maps its request to a plain
  /// denial WITHOUT touching the platform.
  backgroundLocationService,
}

/// The three outcomes the flow branches on. The gateway
/// maps every platform status onto exactly one of these.
enum PermissionOutcome {
  granted,
  denied,
  permanentlyDenied,
}

/// Speak [text] through the scheduler. [alert] marks the
/// denials: failure announcements use the scheduler's
/// alert level (they must be delivered); purposes and
/// confirmations use the default info level, so a danger
/// or emergency prompt always outranks onboarding speech.
class PermissionSpeakEffect {
  const PermissionSpeakEffect(this.text, {this.alert = false});

  final String text;
  final bool alert;

  @override
  bool operator ==(Object other) =>
      other is PermissionSpeakEffect &&
      other.text == text &&
      other.alert == alert;

  @override
  int get hashCode => Object.hash(text, alert);

  @override
  String toString() => 'speak($text)';
}

/// Ask the platform for [permission] (the system dialog).
class PermissionRequestEffect {
  const PermissionRequestEffect(this.permission);

  final GuidePermission permission;

  @override
  bool operator ==(Object other) =>
      other is PermissionRequestEffect && other.permission == permission;

  @override
  int get hashCode => permission.hashCode;

  @override
  String toString() => 'request(${permission.name})';
}

/// Open the system settings page; the flow then PAUSES
/// until the app returns to the foreground, when the
/// permission is re-checked and its result announced.
class PermissionOpenSettingsEffect {
  const PermissionOpenSettingsEffect(this.permission);

  final GuidePermission permission;

  @override
  bool operator ==(Object other) =>
      other is PermissionOpenSettingsEffect && other.permission == permission;

  @override
  int get hashCode => permission.hashCode;

  @override
  String toString() => 'settings(${permission.name})';
}

/// The flow has run out of steps; the app marks the
/// first-launch guide as seen when it executes this.
class PermissionFlowDoneEffect {
  const PermissionFlowDoneEffect();

  @override
  bool operator ==(Object other) => other is PermissionFlowDoneEffect;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'done';
}

/// The first-launch spoken guide: how to talk, how to
/// stop, what to do on a danger prompt, and how to hear
/// this again (the voice command for help replays it).
const String firstLaunchGuideText =
    '欢迎使用明途。说话的方法：按住屏幕下方的大按钮，说完松开；'
    '开着读屏软件时，双击按钮开始说话，再双击一次结束。'
    '走路时听到危险提醒，先停下脚步，再听说明。'
    '想再听这段说明，任何时候说一声帮助就可以。';

/// Purpose announcement per permission: what is needed
/// and what it is for, spoken BEFORE the system dialog.
String permissionPurposeText(GuidePermission permission) {
  switch (permission) {
    case GuidePermission.microphone:
      return '先问麦克风。明途要用麦克风听你说话，'
          '你按住按钮说的话才能变成命令。接下来系统会弹出询问，请点允许。';
    case GuidePermission.location:
      return '再问位置。明途要用你的位置来导航，'
          '告诉你往哪走、还有多远。接下来系统会弹出询问，请点允许。';
    case GuidePermission.camera:
      return '最后问摄像头。明途要用摄像头看前面的路，'
          '提醒你车辆、行人和障碍物。接下来系统会弹出询问，请点允许。';
    case GuidePermission.backgroundLocationService:
      // Unreachable: the deferred step is never announced.
      return '';
  }
}

/// Short confirmation when a permission is granted.
String permissionGrantedText(GuidePermission permission) {
  switch (permission) {
    case GuidePermission.microphone:
      return '麦克风已打开。';
    case GuidePermission.location:
      return '位置已打开。';
    case GuidePermission.camera:
      return '摄像头已打开。';
    case GuidePermission.backgroundLocationService:
      return '';
  }
}

/// Impact announcement for a plain denial (the user can
/// still grant it later from the system settings).
String permissionDeniedText(GuidePermission permission) {
  switch (permission) {
    case GuidePermission.microphone:
      return '麦克风没有打开，明途听不到你说话，按住说话用不了。'
          '之后想用，可以去系统设置里打开。';
    case GuidePermission.location:
      return '位置没有打开，明途不能导航，也报不了你走到了哪里。'
          '之后想用，可以去系统设置里打开。';
    case GuidePermission.camera:
      return '摄像头没有打开，明途看不到前面的路，不能提醒障碍。'
          '之后想用，可以去系统设置里打开。';
    case GuidePermission.backgroundLocationService:
      return '';
  }
}

/// Impact + settings guidance for a permanent denial:
/// spoken right before the settings page opens.
String permissionPermanentlyDeniedText(GuidePermission permission) {
  switch (permission) {
    case GuidePermission.microphone:
      return '麦克风被设为不再询问，明途听不到你说话。'
          '我现在帮你打开系统设置，请找到明途，把麦克风权限打开，再回到明途。';
    case GuidePermission.location:
      return '位置被设为不再询问，明途不能导航。'
          '我现在帮你打开系统设置，请找到明途，把位置权限打开，再回到明途。';
    case GuidePermission.camera:
      return '摄像头被设为不再询问，明途不能提醒障碍。'
          '我现在帮你打开系统设置，请找到明途，把摄像头权限打开，再回到明途。';
    case GuidePermission.backgroundLocationService:
      return '';
  }
}

/// Recheck result after returning from the settings page:
/// the permission is on now.
String permissionRecheckGrantedText(GuidePermission permission) {
  switch (permission) {
    case GuidePermission.microphone:
      return '麦克风已经打开了。';
    case GuidePermission.location:
      return '位置已经打开了。';
    case GuidePermission.camera:
      return '摄像头已经打开了。';
    case GuidePermission.backgroundLocationService:
      return '';
  }
}

/// Recheck result after returning from the settings page:
/// still off; the flow moves on (it never loops back into
/// the settings for the same step in one run).
String permissionRecheckDeniedText(GuidePermission permission) {
  switch (permission) {
    case GuidePermission.microphone:
      return '麦克风还是没有打开，按住说话用不了。之后可以在系统设置里打开。';
    case GuidePermission.location:
      return '位置还是没有打开，明途不能导航。之后可以在系统设置里打开。';
    case GuidePermission.camera:
      return '摄像头还是没有打开，明途不能提醒障碍。之后可以在系统设置里打开。';
    case GuidePermission.backgroundLocationService:
      return '';
  }
}

/// Closing line when every step has been visited.
const String permissionFlowEndText = '权限问完了。想再听使用说明，说一声帮助就可以。';

/// The seam the app uses to talk to the platform's
/// permission system. The production implementation wraps
/// the permission_handler plugin; tests substitute fakes.
/// No implementation may request
/// [GuidePermission.backgroundLocationService] from the
/// platform in this phase.
abstract class PermissionGateway {
  /// False when this platform has no permission system to
  /// talk to (web / VM): the flow then never starts, which
  /// is the honest off-device behaviour.
  bool get isAvailable;

  /// Show the system request for [permission] and report
  /// the outcome the user chose.
  Future<PermissionOutcome> request(GuidePermission permission);

  /// Read the current status without asking.
  Future<PermissionOutcome> status(GuidePermission permission);

  /// Open this app's system settings page.
  Future<void> openSettings();
}

/// Persistence seam for the first-launch marker (the guide
/// + permission flow runs exactly once, on first launch).
/// Implementations that cannot persist answer
/// [hasSeenGuide] == true: without storage there is no
/// honest way to know this is a first launch, and guessing
/// "first" would re-run onboarding on every start.
abstract class GuideStore {
  Future<bool> hasSeenGuide();
  Future<void> markGuideSeen();
}

/// The flow itself. Usage:
///
///   final flow = PermissionFlow();
///   execute(flow.start());
///   // on a PermissionRequestEffect's answer:
///   execute(flow.onRequestResult(step, outcome));
///   // after the app resumes from the settings page:
///   execute(flow.onSettingsReturn(step, await gateway.status(step)));
///
/// The machine is single-run: every method validates its
/// expected state and throws StateError on misuse, so a
/// wiring bug fails loudly in tests instead of silently
/// skipping announcements.
class PermissionFlow {
  PermissionFlow();

  /// The steps this phase actually walks, in order. The
  /// deferred background step is NOT here (ruling:
  /// deferred); see [GuidePermission.backgroundLocationService].
  static const List<GuidePermission> steps = <GuidePermission>[
    GuidePermission.microphone,
    GuidePermission.location,
    GuidePermission.camera,
  ];

  int _index = -1;
  bool _started = false;
  bool _done = false;
  GuidePermission? _awaitingSettingsFor;

  bool get isDone => _done;

  /// The step the flow is paused on while the user is in
  /// the system settings, or null.
  GuidePermission? get awaitingSettingsFor => _awaitingSettingsFor;

  /// The step currently being processed, if any.
  GuidePermission? get currentStep =>
      (_index >= 0 && _index < steps.length) ? steps[_index] : null;

  List<Object> start() {
    if (_started) {
      throw StateError('PermissionFlow.start called twice');
    }
    _started = true;
    _index = 0;
    return _purposeEffects(steps[_index]);
  }

  /// The platform answered the request for [permission].
  List<Object> onRequestResult(
      GuidePermission permission, PermissionOutcome outcome) {
    _expectStep(permission, 'onRequestResult');
    switch (outcome) {
      case PermissionOutcome.granted:
        return <Object>[
          PermissionSpeakEffect(permissionGrantedText(permission)),
          ..._advance(),
        ];
      case PermissionOutcome.denied:
        return <Object>[
          PermissionSpeakEffect(permissionDeniedText(permission),
              alert: true),
          ..._advance(),
        ];
      case PermissionOutcome.permanentlyDenied:
        _awaitingSettingsFor = permission;
        return <Object>[
          PermissionSpeakEffect(
              permissionPermanentlyDeniedText(permission),
              alert: true),
          PermissionOpenSettingsEffect(permission),
        ];
    }
  }

  /// The app came back to the foreground and [permission]
  /// was re-checked with outcome [outcome].
  List<Object> onSettingsReturn(
      GuidePermission permission, PermissionOutcome outcome) {
    if (_awaitingSettingsFor != permission) {
      throw StateError(
          'onSettingsReturn for $permission while awaiting $_awaitingSettingsFor');
    }
    _awaitingSettingsFor = null;
    if (outcome == PermissionOutcome.granted) {
      return <Object>[
        PermissionSpeakEffect(permissionRecheckGrantedText(permission)),
        ..._advance(),
      ];
    }
    return <Object>[
      PermissionSpeakEffect(permissionRecheckDeniedText(permission),
          alert: true),
      ..._advance(),
    ];
  }

  List<Object> _purposeEffects(GuidePermission step) {
    return <Object>[
      PermissionSpeakEffect(permissionPurposeText(step)),
      PermissionRequestEffect(step),
    ];
  }

  /// Move to the next step (its purpose + request), or end
  /// the flow with the closing line.
  List<Object> _advance() {
    _index++;
    if (_index >= steps.length) {
      _done = true;
      return const <Object>[
        PermissionSpeakEffect(permissionFlowEndText),
        PermissionFlowDoneEffect(),
      ];
    }
    return _purposeEffects(steps[_index]);
  }

  void _expectStep(GuidePermission permission, String where) {
    if (!_started || _done || currentStep != permission) {
      throw StateError(
          '$where for $permission while current step is $currentStep');
    }
    if (_awaitingSettingsFor != null) {
      throw StateError('$where while awaiting settings return');
    }
  }
}
