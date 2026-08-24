abstract class SyncEventLogger {
  void log(String message, {String? opId, String? goalId});
}

class MemoryEventLogger implements SyncEventLogger {
  final Map<String, List<String>> _opEvents = {};

  final Map<String, List<String>> _goalEvents = {};

  final List<String> _events = [];

  @override
  void log(String message, {String? opId, String? goalId}) {
    if (opId != null || goalId != null) {
      _events.add('[${opId ?? goalId}] $message');
    } else {
      _events.add(message);
    }
    if (opId != null) {
      _opEvents.putIfAbsent(opId, () => []).add(message);
    }
    if (goalId != null) {
      _goalEvents.putIfAbsent(goalId, () => []).add(message);
    }
  }
}
