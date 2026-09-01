import 'package:flutter/widgets.dart';

import 'local_database.dart';

/// 语言偏好选项：system（跟随系统，默认）/ zh / en。
const List<String> kLocaleOptions = ['system', 'zh', 'en'];

/// 选项标签（自带双语，切换菜单直接用）。
const Map<String, String> kLocaleLabels = {
  'system': '跟随系统 / System',
  'zh': '中文',
  'en': 'English',
};

/// 语言切换通知：EinzApp 监听后重建 MaterialApp（即时生效）。
final ValueNotifier<String> localeNotifier = ValueNotifier<String>('system');

/// 语言偏好设置（存本设备 app_state，key='locale'）。
class LocaleSettings {
  LocaleSettings(this.db);

  final LocalDatabase db;

  static const _kKey = 'locale';

  /// 当前语言偏好（'system'/'zh'/'en'，默认 system）。
  Future<String> load() async {
    final row = await (db.select(db.appState)..where((s) => s.key.equals(_kKey))).getSingleOrNull();
    final v = row?.value;
    return (v == null || !kLocaleOptions.contains(v)) ? 'system' : v;
  }

  /// 保存语言偏好并通知重建。
  Future<void> save(String locale) async {
    assert(kLocaleOptions.contains(locale), '非法语言偏好: $locale');
    await (db.into(db.appState))
        .insertOnConflictUpdate(AppStateCompanion.insert(key: _kKey, value: locale));
    localeNotifier.value = locale;
  }

  /// 解析实际 Locale：手动选择优先；system 按系统语言映射（zh → zh，其他 → en）。
  Locale resolve(String pref, Locale systemLocale) {
    if (pref == 'zh') return const Locale('zh');
    if (pref == 'en') return const Locale('en');
    return systemLocale.languageCode.startsWith('zh') ? const Locale('zh') : const Locale('en');
  }
}
