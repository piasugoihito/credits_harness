/// 表示用の書式。
library;

String formatUpdatedAt(DateTime? t) {
  if (t == null) return '未取得';
  final now = DateTime.now();
  final d = now.difference(t);
  final hm = '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
  if (d.inMinutes < 1) return 'たった今';
  if (d.inHours < 1) return '${d.inMinutes}分前';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return '今日 $hm';
  return '${t.month}/${t.day} $hm';
}
