/// Emergency help for Mingtu AI v0.1.
///
/// This module is LOCAL by design and must work without the LLM and
/// without network. It does NOT claim to have contacted any help station:
/// v0.1 has no verified help-station directory and no real calling
/// mechanism, so [EmergencyResult.contactClaimed] is always false and
/// the user must be told the true status, with fallback options.
class EmergencyResult {
  final bool localTaskCreated;
  final bool contactClaimed; // always false in v0.1
  final String statusText;
  final List<String> fallbackOptions;
  const EmergencyResult({
    required this.localTaskCreated,
    required this.contactClaimed,
    required this.statusText,
    required this.fallbackOptions,
  });
}

class EmergencyService {
  EmergencyResult trigger({
    required String triggerType,
    double? latitude,
    double? longitude,
    double? locationAccuracyM,
    bool networkAvailable = false,
    bool llmAvailable = false,
  }) {
    // networkAvailable / llmAvailable are accepted only to document that
    // they are NOT required; the local flow below does not use them.
    final locationText = (latitude != null && longitude != null)
        ? '已记录当前位置（精度约 ${locationAccuracyM?.toStringAsFixed(0) ?? '未知'} 米）。'
        : '当前无法确认位置，请口头说明你所在的位置。';
    return EmergencyResult(
      localTaskCreated: true,
      contactClaimed: false,
      statusText:
          '已进入紧急求助流程，普通导航已暂停。$locationText尚未确认联系到任何帮助站，请不要等待，先使用你熟悉的求助方式。',
      fallbackOptions: const [
        '请大声呼喊附近人员协助',
        '请拨打你已保存的紧急联系人电话',
        '请停留在原地，不要继续按旧指令行走',
      ],
    );
  }
}
