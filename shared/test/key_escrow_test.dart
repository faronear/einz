// KeyEscrowService 单测：口令加密 Space Key 包往返、错误口令失败、字段一致性。
//
// 需要 LIBSODIUM_PATH 指向 libsodium.dll（与 shared 单测一致）。

import 'package:einz_shared/einz_shared.dart';
import 'package:test/test.dart';

/// 假 ApiClient（不真正联网）测 KeyEscrowService 的纯加密逻辑；
/// HTTP 端点已由 server 冒烟测试覆盖（smoke.test.ts §11）。
class FakeApi extends ApiClient {
  FakeApi() : super('http://fake');
  BackupFile? stored;
  bool deleted = false;

  @override
  Future<void> uploadKeyEscrow(BackupFile package, String token, {String? passphraseHash}) async {
    stored = package;
  }

  @override
  Future<({BackupFile? file, int? updatedAt})> getKeyEscrow(String token) async =>
      (file: stored, updatedAt: null);

  @override
  Future<void> deleteKeyEscrow(String token) async {
    deleted = true;
    stored = null;
  }
}

void main() {
  setUpAll(() async {
    await sodium();
  });

  test('createPackage → openPackage 往返：payload 字段一致', () async {
    final api = FakeApi();
    final escrow = KeyEscrowService(api);

    final pkg = await escrow.createPackage(
      passphrase: '正确口令-abc',
      spaceKeyB64: 'dGhlLXNwYWNlLWtleQ==',
      spaceId: 'space-test',
      keyVersion: 2,
    );
    // 密文包不含明文 Space Key
    expect(pkg.ciphertext, isNot(contains('dGhlLXNwYWNlLWtleQ==')));

    final opened = await escrow.openPackage(passphrase: '正确口令-abc', file: pkg);
    expect(opened.spaceKeyB64, 'dGhlLXNwYWNlLWtleQ==');
    expect(opened.spaceId, 'space-test');
    expect(opened.keyVersion, 2);
  });

  test('错误口令解密失败（FormatException）', () async {
    final escrow = KeyEscrowService(FakeApi());
    final pkg = await escrow.createPackage(
      passphrase: '正确口令',
      spaceKeyB64: 'a2V5',
      spaceId: 's',
      keyVersion: 1,
    );
    await expectLater(
      escrow.openPackage(passphrase: '错误口令', file: pkg),
      throwsA(isA<FormatException>()),
    );
  });

  test('upload/fetch 一键链路：上传后可拉回解密，未托管返回 null', () async {
    final api = FakeApi();
    final escrow = KeyEscrowService(api);

    await escrow.upload(
      passphrase: '口令',
      spaceKeyB64: 'a2V5',
      spaceId: 'space-test',
      keyVersion: 3,
      token: 'tok',
    );
    expect(api.stored, isNotNull);

    final fetched = await escrow.fetch(passphrase: '口令', token: 'tok');
    expect(fetched?.spaceKeyB64, 'a2V5');
    expect(fetched?.keyVersion, 3);

    // 错误口令拉取 → FormatException
    await expectLater(escrow.fetch(passphrase: '错口令', token: 'tok'), throwsA(isA<FormatException>()));

    // 删除后未托管 → null
    await escrow.remove('tok');
    expect(api.deleted, true);
    expect(await escrow.fetch(passphrase: '口令', token: 'tok'), isNull);
  });

  test(r'hashPassphrase：生成 argon2id 哈希（$argon2id$ 前缀），不同口令哈希不同', () async {
    final escrow = KeyEscrowService(FakeApi());
    final h1 = await escrow.hashPassphrase('pass-123');
    final h2 = await escrow.hashPassphrase('other-456');
    // crypto_pwhash_str 自含随机盐：同口令两次也不同，只断言前缀与区分度
    expect(h1.startsWith(r'$argon2id$'), isTrue, reason: '应为 libsodium argon2id 哈希格式');
    expect(h1.length, greaterThan(50), reason: '哈希字符串应含完整参数头与哈希值');
    expect(h1, isNot(h2), reason: '不同口令生成的哈希应不同');
  });
}
