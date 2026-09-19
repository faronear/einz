import 'package:einz/data/server_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // kPrimaryServer 身兼三职（候选之首 / 全不通兜底 / 编译期覆盖的默认值与判定参照），
  // 而候选列表可以随时插新域名——这条断言守住"加了备用域名却忘了同步主域名"的漂移。
  test('候选列表第一项必须就是主域名', () {
    expect(kServerCandidates, isNotEmpty);
    expect(kServerCandidates.first, kPrimaryServer);
    expect(kServerCandidates.first, startsWith('http'));
  });
}
