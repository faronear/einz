import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'chat_page.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';

/// 用空间凭证构造 ChatPage（冷启动门 / 锁屏解锁 / 空间列表三处入口共用）。
///
/// 多空间后"进某个空间"这件事会在三处重复，各写一份必然分叉（少传一个
/// reauth 就要到线上才发现），故收敛到这里。
///
/// [onSwitchSpace] 非空时在聊天页菜单显示「切换空间」（单空间场景不传）。
Widget buildChatPage(
  AppLockPayload payload, {
  LocalDatabase? db,
  VoidCallback? onSwitchSpace,
  void Function(BuildContext context)? onManageSpaces,
}) {
  // 从锁包恢复设备密钥对 → 注入 reauth（会话过期 401/4401 时 challenge-response
  // 重新签发 token）；旧包无密钥对 → null
  final reauth = (payload.publicKeyB64 != null && payload.privateKeyB64 != null)
      ? () => reauthFromPayload(payload)
      : null;
  return ChatPage(
    // 地址不进锁包：解锁前后读的都是启动时定好的 effectiveServer
    db: db,
    spaceId: payload.spaceId,
    deviceId: payload.deviceId,
    spaceKey: base64Decode(payload.spaceKeyB64),
    keyVersion: payload.keyVersion,
    token: payload.token ?? '',
    escrowUpdatedAt: payload.escrowUpdatedAt,
    reauth: reauth,
    publicKeyB64: payload.publicKeyB64,
    privateKeyB64: payload.privateKeyB64,
    onSwitchSpace: onSwitchSpace,
    onManageSpaces: onManageSpaces,
  );
}
