import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:einz_shared/einz_shared.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

import 'brand_logo.dart';
import 'data/burn_after_settings.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'data/locale_settings.dart';
import 'data/lock_timer.dart';
import 'data/message_repository.dart';
import 'data/ws_realtime_service.dart';
import 'l10n/app_localizations.dart';
import 'lock_page.dart';
import 'setup_page.dart';
import 'widgets/top_notice.dart';

/// 附件类型（选择弹层返回）：图像/视频用 image_picker，音频/文件用 file_picker。
enum _AttachmentKind { photo, galleryImage, videoCamera, videoGallery, audioFile, anyFile }

/// 输入区模式：text=文字输入框；hint=提示态（录音条显示「长按开始录音」，入口按钮变键盘、
/// 点击回文字态）；recording=按住录音中（波形实时）；preview=松手后预览态（试听/取消，
/// 发送复用右侧发送键）。
enum _InputMode { text, hint, recording, preview }

/// 聊天页：本地历史 + 发送 + 自动轮询同步（最小可用，无 WS 长连接）。
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.server,
    required this.spaceId,
    required this.deviceId,
    required this.spaceKey,
    required this.keyVersion,
    required this.token,
    this.db,
    this.api,
    this.enableWs = true,
    this.reauth,
    this.escrowPassphrase,
    this.escrowUpdatedAt,
    this.personName, // 我的名字（登记时设置；菜单显示/修改）
    this.deviceName, // 我的设备名（登记时自动获取；菜单显示/修改）
    this.personId, // 我的 personId（头像上传/获取用）
    this.peerName, // 对方名字（setup 探测传入；对话顶部条显示）
  });

  final String server;
  final String spaceId;
  final String deviceId;
  final Uint8List spaceKey;
  final int keyVersion;
  final String token;

  /// 接入口令（escrow，向导设置后随锁包传入）：补设锁/改口令等场景使用；
  /// 邀请码分享不编入口令（降级 B，与 TUI 一致）。
  final String? escrowPassphrase;

  /// 本端已知的服务端口令更新时间（ms）：启动/上线时与服务器对比，
  /// 服务器更新 = 离线期间口令被重设（只发通知，不弹窗）。
  final int? escrowUpdatedAt;

  /// 我的名字（向导登记时设置；顶栏菜单显示/修改，服务端同步）。
  final String? personName;

  /// 我的设备名（向导登记时自动获取设备型号；顶栏菜单显示/修改，服务端同步）。
  final String? deviceName;

  /// 我的 personId（向导登记时确定；头像上传/消息身份标识用）。
  final String? personId;

  /// 对方名字（向导探测时确定；对话顶部条显示，无则占位）。
  final String? peerName;

  /// 测试注入用；默认新建（生产路径）。
  final LocalDatabase? db;

  /// 测试注入用（fake api）；默认按 [server] 新建（生产路径）。
  final ApiClient? api;

  /// WS 实时开关（测试环境关闭，避免真实连接与重连 Timer）。
  final bool enableWs;

  /// session 过期（401/4401）时自动重新认证的回调（setup_page 注入，
  /// challenge-response 重新签发 token）——MessageRepository/WsRealtimeService 共用。
  final Future<String> Function()? reauth;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  late final MessageRepository _repo;
  final _input = TextEditingController();
  final _inputFocusNode = FocusNode(); // 回车发送后重新聚焦（与图标发送一致保持焦点）
  final _lockTimer = LockTimer();
  // 插件懒构造：AudioRecorder()/AudioPlayer() 构造即触发原生平台通道，
  // 仅在实际录音/播放时才实例化（widget 测试环境无原生实现，渲染路径不触碰）。
  AudioRecorder? _recorder;
  AudioPlayer? _player;
  final _picker = ImagePicker();
  // 图片解密缓存（messageId → Future<bytes>），避免重复下载解密。
  final Map<String, Future<Uint8List>> _imageCache = {};
  List<HistoryMessage> _messages = [];
  Timer? _ticker;
  // 分页加载（UI 懒渲染）：上滑到顶部加载更早历史；ticker 只增量追加新增
  final ScrollController _scrollController = ScrollController();
  bool _hasMoreOlder = true;
  bool _loadingOlder = false;
  static const int _pageSize = 50;
  _InputMode _inputMode = _InputMode.text; // 输入区模式（文字/提示/录音中/预览）
  String? _recordingPath; // 本次录音临时文件（录音中/预览态存续，发送或取消后清空）
  final List<double> _voiceSamples = []; // 本次录音振幅采样（录音中实时追加，预览态冻结）
  StreamSubscription<Amplitude>? _ampSub; // 录音振幅流订阅（波形驱动）
  Timer? _recordTimer; // 录音秒数计时（60s 上限自动停）
  int _recordSeconds = 0;
  bool _previewPlaying = false; // 预览态试听播放中
  String? _playingMessageId;
  int _burnSeconds = 0; // 当前阅后即焚秒数（0=无限；显示经 l10n 映射）
  bool _hasPin = false; // 本机是否已设置启动锁（菜单项「PIN: 已设置/未设置」）
  WsRealtimeService? _ws; // WS 实时（收到 message.new 立即刷新；断线自动重连）
  late String _myPersonName; // 我的名字（菜单显示；改名后 setState 刷新）
  late String _myDeviceName; // 我的设备名（菜单显示；改名后 setState 刷新）
  Uint8List? _myAvatarBytes; // 我的头像 bytes 缓存（菜单显示；上传后刷新）
  late String _peerName; // 对方名字（对话顶部条显示）
  bool _peerOnline = false; // 对方在线状态（last_seen 距今 <60s）
  int? _escrowUpdatedAt; // 本端已知口令更新时间（上线补查对比用；沿用 widget 初值）
  Timer? _peerTicker; // 对方在线轮询（30s）

  /// 阅后即焚档位文案（l10n 映射）。
  String _burnOptionLabel(int seconds, AppLocalizations l10n) {
    switch (seconds) {
      case 0:
        return l10n.burnOptionUnlimited;
      case 60:
        return l10n.burnOption1Minute;
      case 300:
        return l10n.burnOption5Minutes;
      case 1800:
        return l10n.burnOption30Minutes;
      case 3600:
        return l10n.burnOption1Hour;
      case 86400:
        return l10n.burnOption1Day;
      case 604800:
        return l10n.burnOption7Days;
      default:
        return '$seconds s';
    }
  }

  @override
  void initState() {
    super.initState();
    _myPersonName = widget.personName ?? '';
    _myDeviceName = widget.deviceName ?? '';
    _peerName = widget.peerName ?? '';
    _loadMyAvatar();
    _refreshPeerOnline();
    _peerTicker = Timer.periodic(const Duration(seconds: 30), (_) => _refreshPeerOnline());
    WidgetsBinding.instance.addObserver(this);
    final db = widget.db ?? LocalDatabase();
    // 名字未由向导传入（如 PIN 解锁后重启进聊天）→ 从本地 profile 恢复
    AppLockService(db).loadProfile().then((p) {
      if (!mounted) return;
      setState(() {
        if (_myPersonName.isEmpty) _myPersonName = p['personName'] ?? '';
        if (_myDeviceName.isEmpty) _myDeviceName = p['deviceName'] ?? '';
        if (_peerName.isEmpty) _peerName = p['peerName'] ?? '';
      });
    });
    _repo = MessageRepository(
      db: db,
      api: widget.api ?? ApiClient(widget.server),
      spaceKey: widget.spaceKey,
      spaceId: widget.spaceId,
      deviceId: widget.deviceId,
      keyVersion: widget.keyVersion,
      token: widget.token,
      settings: BurnAfterSettings(db),
      reauth: widget.reauth == null ? null : _reauthWithRevokedFallback,
    );
    _loadInitial();
    _scrollController.addListener(_maybeLoadOlder);
    _loadBurnLabel();
    _refreshPinStatus();
    // 每 3 秒轮询同步（WS 连接成功后降频为 30s 兜底；断开恢复高频——见 _onWsStatusChanged）
    _restartTicker(const Duration(seconds: 3));
    _registerPushToken();
    if (widget.enableWs) {
      final ws = WsRealtimeService(
        server: widget.server,
        token: widget.token,
        reauth: widget.reauth == null ? null : _reauthWithRevokedFallback,
      );
      _ws = ws;
      ws.connected.addListener(_onWsStatusChanged);
      ws.start(
        onMessageNew: () => _refresh(),
        onDeviceRevoked: _onDeviceRevoked,
        onPeerStatus: _onPeerStatus,
        onPassphraseRotated: _onPassphraseRotated,
        onProfileUpdated: _onProfileUpdated,
      );
    }
  }

  /// 对端上下线（Server 广播——立即更新对方在线状态，不等 30s 轮询）。
  void _onPeerStatus(WsPeerStatusEvent event) {
    if (event.deviceId == widget.deviceId) return; // 本设备自身的事件忽略
    final online = event.type == kWsTypePeerOnline;
    if (mounted && online != _peerOnline) setState(() => _peerOnline = online);
  }

  /// 空间口令被重设（Server 广播 passphrase.rotated）：只发通知不弹窗——
  /// 修改口令时（按需）才要求输入新口令。
  void _onPassphraseRotated(WsPassphraseRotatedEvent event) {
    if (!mounted) return;
    showTopNotice(context, AppLocalizations.of(context)!.chatPageEscrowRotatedNotice);
  }

  /// 对方改名（Server 广播 profile.updated）：立即更新顶部条对方名。
  void _onProfileUpdated(WsProfileUpdatedEvent event) {
    final name = event.personName;
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _peerName = name);
  }

  /// 上线补查（离线期间口令被重设）：启动/WS 连接后对比服务端 updated_at，
  /// 服务器更新 = 口令已重设——只发通知不弹窗（修改口令时按需才要求输入新口令）。
  Future<void> _checkEscrowRotated() async {
    if (!mounted || widget.token.isEmpty || widget.server.isEmpty) return;
    try {
      final api = widget.api ?? ApiClient(widget.server);
      final snap = await api.getKeyEscrow(widget.token);
      final serverAt = snap.updatedAt;
      final knownAt = _escrowUpdatedAt ?? widget.escrowUpdatedAt;
      if (serverAt != null && knownAt != null && serverAt > knownAt) {
        if (!mounted) return;
        showTopNotice(context, AppLocalizations.of(context)!.chatPageEscrowRotatedNotice);
        _escrowUpdatedAt = serverAt; // 记录已知时间（防 WS 重连/重复补查刷屏）
      }
    } catch (_) {
      // 查询失败（网络/未托管）静默：不打断正常使用
    }
  }

  /// session 过期自动续期（WS 4401 / 请求 401）：challenge-response 重新签发 token。
  /// 认证 403（设备已被撤销，服务端拒绝挑战）→ 走 [_onDeviceRevoked] 撤销处理
  /// （清理本地数据 → 提示 → 回设置页）；其他异常原样抛出（调用方退避/提示）。
  Future<String> _reauthWithRevokedFallback() async {
    try {
      return await widget.reauth!();
    } on ApiException catch (e) {
      if (e.code == 'FORBIDDEN') {
        await _onDeviceRevoked();
      }
      rethrow;
    }
  }

  /// 本设备被撤销（Server 广播 device.revoked）：清理本地数据（锁包+消息库）
  /// → 提示 → 强制回设置页重新配置。
  Future<void> _onDeviceRevoked() async {
    _ticker?.cancel();
    await _ws?.stop();
    if (!mounted) return;
    try {
      final db = widget.db ?? LocalDatabase();
      await AppLockService(db).clear();
      await (db.delete(db.localAttachments)).go();
      await (db.delete(db.localMessages)).go();
      await (db.delete(db.syncState)).go();
    } catch (_) {
      // 清理失败不阻塞登出（尽力清除）
    }
    if (!mounted) return;
    showTopNotice(context, AppLocalizations.of(context)!.chatPageDeviceRevoked);
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const SetupPage()),
      (route) => false,
    );
  }

  /// 重建轮询 ticker（WS 状态变化时切换间隔）。
  void _restartTicker(Duration interval) {
    _ticker?.cancel();
    _ticker = Timer.periodic(interval, (_) => _refresh());
  }

  /// WS 状态变化：在线 → 降频兜底（30s）；离线 → 恢复高频轮询（3s）。
  void _onWsStatusChanged() {
    final online = _ws?.connected.value ?? false;
    _restartTicker(online ? const Duration(seconds: 30) : const Duration(seconds: 3));
    if (mounted) setState(() {}); // 刷新标题红绿灯（在线绿/离线红）
    _refreshPeerOnline(); // 连接恢复时顺带刷新对方在线状态
    if (online) _checkEscrowRotated(); // 上线补查：离线期间口令被重设则发通知
  }

  /// 加载本设备阅后即焚档位秒数（每设备独立，纯本地）。
  Future<void> _loadBurnLabel() async {
    final s = BurnAfterSettings(widget.db ?? LocalDatabase());
    final seconds = await s.load();
    if (mounted) setState(() => _burnSeconds = seconds);
  }

  /// 顶栏 🌐：切换界面语言（跟随系统/中文/English，即时生效）。
  Future<void> _showLocalePicker() async {
    final settings = LocaleSettings(widget.db ?? LocalDatabase());
    final current = await settings.load();
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('界面语言 / Language', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final option in kLocaleOptions)
              ListTile(
                title: Text(kLocaleLabels[option]!),
                trailing: option == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(ctx).pop(option),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await settings.save(picked);
    if (!mounted) return;
    showTopNotice(context, AppLocalizations.of(context)!.chatPageLocaleSwitched(kLocaleLabels[picked]!));
  }

  /// 邀请设备：直接生成一次性邀请码（POST /invites，需已认证）。
  /// 不做 personA/personB 区分、不询问对方名字——默认给尚未加入的对方（personB），
  /// 生成后展示号码 + 二维码（内容 = 纯邀请码，不编入口令——与 TUI 一致，
  /// 口令由对方加入时另行输入）。
  Future<void> _showInviteDialog() async {
    // 老板决策：点顶栏添加按钮直接生成邀请码（不再先弹"邀请设备"确认窗）
    try {
      final api = widget.api ?? ApiClient(widget.server);
      final r = await api.createInvite(token: widget.token, personId: 'personB');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('邀请码已生成'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 自绘二维码：QrImageView 的 LayoutBuilder 会触发 AlertDialog
              // 固有尺寸异常（见 _InviteQrCode 注释），此处不用它
              Center(child: _InviteQrCode(data: r.inviteCode)),
              const SizedBox(height: 12),
              SelectableText(r.inviteCode,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: 1)),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('扫码或填写以上邀请码加入，即可绑定新设备到秘境',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: r.inviteCode));
                if (!ctx.mounted) return;
                showTopNotice(ctx, '邀请码已复制');
                Navigator.of(ctx).pop();
              },
              child: const Text('复制'),
            ),
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(), child: const Text('关闭')),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showTopNotice(context, '邀请码生成失败: $e');
    }
  }

  /// 补设/重设启动锁（跳过 PIN 后某天想设置时用；复用 PIN 表单）。
  /// 用当前会话的 Space Key 包 setPin 加密落盘（内部会清掉明文副本）。
  Future<void> _showSetLockDialog() async {
    final payload = AppLockPayload(
      server: widget.server,
      spaceId: widget.spaceId,
      deviceId: widget.deviceId,
      spaceKeyB64: base64Encode(widget.spaceKey),
      keyVersion: widget.keyVersion,
      token: widget.token,
      escrowPassphrase: widget.escrowPassphrase,
    );
    // 弹窗内容抽为 _SetLockDialog（StatefulWidget）：controller 生命周期随 State
    // 卸载同步释放，避免"点设置后 dispose 竞态"（TextField 卸载动画中向已销毁
    // controller 加 listener → debugAssertNotDisposed / _dependents.isEmpty 红屏，
    // 2026-09-05 真机定位）。
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _SetLockDialog(
        payload: payload,
        db: widget.db ?? LocalDatabase(),
      ),
    );
    if (ok == true && mounted) {
      setState(() => _hasPin = true); // 设置成功：菜单项刷新为「PIN: 已设置」
    }
  }

  /// 刷新本机 PIN 状态（菜单项「PIN: 已设置/未设置」；initState 时读取）。
  Future<void> _refreshPinStatus() async {
    final has = await AppLockService(widget.db ?? LocalDatabase()).isSetup;
    if (!mounted || has == _hasPin) return;
    setState(() => _hasPin = has);
  }

  /// 修改口令（escrow 托管口令，空间级）：旧口令验证 → 新口令重加密上传 → 本地同步。
  Future<void> _showChangePassphraseDialog() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _ChangePassphraseDialog(
        server: widget.server,
        spaceKeyB64: base64Encode(widget.spaceKey),
        spaceId: widget.spaceId,
        keyVersion: widget.keyVersion,
        token: widget.token,
        db: widget.db ?? LocalDatabase(),
        onPassphraseUpdated: (updatedAt) {
          if (mounted) _escrowUpdatedAt = updatedAt ?? _escrowUpdatedAt;
        },
      ),
    );
    if (changed == true && mounted) {
      showTopNotice(context, AppLocalizations.of(context)!.chatPageChangePassphraseDone);
    }
  }

  /// 对方在线判定：对方有实时 WS 连接（connected_at 非 null）= 在线；
  /// 旧服务器无 connected_at 字段时退回 last_seen 距今 < 60s 兜底
  /// （30s 轮询 + WS 状态变化时刷新）。
  Future<void> _refreshPeerOnline() async {
    try {
      final api = widget.api ?? ApiClient(widget.server);
      final devices = await api.listDevices(widget.token);
      final now = DateTime.now().millisecondsSinceEpoch;
      final peer = devices.where((d) => d['device_id'] != widget.deviceId).toList();
      final online = peer.isNotEmpty && peer.any((d) {
        // 实时 WS 连接 = 真在线（server 重启/未入网时立即准确）；last_seen 会被
        // 轮询 touchLastSeen 持续刷新，不能代表实时连接（修复"未入网却显示绿灯"）。
        if (d.containsKey('connected_at')) return d['connected_at'] != null;
        final last = d['last_seen'];
        if (last is! num) return false;
        return now - last < 60 * 1000;
      });
      if (mounted && online != _peerOnline) setState(() => _peerOnline = online);
    } catch (_) {
      // 网络失败：保持上次状态
    }
  }

  /// 加载我的头像（异步；未设置/失败 → 保持默认图标）。
  Future<void> _loadMyAvatar() async {
    final pid = widget.personId;
    if (pid == null || pid.isEmpty) return;
    try {
      final api = widget.api ?? ApiClient(widget.server);
      final bytes = await api.getAvatar(pid);
      if (bytes != null && mounted) setState(() => _myAvatarBytes = bytes);
    } catch (_) {
      // 网络失败：保持默认图标
    }
  }

  /// 修改我的头像：选图 → 上传服务端（per-person 覆盖）→ 本地缓存刷新菜单显示。
  Future<void> _showAvatarUpload() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await FilePicker.pickFiles(type: FileType.image);
    if (picked.isEmpty) return;
    final file = picked.first;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
      if (mounted) {
        showTopNotice(context, l10n.chatPageAvatarTooLarge);
      }
      return;
    }
    try {
      final api = widget.api ?? ApiClient(widget.server);
      await api.uploadAvatar(bytes, widget.token);
      if (!mounted) return;
      setState(() => _myAvatarBytes = bytes);
      showTopNotice(context, l10n.chatPageAvatarUploaded);
    } catch (e) {
      if (!mounted) return;
      showTopNotice(context, l10n.chatPageAvatarFailed('$e'));
    }
  }

  /// 修改我的名字/设备名称（服务端同步 + 本地刷新菜单显示）。
  Future<void> _showRenameDialog({required bool renameDevice}) async {
    final l10n = AppLocalizations.of(context)!;
    final ctrl = TextEditingController(text: renameDevice ? _myDeviceName : _myPersonName);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(renameDevice ? l10n.chatPageRenameDeviceTitle : l10n.chatPageRenameNameTitle),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(
            labelText: renameDevice ? l10n.chatPageRenameDeviceLabel : l10n.chatPageRenameNameLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
          FilledButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              try {
                final api = widget.api ?? ApiClient(widget.server);
                if (renameDevice) {
                  await api.updateDeviceName(name, widget.token);
                  _myDeviceName = name;
                } else {
                  await api.updatePersonName(name, widget.token);
                  _myPersonName = name;
                }
                // 同步本地 profile：重启后 ChatPage 从 profile 恢复新名字
                // （否则 loadProfile 读到向导完成时的旧名——2026-09-07 老板实测
                // app 菜单改名后退出重进回到 personB）
                await _saveProfile();
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              } catch (e) {
                if (ctx.mounted) {
                  showTopNotice(ctx, l10n.chatPageRenameFailed('$e'));
                }
              }
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    // 对话框 route 关闭动画完成后才 dispose（TextField 卸载后不再依赖
    // controller；立即 dispose 会触发红屏断言 _dependents.isEmpty）
    Future<void>.delayed(const Duration(milliseconds: 400), ctrl.dispose);
    if (saved == true && mounted) setState(() {}); // 刷新菜单显示的新名字
  }

  /// 同步当前名字到本地 profile（改名/改设备名后调用——重启从 profile 恢复）。
  Future<void> _saveProfile() async {
    await AppLockService(widget.db ?? LocalDatabase()).saveProfile(
      personName: _myPersonName,
      peerName: _peerName,
      deviceName: _myDeviceName,
    );
  }

  /// 退出秘境（等价 TUI /exit）：确认后回到锁屏（LockPage），下次解锁重新认证。
  Future<void> _showExitAppDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final shouldExit = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.chatPageExitTitle),
        content: Text(l10n.chatPageExitMessage),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.chatPageMenuExit)),
        ],
      ),
    );
    if (shouldExit == true) {
      // 彻底关闭应用（等价 TUI /exit；不再回 LockPage——未设 PIN 时锁屏不应激活）
      exit(0);
    }
  }

  /// 顶栏 ⏱：选择阅后即焚档位（保存到本设备设置）。
  Future<void> _showBurnPicker() async {
    final settings = BurnAfterSettings(widget.db ?? LocalDatabase());
    final current = await settings.load();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(l10n.chatPageBurnHeading, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final entry in kBurnAfterOptions.entries)
              ListTile(
                title: Text(_burnOptionLabel(entry.value, l10n)),
                trailing: entry.value == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(ctx).pop(entry.value.toString()),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final seconds = int.parse(picked);
    await settings.save(seconds);
    if (!mounted) return;
    setState(() => _burnSeconds = seconds);
    showTopNotice(
      context,
      seconds == 0
          ? l10n.chatPageBurnOff
          : l10n.chatPageBurnWillDelete(_burnOptionLabel(seconds, l10n)),
    );
  }

  /// iOS：认证后把 APNs device token 注册到 Server（PROTOCOL.md §7.3）。
  /// 推送只发"有新消息"提示；注册失败不影响聊天（WS/轮询兜底）。
  Future<void> _registerPushToken() async {
    if (!Platform.isIOS) return;
    try {
      const channel = MethodChannel('einz/apns');
      final apnsToken = await channel.invokeMethod<String>('getToken');
      if (apnsToken != null && apnsToken.isNotEmpty) {
        await _repo.api.registerPushToken('ios', apnsToken, widget.token);
      }
    } catch (_) {
      // 忽略：APNs 未就绪（模拟器/未配 entitlement）时静默降级
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _peerTicker?.cancel();
    _recordTimer?.cancel();
    _ampSub?.cancel();
    _ws?.connected.removeListener(_onWsStatusChanged);
    _ws?.stop();
    _scrollController.dispose();
    _input.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  /// App 生命周期：切后台记时，回前台超过阈值 → 覆盖锁屏（保留聊天页状态）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _lockTimer.recordBackgrounded(DateTime.now());
    } else if (state == AppLifecycleState.resumed) {
      final relock = _lockTimer.shouldRelock(now: DateTime.now());
      _lockTimer.clear();
      if (relock && mounted) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LockPage(asOverlay: true)));
      }
    }
  }

  /// 首次载入：同步全量 → 清理到期 → 只渲染最近一页（UI 分页懒加载）。
  Future<void> _loadInitial() async {
    try {
      await _repo.sync();
      await _repo.purgeExpired();
      await _repo.refreshDeviceMap();
      final recent = await _repo.historyRecent(limit: _pageSize);
      if (!mounted) return;
      setState(() => _messages = recent);
    } catch (_) {
      // 网络抖动忽略：保持空列表，等 ticker 重试
    }
  }

  /// 已加载列表中最新的 serverSequence（未同步=最新时返回 0）。
  int get _lastLoadedSequence {
    for (final m in _messages.reversed) {
      final s = m.env.serverSequence;
      if (s != null) return s;
    }
    return 0;
  }

  /// 滚动到接近顶部时加载更早的历史（分页）。
  void _maybeLoadOlder() {
    if (!_hasMoreOlder || _loadingOlder) return;
    if (_scrollController.position.extentBefore < 200) {
      _loadOlder();
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMoreOlder) return;
    _loadingOlder = true;
    try {
      final first = _messages.isEmpty ? null : _messages.first.env.serverSequence;
      if (first == null) {
        // 没有已同步消息（或全是未同步）→ 没有更早历史
        if (mounted) setState(() => _hasMoreOlder = false);
        return;
      }
      final older = await _repo.historyBefore(beforeSequence: first, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _messages = [...older, ..._messages];
        if (older.length < _pageSize) _hasMoreOlder = false;
      });
    } catch (_) {
      // 加载失败：下次滚动再试
    } finally {
      _loadingOlder = false;
    }
  }

  /// 新消息（接收/发送）后滚动到底：让最新消息显示在最下方（老板要求"总是"）。
  /// post-frame 里执行（ListView 重建后 maxScrollExtent 才有效）。
  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _refresh() async {
    try {
      await _repo.sync();
      final now = DateTime.now().millisecondsSinceEpoch;
      // 阅后即焚：删除本设备已到期的消息（纯本地）
      await _repo.purgeExpired(now: now);
      // 增量刷新：只取比已加载最新更晚的消息追加（不重建全量列表）
      final fresh = await _repo.historySince(afterSequence: _lastLoadedSequence);
      await _repo.refreshDeviceMap();
      if (!mounted) return;
      setState(() {
        // 移除本设备已到期的消息（与 purgeExpired 同一标准）
        _messages.removeWhere((m) => m.expiresAt != null && m.expiresAt! <= now);
        final existing = {for (final m in _messages) m.env.messageId};
        _messages.addAll(fresh.where((f) => !existing.contains(f.env.messageId)));
      });
      _scrollToLatest(); // 新消息（接收/发送）后滚动到底
    } catch (_) {
      // 网络抖动忽略，下次轮询重试
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    try {
      await _repo.send(text);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      showTopNotice(context, AppLocalizations.of(context)!.chatPageSendFailed('$e'));
    }
  }

  // ---------- 语音：点击麦克风切提示态 → 长按提示态录音条录音 → 松手预览（试听/取消）→ 发送 ----------

  /// 语音入口按钮点击：文字态=切提示态；提示/预览态=回文字态；录音中无操作。
  void _onVoiceEntryTap() {
    if (_inputMode == _InputMode.text) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _inputMode = _InputMode.hint);
    } else if (_inputMode == _InputMode.hint) {
      setState(() => _inputMode = _InputMode.text);
    } else if (_inputMode == _InputMode.preview) {
      unawaited(_cancelVoice());
    }
    // recording：手势在录音条上，入口按钮不可达，无操作
  }

  /// 语音入口按钮图标：文字态=麦克风；提示/预览态=键盘；录音中=红色麦克风。
  IconData _voiceEntryIcon() {
    switch (_inputMode) {
      case _InputMode.text:
        return Icons.mic_none;
      case _InputMode.hint:
      case _InputMode.preview:
        return Icons.keyboard_alt_outlined;
      case _InputMode.recording:
        return Icons.mic;
    }
  }

  Future<void> _startVoice() async {
    if (_inputMode == _InputMode.recording) return;
    // 录音时收起键盘（输入框被录音条覆盖，键盘占屏无意义）
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      // 重新录音（预览态再长按）：先清掉上一次未发送的临时文件
      final old = _recordingPath;
      if (old != null) {
        final of = File(old);
        if (await of.exists()) await of.delete().catchError((_) => of);
        _recordingPath = null;
      }
      // 试听/消息播放与录音互斥
      _previewPlaying = false;
      if (_playingMessageId != null) _playingMessageId = null;
      await _player?.stop();
      final path = '${Directory.systemTemp.path}/einz_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await (_recorder ??= AudioRecorder()).start(const RecordConfig(), path: path);
      // 振幅流：实时驱动录音条波形（record 插件内部无订阅者时不做事）
      _voiceSamples.clear();
      _recordSeconds = 0;
      _ampSub?.cancel();
      _ampSub = _recorder!
          .onAmplitudeChanged(const Duration(milliseconds: 70))
          .listen((amplitude) {
        if (!mounted || _inputMode != _InputMode.recording) return;
        final raw = ((amplitude.current + 50) / 50).clamp(0.06, 1.0);
        setState(() {
          final last = _voiceSamples.isNotEmpty ? _voiceSamples.last : raw;
          _voiceSamples.add((last * 0.4 + raw * 0.6).clamp(0.06, 1.0));
        });
      });
      setState(() {
        _inputMode = _InputMode.recording;
        _recordingPath = path;
      });
      // 60s 上限：到点自动停（进预览态），防误触长时间录音
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _inputMode != _InputMode.recording) return;
        setState(() => _recordSeconds++);
        if (_recordSeconds >= 60) _stopVoice();
      });
    } catch (e) {
      if (!mounted) return;
      showTopNotice(context, AppLocalizations.of(context)!.chatPageVoiceStartFailed('$e'));
    }
  }

  /// 松手 / 60s 到点：停录音 → 文件有效进预览态（不自动发送），空录音直接取消回输入框。
  Future<void> _stopVoice() async {
    if (_inputMode != _InputMode.recording) return;
    final path = _recordingPath;
    _recordTimer?.cancel();
    _recordTimer = null;
    await _ampSub?.cancel();
    _ampSub = null;
    try {
      await _recorder?.stop();
      var ok = false;
      if (path != null) {
        final f = File(path);
        ok = await f.exists() && await f.length() > 0;
      }
      if (!mounted) return;
      setState(() {
        _inputMode = ok ? _InputMode.preview : _InputMode.text;
        if (!ok) _recordingPath = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _inputMode = _InputMode.text;
        _recordingPath = null;
      });
      showTopNotice(context, AppLocalizations.of(context)!.chatPageVoiceFailed('$e'));
    }
  }

  /// 预览态发送（右侧发送键）：加密上传（type=voice）→ 恢复文字输入框。
  Future<void> _sendVoice() async {
    if (_inputMode != _InputMode.preview) return;
    final path = _recordingPath;
    if (path == null) return;
    try {
      final f = File(path);
      if (!await f.exists() || await f.length() == 0) {
        if (!mounted) return;
        setState(() {
          _inputMode = _InputMode.text;
          _recordingPath = null;
          _voiceSamples.clear();
        });
        return;
      }
      await _repo.sendAttachment(
        fileBytes: await f.readAsBytes(),
        fileName: 'voice.m4a',
        type: 'voice',
      );
      await f.delete().catchError((_) => f);
      if (!mounted) return;
      setState(() {
        _inputMode = _InputMode.text;
        _recordingPath = null;
        _voiceSamples.clear();
      });
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      showTopNotice(context, AppLocalizations.of(context)!.chatPageVoiceFailed('$e'));
    }
  }

  /// 预览态取消：删临时文件，恢复文字输入框。
  Future<void> _cancelVoice() async {
    if (_inputMode != _InputMode.preview) return;
    final path = _recordingPath;
    _previewPlaying = false;
    await _player?.stop();
    if (!mounted) return;
    setState(() {
      _inputMode = _InputMode.text;
      _recordingPath = null;
      _voiceSamples.clear();
    });
    if (path != null) {
      final f = File(path);
      if (await f.exists()) await f.delete().catchError((_) => f);
    }
  }

  /// 预览态试听：点播放/暂停切换（与消息播放互斥）。
  Future<void> _playVoicePreview() async {
    final path = _recordingPath;
    if (path == null || !await File(path).exists()) return;
    final player = _player ??= AudioPlayer();
    if (_previewPlaying) {
      await player.stop();
      if (mounted) setState(() => _previewPlaying = false);
      return;
    }
    if (_playingMessageId != null && mounted) setState(() => _playingMessageId = null);
    try {
      setState(() => _previewPlaying = true);
      await player.stop();
      await player.play(DeviceFileSource(path));
      // 播完自动复位播放图标
      unawaited(player.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _previewPlaying = false);
      }));
    } catch (e) {
      if (!mounted) return;
      setState(() => _previewPlaying = false);
      showTopNotice(context, AppLocalizations.of(context)!.chatPageAudioPlayFailed('$e'));
    }
  }

  /// 最近 [n] 个波形采样（录音中滚动窗口，预览态冻结尾部）。
  List<double> _voiceLastSamples(int n) =>
      _voiceSamples.length <= n ? _voiceSamples : _voiceSamples.sublist(_voiceSamples.length - n);

  /// 录音条（覆盖在文字输入框上）：提示态=「长按开始录音」文字（无波形）；
  /// 录音中=实时波形+计时；预览态=冻结波形+试听/取消。
  /// 由外部 Stack 给定与输入框完全一致的行高（移除固定高度，随约束填充）。
  Widget _buildVoiceBar() {
    final recording = _inputMode == _InputMode.recording;
    final preview = _inputMode == _InputMode.preview;
    final elapsed = '${_recordSeconds ~/ 60}:${(_recordSeconds % 60).toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: recording ? Colors.red.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: recording ? Colors.red.shade200 : Colors.grey.shade300),
      ),
      child: recording
          ? Row(
              children: [
                const Icon(Icons.mic, size: 16, color: Colors.red),
                const SizedBox(width: 8),
                Text(elapsed,
                    style: const TextStyle(
                        color: Colors.red, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 10),
                Expanded(
                    child: _WaveformBars(samples: _voiceLastSamples(40), color: Colors.red)),
              ],
            )
          : preview
              ? Row(
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 22,
                      icon: Icon(_previewPlaying ? Icons.stop_circle : Icons.play_circle,
                          color: Theme.of(context).colorScheme.primary),
                      onPressed: _playVoicePreview,
                    ),
                    Expanded(
                        child: _WaveformBars(
                            samples: _voiceLastSamples(40), color: Colors.grey.shade600)),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 22,
                      icon: const Icon(Icons.close, color: Colors.grey),
                      onPressed: _cancelVoice,
                    ),
                  ],
                )
              : Row(
                  // 提示态：文字说明版录音条（无波形），长按开始录音
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.mic, size: 16, color: Colors.grey.shade600),
                    const SizedBox(width: 6),
                    Text(
                      AppLocalizations.of(context)!.chatPageLongPressToRecord,
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                    ),
                  ],
                ),
    );
  }

  // ---------- 音频播放（语音/音频文件共用）：下载解密 → 临时文件 → audioplayers ----------

  /// 从文件名取扩展名（audio 消息临时文件用，voice 固定 m4a）。
  String _extOf(String name) {
    final dot = name.lastIndexOf('.');
    return (dot >= 0 && dot < name.length - 1) ? name.substring(dot + 1) : 'bin';
  }

  Future<void> _playAudioMessage(
      ({MessageEnvelope env, String plaintext, String sender, Map<String, dynamic>? attachment, int? expiresAt}) m) async {
    final att = m.attachment;
    if (att == null) {
      if (!mounted) return;
      showTopNotice(context, AppLocalizations.of(context)!.chatPageAudioMetaMissing);
      return;
    }
    // 正在播放同一条 → 停止
    if (_playingMessageId == m.env.messageId) {
      await _player?.stop();
      if (mounted) setState(() => _playingMessageId = null);
      return;
    }
    try {
      final player = _player ??= AudioPlayer();
      _previewPlaying = false; // 与预览态试听互斥
      setState(() => _playingMessageId = m.env.messageId);
      final bytes = await _repo.fetchAttachment(
        attachmentId: att['attachment_id'] as String,
        keyVersion: att['key_version'] as int,
        sha256: att['sha256'] as String,
        nonce: base64Decode(att['nonce'] as String),
      );
      final ext = m.env.type == 'voice' ? 'm4a' : _extOf(m.plaintext);
      final tmp = File('${Directory.systemTemp.path}/einz_audio_${m.env.messageId}.$ext');
      await tmp.writeAsBytes(bytes);
      await player.stop();
      await player.play(DeviceFileSource(tmp.path));
      player.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _playingMessageId = null);
      }).catchError((_) {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _playingMessageId = null);
      showTopNotice(context, AppLocalizations.of(context)!.chatPageAudioPlayFailed('$e'));
    }
  }

  // ---------- 图像/视频/音频/文件：选择 → 加密上传 → 发送 ----------

  Future<void> _showAttachmentSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final kind = await showModalBottomSheet<_AttachmentKind>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: Text(l10n.chatPageAttachPhoto),
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.photo),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(l10n.chatPageAttachGalleryImage),
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.galleryImage),
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: Text(l10n.chatPageAttachVideoCamera),
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.videoCamera),
            ),
            ListTile(
              leading: const Icon(Icons.movie),
              title: Text(l10n.chatPageAttachVideoGallery),
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.videoGallery),
            ),
            ListTile(
              leading: const Icon(Icons.music_note),
              title: Text(l10n.chatPageAttachAudioFile),
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.audioFile),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: Text(l10n.chatPageAttachAnyFile),
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.anyFile),
            ),
          ],
        ),
      ),
    );
    if (kind != null) await _sendMedia(kind);
  }

  Future<void> _sendMedia(_AttachmentKind kind) async {
    try {
      final XFile? image;
      String? fileName;
      String? type;
      switch (kind) {
        case _AttachmentKind.photo:
          image = await _picker.pickImage(source: ImageSource.camera, maxWidth: 1600);
          if (image == null) return;
          fileName = 'image.jpg';
          type = 'image';
          await _repo.sendAttachment(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.galleryImage:
          image = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1600);
          if (image == null) return;
          fileName = 'image.jpg';
          type = 'image';
          await _repo.sendAttachment(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.videoCamera:
          image = await _picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(minutes: 1));
          if (image == null) return;
          fileName = 'video.mp4';
          type = 'video';
          await _repo.sendAttachment(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.videoGallery:
          image = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(minutes: 1));
          if (image == null) return;
          fileName = 'video.mp4';
          type = 'video';
          await _repo.sendAttachment(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.audioFile:
          // file_picker 12.x：静态方法直接调用，返回 List<PlatformFile>；
          // 文件内容用异步 readAsBytes()（withData 已废弃）
          final audioFiles = await FilePicker.pickFiles(type: FileType.audio);
          if (audioFiles.isEmpty) return;
          final audio = audioFiles.first;
          final audioName = audio.name;
          final audioBytes = await audio.readAsBytes();
          await _repo.sendAttachment(
            fileBytes: audioBytes,
            fileName: audioName,
            type: 'audio',
            caption: audioName,
          );
        case _AttachmentKind.anyFile:
          final anyFiles = await FilePicker.pickFiles(type: FileType.any);
          if (anyFiles.isEmpty) return;
          final any = anyFiles.first;
          final anyName = any.name;
          final anyBytes = await any.readAsBytes();
          await _repo.sendAttachment(
            fileBytes: anyBytes,
            fileName: anyName,
            type: 'file',
            caption: anyName,
          );
      }
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      showTopNotice(context, AppLocalizations.of(context)!.chatPageSendFailed('$e'));
    }
  }

  // ---------- 视频：下载解密 → 临时文件 → video_player 播放 ----------

  /// 视频消息：播放按钮 + 说明文字；点击下载解密后全屏播放。
  Widget _buildVideo(
      ({MessageEnvelope env, String plaintext, String sender, Map<String, dynamic>? attachment, int? expiresAt}) m) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.play_circle),
          onPressed: () => _playVideo(m),
          visualDensity: VisualDensity.compact,
        ),
        Text('🎬 ${m.plaintext}'),
      ],
    );
  }

  Future<void> _playVideo(
      ({MessageEnvelope env, String plaintext, String sender, Map<String, dynamic>? attachment, int? expiresAt}) m) async {
    final att = m.attachment;
    if (att == null) {
      if (!mounted) return;
      showTopNotice(context, AppLocalizations.of(context)!.chatPageVideoMetaMissing);
      return;
    }
    VideoPlayerController? controller;
    try {
      final bytes = await _repo.fetchAttachment(
        attachmentId: att['attachment_id'] as String,
        keyVersion: att['key_version'] as int,
        sha256: att['sha256'] as String,
        nonce: base64Decode(att['nonce'] as String),
      );
      final tmp = File('${Directory.systemTemp.path}/einz_video_${m.env.messageId}.mp4');
      await tmp.writeAsBytes(bytes);
      controller = VideoPlayerController.file(tmp);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: Stack(
            children: [
              AspectRatio(
                aspectRatio: controller!.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ],
          ),
        ),
      );
      await controller.dispose();
    } catch (e) {
      await controller?.dispose();
      if (!mounted) return;
      showTopNotice(context, AppLocalizations.of(context)!.chatPageVideoPlayFailed('$e'));
    }
  }

  /// 图片消息：下载解密 → 缩略展示；点击全屏查看。
  Widget _buildImage(
      ({MessageEnvelope env, String plaintext, String sender, Map<String, dynamic>? attachment, int? expiresAt}) m) {
    final att = m.attachment;
    if (att == null) return Text('📷 ${m.plaintext}');
    final future = _imageCache.putIfAbsent(
      m.env.messageId,
      () => _repo.fetchAttachment(
        attachmentId: att['attachment_id'] as String,
        keyVersion: att['key_version'] as int,
        sha256: att['sha256'] as String,
        nonce: base64Decode(att['nonce'] as String),
      ),
    );
    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snap) {
        if (snap.hasData) {
          return GestureDetector(
            onTap: () => _showFullImage(snap.data!),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(snap.data!, width: 180, height: 180, fit: BoxFit.cover),
            ),
          );
        }
        if (snap.hasError) {
          return Text(AppLocalizations.of(context)!.chatPageImageLoadFailed(m.plaintext));
        }
        return const SizedBox(width: 60, height: 60, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
      },
    );
  }

  void _showFullImage(Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: InteractiveViewer(
          child: Image.memory(bytes, fit: BoxFit.contain),
        ),
      ),
    );
  }

  /// 消息内容按类型渲染（text 文本 / voice、audio 播放条 / image、video、file 各自卡片）。
  Widget _buildMessageContent(
      ({MessageEnvelope env, String plaintext, String sender, Map<String, dynamic>? attachment, int? expiresAt}) m) {
    switch (m.env.type) {
      case 'voice':
      case 'audio':
        return _buildAudioBar(m);
      case 'image':
        return _buildImage(m);
      case 'video':
        return _buildVideo(m);
      case 'file':
        return _buildFileCard(m);
      default:
        return Text(m.plaintext);
    }
  }

  /// 音频消息（语音/音频文件共用）：播放条；点击下载解密后播放。
  Widget _buildAudioBar(
      ({MessageEnvelope env, String plaintext, String sender, Map<String, dynamic>? attachment, int? expiresAt}) m) {
    final playing = _playingMessageId == m.env.messageId;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(playing ? Icons.stop_circle : Icons.play_circle),
          onPressed: () => _playAudioMessage(m),
          visualDensity: VisualDensity.compact,
        ),
        Flexible(
          child: Text(
            playing
                ? AppLocalizations.of(context)!.chatPagePlaying
                : (m.env.type == 'voice'
                    ? '🎤 ${AppLocalizations.of(context)!.chatPageVoiceLabel}'
                    : '🎵 ${m.plaintext}'),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// 文件消息：文件卡片（文件名 + 大小 + 下载保存）。
  Widget _buildFileCard(
      ({MessageEnvelope env, String plaintext, String sender, Map<String, dynamic>? attachment, int? expiresAt}) m) {
    final size = (m.attachment?['size'] as int?) ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.download),
          onPressed: () => _downloadFile(m),
          visualDensity: VisualDensity.compact,
        ),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('📄 ${m.plaintext}', overflow: TextOverflow.ellipsis),
              Text(_formatSize(size), style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
      ],
    );
  }

  String _formatSize(int bytes) {
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  /// 下载并保存文件附件到应用文档目录（captain=文件名）。
  Future<void> _downloadFile(
      ({MessageEnvelope env, String plaintext, String sender, Map<String, dynamic>? attachment, int? expiresAt}) m) async {
    final att = m.attachment;
    if (att == null) {
      if (!mounted) return;
      showTopNotice(context, AppLocalizations.of(context)!.chatPageAttachmentMetaMissing);
      return;
    }
    try {
      final bytes = await _repo.fetchAttachment(
        attachmentId: att['attachment_id'] as String,
        keyVersion: att['key_version'] as int,
        sha256: att['sha256'] as String,
        nonce: base64Decode(att['nonce'] as String),
      );
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${m.plaintext}');
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      showTopNotice(context, AppLocalizations.of(context)!.chatPageSaved(file.path));
    } catch (e) {
      if (!mounted) return;
      showTopNotice(context, AppLocalizations.of(context)!.chatPageDownloadFailed('$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        // 抬头只显示品牌名+slogan（不暴露空间 ID，对普通用户无意义）；
        // 在线状态由对话顶部条双灯呈现（「我的」灯三态：灰=未连接服务/绿=已连接/红=断线）
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandLogo(),
            const SizedBox(width: 10),
            Flexible(
              child: Text(l10n.chatPageTitleBrand,
                  style: const TextStyle(fontSize: 17),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        actions: [
          // 顶栏统一入口：语言/阅后即焚/邀请码/本机 PIN（显示各功能当前值）
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '菜单 / More',
            onSelected: (value) {
              // 修复（2026-09-05）：不能在菜单 pop 动画未完成时立即打开新 route——
              // MenuRoute 与 DialogRoute 会在 Overlay 中交叉卸载，触发
              // InheritedElement.debugDeactivated 的 _dependents.isEmpty 断言崩溃
              // （真机 vsync 下必现，widget 测试帧驱动掩盖）。等菜单完全关闭再打开。
              Future<void>.delayed(const Duration(milliseconds: 300), () {
                if (!mounted) return;
                switch (value) {
                  case 'locale':
                    _showLocalePicker();
                  case 'burn':
                    _showBurnPicker();
                  case 'invite':
                    _showInviteDialog();
                  case 'pin':
                    _showSetLockDialog();
                  case 'passphrase':
                    _showChangePassphraseDialog();
                  case 'name':
                    _showRenameDialog(renameDevice: false);
                  case 'avatar':
                    _showAvatarUpload();
                  case 'devname':
                    _showRenameDialog(renameDevice: true);
                  case 'exit':
                    _showExitAppDialog();
                }
              });
            },
            itemBuilder: (context) {
              // 语言当前值：取实际生效 locale 的语言码 → 中文/English 名
              final langCode = Localizations.localeOf(context).languageCode;
              // 行内左侧标签用稍淡色，与右侧当前值文字（默认 onSurface 深色）区分
              final labelStyle =
                  TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
              return [
                // 「我的」组（关于我的信息）置顶：名字/头像/设备名称
                PopupMenuItem(
                  value: 'name',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuMyNameLabel, style: labelStyle),
                      const Spacer(),
                      Text(_myPersonName.isEmpty ? l10n.chatPageNameUnset : _myPersonName),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'avatar',
                  child: Row(
                    children: [
                      Expanded(child: Text(l10n.chatPageMenuAvatar, style: labelStyle)),
                      const SizedBox(width: 10),
                      CircleAvatar(
                        radius: 12,
                        backgroundImage:
                            _myAvatarBytes != null ? MemoryImage(_myAvatarBytes!) : null,
                        child: _myAvatarBytes == null
                            ? const Icon(Icons.person, size: 16)
                            : null,
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'devname',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuDeviceNameLabel, style: labelStyle),
                      const Spacer(),
                      Text(_myDeviceName.isEmpty ? l10n.chatPageNameUnset : _myDeviceName),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                // 系统设置组：语言/阅后即焚/邀请/PIN/导出/口令
                PopupMenuItem(
                  value: 'locale',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuLocaleLabel, style: labelStyle),
                      const Spacer(),
                      Text(kLocaleLabels[langCode] ?? langCode),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'burn',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuBurnLabel, style: labelStyle),
                      const Spacer(),
                      Text(_burnOptionLabel(_burnSeconds, l10n)),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'pin',
                  child: Row(
                    children: [
                      Text(l10n.chatPagePinLabel, style: labelStyle),
                      const Spacer(),
                      Text(_hasPin ? l10n.chatPagePinSetValue : l10n.chatPagePinUnsetValue),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'invite',
                  child: Text(l10n.chatPageMenuInvite, style: labelStyle),
                ),
                PopupMenuItem(
                  value: 'passphrase',
                  child: Text(l10n.chatPageMenuChangePassphrase, style: labelStyle),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'exit',
                  child: Text(l10n.chatPageMenuExit, style: labelStyle),
                ),
              ];
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
          // 对话顶部：双方名字 + 各自在线状态（对方左 / 我右，与消息对齐一致）
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 对方（左）：在线圆点 + 名字（名字为空则不显示文本，只留圆点）
                Row(
                  children: [
                    Icon(Icons.circle, size: 8, color: _peerOnline ? Colors.green : Colors.red),
                    if (_peerName.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(_peerName,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                    ],
                  ],
                ),
                // 我的（右）：身份名字 + 在线圆点（三态：灰=未连接服务 / 绿=已连接 / 红=断线；
                // 名字为空则不显示文本，只留圆点）
                Row(
                  children: [
                    if (_myPersonName.isNotEmpty) ...[
                      Text(_myPersonName,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      const SizedBox(width: 6),
                    ],
                    Icon(Icons.circle, size: 8,
                        color: _ws == null
                            ? Colors.grey
                            : (_ws!.connected.value ? Colors.green : Colors.red)),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (context, i) {
                final m = _messages[i];
                final mine = m.sender == 'me';
                // 头像 personId：信封字段优先，缺失（旧版附件/语音消息）用设备映射兜底
                final avatarPersonId =
                    m.env.senderPersonId ?? _repo.personIdOfDevice(m.env.senderDeviceId);
                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 每条消息前放置发送者头像（点击有头像时放大全屏查看）
                      if (!mine)
                        _MessageAvatar(
                            personId: avatarPersonId, server: widget.server, api: widget.api),
                      const SizedBox(width: 6),
                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        // 气泡最大宽度 = 屏幕 75%：长文本在此约束下自动换行
                        // （否则 Row(min) 给 Text 无界宽度 → 长消息挤在一行溢出屏幕）
                        constraints: BoxConstraints(
                            maxWidth: MediaQuery.sizeOf(context).width * 0.75),
                        decoration: BoxDecoration(
                          color: mine ? Colors.indigo.shade100 : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (m.expiresAt != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: Text(l10n.chatPageBurnBadge,
                                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
                              ),
                            _buildMessageContent(m),
                          ],
                        ),
                      ),
                      if (mine) ...[
                        const SizedBox(width: 6),
                        _MessageAvatar(
                            personId: avatarPersonId, server: widget.server, api: widget.api),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  // 附件：拍照 / 相册（图像、视频共用入口）
                  IconButton(
                    onPressed: _showAttachmentSheet,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                  // 语音入口：点按=切提示态/回文字态；长按=直接开始录音（与长按录音条等价）
                  GestureDetector(
                    onLongPressStart: (_) => _startVoice(),
                    onLongPressEnd: (_) => _stopVoice(),
                    child: IconButton(
                      icon: Icon(_voiceEntryIcon(),
                          color: _inputMode == _InputMode.recording ? Colors.red : null),
                      onPressed: _onVoiceEntryTap,
                    ),
                  ),
                  Expanded(
                    // Stack：文字输入框始终占位（行高恒定，切换录音条时按钮不浮动），
                    // 录音/预览时录音条 Positioned.fill 覆盖其上（与输入框严格同高）
                    child: Stack(
                      children: [
                        // 录音条覆盖时完全隐藏输入框（maintainSize 保持占位高度，
                        // 行高/按钮位置不变；避免圆角录音条透出输入框边角）
                        Visibility(
                          visible: _inputMode == _InputMode.text,
                          maintainState: true,
                          maintainSize: true,
                          maintainAnimation: true,
                          child: TextField(
                            controller: _input,
                            focusNode: _inputFocusNode,
                            decoration:
                                InputDecoration(hintText: l10n.chatPageInputHint, isDense: true),
                            // 回车发送后焦点回到输入框（键盘完成动作默认失焦——补回聚焦）
                            onSubmitted: (_) {
                              _send();
                              _inputFocusNode.requestFocus();
                            },
                          ),
                        ),
                        if (_inputMode != _InputMode.text)
                          // 长按手势挂在常驻的 GestureDetector 上：提示态长按开始录音，
                          // 进入录音态后此层不重建，松手能正常触发停止
                          Positioned.fill(
                            child: GestureDetector(
                              onLongPressStart: (_) => _startVoice(),
                              onLongPressEnd: (_) => _stopVoice(),
                              child: _buildVoiceBar(),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 发送键：文字态发文字；预览态发录音；提示/录音态禁用（无可发内容）
                  IconButton.filled(
                    onPressed: _inputMode == _InputMode.preview
                        ? _sendVoice
                        : (_inputMode == _InputMode.text ? _send : null),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      ],
      ),
    );
  }
}

/// 补设/重设启动锁弹窗（StatefulWidget）：controller 生命周期随 State 卸载同步释放，
/// 避免"点设置后 dispose 竞态"（TextField 卸载动画中向已销毁 controller 加 listener
/// → debugAssertNotDisposed / _dependents.isEmpty 红屏，2026-09-05 真机定位）。
class _SetLockDialog extends StatefulWidget {
  const _SetLockDialog({required this.payload, required this.db});

  final AppLockPayload payload;
  final LocalDatabase db;

  @override
  State<_SetLockDialog> createState() => _SetLockDialogState();
}

class _SetLockDialogState extends State<_SetLockDialog> {
  final _pinCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pinCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final pin = _pinCtrl.text;
    // 两空 = 设为空：取消启动锁（Space Key 转明文保存，与向导"暂不设置"一致）
    if (pin.isEmpty && _confirmCtrl.text.isEmpty) {
      // async gap 前同步捕获 overlay（根 Overlay 在路由 pop 后仍存活），避免 use_build_context_synchronously
      final overlay = Overlay.of(context, rootOverlay: true);
      // 显性确认：清除 PIN 锁屏（防误触——两空提交前必须弹窗确认）
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.chatPageClearLockTitle),
          content: Text(l10n.chatPageClearLockMessage),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.confirm)),
          ],
        ),
      );
      if (confirmed != true) return; // 取消：留在本弹窗（不执行清除）
      try {
        await AppLockService(widget.db).savePlain(widget.payload);
        await AppLockService(widget.db).clearPackage();
        if (!mounted) return;
        Navigator.of(context).pop(true); // 菜单刷新「PIN: 未设置」
        showTopNoticeOn(overlay, l10n.chatPageSetLockCleared);
      } catch (e) {
        if (!mounted) return;
        setState(() => _error = l10n.setPinDialogSetupFailed('$e'));
      }
      return;
    }
    if (pin.length < 4) {
      setState(() => _error = l10n.setPinDialogPinTooShort);
      return;
    }
    if (pin != _confirmCtrl.text) {
      setState(() => _error = l10n.setPinDialogPinMismatch);
      return;
    }
    // async gap 前同步捕获 overlay（根 Overlay 在路由 pop 后仍存活），避免 use_build_context_synchronously
    final overlay = Overlay.of(context, rootOverlay: true);
    // 显性确认：设置/重设 PIN 锁屏（防误触——与设空清除的确认弹窗对称）
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.chatPageSetLockConfirmTitle),
        content: Text(l10n.chatPageSetLockConfirmMessage),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.confirm)),
        ],
      ),
    );
    if (confirmed != true) return; // 取消：留在本弹窗（不设置）
    try {
      await AppLockService(widget.db).setPin(pin, payload: widget.payload);
      if (!mounted) return;
      Navigator.of(context).pop(true); // true = 设置成功（菜单刷新「PIN: 已设置」）
      showTopNoticeOn(overlay, l10n.chatPageSetLockDone);
    } catch (e) {
      if (!mounted) return; // 弹窗可能已被关闭（barrier/返回），避免 setState on disposed
      setState(() => _error = l10n.setPinDialogSetupFailed('$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.chatPageSetLockTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, // 小字/输入框与大标题左对齐（老板要求）
        children: [
          // 提示：可留空直接提交，即可清空 PIN（大标题下、输入框上方——老板要求）
          Text(
            l10n.chatPageSetLockClearHint,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _pinCtrl,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l10n.setPinDialogPinLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _confirmCtrl,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l10n.setPinDialogConfirmLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.cancel)),
        FilledButton(onPressed: _submit, child: Text(l10n.setPinDialogSetPin)),
      ],
    );
  }
}

/// 修改口令弹窗（StatefulWidget）：旧口令验证（fetch 口令密保箱解密）→
/// 新口令重加密上传（含新 argon2id 哈希）→ 本地明文 payload 同步更新。
class _ChangePassphraseDialog extends StatefulWidget {
  const _ChangePassphraseDialog({
    required this.server,
    required this.spaceKeyB64,
    required this.spaceId,
    required this.keyVersion,
    required this.token,
    required this.db,
    required this.onPassphraseUpdated,
  });

  final String server;
  final String spaceKeyB64;
  final String spaceId;
  final int keyVersion;
  final String token;
  final LocalDatabase db;

  /// 上传成功后回传服务端 updated_at（聊天页记录已知时间，防下次补查误报自己改了口令）。
  final ValueChanged<int?> onPassphraseUpdated;

  @override
  State<_ChangePassphraseDialog> createState() => _ChangePassphraseDialogState();
}

class _ChangePassphraseDialogState extends State<_ChangePassphraseDialog> {
  final _oldCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _oldCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final oldPass = _oldCtrl.text.trim();
    final newPass = _newCtrl.text.trim();
    final confirm = _confirmCtrl.text.trim();
    if (newPass.isEmpty) {
      setState(() => _error = l10n.setupPageNeedPassphrase);
      return;
    }
    if (newPass != confirm) {
      setState(() => _error = l10n.chatPageChangePassphraseMismatch);
      return;
    }
    // 显性确认：修改密保口令（防误触——老板要求）
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.chatPageChangePassphraseConfirmTitle),
        content: Text(l10n.chatPageChangePassphraseConfirmMessage),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.confirm)),
        ],
      ),
    );
    if (confirmed != true) return; // 取消：留在本弹窗（不修改）
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ApiClient(widget.server);
      final escrow = KeyEscrowService(api);
      // 1) 验证旧口令：必须能解开服务器当前口令密保箱
      final snap = await api.getKeyEscrow(widget.token);
      final file = snap.file;
      if (file == null) {
        throw const _NoEscrowException();
      }
      try {
        await escrow.openPackage(passphrase: oldPass, file: file);
      } on FormatException {
        if (!mounted) return;
        setState(() => _error = l10n.chatPageChangePassphraseOldWrong);
        return;
      }
      // 2) 新口令重加密 + 上传（rotated: true → 服务端广播口令重设通知并推进 updated_at）
      await escrow.upload(
        passphrase: newPass,
        spaceKeyB64: widget.spaceKeyB64,
        spaceId: widget.spaceId,
        keyVersion: widget.keyVersion,
        token: widget.token,
        rotated: true,
      );
      // 3) 本地明文 payload 同步（跳过 PIN 场景；设 PIN 场景由 _syncEscrow 保护）。
      //    同步本端已知口令更新时间，避免下次上线补查误报"对方重设"（其实是自己刚改的）
      int? serverUpdatedAt;
      try {
        serverUpdatedAt = (await api.getKeyEscrow(widget.token)).updatedAt;
      } catch (_) {
        // 记录失败不影响结果（下次上线补查再对比）
      }
      await AppLockService(widget.db)
          .updateEscrowPassphrase(newPass, updatedAt: serverUpdatedAt);
      widget.onPassphraseUpdated(serverUpdatedAt); // 聊天页记录已知时间
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on _NoEscrowException {
      if (!mounted) return;
      setState(() => _error = l10n.chatPageChangePassphraseNoEscrow);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = l10n.chatPageChangePassphraseFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.chatPageChangePassphraseTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _oldCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.chatPageChangePassphraseOldLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _newCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.chatPageChangePassphraseNewLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _confirmCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.chatPageChangePassphraseConfirmLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.cancel)),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(l10n.chatPageChangePassphraseTitle),
        ),
      ],
    );
  }
}

