/// Indoor task for Mingtu AI v0.1: ONE campus library scene only.
///
/// Steps advance ONLY when verification evidence is supplied. A step is
/// never marked complete just because its prompt was spoken, and the
/// task is never marked complete just because the flow reached the end.
/// Hospital / station / other scenes are NOT in this file.
enum LibraryStep { locateServiceDesk, readSign, confirmArrival }

class IndoorTask {
  final List<LibraryStep> steps = const [
    LibraryStep.locateServiceDesk,
    LibraryStep.readSign,
    LibraryStep.confirmArrival,
  ];
  int _index = 0;
  bool _completed = false;
  final List<LibraryStep> verifiedSteps = [];

  LibraryStep? get currentStep => _completed ? null : steps[_index];
  bool get isCompleted => _completed;
  int get currentIndex => _index;

  /// Advance only with verification. Returns false (and does not advance)
  /// if [verified] is false or the task is already complete.
  bool tryAdvance({required bool verified, String? evidence}) {
    if (_completed || !verified) return false;
    verifiedSteps.add(steps[_index]);
    _index += 1;
    if (_index >= steps.length) _completed = true;
    return true;
  }

  void reset() {
    _index = 0;
    _completed = false;
    verifiedSteps.clear();
  }
}
