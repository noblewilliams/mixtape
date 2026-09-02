import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

bool _initialized = false;

/// Loads the IANA database once per isolate.
void ensureTimeZonesInitialized() {
  if (_initialized) return;
  tzdata.initializeTimeZones();
  _initialized = true;
}

/// A wall-clock day (`YYYY-MM-DD`) and hour (0-23) in the option zone.
class LocalTime {
  const LocalTime(this.day, this.hour);

  final String day;
  final int hour;

  @override
  bool operator ==(Object other) => other is LocalTime && other.day == day && other.hour == hour;

  @override
  int get hashCode => Object.hash(day, hour);

  @override
  String toString() => 'LocalTime($day, $hour)';
}

/// Converts UTC instants to local day and hour in one IANA zone.
///
/// Exact conversion is normative. Per UTC hour, the zone offset is cached only
/// when it is the same at the start and at the end of that hour; an hour that
/// contains a transition converts every instant in it exactly, which matters
/// in half-hour zones such as America/St_Johns.
class ZoneClock {
  ZoneClock(this.timeZone) : _location = _locate(timeZone);

  static const int _hourMs = 3600000;

  static tz.Location _locate(String timeZone) {
    ensureTimeZonesInitialized();
    return tz.getLocation(timeZone);
  }

  final String timeZone;
  final tz.Location _location;

  /// UTC hour start -> offset in ms, or null when that hour must convert exactly.
  final Map<int, int?> _hours = {};

  LocalTime local(int utcMs) {
    final hourStart = utcMs - (utcMs % _hourMs);
    int? offset;
    if (_hours.containsKey(hourStart)) {
      offset = _hours[hourStart];
    } else {
      final start = _offsetAt(hourStart);
      offset = start == _offsetAt(hourStart + _hourMs) ? start : null;
      _hours[hourStart] = offset;
    }
    if (offset != null) {
      final wall = DateTime.fromMillisecondsSinceEpoch(utcMs + offset, isUtc: true);
      return LocalTime(_day(wall.year, wall.month, wall.day), wall.hour);
    }
    final wall = tz.TZDateTime.from(
      DateTime.fromMillisecondsSinceEpoch(utcMs, isUtc: true),
      _location,
    );
    return LocalTime(_day(wall.year, wall.month, wall.day), wall.hour);
  }

  int _offsetAt(int utcMs) => _location.timeZone(utcMs).offset;

  static String _day(int year, int month, int day) =>
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
}
