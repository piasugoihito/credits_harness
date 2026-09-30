/// ドメインモデル(純Dart)。DB・UI・パーサーで共通に使う。
library;

const weekdayLabels = {1: '月', 2: '火', 3: '水', 4: '木', 5: '金', 6: '土', 7: '日'};

/// TWINS の時間割の1コマ。day は 1=月..7=日、period は 1..6。
class Slot {
  final String year;
  final String code;
  final String name;
  final String teacher;
  final int day;
  final int period;

  const Slot({
    required this.year,
    required this.code,
    required this.name,
    required this.teacher,
    required this.day,
    required this.period,
  });

  /// Python PoC の出力と同じ形(ゴールデンテスト・保存用)。
  Map<String, Object?> toJson() => {
    'day': weekdayLabels[day] ?? '$day',
    'day_index': day,
    'period': period,
    'code': code,
    'name': name,
    'teacher': teacher,
    'year': year,
  };

  factory Slot.fromJson(Map<String, Object?> j) => Slot(
    year: j['year'] as String? ?? '',
    code: j['code'] as String,
    name: j['name'] as String? ?? '',
    teacher: j['teacher'] as String? ?? '',
    day: j['day_index'] as int,
    period: j['period'] as int,
  );

  @override
  bool operator ==(Object other) =>
      other is Slot &&
      other.year == year &&
      other.code == code &&
      other.name == name &&
      other.teacher == teacher &&
      other.day == day &&
      other.period == period;

  @override
  int get hashCode => Object.hash(year, code, name, teacher, day, period);

  @override
  String toString() => 'Slot($code $name ${weekdayLabels[day]}$period)';
}

/// TWINS の学期タブ。
class TabInfo {
  final String label;
  final bool selected;
  const TabInfo(this.label, this.selected);

  Map<String, Object?> toJson() => {'label': label, 'selected': selected};
}

/// manaba の未提出課題。start/due は "yyyy-MM-dd HH:mm"(JST)。due==null は期限なし。
class Assignment {
  final String id;
  final String type;
  final String title;
  final String url;
  final String course;
  final String courseUrl;
  final String? start;
  final String? due;

  const Assignment({
    required this.id,
    required this.type,
    required this.title,
    required this.url,
    required this.course,
    required this.courseUrl,
    this.start,
    this.due,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    'title': title,
    'url': url,
    'course': course,
    'course_url': courseUrl,
    'start': start,
    'due': due,
  };

  factory Assignment.fromJson(Map<String, Object?> j) => Assignment(
    id: j['id'] as String,
    type: j['type'] as String? ?? '',
    title: j['title'] as String? ?? '',
    url: j['url'] as String? ?? '',
    course: j['course'] as String? ?? '',
    courseUrl: j['course_url'] as String? ?? '',
    start: j['start'] as String?,
    due: j['due'] as String?,
  );
}

/// KdB から取得したシラバス。
class Syllabus {
  final String code;
  final String name;
  final String url;
  final DateTime fetchedAt;
  final String text;
  final Map<String, String> sections;

  const Syllabus({
    required this.code,
    required this.name,
    required this.url,
    required this.fetchedAt,
    required this.text,
    required this.sections,
  });
}
