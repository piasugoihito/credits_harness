/// 授業開始のローカル通知(端末内で完結・サーバー不要)。
library;

import 'dart:io' show Platform;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../core/schedule.dart';

const _channel = AndroidNotificationChannel(
  'class_start',
  '授業開始',
  description: '授業開始の数分前に、何の授業かをお知らせします',
  importance: Importance.high,
);

class PermissionStatus {
  final bool notificationsEnabled;
  final bool exactAlarms;
  const PermissionStatus(this.notificationsEnabled, this.exactAlarms);
}

class Notifier {
  Notifier._();
  static final instance = Notifier._();

  final _plugin = FlutterLocalNotificationsPlugin();
  late final tz.Location jst;
  bool _initialized = false;
  void Function(String? payload)? onTap;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  Future<void> init() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    jst = tz.getLocation('Asia/Tokyo');
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (r) => onTap?.call(r.payload),
    );
    await _android?.createNotificationChannel(_channel);
    _initialized = true;
  }

  /// アプリが通知タップで起動された場合、その payload(科目番号)。
  Future<String?> launchPayload() async {
    final d = await _plugin.getNotificationAppLaunchDetails();
    return d?.didNotificationLaunchApp == true ? d?.notificationResponse?.payload : null;
  }

  tz.TZDateTime now() => tz.TZDateTime.now(jst);

  MacOSFlutterLocalNotificationsPlugin? get _macos =>
      _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();

  Future<PermissionStatus> status() async {
    // macOS: 正確なアラームの概念は無い(通知の許可だけ)
    if (Platform.isMacOS) return PermissionStatus((await _macos?.checkPermissions())?.isEnabled ?? false, true);
    if (!Platform.isAndroid) return const PermissionStatus(true, true);
    return PermissionStatus(
      await _android?.areNotificationsEnabled() ?? false,
      await _android?.canScheduleExactNotifications() ?? false,
    );
  }

  /// 通知の実行時権限(Android 13+)と正確なアラーム(Android 12+)を要求する。
  Future<PermissionStatus> requestPermissions({bool exactAlarms = true}) async {
    if (Platform.isAndroid) {
      await _android?.requestNotificationsPermission();
      if (exactAlarms && !(await _android?.canScheduleExactNotifications() ?? false)) {
        await _android?.requestExactAlarmsPermission();
      }
    } else if (Platform.isMacOS) {
      await _macos?.requestPermissions(alert: true, sound: true);
    } else {
      await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
        alert: true,
        sound: true,
      );
    }
    return status();
  }

  NotificationDetails get _details => NotificationDetails(
    android: AndroidNotificationDetails(
      _channel.id,
      _channel.name,
      channelDescription: _channel.description,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
    ),
    iOS: const DarwinNotificationDetails(),
    macOS: const DarwinNotificationDetails(),
  );

  Future<AndroidScheduleMode> _mode() async => (await _android?.canScheduleExactNotifications() ?? false)
      ? AndroidScheduleMode.exactAllowWhileIdle
      : AndroidScheduleMode.inexactAllowWhileIdle; // 正確なアラームが拒否されたら不正確で代替

  /// 常に「全キャンセル → 全登録」(冪等)。戻り値: 正確なアラームで登録できたか。
  Future<bool> applyPlan(List<PlannedNotification> plan) async {
    await _plugin.cancelAllPendingNotifications();
    final mode = await _mode();
    for (final n in plan) {
      await _plugin.zonedSchedule(
        id: n.id,
        scheduledDate: n.fireAt,
        notificationDetails: _details,
        androidScheduleMode: mode,
        title: n.title,
        body: n.body,
        payload: n.payload,
      );
    }
    return mode == AndroidScheduleMode.exactAllowWhileIdle;
  }

  Future<void> cancelAll() => _plugin.cancelAllPendingNotifications();

  Future<int> pendingCount() async => (await _plugin.pendingNotificationRequests()).length;

  /// 動作確認用: after 後に1件だけ予約する(既存の予約は消さない)。
  Future<tz.TZDateTime> scheduleTest(Duration after, {String title = 'テスト通知', String? body}) async {
    final at = now().add(after);
    await _plugin.zonedSchedule(
      id: 1,
      scheduledDate: at,
      notificationDetails: _details,
      androidScheduleMode: await _mode(),
      title: title,
      body: body ?? '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')} に予約した通知です',
      payload: 'TEST',
    );
    return at;
  }
}