/// 尚未托管口令（服务器无 escrow 包）。
class _NoEscrowException implements Exception {
  const _NoEscrowException();
}

/// 波形条（录音条内）：等宽竖条，高度按振幅采样归一化值；
/// 按可用宽度只渲染能放下的条数（取尾部最新采样），窄屏也不会顶出屏幕。
class _WaveformBars extends StatelessWidget {
  const _WaveformBars({required this.samples, required this.color});

  final List<double> samples;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const step = 6.0; // 每根条占宽：3px 本体 + 1.5px 边距 ×2
      final maxBars = (constraints.maxWidth / step).floor();
      final count = maxBars <= 0 ? 0 : (samples.length < maxBars ? samples.length : maxBars);
      final shown = count <= 0 ? const <double>[] : samples.sublist(samples.length - count);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final sample in shown)
            Container(
              width: 3,
              height: 8 + sample * 22,
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
        ],
      );
    });
  }
}

/// 消息发送者头像：按 personId 从服务端加载（静态缓存避免重复请求），
/// 未设置/加载失败显示默认图标；点击有头像时放大到全屏查看。
class _MessageAvatar extends StatefulWidget {
  const _MessageAvatar({this.personId, required this.server, this.api});

  final String? personId;
  final String server;
  final ApiClient? api;

