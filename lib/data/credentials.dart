/// 学籍番号・パスワード(Android Keystore / iOS Keychain)と自動ログイン失敗フラグ。
///
/// 値をログ・例外メッセージ・toString に含めないこと。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Credentials {
  final String user;
  final String password;
  const Credentials(this.user, this.password);

  @override
  String toString() => 'Credentials(***)';
}

class CredentialStore {
  static const _kUser = 'twins_user';
  static const _kPass = 'twins_password';
  static const _kAutofillFailed = 'autofill_failed';

  final FlutterSecureStorage _secure;
  CredentialStore([FlutterSecureStorage? secure])
    : _secure =
          secure ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
          );

  Future<Credentials?> read() async {
    final u = await _secure.read(key: _kUser);
    final p = await _secure.read(key: _kPass);
    if (u == null || u.isEmpty || p == null || p.isEmpty) return null;
    return Credentials(u, p);
  }

  /// 保存すると自動ログイン失敗フラグも解除する(FR-2: 資格情報の更新で1回だけ再試行)。
  Future<void> save(Credentials c) async {
    await _secure.write(key: _kUser, value: c.user);
    await _secure.write(key: _kPass, value: c.password);
    await clearAutofillFailed();
  }

  Future<void> delete() async {
    await _secure.delete(key: _kUser);
    await _secure.delete(key: _kPass);
  }

  Future<bool> autofillFailed() async => (await SharedPreferences.getInstance()).getBool(_kAutofillFailed) ?? false;

  Future<void> setAutofillFailed() async => (await SharedPreferences.getInstance()).setBool(_kAutofillFailed, true);

  Future<void> clearAutofillFailed() async => (await SharedPreferences.getInstance()).remove(_kAutofillFailed);
}
