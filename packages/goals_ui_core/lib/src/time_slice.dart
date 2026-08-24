import 'package:goals_core/util.dart' show DateTimeExtension;

enum TimeSlice {
  today(null, "Today", 0),
  this_week(TimeSlice.today, "This Week", 1),
  this_month(TimeSlice.this_week, "This Month", 2),
  this_quarter(TimeSlice.this_month, "This Quarter", 3),
  this_year(TimeSlice.this_quarter, "This Year", 4),
  long_term(TimeSlice.this_year, "Long Term", 5),
  unscheduled(null, "Inbox", -1);

  const TimeSlice(this.zoomDown, this.displayName, this.sortOrder);

  final TimeSlice? zoomDown;
  final String displayName;
  final int sortOrder;

  DateTime? startTime(DateTime now) {
    switch (this) {
      case TimeSlice.today:
        return now.startOfDay;
      case TimeSlice.this_week:
        return now.startOfWeek;
      case TimeSlice.this_month:
        return now.startOfMonth;
      case TimeSlice.this_quarter:
        return now.startOfQuarter;
      case TimeSlice.this_year:
        return now.startOfYear;
      case TimeSlice.long_term:
      case TimeSlice.unscheduled:
        return null;
    }
  }

  DateTime? endTime(DateTime now) {
    switch (this) {
      case TimeSlice.today:
        return now.endOfDay;
      case TimeSlice.this_week:
        return now.endOfWeek;
      case TimeSlice.this_month:
        return now.endOfMonth;
      case TimeSlice.this_quarter:
        return now.endOfQuarter;
      case TimeSlice.this_year:
        return now.endOfYear;
      case TimeSlice.long_term:
      case TimeSlice.unscheduled:
        return null;
    }
  }
}
