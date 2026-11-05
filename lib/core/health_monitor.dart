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
  String announcementText() {
    final problems = _services.values
        .where((s) =>
            s.status == ServiceHealthStatus.unavailable ||
            s.status == ServiceHealthStatus.degraded)
        .toList();
    if (problems.isEmpty) return '';
    final names = problems.map((s) => s.service).join('、');
    return '注意：$names 当前不可用或性能下降，相关提示可能不准确，'
        '请谨慎行动，必要时寻求帮助。';
  }
}
