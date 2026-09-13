// 设备存储：成员名称/性别缓存落盘往返（离线启动兜底配色用）。
//
// 老板 2026-09-13：服务器离线启动时 TUI 仍要按性别配色，不能全回退青绿——
// 因此 GET /space 的 person_names/person_genders 要落盘、启动时读回。
import 'dart:io';

import 'package:test/test.dart';

import 'package:einz_cli/store.dart';

void main() {
  test('personNames/personGenders 落盘后可读回', () {
    final dir = Directory.systemTemp.createTempSync('einz-store-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/s.json';

    final st = DeviceStore(publicKey: 'pk', privateKey: 'sk')
      ..personNames = {'personA': 'Lukas', 'personB': 'Alice'}
      ..personGenders = {'personA': 'male', 'personB': 'female'};
    st.save(path);

    final loaded = DeviceStore.load(path);
    expect(loaded.personNames, {'personA': 'Lukas', 'personB': 'Alice'});
    expect(loaded.personGenders, {'personA': 'male', 'personB': 'female'});
  });

  test('旧 store 缺缓存字段时按空表处理（不崩）', () {
    final dir = Directory.systemTemp.createTempSync('einz-store-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/old.json';
    File(path).writeAsStringSync('{"public_key":"pk","private_key":"sk"}');

    final loaded = DeviceStore.load(path);
    expect(loaded.personNames, isEmpty);
    expect(loaded.personGenders, isEmpty);
  });
}
