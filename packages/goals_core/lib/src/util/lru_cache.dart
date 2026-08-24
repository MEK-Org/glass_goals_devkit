import 'package:sortedmap/sortedmap.dart' show Ordering, SortedMap;

class LruCache<K extends Comparable, V> {
  final Map<K, V> _map = {};
  final SortedMap<K, int> expiries = SortedMap(Ordering.byValue());

  /// The size after which the cache will start evicting items that are older
  /// than max age.
  final int cullingThreshold;
  final Duration maxAge;

  LruCache({required this.cullingThreshold, required this.maxAge});

  V? get(K key) {
    V? mapValue = _map[key];
    if (mapValue != null) {
      expiries.remove(key);
      expiries[key] =
          DateTime.now().millisecondsSinceEpoch + maxAge.inMilliseconds;
      return mapValue;
    }
    expiries.remove(key);
    this._doCulling();
    return null;
  }

  operator [](K key) {
    return get(key);
  }

  void operator []=(K key, V value) {
    put(key, value);
  }

  void put(K key, V value) {
    _map[key] = value;
    expiries[key] =
        DateTime.now().millisecondsSinceEpoch + maxAge.inMilliseconds;
    this._doCulling();
  }

  void _doCulling() {
    if (expiries.length > cullingThreshold) {
      final mapKeys = [...expiries.keys];
      for (K key in mapKeys) {
        if (expiries[key]! < DateTime.now().millisecondsSinceEpoch) {
          _map.remove(key);
          expiries.remove(key);
        } else {
          break;
        }
      }
    }
  }

  void clear() {
    _map.clear();
    expiries.clear();
  }
}
