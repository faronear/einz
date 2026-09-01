// BurnAfterSettings 单测：本设备阅后即焚设置存取（app_state key-value）。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/data/burn_after_settings.dart';
import 'package:einz/data/local_database.dart';

void main() {
  late LocalDatabase db;
  late BurnAfterSettings settings;

  setUp(() async {
    db = LocalDatabase.forTesting(NativeDatabase.memory());
    settings = BurnAfterSettings(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('默认 0 = 无限（不删除）', () async {
    expect(await settings.load(), 0);
  });

  test('save/load 往返：档位秒数', () async {
    await settings.save(300); // 5 分钟
    expect(await settings.load(), 300);

    await settings.save(86400); // 1 天
    expect(await settings.load(), 86400);
  });

  test('保存 0 关闭阅后即焚', () async {
    await settings.save(60);
    expect(await settings.load(), 60);
    await settings.save(0);
    expect(await settings.load(), 0);
  });
}
