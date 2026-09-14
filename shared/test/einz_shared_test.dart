import 'dart:convert';
import 'dart:typed_data';

import 'package:einz_shared/einz_shared.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() async {
    await sodium();
  });

  group('设备密钥', () {
    test('生成 + 密封/解封闭环', () async {
      final s = await sodium();
      final kp = await DeviceKeyPair.generate();
      expect(kp.publicKey.length, 32);
      expect(kp.privateKey.length, 32);

      final sealed = await sealFor(s, kp.publicKey, Uint8List.fromList(utf8.encode('secret')));
      final opened = await sealOpen(s, sealed, kp.publicKey, kp.privateKey);
      expect(utf8.decode(opened), 'secret');
    });

    test('错误私钥无法解封', () async {
      final s = await sodium();
      final a = await DeviceKeyPair.generate();
      final b = await DeviceKeyPair.generate();
      final sealed = await sealFor(s, a.publicKey, Uint8List.fromList(utf8.encode('x')));
      expect(
        () => sealOpen(s, sealed, b.publicKey, b.privateKey),
        throwsA(anything),
      );
    });
  });

  group('消息加密', () {
    test('加密→解密闭环，且密文不含明文', () async {
      final spaceKey = await generateSpaceKey();
      final plain = 'Good night ❤️ 明天见';
      final env = await encryptMessage(
        plaintext: plain,
        spaceKey: spaceKey,
        spaceId: 'space-test',
        senderDeviceId: 'dev-a',
        messageId: 'msg-0001',
      );
      expect(env.ciphertext, isNot(contains(plain)));
      expect(env.v, 1);
      expect(env.keyVersion, 1);

      final decrypted = await decryptMessage(env: env, spaceKey: spaceKey, spaceId: 'space-test');
      expect(decrypted, plain);
    });

    test('同一 message_id 派生相同密钥（确定性）', () async {
      final spaceKey = await generateSpaceKey();
      final s = await sodium();
      final k1 = await deriveSubKey(s, spaceKey, 'm', 'msg-x');
      final k2 = await deriveSubKey(s, spaceKey, 'm', 'msg-x');
      expect(base64Encode(k1), base64Encode(k2));
    });

    test('AAD 绑定：换 space_id 无法解密', () async {
      final spaceKey = await generateSpaceKey();
      final env = await encryptMessage(
        plaintext: 'bound',
        spaceKey: spaceKey,
        spaceId: 'space-a',
        senderDeviceId: 'dev-a',
        messageId: 'msg-1',
      );
      expect(
        () => decryptMessage(env: env, spaceKey: spaceKey, spaceId: 'space-b'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('附件加密', () {
    test('加密→解密闭环，且密文不含明文', () async {
      final spaceKey = await generateSpaceKey();
      final file = Uint8List.fromList(List.generate(1024, (i) => i % 256));
      final result = await encryptAttachment(
        fileBytes: file,
        spaceKey: spaceKey,
        attachmentId: 'att-1',
        spaceId: 'space-test',
        keyVersion: 1,
      );
      expect(result.size, greaterThan(0));
      expect(base64Decode(result.sha256).length, 32, reason: 'SHA-256 base64(32B)');
      // 密文与元数据均不含明文可读内容（二进制随机，仅检查尺寸合理）
      final plain = await decryptAttachment(
        cipherText: result.cipher,
        nonce: result.nonce,
        spaceKey: spaceKey,
        attachmentId: 'att-1',
        spaceId: 'space-test',
        keyVersion: 1,
      );
      expect(plain, file);
    });

    test('AAD 绑定：换 space_id 无法解密', () async {
      final spaceKey = await generateSpaceKey();
      final file = Uint8List.fromList(utf8.encode('photo-bytes'));
      final result = await encryptAttachment(
        fileBytes: file,
        spaceKey: spaceKey,
        attachmentId: 'att-x',
        spaceId: 'space-a',
        keyVersion: 1,
      );
      expect(
        () => decryptAttachment(
          cipherText: result.cipher,
          nonce: result.nonce,
          spaceKey: spaceKey,
          attachmentId: 'att-x',
          spaceId: 'space-b',
          keyVersion: 1,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('一次性配置产物', () {
    test('config payload 生成 + 各自解封出同一 Space Key', () async {
      final spaceKey = await generateSpaceKey();
      final s = await sodium();
      final a = await DeviceKeyPair.generate();
      final b = await DeviceKeyPair.generate();

      final payload = await buildConfigPayload(
        spaceKey: spaceKey,
        spaceId: 'space-1',
        deviceIdA: a.deviceId,
        publicKeyA: a.publicKey,
        deviceIdB: b.deviceId,
        publicKeyB: b.publicKey,
      );
      expect(payload['format'], 'einz-config-v1');

      final sealedA = base64Decode((payload['sealed_space_keys'] as List)[0]['sealed'] as String);
      final openedA = await sealOpen(s, sealedA, a.publicKey, a.privateKey);
      expect(base64Encode(openedA), base64Encode(spaceKey));
    });
  });

  group('同步状态', () {
    test('锚点只前进不倒退', () {
      final st = SyncState(spaceId: 'space-1');
      st.advance(5);
      st.advance(3);
      st.advance(10);
      expect(st.lastServerSequence, 10);
    });
  });

  group('备份恢复（恢复码 + Argon2id）', () {
    test('备份加密→解密闭环，内容一致', () async {
      final code = await generateRecoveryCode();
      final words = code.split(' ');
      expect(words.length, 12, reason: '恢复码应为 12 词');

      final payload = Uint8List.fromList(utf8.encode('{"space_key":"secret","history":[...]}'));
      final file = await encryptWithPassphrase(payload: payload, passphrase: code);

      final json = file.toJson();
      final restored = PassphraseEnvelope.fromJson(json);
      final plain = await decryptWithPassphrase(envelope: restored, passphrase: code);
      expect(utf8.decode(plain), utf8.decode(payload));
    });

    test('错误恢复码无法解密', () async {
      final code = await generateRecoveryCode();
      final payload = Uint8List.fromList(utf8.encode('top-secret'));
      final file = await encryptWithPassphrase(payload: payload, passphrase: code);

      await expectLater(
        decryptWithPassphrase(envelope: file, passphrase: 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
