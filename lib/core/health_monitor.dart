/// System health monitoring and fail-degradation for Mingtu AI.
///
/// Per spec section 15: a failed camera must not keep feeding old
/// frames into new step instructions, a failed location must not be
/// presented as a known position, and a failed model API must not
/// disable local emergency handling or local risk rules. This monitor
/// only records health and produces the honest voice announcement
/// text; it never invents a healthy status for an unwired service.
library;

import 'contracts.dart';

class HealthMonitor {
  final Map<String, ServiceHealth> _services = {};

  void report(
    String service,
    ServiceHealthStatus status,
    String detail, {
    DateTime? at,
  }) {
    _services[service] = ServiceHealth(
      service: service,
      status: status,
      detail: detail,
      updatedAt: at ?? DateTime.now(),
    );
  }

  ServiceHealth? get(String service) => _services[service];

  Map<String, ServiceHealth> get all => Map.unmodifiable(_services);

  List<ServiceHealth> get unavailable => _services.values
      .where((s) => s.status == ServiceHealthStatus.unavailable)
      .toList();

  List<ServiceHealth> get degraded => _services.values
      .where((s) => s.status == ServiceHealthStatus.degraded)
      .toList();

  bool get hasCriticalFailure => unavailable.any(
        (s) => s.service == 'voice_output' || s.service == 'location',
      );

  /// Voice announcement for degraded services. Empty when nothing is
  /// reported degraded/unavailable, so callers never announce a
  /// problem that does not exist.
  ///
  /// v0.7: service names are spoken in Chinese. Before this fix the
  /// announcement read out the English identifiers
  /// (map_navigation, voice_output, ...) to a blind user.
  static String chineseServiceName(String service) {
    switch (service) {
      case 'map_navigation':
        return '地图导航';
      case 'voice_output':
        return '语音播报';
      case 'voice_input':
        return '语音识别';
      case 'camera':
        return '摄像头';
      case 'location':
        return '定位';
      case 'emergency':
        return '紧急求助';
      case 'llm':
        return '云端模型';
      case 'cloud_vision':
        return '云端视觉辅助';
      default:
        return '一项服务';
    }
  }

  String announcementText() {
    final problems = _services.values
        .where((s) =>
            s.status == ServiceHealthStatus.unavailable ||
            s.status == ServiceHealthStatus.degraded)
        .toList();
    if (problems.isEmpty) return '';
    final names =
        problems.map((s) => chineseServiceName(s.service)).join('、');
    return '注意：$names 当前不可用或性能下降，相关提示可能不准确，'
        '请谨慎行动，必要时寻求帮助。';
  }
}
