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
import 'data/ui_style_settings.dart';
import 'data/ws_realtime_service.dart';
import 'l10n/app_localizations.dart';
import 'lock_page.dart';
import 'setup_page.dart';
import 'widgets/top_notice.dart';
import 'widgets/ui_style_picker.dart';

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
    this.publicKeyB64, // 设备公钥（b64，随锁包持久化；弹窗展示用）
    this.privateKeyB64, // 设备私钥（b64，随锁包持久化；补设锁写入新锁包）
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

  /// 设备 X25519 公钥（b64，随锁包持久化）：「我的设备」弹窗展示用。
  final String? publicKeyB64;

  /// 设备 X25519 私钥（b64，随锁包持久化）：补设锁/改口令时写入新锁包。
  final String? privateKeyB64;

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
  // 视频解密缓存（messageId → Future<bytes>），内联预览用（避免重复解密）。
  final Map<String, Future<Uint8List>> _videoCache = {};
  List<HistoryMessage> _messages = [];
  Timer? _ticker;
  // 分页加载（UI 懒渲染）：上滑到顶部加载更早历史；ticker 只增量追加新增
  final ScrollController _scrollController = ScrollController();
  bool _hasMoreOlder = true;
  bool _loadingOlder = false;
  // 首屏本地历史是否已上屏（用于守卫 _refreshLocal：未加载时 _lastLoadedSequence=0
  // 会触发全量解密）
  bool _initialLoaded = false;
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
  HistoryMessage? _quoteTarget; // 长按「引用」选中的原消息（输入栏引用条 + 发送携带）
  // 点击引用卡跳转定位：目标消息的 GlobalKey（仅目标项持有，避免全列表 key
  // 阻碍懒回收）+ 目标 messageId（itemBuilder 按需挂 key）
  final GlobalKey _jumpTargetKey = GlobalKey();
  String? _jumpTargetId;
  // 跳转后目标消息短暂高亮背景（显眼橘黄 #FF9800，2s 后恢复原色）：
  // messageId + 定时清除（只换背景色、尺寸不变——边框方案实测闪烁期间
  // 气泡尺寸变化已弃用，老板要求 2026-09-10）
  String? _highlightMessageId;
  Timer? _highlightTimer;
  late String _uiStyle; // 当前界面风格（'plain'=素雅纯色 / 'gradient'=渐变粉蓝）
  bool _hasPin = false; // 本机是否已设置启动锁（菜单项「PIN: 已设置/未设置」）
  WsRealtimeService? _ws; // WS 实时（收到 message.new 立即刷新；断线自动重连）
  late String _myPersonName; // 我的名字（菜单显示；改名后 setState 刷新）
  late String _myDeviceName; // 我的设备名（菜单显示；改名后 setState 刷新）
  late String _myGender; // 我的性别（male/female/''；profile 恢复，个人资料弹窗图标展示）
  late String _peerGender; // 对方性别（male/female/''；profile 恢复，消息气泡配色用）
  Uint8List? _myAvatarBytes; // 我的头像 bytes 缓存（菜单显示；上传后刷新）
  late String _peerName; // 对方名字（对话顶部条显示）
  bool _peerOnline = false; // 对方在线状态（last_seen 距今 <60s）
  int? _escrowUpdatedAt; // 本端已知口令更新时间（上线补查对比用；沿用 widget 初值）
  Timer? _peerTicker; // 对方在线轮询（30s）

  /// 阅后即焚档位文案（l10n 映射）。
  String _burnOptionLabel(int seconds, AppLocalizations l10n) {
    switch (seconds) {
      case 0:
        return l10n.burnOptionKeepIndefinitely;
      case 60:
        return l10n.burnOption1Minute;
      case 300:
        return l10n.burnOption5Minutes;
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

  /// 消息发送时间标注：当天 HH:MM / 当年 mm-dd HH:MM / 跨年 yyyy-mm-dd HH:MM。
  String _messageTimeLabel(HistoryMessage m) {
    final local = DateTime.fromMillisecondsSinceEpoch(m.createdAt).toLocal();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${two(local.hour)}:${two(local.minute)}';
    }
    if (local.year == now.year) {
      return '${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
    }
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  /// 自己消息的发送状态小标：pending=发送中（时钟）/ sent=已发送（对勾）/
  /// failed=发送失败（红色警告，点按重发）。仅自己、非墓碑消息显示（老板 2026-09-12）。
  Widget _buildSendStatusIcon(HistoryMessage m) {
    final l10n = AppLocalizations.of(context)!;
    final subtle = _uiStyle == 'gradient' ? Colors.white70 : Colors.grey;
    switch (m.status) {
      case 'failed':
        return Tooltip(
          message: l10n.chatPageMsgFailed,
          child: GestureDetector(
            onTap: () async {
              await _repo.retryMessage(m.env.messageId);
              await _refreshLocal();
            },
            child: Icon(Icons.error_outline, size: 12, color: Colors.red.shade600),
          ),
        );
      case 'sent':
      case 'delivered':
      case 'read':
        return Tooltip(
          message: l10n.chatPageMsgSent,
          child: Icon(Icons.check, size: 12, color: subtle),
        );
      default: // pending（队列中/发送中）
        return Tooltip(
          message: l10n.chatPageMsgSending,
          // 纸飞机=发送中（老板 2026-09-12；原来与阅后即焚的时钟撞字形）
          child: Icon(Icons.send, size: 11, color: subtle),
        );
    }
  }

  /// 阅后即焚时长紧凑标注（1m / 5m / 30m / 1h / 1d / 7d）。
  String _burnDurationLabel(int seconds) {
    if (seconds <= 0) return '';
    if (seconds % 86400 == 0) return '${seconds ~/ 86400}d';
    if (seconds % 3600 == 0) return '${seconds ~/ 3600}h';
    if (seconds % 60 == 0) return '${seconds ~/ 60}m';
    return '${seconds}s';
  }

  /// 阅后即焚「设置（修改）时间」紧凑标注（HH:MM）。由到期时间戳反推：
  /// setMessageBurn 设 expiresAt = 设置时刻 + 时长，故 设置时刻 = expiresAt - 时长。
  String _burnSetTimeLabel(int? expiresAt, int burnSeconds) {
    if (expiresAt == null || burnSeconds <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(expiresAt - burnSeconds * 1000);
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// 阅后即焚时钟标签：只有用户长按单条消息手动设置的才标注「设置(修改)时间+时长」
  /// （如 ⏰ 20:47+5m，便于看出倒计时起点）；由全局设置快照的只标时长（如 ⏰ 5m），
  /// 首次接收时间已由 [m.createdAt] 的时间戳给出（老板 2026-09-12）。
  String _burnTagLabel(int? expiresAt, int burnSeconds, {required bool manual}) {
    final dur = _burnDurationLabel(burnSeconds);
    if (!manual) return dur;
    final setTime = _burnSetTimeLabel(expiresAt, burnSeconds);
    return setTime.isNotEmpty ? '$setTime+$dur' : dur;
  }

  @override
  void initState() {
    super.initState();
    _myPersonName = widget.personName ?? '';
    _myDeviceName = widget.deviceName ?? '';
    _myGender = ''; // 个人资料弹窗性别图标：由 profile 恢复（向导完成时写入）
    _peerGender = ''; // 消息气泡配色：由 profile 恢复（向导完成时写入）
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
        if (_myGender.isEmpty) _myGender = p['myGender'] ?? '';
        if (_peerGender.isEmpty) _peerGender = p['peerGender'] ?? '';
      });
      // 快照可能过期（对方改名 / v2 早期把对方性别写死空串）→ 以服务端为准校正
      // 名字与性别（老板 2026-09-11：App 重启后一直显示旧的对方名字）
      _refreshProfileFromServer();
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
    // 首帧同步取值（同进程内延续上次选择，避免首帧 LateInitializationError），
    // 随后用持久化值校正（_loadUiStyle 异步）
    _uiStyle = uiStyleNotifier.value;
    _loadUiStyle(); // 恢复界面风格（plain/gradient，默认素雅纯色）
    // 风格切换即时生效（弹窗不关闭也能预览）：notifier 通知 → 重建背景
    uiStyleNotifier.addListener(_onUiStyleChanged);
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

  /// 对方改名/换头像（Server 广播 profile.updated）：立即更新顶部条对方名；
  /// 头像则让缓存失效重拉（广播由改名或 POST /avatar 触发）。
  void _onProfileUpdated(WsProfileUpdatedEvent event) {
    // 头像：无论改名还是换头像都刷一次（同一 per-person 头像文件可能已变）
    _MessageAvatarState.invalidate(event.personId);
    _refreshProfileFromServer();
    final name = event.personName;
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _peerName = name);
  }

  /// 从服务端校正双方名字与性别（GET /space 的 personNames/personGenders）。
  /// 本机 profile 只是入网时的快照：对方改名后若没收到广播（或广播前就重启），
  /// App 会一直显示旧名字（老板 2026-09-11 实测）；性别同理（v2 早期把对方性别
  /// 写死空串 → 气泡回退灰色）。启动与收到 profile.updated 时调用
  /// （对齐 CLI 的 _refreshPersonNames）。
  Future<void> _refreshProfileFromServer() async {
    if (!mounted || widget.token.isEmpty || widget.server.isEmpty) return;
    try {
      final api = widget.api ?? ApiClient(widget.server);
      final space = await api.getSpace(widget.token);
      // 重启（PIN 解锁）路径不传 personId（main.dart 只还原明文 payload）——
      // 从 /space 的设备表里按 deviceId 反查，否则拿不到"我"，校正无从下手
      var mine = widget.personId;
      if (mine == null || mine.isEmpty) {
        for (final d in space.devices) {
          if (d.deviceId == widget.deviceId) {
            mine = d.personId;
            break;
          }
        }
      }
      if (mine == null || mine.isEmpty) return;
      final myG = space.personGenders[mine] ?? '';
      var peerG = '';
      var peerName = '';
      for (final entry in space.personNames.entries) {
        if (entry.key == mine) continue;
        peerName = entry.value;
        peerG = space.personGenders[entry.key] ?? '';
        break;
      }
      final myName = space.personNames[mine] ?? '';
      if (!mounted) return;
      setState(() {
        if (myName.isNotEmpty) _myPersonName = myName;
        if (peerName.isNotEmpty) _peerName = peerName;
        if (myG.isNotEmpty) _myGender = myG;
        if (peerG.isNotEmpty) _peerGender = peerG;
      });
      // 校正结果回写本地快照：否则下次启动（尤其离线）又用回入网时的旧值
      // （setState 只覆盖非空值，故不会把已有名字写成空）
      await AppLockService(widget.db ?? LocalDatabase()).saveProfile(
        personName: _myPersonName,
        peerName: _peerName,
        deviceName: _myDeviceName,
        myGender: _myGender,
        peerGender: _peerGender,
      );
    } catch (_) {
      // 网络失败：保持快照值（下次刷新再试）
    }
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

  /// 加载持久化的界面风格（默认素雅纯色，保留原有视觉效果）。
  Future<void> _loadUiStyle() async {
    final s = UiStyleSettings(widget.db ?? LocalDatabase());
    final style = await s.load();
    if (mounted) setState(() => _uiStyle = style);
  }

  /// 风格切换通知（弹窗内点选即触发）：立即重建背景与菜单当前值。
  void _onUiStyleChanged() {
    if (mounted) setState(() => _uiStyle = uiStyleNotifier.value);
  }

  /// 顶栏 🎨：切换界面风格（素雅纯色/渐变粉蓝）。弹窗内点选即生效且不关闭，
  /// 用户不离开弹窗即可预览大致效果（右上角 ✕ 或下滑关闭）。
  Future<void> _showStylePicker() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => UiStylePickerSheet(
        settings: UiStyleSettings(widget.db ?? LocalDatabase()),
      ),
    );
  }

  /// 邀请设备：生成一次性 join token（POST /spaces/{id}/join-tokens，Multiverse
  /// v2，24h 一次性、免认证；旧 v1 createInvite 已废弃，不再生成 v1 邀请码）。
  /// 二维码与展示内容 = 邀请链接（`https://einz.tic.cc/join/<token>`），对方 App/
  /// CLI 可扫码或粘贴链接加入；口令由对方加入时另行输入（降级 B，与 TUI 一致）。
  Future<void> _showInviteDialog() async {
    // 老板决策：点顶栏添加按钮直接生成邀请码（不再先弹"邀请设备"确认窗）
    try {
      final api = widget.api ?? ApiClient(widget.server);
      final r = await api.createJoinToken(widget.spaceId);
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
              Center(child: _InviteQrCode(data: r.link)),
              const SizedBox(height: 12),
              // 邀请链接 + 拷贝图标（点击即复制，弹窗不关闭——根 Overlay 通知
              // 在弹窗之上可见，老板 2026-09-11）
              Row(
                children: [
                  Expanded(
                    child: SelectableText(r.link,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF2271F7))),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16),
                    color: const Color(0xFF2271F7),
                    tooltip: '复制邀请链接',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    visualDensity: VisualDensity.compact,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: r.link));
                      if (!ctx.mounted) return;
                      showTopNotice(ctx, '邀请链接已复制');
                    },
                  ),
                ],
              ),
              const SizedBox(height: 2),
              // 单独 token + 拷贝图标
              Row(
                children: [
                  Expanded(
                    child: SelectableText(r.joinToken,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.grey, letterSpacing: 0.5)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16),
                    color: Colors.grey,
                    tooltip: '复制邀请码',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    visualDensity: VisualDensity.compact,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: r.joinToken));
                      if (!ctx.mounted) return;
                      showTopNotice(ctx, '邀请码已复制');
                    },
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('新设备必须验证邀请码，才能绑定到当前秘境。24 小时内一次性有效。',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: r.link));
                if (!ctx.mounted) return;
                showTopNotice(ctx, '邀请链接已复制');
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
      publicKeyB64: widget.publicKeyB64,
      privateKeyB64: widget.privateKeyB64,
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
      // 消息流里的头像走静态缓存：主动失效才会重拉（否则要重启才更新）
      _MessageAvatarState.invalidate(widget.personId);
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
    // 公钥只读展示（我的设备弹窗）：静态文本控制器，随对话框关闭释放
    final pubKeyCtrl = TextEditingController(
      text: widget.publicKeyB64 ?? l10n.chatPageDevicePublicKeyFailed,
    );
    // 性别只读展示（我的个人资料弹窗）：框内显示 男/女，随对话框关闭释放
    final genderCtrl = TextEditingController(
      text: _myGender == 'female'
          ? l10n.wizardGenderFemale
          : _myGender == 'male'
              ? l10n.wizardGenderMale
              : '',
    );
    // 名称为空/全空格警示（红字显示在输入框下方；开始填写即消）
    final nameError = ValueNotifier<String?>(null);
    // 名字/设备名编辑态切换：初始只读透明 + 右侧编辑按钮；点编辑 → 白底可编辑、按钮消失
    final editing = ValueNotifier<bool>(false);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(renameDevice ? l10n.chatPageRenameDeviceTitle : l10n.chatPageRenameNameTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 名字/设备名输入框：初始只读 + 透明背景，右侧「编辑」按钮；点编辑 →
            // 白底可编辑、按钮消失（老板要求 2026-09-09）
            ValueListenableBuilder<bool>(
              valueListenable: editing,
              builder: (_, isEditing, _) => TextField(
                controller: ctrl,
                readOnly: !isEditing,
                decoration: InputDecoration(
                  labelText: renameDevice ? l10n.chatPageRenameDeviceLabel : l10n.chatPageRenameNameLabel,
                  border: const OutlineInputBorder(),
                  filled: isEditing, // 编辑态白底；只读态透明（沿用弹窗背景）
                  fillColor: Colors.white,
                  suffixIcon: isEditing
                      ? null
                      : IconButton(
                          tooltip: l10n.chatPageEdit,
                          icon: const Icon(Icons.edit, size: 18),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => editing.value = true,
                        ),
                ),
                // 开始填写即清除空名警示（与向导输入框一致）
                onChanged: (_) {
                  if (nameError.value != null) nameError.value = null;
                },
              ),
            ),
            ValueListenableBuilder<String?>(
              valueListenable: nameError,
              builder: (_, err, _) => err == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        err,
                        style: const TextStyle(
                          color: Colors.red,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
            ),
            // 我的设备弹窗：公钥只读展示——放在设备名称之后（textarea 样式，边框
            // 左上角「公钥」标签，右侧拷贝按钮；只读不加背景色，沿用弹窗背景）
            if (renameDevice) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: pubKeyCtrl,
                readOnly: true,
                maxLines: 2,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Colors.grey),
                decoration: InputDecoration(
                  labelText: l10n.chatPageDevicePublicKeyLabel,
                  border: const OutlineInputBorder(),
                  // 公钥只读：不加背景色，沿用弹窗背景（可编辑的设备名称才是白底）
                  suffixIcon: IconButton(
                    tooltip: l10n.chatPageCopy,
                    icon: const Icon(Icons.copy, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.publicKeyB64 == null
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: widget.publicKeyB64!));
                            showTopNotice(ctx, l10n.chatPageCopied);
                          },
                  ),
                ),
              ),
            ],
            // 我的个人资料弹窗：性别用与名字输入框同款组件（只读）——「性别」标签
            // 在边框左上角（同「我的名字」），框内显示 男/女 + 性别图标
            // （老板要求 2026-09-09）
            if (!renameDevice) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: genderCtrl,
                readOnly: true,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  labelText: l10n.chatPageGenderLabel,
                  border: const OutlineInputBorder(), // 与名字输入框同款边框
                  // 只读展示：不加背景色（沿用弹窗背景），与白底可编辑的名字输入框区分
                  suffixIcon: _myGender == 'male'
                      ? const Icon(Icons.male, color: Color(0xFF3BAFFD), size: 24)
                      : _myGender == 'female'
                          ? const Icon(Icons.female, color: Color(0xFFD6529C), size: 24)
                          : null,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
          FilledButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isEmpty) {
                // 空/全空格：红字警示并停留（不再静默跳过）；人名与设备名各用各的提示
                nameError.value = renameDevice
                    ? l10n.chatPageRenameDeviceEmptyError
                    : l10n.chatPageRenameMyselfEmptyError;
                return;
              }
              // 不允许改成与对方相同的名字（老板 2026-09-10）
              if (!renameDevice && widget.peerName != null && name == widget.peerName) {
                nameError.value = l10n.chatPageRenameSameAsPeerError;
                return;
              }
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
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      ctrl.dispose();
      pubKeyCtrl.dispose();
      genderCtrl.dispose();
      nameError.dispose();
      editing.dispose();
    });
    if (saved == true && mounted) setState(() {}); // 刷新菜单显示的新名字
  }

  /// 同步当前名字到本地 profile（改名/改设备名后调用——重启从 profile 恢复）。
  Future<void> _saveProfile() async {
    await AppLockService(widget.db ?? LocalDatabase()).saveProfile(
      personName: _myPersonName,
      peerName: _peerName,
      deviceName: _myDeviceName,
      myGender: _myGender,
      peerGender: _peerGender,
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

  /// 阅后即焚档位选择弹窗（右上角菜单全局 / 长按菜单单条消息共用）：
  /// 返回选中秒数（null=取消）；[current] 为当前值（右侧勾选标记）。
  Future<int?> _pickBurnSeconds({required int current}) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        // Column(min)：档位经精简后内容高度不超屏幕，整体显示无需滚动
        // （此前 8 档溢出 47px，删除「30 分钟」后 7 档正好容纳）
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(l10n.chatPageBurnHeading,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
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
    return picked == null ? null : int.parse(picked);
  }

  /// 顶栏 ⏱：选择阅后即焚档位（保存到本设备设置，发送新消息时生效）。
  Future<void> _showBurnPicker() async {
    final settings = BurnAfterSettings(widget.db ?? LocalDatabase());
    final current = await settings.load();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final seconds = await _pickBurnSeconds(current: current);
    if (seconds == null || !mounted) return;
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

  /// 长按菜单「阅后即焚」：选择档位后应用到被点击的这条消息（本机生效，
  /// 纯本地；老板要求 2026-09-10）。可选「无限」取消已有阅后即焚、选档位
  /// 新设或调整；到期由 repo.tombstoneExpired 统一打墓碑。
  Future<void> _setMessageBurn(HistoryMessage m) async {
    final l10n = AppLocalizations.of(context)!;
    final seconds = await _pickBurnSeconds(current: m.burnAfterSeconds);
    if (seconds == null || !mounted) return;
    final ok = await _repo.setMessageBurn(m.env.messageId, seconds);
    if (!mounted) return;
    if (!ok) {
      showTopNotice(context, l10n.chatPageBurnFailed);
      return;
    }
    // 就地更新列表里该消息的 burn 状态（倒计时即刻生效，不用整表刷新）
    final expiresAt = seconds > 0
        ? DateTime.now().millisecondsSinceEpoch + seconds * 1000
        : null;
    setState(() {
      _messages = [
        for (final x in _messages)
          if (x.env.messageId == m.env.messageId)
            (env: x.env, plaintext: x.plaintext, sender: x.sender,
                attachment: x.attachment, expiresAt: expiresAt,
                createdAt: x.createdAt, burnAfterSeconds: seconds,
                quote: x.quote, deleted: x.deleted,
                // 长按手动设置（与 repo.setMessageBurn 落盘一致）；取消时无标签
                burnManual: seconds > 0, status: x.status)
          else
            x,
      ];
    });
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
    uiStyleNotifier.removeListener(_onUiStyleChanged);
    _ticker?.cancel();
    _peerTicker?.cancel();
    _recordTimer?.cancel();
    _highlightTimer?.cancel(); // 跳转高亮定时清除（防 dispose 后 setState）
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

  /// 首次载入：先用本地缓存秒开（离线/慢网也能立刻看到历史）→ 再同步全量 →
  /// 重新渲染最近一页（UI 分页懒加载）。
  Future<void> _loadInitial() async {
    // 1) 本地缓存秒开（不等网络）
    try {
      final cached = await _repo.historyRecent(limit: _pageSize);
      if (mounted && cached.isNotEmpty) {
        setState(() => _messages = cached);
        _scrollToLatest(animate: false);
      }
    } catch (_) {
      // 解密失败（如缺归档密钥）忽略：继续走网络同步
    }
    _initialLoaded = true; // 允许 _refreshLocal 工作（此后 _lastLoadedSequence 有意义）

    // 2) 同步全量 → 清理到期 → 用最新本地历史覆盖
    try {
      await _repo.sync();
      await _repo.tombstoneExpired();
      await _repo.refreshDeviceMap();
      final recent = await _repo.historyRecent(limit: _pageSize);
      if (!mounted) return;
      setState(() => _messages = recent);
      // 首次载入即定位到最新消息（老板实测 2026-09-09：原来停在最早消息处，
      // 要等 ticker 自动刷新才滚到底）——直接跳转不播动画，进入即见最新
      _scrollToLatest(animate: false);
    } catch (_) {
      // 网络抖动忽略：本地缓存已上屏，等 ticker 重试
    }
  }

  /// 纯本地增量刷新（不发网络）：把本地新增/变更的消息并入列表——发送后「乐观回显」
  /// 与收到消息先上屏都用它，避免等 sync 网络往返（老板 2026-09-12）。
  /// 合并语义：按 messageId 就地替换（刷新 pending→sent/failed 状态），新 id 追加；
  /// 墓碑单调（本地已删的不会被旧读覆盖复活）；仅在有新消息时滚到底。
  Future<void> _refreshLocal() async {
    if (!_initialLoaded) return;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      // 阅后即焚：到期消息打本地墓碑（纯本地）
      await _repo.tombstoneExpired(now: now);
      final fresh = await _repo.historySince(afterSequence: _lastLoadedSequence);
      // 补偿：列表里仍标 pending/failed 的消息按 id 重读。它们的 server_sequence
      // 是本端 postMessage 后才回填的，可能"迟到"到高水位之下——只靠 historySince
      // 会永久漏掉，界面就一直显示"发送中"（老板 2026-09-12 实测）。
      final inflightIds = [
        for (final m in _messages)
          if (!m.deleted && (m.status == 'pending' || m.status == 'failed'))
            m.env.messageId,
      ];
      final inflight = await _repo.historyByMessageIds(inflightIds);
      if (!mounted) return;
      // inflight 后写入 → 同 id 时以它为准（读得更晚，状态更准）
      final freshById = {
        for (final f in fresh) f.env.messageId: f,
        for (final f in inflight) f.env.messageId: f,
      };
      final existingIds = {for (final m in _messages) m.env.messageId};
      final added = freshById.values
          .where((f) => !existingIds.contains(f.env.messageId))
          .toList();
      setState(() {
        _messages = [
          for (final m in _messages)
            if (m.expiresAt != null && m.expiresAt! <= now && !m.deleted)
              _asDeleted(m)
            else if (!freshById.containsKey(m.env.messageId))
              m
            else
              _mergeRefreshed(m, freshById[m.env.messageId]!),
          ...added,
        ];
      });
      if (added.isNotEmpty) _scrollToLatest();
    } catch (_) {
      // 本地读取失败忽略，下次刷新重试
    }
  }

  /// 用本地最新一行覆盖旧记录，但墓碑单调（任一为已删即已删），避免一个早于
  /// tombstoneMessage 发起的读晚到后把已删内容「复活」。
  HistoryMessage _mergeRefreshed(HistoryMessage old, HistoryMessage fresh) {
    final deleted = old.deleted || fresh.deleted;
    if (deleted == fresh.deleted) return fresh;
    return (
      env: fresh.env,
      plaintext: fresh.plaintext,
      sender: fresh.sender,
      attachment: fresh.attachment,
      expiresAt: fresh.expiresAt,
      createdAt: fresh.createdAt,
      burnAfterSeconds: fresh.burnAfterSeconds,
      quote: fresh.quote,
      deleted: deleted,
      burnManual: fresh.burnManual,
      status: fresh.status,
    );
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

  /// 滚动到底部：让最新消息显示在最下方（老板要求"总是"）。
  /// [animate] 为 false 时直接跳转（首次载入用——进入聊天页应立即看到最新，
  /// 不播从顶部一路飞过的动画）；新消息到达用默认平滑滚动。
  /// post-frame 里执行（ListView 重建后 maxScrollExtent 才有效）。
  void _scrollToLatest({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (animate) {
        _scrollController
            .animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            )
            .then((_) => _jumpToBottom()); // 动画落点可能偏短（懒加载估算）：校正贴底
      } else {
        _jumpToBottom();
      }
    });
  }

  /// 直接跳到列表底部。懒构建列表首帧的 maxScrollExtent 是**估算值**——末尾是
  /// 引用消息（气泡更高）时真实 extent 更大、估算偏低，一次 jumpTo 会停在半路
  /// （老板实测 2026-09-09：发了几条引用后重启不能自动跳到底）。跳转会触发
  /// 目标附近条目补建、extent 变准，逐帧校正直到贴底（depth 上限防极端死循环）。
  void _jumpToBottom([int depth = 0]) {
    if (!mounted || !_scrollController.hasClients || depth > 5) return;
    final target = _scrollController.position.maxScrollExtent;
    _scrollController.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (_scrollController.position.maxScrollExtent > target + 1) {
        _jumpToBottom(depth + 1);
      }
    });
  }

  /// 点击引用卡跳转到原消息位置（老板要求 2026-09-10）。
  ///
  /// 原消息可能在已加载列表外（UI 分页懒加载只渲染最近一页）——先按 messageId
  /// 查 serverSequence，往前分页加载直到覆盖目标，再定位。定位用「估算 jumpTo
  /// 触发目标附近构建 → 目标项 GlobalKey ensureVisible 精确校正」两步（懒构建
  /// 下远处 item 无元素，直接 ensureVisible 会找不到）。
  Future<void> _jumpToMessage(String messageId) async {
    if (messageId.isEmpty || !mounted) return;
    var index = _messages.indexWhere((m) => m.env.messageId == messageId);
    if (index < 0) {
      // 目标未加载：往前分页补载直到覆盖目标（或历史已到顶）
      final targetSeq = await _repo.sequenceOfMessage(messageId);
      if (targetSeq == null) return; // 原消息不存在（非本空间/已清理）
      while (index < 0 && mounted) {
        final first = _messages.isEmpty ? null : _messages.first.env.serverSequence;
        if (first == null || first <= targetSeq) break;
        final older = await _repo.historyBefore(beforeSequence: first, limit: _pageSize);
        if (older.isEmpty) break;
        if (!mounted) return;
        setState(() {
          _messages = [...older, ..._messages];
          _hasMoreOlder = older.length >= _pageSize;
        });
        index = _messages.indexWhere((m) => m.env.messageId == messageId);
      }
      if (index < 0) return;
    }
    if (!mounted) return;
    setState(() => _jumpTargetId = messageId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      // 先立即置高亮背景：目标已构建（视口/预构建区）即刻生效；目标很远时由
      // 后续 jumpTo 触发的构建按 _highlightMessageId 应用。不能放进嵌套
      // post-frame——目标已在视口时 jumpTo 是 no-op 不调度新帧，嵌套回调
      // 永不执行（2026-09-10 测试暴露的真机同类 bug）。
      // 节奏（老板要求 2026-09-10）：渐变 1.5s 完成后立即触发清除（停留 0s），
      // 随后 AnimatedContainer 再渐变 1.5s 回原色（总时长 3s）。
      _highlightTimer?.cancel();
      setState(() => _highlightMessageId = messageId);
      _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _highlightMessageId = null);
      });
      // 定位：按平均高度估算跳转（触发目标附近条目构建）
      final estimated = (index * 120.0)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.jumpTo(estimated);
      // 目标项已构建 → GlobalKey 精确校正（居中显示；目标已在视口时 jumpTo
      // no-op、无新帧，此回调不执行，但目标本就可见无需校正）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = _jumpTargetKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx,
              duration: const Duration(milliseconds: 300), alignment: 0.5);
        }
      });
    });
  }

  /// 增量刷新：**先本地秒上屏**（_refreshLocal）→ 再网络 sync → 再本地刷新一次。
  /// 这样收到的消息/自己的回执能立即出现，网络慢也不阻塞已到内容（老板 2026-09-12）。
  Future<void> _refresh() async {
    await _refreshLocal();
    try {
      await _repo.sync();
      await _repo.refreshDeviceMap();
      await _refreshLocal();
    } catch (_) {
      // 网络抖动忽略，下次轮询重试
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final quote = _quoteTarget;
    _input.clear();
    setState(() => _quoteTarget = null);
    try {
      await _repo.send(
        text,
        quote: quote == null
            ? null
            : {
                'messageId': quote.env.messageId,
                'preview': _quotePreview(quote.plaintext),
              },
        // 本地落库即回显 pending 气泡（乐观 UI），不等上传/sync 往返
        onPersisted: (_) => _refreshLocal(),
      );
      // 上传已尝试完成：刷新状态（pending→sent/failed）
      await _refreshLocal();
    } catch (e) {
      if (!mounted) return;
      showTopNotice(context, AppLocalizations.of(context)!.chatPageSendFailed('$e'));
    }
  }

  /// 发送附件（语音/图片/视频/文件）：本地落库即回显，再刷新状态。
  Future<void> _sendAttachmentOptimistic({
    required Uint8List fileBytes,
    required String fileName,
    required String type,
    String? caption,
  }) async {
    await _repo.sendAttachment(
      fileBytes: fileBytes,
      fileName: fileName,
      type: type,
      caption: caption,
      onPersisted: (_) => _refreshLocal(),
    );
    await _refreshLocal();
  }

  // ---------- 长按消息操作：引用 / 删除（2 人世界不做转发） ----------

  /// 长按消息弹出操作菜单：引用 / 删除。
  Future<void> _showMessageActions(HistoryMessage m) async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部：发言人头像 + 该消息正文（按性别气泡风格，单行截断不溢出；
            // 老板要求 2026-09-10）
            _buildMessagePreviewRow(m),
            // 与下方可点击菜单项分隔（预览行非交互，避免误触）
            const Divider(height: 1, thickness: 1),
            ListTile(
              leading: const Icon(Icons.format_quote),
              title: Text(l10n.chatPageActionQuote),
              onTap: () => Navigator.of(ctx).pop('quote'),
            ),
            // 单条消息阅后即焚：可新设/调整档位、选「无限」取消（老板要求 2026-09-10）
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text(l10n.chatPageActionBurn),
              onTap: () => Navigator.of(ctx).pop('burn'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Colors.red.shade400),
              title: Text(l10n.chatPageActionDelete,
                  style: TextStyle(color: Colors.red.shade400)),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'delete') {
      await _deleteMessage(m);
    } else if (action == 'quote') {
      setState(() => _quoteTarget = m);
      _inputFocusNode.requestFocus();
    } else if (action == 'burn') {
      await _setMessageBurn(m);
    }
  }

  /// 长按菜单顶部的消息预览行：发言人头像 + 按性别气泡风格的正文。
  /// 正文单行截断不溢出（老板要求 2026-09-10）；头像左右位置与消息流一致
  /// （我的在右、对方在左）；附件消息无正文时显示消息类型作占位。
  /// Row 撑满整行并按消息流对齐（对方靠左、我的靠右）——此前 mainAxisSize.min
  /// 短消息整行收缩被弹窗居中，长消息撑满贴边，视觉效果不稳定（老板要求
  /// 2026-09-10 修复）。
  Widget _buildMessagePreviewRow(HistoryMessage m) {
    final mine = m.sender == 'me';
    final avatarPersonId =
        m.env.senderPersonId ?? _repo.personIdOfDevice(m.env.senderDeviceId);
    final preview = m.plaintext.trim();
    final text = preview.isEmpty ? m.env.type : preview;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        key: const ValueKey('messagePreviewRow'), // 测试断言对齐用（项目惯例）
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment:
            mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!mine) ...[
            _MessageAvatar(
                personId: avatarPersonId, server: widget.server, api: widget.api),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                // 与消息流一致：按发言人性别配色（男天蓝 / 女品牌粉）
                color: _bubbleColor(mine: mine),
                borderRadius: BorderRadius.circular(12),
              ),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  color: _uiStyle == 'gradient' ? Colors.white : null,
                  fontSize: 14,
                ),
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          if (mine) ...[
            const SizedBox(width: 8),
            _MessageAvatar(
                personId: avatarPersonId, server: widget.server, api: widget.api),
          ],
        ],
      ),
    );
  }

  /// 记录副本：标记为已删除/已焚毁（墓碑，内容隐藏、时间+焚毁记录保留）。
  HistoryMessage _asDeleted(HistoryMessage m) => (
        env: m.env,
        plaintext: m.plaintext,
        sender: m.sender,
        attachment: m.attachment,
        expiresAt: m.expiresAt,
        createdAt: m.createdAt,
        burnAfterSeconds: m.burnAfterSeconds,
        quote: m.quote,
        deleted: true,
        burnManual: m.burnManual,
        status: m.status,
      );

  /// 删除消息：确认弹窗 → 本机打墓碑标记（内容隐藏、时间+焚毁记录保留；
  /// 对方设备不受影响；重启后记录仍在、内容仍隐藏）。
  Future<void> _deleteMessage(HistoryMessage m) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.chatPageDeleteConfirmTitle),
        content: Text(l10n.chatPageDeleteConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.chatPageDeleteCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.chatPageDeleteConfirmOk),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _repo.tombstoneMessage(m.env.messageId);
    if (!mounted) return;
    setState(() {
      _messages = [
        for (final x in _messages)
          if (x.env.messageId == m.env.messageId) _asDeleted(x) else x,
      ];
    });
  }

  /// 引用预览截断（60 字内）。
  String _quotePreview(String text) {
    final t = text.trim();
    return t.length > 60 ? '${t.substring(0, 60)}…' : t;
  }

  /// 输入栏引用条：被引用消息预览 + 取消按钮。
  Widget _buildQuoteBanner(HistoryMessage quote) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _uiStyle == 'gradient' ? Colors.white : const Color(0xFFFCEBF2),
        borderRadius: BorderRadius.circular(12),
        border: const Border(left: BorderSide(color: Color(0xFF3BAFFD), width: 3)),
      ),
      child: Row(
        children: [
          Icon(Icons.format_quote,
              size: 14, color: _uiStyle == 'gradient' ? Colors.white70 : Colors.grey),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              // 双引号图标已足够表达引用，不再加「引用：」前缀（老板要求 2026-09-09）
              _quotePreview(quote.plaintext),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  color: _uiStyle == 'gradient' ? Colors.white70 : Colors.grey.shade700),
            ),
          ),
          InkWell(
            onTap: () => setState(() => _quoteTarget = null),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close, size: 16),
            ),
          ),
        ],
      ),
    );
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
    // 语音文字说明带录音秒数（老板 2026-09-11）：caption 随消息同步，接收端
    // 同样显示（如「语音（12 秒）」）；须在 await 前取好（避免 async gap 用 context）
    final caption =
        '${AppLocalizations.of(context)!.chatPageVoiceLabel}（$_recordSeconds 秒）';
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
      await _sendAttachmentOptimistic(
        fileBytes: await f.readAsBytes(),
        fileName: 'voice.m4a',
        type: 'voice',
        caption: caption,
      );
      await f.delete().catchError((_) => f);
      if (!mounted) return;
      setState(() {
        _inputMode = _InputMode.text;
        _recordingPath = null;
        _voiceSamples.clear();
      });
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
      HistoryMessage m) async {
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
          await _sendAttachmentOptimistic(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.galleryImage:
          image = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1600);
          if (image == null) return;
          fileName = 'image.jpg';
          type = 'image';
          await _sendAttachmentOptimistic(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.videoCamera:
          image = await _picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(minutes: 1));
          if (image == null) return;
          fileName = 'video.mp4';
          type = 'video';
          await _sendAttachmentOptimistic(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.videoGallery:
          image = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(minutes: 1));
          if (image == null) return;
          fileName = 'video.mp4';
          type = 'video';
          await _sendAttachmentOptimistic(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.audioFile:
          // file_picker 12.x：静态方法直接调用，返回 List<PlatformFile>；
          // 文件内容用异步 readAsBytes()（withData 已废弃）
          final audioFiles = await FilePicker.pickFiles(type: FileType.audio);
          if (audioFiles.isEmpty) return;
          final audio = audioFiles.first;
          final audioName = audio.name;
          final audioBytes = await audio.readAsBytes();
          await _sendAttachmentOptimistic(
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
          await _sendAttachmentOptimistic(
            fileBytes: anyBytes,
            fileName: anyName,
            type: 'file',
            caption: anyName,
          );
      }
    } catch (e) {
      if (!mounted) return;
      showTopNotice(context, AppLocalizations.of(context)!.chatPageSendFailed('$e'));
    }
  }

  // ---------- 视频：下载解密 → 临时文件 → video_player 播放 ----------

  /// 视频消息：内联预览（首帧 + 播放按钮），点击全屏播放；发送端本地密文
  /// 即时显示、接收端服务端拉取（老板 2026-09-11：改回直接显示）。
  Widget _buildVideo(
      HistoryMessage m) {
    final att = m.attachment;
    if (att == null) return Text('🎬 ${m.plaintext}');
    final future = _videoCache.putIfAbsent(
      m.env.messageId,
      () => _attachmentBytes(m),
    );
    return FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snap) {
        if (snap.hasData) {
          return _VideoPreview(bytes: snap.data!);
        }
        if (snap.hasError) {
          return Text('🎬 ${m.plaintext}');
        }
        return const SizedBox(
            width: 60, height: 60, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
      },
    );
  }

  /// 附件明文：发送端优先本地密文解密（上传完成前/失败后也能即时显示），
  /// 无本地密文（接收端）走服务端拉取。
  Future<Uint8List> _attachmentBytes(HistoryMessage m) {
    final att = m.attachment;
    if (att == null) throw StateError('附件元数据缺失');
    return _repo.attachmentBytes(att);
  }

  /// 图片消息：本地密文（发送端即时显示/上传失败兜底）或服务端拉取 →
  /// 缩略展示；点击全屏查看。
  Widget _buildImage(
      HistoryMessage m) {
    final att = m.attachment;
    if (att == null) return Text('📷 ${m.plaintext}');
    final future = _imageCache.putIfAbsent(
      m.env.messageId,
      () => _attachmentBytes(m),
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

  /// 全屏查看图片（黑底大图 + 双指缩放 + 右上角关闭，与头像全屏一致）。
  void _showFullImage(Uint8List bytes) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 消息气泡底色：按发言人性别——男天蓝 / 女品牌粉（浅色 tint 便于阅读）；
  /// 性别未登记（旧配置）回退原默认色（本人 indigo.shade100 / 对方 grey.shade200）。
  /// gradient 风格改用深色气泡（男深蓝 #2271F7 / 女深粉 #B83D80，白字醒目——
  /// 浅 tint 在渐变背景上区分度不足，老板要求 2026-09-09）。
  Color _bubbleColor({required bool mine}) {
    final gender = mine ? _myGender : _peerGender;
    if (_uiStyle == 'gradient') {
      if (gender == 'female') return const Color(0xFFB83D80); // 深粉（品牌粉加深）
      if (gender == 'male') return const Color(0xFF2271F7); // 品牌深蓝
      return mine ? const Color(0xFF2271F7) : const Color(0xFF64748B); // 性别未登记
    }
    if (gender == 'female') return const Color(0xFFD6529C).withValues(alpha: 0.18);
    if (gender == 'male') return const Color(0xFF3BAFFD).withValues(alpha: 0.18);
    return mine ? Colors.indigo.shade100 : Colors.grey.shade200;
  }

  /// 消息内容按类型渲染（text 文本 / voice、audio 播放条 / image、video、file 各自卡片）。
  Widget _buildMessageContent(
      HistoryMessage m) {
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
      HistoryMessage m) {
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
                    ? '🎤 ${_voiceMessageLabel(m)}'
                    : '🎵 ${m.plaintext}'),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// 语音消息文字说明：优先显示消息自带说明（新版带秒数，如「语音（12 秒）」）；
  /// 旧消息 plaintext 以「🎤 」开头（sendAttachment 旧默认），去掉前缀避免与
  /// 渲染端 🎤 重复；空则回退 l10n 标签。
  String _voiceMessageLabel(HistoryMessage m) {
    final t = m.plaintext.trim();
    if (t.isEmpty) return AppLocalizations.of(context)!.chatPageVoiceLabel;
    return t.startsWith('🎤 ') ? t.substring(2) : t;
  }

  /// 文件消息：文件卡片（文件名 + 大小 + 下载保存）。
  Widget _buildFileCard(
      HistoryMessage m) {
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
              Text(_formatSize(size),
                  style: TextStyle(
                      fontSize: 11,
                      color: _uiStyle == 'gradient' ? Colors.white70 : Colors.grey)),
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
      HistoryMessage m) async {
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
      // gradient 风格：body 延伸到 AppBar 之后，AppBar 透明浮在渐变上（同向导全屏
      // 渐变做法）；plain 风格保持原有布局（AppBar 浅粉底，body 从其下方开始）
      extendBodyBehindAppBar: _uiStyle == 'gradient',
      appBar: AppBar(
        backgroundColor: _uiStyle == 'gradient' ? Colors.transparent : null,
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
                  case 'style':
                    _showStylePicker();
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
                  value: 'style',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuStyleLabel, style: labelStyle),
                      const Spacer(),
                      Text(kUiStyleLabels[_uiStyle] ?? ''),
                    ],
                  ),
                ),
                const PopupMenuDivider(), // 分隔：以下是安全相关设置（老板要求 2026-09-10）
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
          // 界面风格背景层：gradient=品牌粉蓝渐变（首屏/向导同款）；plain=不铺
          // 背景（露出 Scaffold 浅粉白纸感底色，与原有视觉效果完全一致）
          if (_uiStyle == 'gradient')
            const Positioned.fill(
              child: DecoratedBox(
                // Key 供测试精确断言聊天页背景（弹窗预览图也有渐变，需区分）
                key: ValueKey('chatPageGradientBackground'),
                decoration: BoxDecoration(gradient: kBrandGradient),
              ),
            ),
          // gradient 风格：body 延伸到 AppBar 之后——内容从工具栏高度下方开始
          // （避免与浮动 AppBar 重叠；同向导 SizedBox(kToolbarHeight) 做法）
          Padding(
            padding: EdgeInsets.only(
              top: _uiStyle == 'gradient'
                  ? MediaQuery.paddingOf(context).top + kToolbarHeight
                  : 0,
            ),
            child: Column(
              children: [
          // 对话顶部：双方名字 + 各自在线状态（对方左 / 我右，与消息对齐一致）
          // 两风格统一悬浮圆角条：不顶左右两头、四角有弧度、浮在背景上（老板要求
          // 2026-09-09——素雅纯色风格与渐变风格一致）
          Container(
            key: const ValueKey('chatPageStatusBar'),
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x26000000), // 柔和投影（背景上浮起）
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
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
                      GestureDetector(
                        // 仅跳转目标项持有 GlobalKey（ensureVisible 定位用）；
                        // 其余项无 key，不阻碍懒构建回收
                        key: m.env.messageId == _jumpTargetId ? _jumpTargetKey : null,
                        // 墓碑消息（已删除/已焚毁）不激发长按菜单（无内容可操作）
                        onLongPress:
                            m.deleted ? null : () => _showMessageActions(m),
                        child: AnimatedContainer(
                          // 高亮渐变节奏（老板要求 2026-09-10）：渐变成橘黄 1.5s、
                          // 停留 0s、渐变回去 1.5s——duration 1500ms 管渐变
                          duration: const Duration(milliseconds: 1500),
                          curve: Curves.easeOut,
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          // 气泡最大宽度 = 屏幕 75%：长文本在此约束下自动换行
                          // （否则 Row(min) 给 Text 无界宽度 → 长消息挤在一行溢出屏幕）
                          constraints: BoxConstraints(
                              maxWidth: MediaQuery.sizeOf(context).width * 0.75),
                          decoration: BoxDecoration(
                            // 气泡底色按发言人性别：男天蓝 / 女品牌粉（老板要求 2026-09-09）；
                            // 跳转目标短暂高亮背景改为显眼橘黄 #FF9800（老板要求
                            // 2026-09-10：不撞任何性别气泡色系；只换背景色、尺寸
                            // 不变——边框方案实测闪烁期间气泡尺寸变化，已弃用）
                            color: m.env.messageId == _highlightMessageId
                                ? const Color(0xFFFF9800)
                                : _bubbleColor(mine: mine),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: DefaultTextStyle.merge(
                            // gradient 深色气泡下文字/图标改白色（醒目，老板要求）；
                            // plain 浅色气泡不合并颜色（保持默认深色文字/图标）
                            style: TextStyle(
                                color: _uiStyle == 'gradient' ? Colors.white : null),
                            child: IconTheme.merge(
                              data: IconThemeData(
                                  color: _uiStyle == 'gradient' ? Colors.white : null),
                              child: Column(
                                crossAxisAlignment: mine
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 2),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // 自己消息：发送状态小标放在**时间前面**（老板
                                        // 2026-09-12：原来放末尾，会被阅后即焚标记挤到
                                        // 中间/后面，无法一眼看出"这条发出去没"）
                                        if (mine && !m.deleted) ...[
                                          _buildSendStatusIcon(m),
                                          const SizedBox(width: 4),
                                        ],
                                        Text(_messageTimeLabel(m),
                                            style: TextStyle(
                                                fontSize: 10,
                                                color: _uiStyle == 'gradient'
                                                    ? Colors.white70
                                                    : Colors.grey)),
                                        if (m.expiresAt != null) ...[
                                          const SizedBox(width: 4),
                                          // 沙漏=阅后即焚倒计时（老板 2026-09-12，
                                          // 替代原来的时钟图标，避免与发送中混淆）
                                          const _BurnHourglass(),
                                          const SizedBox(width: 2),
                                          // 时钟标签：手动设置 → ⏰ <修改时间>+<时长>
                                          // （如 ⏰ 20:47+5m）；全局设置 → 只标时长（⏰ 5m）
                                          Text(_burnTagLabel(m.expiresAt, m.burnAfterSeconds,
                                                  manual: m.burnManual),
                                              style: TextStyle(
                                                  fontSize: 10,
                                                  color: _uiStyle == 'gradient'
                                                      ? Colors.white70
                                                      : Colors.grey)),
                                        ],
                                      ],
                                    ),
                                  ),
                                  // 墓碑消息（已删除/已焚毁）：只保留时间（+时钟+时长）
                                  // 记录，正文与引用块隐藏（老板决策 2026-09-09）
                                  if (!m.deleted) ...[
                                    _buildMessageContent(m),
                                    // 被引用的消息放在正文下方（老板要求 2026-09-09：
                                    // 引用块应在消息正文下面，而不是上面）
                                    // 点击引用卡跳转到原消息位置（老板要求 2026-09-10）
                                    if (m.quote != null)
                                      GestureDetector(
                                        onTap: () => _jumpToMessage(
                                            m.quote!['messageId'] as String? ?? ''),
                                        child: Container(
                                          margin: const EdgeInsets.only(top: 4),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 4),
                                          constraints: BoxConstraints(
                                              maxWidth: MediaQuery.sizeOf(context)
                                                      .width *
                                                  0.55),
                                          decoration: BoxDecoration(
                                            color: _uiStyle == 'gradient'
                                                ? Colors.white12
                                                : Colors.black
                                                    .withValues(alpha: 0.06),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            _quotePreview(
                                                m.quote!['preview'] as String? ?? ''),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: _uiStyle == 'gradient'
                                                    ? Colors.white70
                                                    : Colors.grey.shade700),
                                          ),
                                        ),
                                      ),
                                  ],
                                ],
                              ),
                            ),
                          ),
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
            // 输入栏锚定在屏幕底部：必须去掉顶部 inset——extendBodyBehindAppBar 下
            // Scaffold 给 body 的 MediaQuery.padding.top 含「状态栏 + 工具栏」高度
            // （真机约 115px），SafeArea 默认会把它全垫在输入栏上方，造成约 2 个
            // 输入框高度的渐变空隙、消息列表被截断（老板实测 2026-09-09）。
            // 底部 inset 保留（Home 条防遮挡）。
            top: false,
            child: Container(
              key: const ValueKey('chatPageInputBar'),
              // gradient 风格：输入栏不顶左右两头——悬浮圆角白条（渐变从两侧/底部
              // 透出，同向导白卡在渐变上的层次）；plain 风格保持原样（全宽透明）
              color: _uiStyle == 'gradient' ? null : Colors.transparent,
              decoration: _uiStyle == 'gradient'
                  ? BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x26000000), // 柔和投影（渐变上浮起）
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ],
                    )
                  : null,
              padding: _uiStyle == 'gradient'
                  ? const EdgeInsets.fromLTRB(12, 4, 12, 8)
                  : const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_quoteTarget != null) _buildQuoteBanner(_quoteTarget!),
                  Row(
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
                                decoration: InputDecoration(
                                    hintText: l10n.chatPageInputHint, isDense: true),
                                // 回车发送后焦点回到输入框（键盘完成动作默认失焦——补回聚焦）
                                onSubmitted: (_) {
                                  _send();
                                  _inputFocusNode.requestFocus();
                                },
                                // 发送后键盘常驻遮挡消息流；点按输入框以外的任意处
                                // （消息列表/空白/其他控件）收起键盘（老板要求 2026-09-12）。
                                // 移动端默认不动 focus，需显式 unfocus。
                                onTapOutside: (_) =>
                                    FocusManager.instance.primaryFocus?.unfocus(),
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
                ],
              ),
            ),
          ),
              ],
            ),
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
    // 两空 = 设为空：取消启动锁（Space Key 转明文保存，与向导"不设置锁屏码"一致）
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
    if (!AppLockService.isPinDigitsOnly(pin)) {
      setState(() => _error = l10n.setPinDialogPinDigitsOnly);
      return;
    }
    if (pin.length < AppLockService.pinMinLength) {
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
  // 与创建向导保持一致的最短口令长度（老板要求 2026-09-12）
  static const int _passphraseMinLength = 8;
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
    // 提交即清上一轮红字：否则校验通过进入显性确认弹窗时，旧错误仍残留在其背后
    if (_error != null) setState(() => _error = null);
    final oldPass = _oldCtrl.text.trim();
    final newPass = _newCtrl.text.trim();
    final confirm = _confirmCtrl.text.trim();
    if (newPass.isEmpty) {
      setState(() => _error = l10n.setupPageNeedPassphrase);
      return;
    }
    if (newPass.length < _passphraseMinLength) {
      setState(() => _error = l10n.wizardPassphraseTooShort);
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
              hintText: l10n.wizardPassphraseMinLengthHint,
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

  /// 头像失效广播（personId）：通知当前在树上的头像重拉——否则静态缓存只在
  /// 进程内有效，换了头像要重启 App 才看得到（老板 2026-09-11）。
  static final ValueNotifier<String?> invalidated = ValueNotifier<String?>(null);

  /// 让某人的头像失效：上传本人头像 / 收到对方 profile.updated 时调用。
  static void invalidate(String? personId) {
    if (personId == null || personId.isEmpty) return;
    invalidated.value = personId;
  }

  Uint8List? get _bytes => widget.personId == null ? null : _cache[widget.personId];

  @override
  void initState() {
    super.initState();
    final pid = widget.personId;
    if (pid != null && !_cache.containsKey(pid)) {
      _load(pid);
    }
    invalidated.addListener(_onInvalidated);
  }

  @override
  void dispose() {
    invalidated.removeListener(_onInvalidated);
    super.dispose();
  }

  void _onInvalidated() {
    final pid = widget.personId;
    if (pid == null || invalidated.value != pid) return;
    _load(pid); // 覆盖旧缓存后再 setState（不先清空——避免闪成默认图标）
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

  /// 二维码内容：邀请链接（`https://einz.tic.cc/join/<token>`，约 80 字符；
  /// QR 容量绰绰有余，不会超长）。
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

/// 视频消息内联预览：暂停态显示首帧 + 播放按钮；点击全屏播放。
/// 发送端本地密文即时显示（上传完成前/失败后也能看），接收端服务端拉取
/// （老板 2026-09-11：改回 v1 直接显示视频）。
class _VideoPreview extends StatefulWidget {
  const _VideoPreview({required this.bytes});

  final Uint8List bytes;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final tmp = File(
          '${Directory.systemTemp.path}/einz_preview_${DateTime.now().microsecondsSinceEpoch}.mp4');
      await tmp.writeAsBytes(widget.bytes);
      final c = VideoPlayerController.file(tmp);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (_failed || c == null) {
      return const SizedBox(width: 180, height: 100);
    }
    return GestureDetector(
      onTap: () => _playFullscreen(c),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 180,
          height: 180,
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoPlayer(c), // 暂停态显示首帧
              const Center(
                child: Icon(Icons.play_circle_fill, size: 44, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _playFullscreen(VideoPlayerController c) async {
    await c.seekTo(Duration.zero);
    await c.play();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        // 与图片全屏一致：纯黑底 + 铺满全屏（老板要求 2026-09-12——
        // 视频全屏也应是黑底大画面，而不是默认半透明遮罩下的圆角小卡）
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
          ],
        ),
      ),
    );
    await c.pause();
  }
}

/// 阅后即焚「沙漏」小图标（老板 2026-09-12）：在 hourglass_top ↔ hourglass_bottom
/// 之间缓慢翻转，暗示倒计时在流逝。
///
/// 说明：图标仅 11px，做"按剩余时间精确流沙"既看不清又需逐秒驱动，故用循环
/// 翻转表达"时间在走"。颜色不指定 → 继承 IconTheme（渐变风格下为白系，与相邻
/// 的时间/时长文字一致）。
class _BurnHourglass extends StatefulWidget {
  const _BurnHourglass();

  @override
  State<_BurnHourglass> createState() => _BurnHourglassState();
}

class _BurnHourglassState extends State<_BurnHourglass>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Icon(
        _controller.value < 0.5 ? Icons.hourglass_top : Icons.hourglass_bottom,
        size: 11,
      ),
    );
  }
}
