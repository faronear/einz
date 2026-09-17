import 'package:flutter/widgets.dart';

import 'local_database.dart';

/// 界面风格选项：plain（素雅纯色，默认，即原有浅粉白纸感背景）/
/// gradient（渐变粉蓝，与首屏/向导同款品牌渐变）。
const List<String> kUiStyleOptions = ['plain', 'gradient'];

/// 品牌粉蓝渐变（首屏/向导同款，聊天页 gradient 风格与预览图共用）。
const LinearGradient kBrandGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF3BAFFD), Color(0xFFD6529C)],
);

/// 界面风格切换通知：聊天页监听后即时重建（点选即切换，弹窗随即关闭）。
final ValueNotifier<String> uiStyleNotifier = ValueNotifier<String>('gradient');

/// 界面风格偏好设置（存本设备 app_state，key='ui_style'）。
class UiStyleSettings {
  UiStyleSettings(this.db);

  final LocalDatabase db;

  static const _kKey = 'ui_style';

  /// 当前界面风格（'plain'/'gradient'，默认 gradient——首次进入聊天即粉蓝渐变，
  /// 老板要求 2026-09-17；已保存过偏好的设备沿用其选择）。
  Future<String> load() async {
    final row = await (db.select(db.appState)..where((s) => s.key.equals(_kKey))).getSingleOrNull();
    final v = row?.value;
    return (v == null || !kUiStyleOptions.contains(v)) ? 'gradient' : v;
  }

  /// 保存界面风格并通知即时生效。
  Future<void> save(String style) async {
    assert(kUiStyleOptions.contains(style), '非法界面风格: $style');
    await (db.into(db.appState))
        .insertOnConflictUpdate(AppStateCompanion.insert(key: _kKey, value: style));
    uiStyleNotifier.value = style;
  }
}
