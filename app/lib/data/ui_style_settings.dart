import 'package:flutter/widgets.dart';

import 'local_database.dart';

/// 界面风格选项：plain（素雅纯色，默认，即原有浅粉白纸感背景）/
/// gradient（渐变粉蓝，与首屏/向导同款品牌渐变）。
const List<String> kUiStyleOptions = ['plain', 'gradient'];

/// 选项标签（自带双语，菜单当前值/弹窗直接用）。
const Map<String, String> kUiStyleLabels = {
  'plain': '素雅纯色 / Plain',
  'gradient': '渐变粉蓝 / Gradient',
};

/// 选项描述（一句话，弹窗中每张预览图下方展示）。
const Map<String, String> kUiStyleDescriptions = {
  'plain': '浅粉纯色背景，素净清爽 / Plain light-pink background, clean & calm',
  'gradient': '粉蓝渐变背景，与首屏/向导一致 / Pink-blue gradient matching the splash & setup screens',
};

/// 品牌粉蓝渐变（首屏/向导同款，聊天页 gradient 风格与预览图共用）。
const LinearGradient kBrandGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF3BAFFD), Color(0xFFD6529C)],
);

/// 界面风格切换通知：聊天页监听后即时重建（弹窗不关闭也能预览效果）。
final ValueNotifier<String> uiStyleNotifier = ValueNotifier<String>('plain');

/// 界面风格偏好设置（存本设备 app_state，key='ui_style'）。
class UiStyleSettings {
  UiStyleSettings(this.db);

  final LocalDatabase db;

  static const _kKey = 'ui_style';

  /// 当前界面风格（'plain'/'gradient'，默认 plain——保留原有视觉效果）。
  Future<String> load() async {
    final row = await (db.select(db.appState)..where((s) => s.key.equals(_kKey))).getSingleOrNull();
    final v = row?.value;
    return (v == null || !kUiStyleOptions.contains(v)) ? 'plain' : v;
  }

  /// 保存界面风格并通知即时生效。
  Future<void> save(String style) async {
    assert(kUiStyleOptions.contains(style), '非法界面风格: $style');
    await (db.into(db.appState))
        .insertOnConflictUpdate(AppStateCompanion.insert(key: _kKey, value: style));
    uiStyleNotifier.value = style;
  }
}