  @override
  State<_MessageAvatar> createState() => _MessageAvatarState();
}

class _MessageAvatarState extends State<_MessageAvatar> {
  static final Map<String, Uint8List> _cache = {}; // personId → 头像 bytes

  Uint8List? get _bytes => widget.personId == null ? null : _cache[widget.personId];

  @override
  void initState() {
    super.initState();
    final pid = widget.personId;
    if (pid != null && !_cache.containsKey(pid)) {
      _load(pid);
    }
  }

  Future<void> _load(String personId) async {
    try {
      final api = widget.api ?? ApiClient(widget.server);
      final bytes = await api.getAvatar(personId);
      if (bytes != null && mounted) {
        _cache[personId] = bytes;
        setState(() {});
      }
    } catch (_) {
      // 网络失败：保持默认图标
    }
  }

  /// 全屏查看头像（黑底大图 + 右上角关闭）。
  void _showFullscreen() {
    final bytes = _bytes;
    if (bytes == null) return;
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            Positioned.fill(child: Image.memory(bytes, fit: BoxFit.contain)),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return GestureDetector(
      onTap: bytes != null ? _showFullscreen : null,
      child: CircleAvatar(
        radius: 16,
        backgroundColor: Colors.grey.shade300,
        backgroundImage: bytes != null ? MemoryImage(bytes) : null,
        child: bytes == null ? const Icon(Icons.person, size: 18) : null,
      ),
    );
  }
}

