import 'package:credits_harness/core/assignment_groups.dart';
import 'package:credits_harness/core/models.dart';
import 'package:credits_harness/core/url_guard.dart';
import 'package:flutter_test/flutter_test.dart';

Assignment _a(String id, String? due) =>
    Assignment(id: id, type: '', title: id, url: '', course: '', courseUrl: '', due: due);

void main() {
  group('課題のグループ分け', () {
    // 2030-06-10 12:00 JST
    final now = DateTime.utc(2030, 6, 10, 3);

    test('期限切れ / 24時間以内 / それ以降 / 期限なし', () {
      final g = groupAssignments([
        _a('none', null),
        _a('later', '2030-06-11 12:01'),
        _a('soon', '2030-06-11 12:00'),
        _a('past', '2030-06-10 11:59'),
        _a('now', '2030-06-10 12:00'),
      ], now);
      expect(g.keys, [DueGroup.overdue, DueGroup.within24h, DueGroup.later, DueGroup.noDue]);
      expect(g[DueGroup.overdue]!.map((a) => a.id), ['past', 'now']);
      expect(g[DueGroup.within24h]!.map((a) => a.id), ['soon']);
      expect(g[DueGroup.later]!.map((a) => a.id), ['later']);
    });

    test('相対表示', () {
      expect(relativeDueLabel(_a('x', '2030-06-10 15:30'), now), 'あと3時間');
      expect(relativeDueLabel(_a('x', '2030-06-08 12:00'), now), '2日前に終了');
      expect(relativeDueLabel(_a('x', null), now), '期限なし');
    });

    test('不正な日時は期限なし扱い', () {
      expect(dueGroupOf(_a('x', '2030/06/10'), now), DueGroup.noDue);
    });
  });

  group('許可ドメイン', () {
    test('tsukuba.ac.jp とサブドメインの https のみ', () {
      expect(isAllowedUrl(Uri.parse('https://twins.tsukuba.ac.jp/campusweb/')), isTrue);
      expect(isAllowedUrl(Uri.parse('https://manaba.tsukuba.ac.jp/ct/home')), isTrue);
      expect(isAllowedUrl(Uri.parse('https://TSUKUBA.AC.JP/')), isTrue);
      expect(isAllowedUrl(Uri.parse('http://twins.tsukuba.ac.jp/')), isFalse);
      expect(isAllowedUrl(Uri.parse('https://twins.tsukuba.ac.jp.evil.com/')), isFalse);
      expect(isAllowedUrl(Uri.parse('https://eviltsukuba.ac.jp/')), isFalse);
      expect(isAllowedUrl(Uri.parse('about:blank')), isFalse);
      expect(isAllowedUrl(null), isFalse);
    });

    test('禁止操作のシグネチャ', () {
      expect(forbiddenAction.hasMatch("DeleteCallA('2026','25','X','1','1')"), isTrue);
      expect(forbiddenAction.hasMatch("InputCallA('1','1')"), isTrue);
      expect(forbiddenAction.hasMatch('campussquare.do?_eventId=search'), isFalse);
    });
  });
}