/// 邀请码二维码（自绘，替代 QrImageView）。
///
/// QrImageView（qr_flutter 4.1.0）两个坑（2026-09-08 老板真机报告：生成邀请码
/// 时屏幕变暗但弹窗不出现；且弹窗里的二维码从未显示）：
/// 1. 内部无条件包 LayoutBuilder，而 AlertDialog 用 IntrinsicWidth 包裹内容做
///    固有尺寸测量 → performLayout 抛 "LayoutBuilder does not support returning
///    intrinsic dimensions"（Flutter issue #46063 同款签名）→ 弹窗首帧布局中断，
///    遮罩变暗、内容不显示；
/// 2. 其绘制面 CustomPaint 无显式尺寸、被内部 Padding 松约束包裹 → 实际 0x0，
///    QrPainter.paint 直接 return，二维码不可见。
/// 这里直接用 QrCode + QrPainter 自绘：无 LayoutBuilder（固有测量安全）、
/// 显式 SizedBox 定尺寸（必定可见）。
class _InviteQrCode extends StatelessWidget {
  const _InviteQrCode({required this.data});

  /// 邀请码（服务端固定 20 字符 + 分隔符，QR 容量绰绰有余，不会超长）。
  final String data;

  @override
  Widget build(BuildContext context) {
    final qr = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.L,
    );
    return SizedBox(
      width: 160,
      height: 160,
      child: CustomPaint(painter: QrPainter.withQr(qr: qr)),
    );
  }
}
