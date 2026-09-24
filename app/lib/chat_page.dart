import 'dart:async';
import 'widgets/menu_metrics.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:einz_shared/einz_shared.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'about_page.dart';
import 'brand_logo.dart';
import 'data/attachment_storage_settings.dart';
import 'data/attachment_store.dart';
import 'data/burn_after_settings.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'data/server_config.dart';
import 'data/locale_settings.dart';
import 'data/lock_timer.dart';
import 'data/media_cache.dart';
import 'data/message_repository.dart';
import 'data/ui_style_settings.dart';
import 'data/ws_realtime_service.dart';
import 'l10n/app_localizations.dart';
import 'lock_page.dart';
import 'setup_page.dart';
import 'widgets/reset_entrance.dart';
import 'widgets/space_switcher.dart';
import 'data/vault_session.dart';
import 'widgets/emoji_panel.dart';
import 'widgets/immersive_fullscreen.dart';
import 'widgets/passphrase_field.dart';
import 'widgets/option_picker_sheet.dart';
import 'widgets/top_notice.dart';
import 'widgets/ui_style_picker.dart';

/// 选择弹层返回项：图像/视频用 image_picker，音频/文件用 file_picker；emoji 不
/// 上传附件，只打开输入栏内的表情面板（在 _showAttachmentSheet 里单独分流）。
enum _AttachmentKind { emoji, photo, galleryImage, videoCamera, videoGallery, audioFile, anyFile }

/// 本平台是否具备**相机采集**能力（拍照/拍摄）。
///
/// 桌面端（macOS/Windows/Linux）没有：`image_picker` 在桌面平台遇到
/// `ImageSource.camera` 会直接抛 `StateError`（除非挂 cameraDelegate），所以附件
/// 面板在桌面端不摆「拍照/拍摄」两个入口——摆了也只会弹一条"发送失败"
/// （老板 2026-09-20 在 MacBook 实测：点拍视频报错）。相册/文件入口在桌面端走
/// 系统文件对话框，照常可用。
bool get _hasCameraCapture =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// 输入区模式：text=文字输入框；hint=提示态（录音条显示「长按开始录音」，入口按钮变键盘、
/// 点击回文字态）；recording=按住录音中（波形实时）；preview=松手后预览态（试听/取消，
/// 发送复用右侧发送键）。
enum _InputMode { text, hint, recording, preview }

/// 聊天页：本地历史 + 发送 + 自动轮询同步（最小可用，无 WS 长连接）。
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.spaceId,
    required this.entranceId,
    required this.spaceKey,
    required this.keyVersion,
    required this.token,
    this.db,
    this.api,
    this.enableWs = true,
    this.reauth,
    this.escrowUpdatedAt,
    this.partnerName, // 我的名字（登记时设置；菜单显示/修改）
    this.entranceName, // 我的通道名（登记时自动获取；菜单显示/修改）
    this.partnerId, // 我的 partnerId（头像上传/获取用）
    this.peerName, // 对方名字（setup 探测传入；对话顶部条显示）
    this.publicKeyB64, // 通道公钥（b64，随锁包持久化；弹窗展示用）
    this.privateKeyB64, // 通道私钥（b64，随锁包持久化；补设锁写入新锁包）
  });

  final String spaceId;
  final String entranceId;
  final Uint8List spaceKey;
  final int keyVersion;
  final String token;

  /// 本端已知的服务端口令更新时间（ms）：启动/上线时与服务器对比，
  /// 服务器更新 = 离线期间口令被重设（只发通知，不弹窗）。
  final int? escrowUpdatedAt;

  /// 我的名字（向导登记时设置；顶栏菜单显示/修改，服务端同步）。
  final String? partnerName;

  /// 我的通道名（向导登记时自动获取设备型号；顶栏菜单显示/修改，服务端同步）。
  final String? entranceName;

  /// 我的 partnerId（向导登记时确定；头像上传/消息身份标识用）。
  final String? partnerId;

  /// 对方名字（向导探测时确定；对话顶部条显示，无则占位）。
  final String? peerName;

  /// 通道 X25519 公钥（b64，随锁包持久化）：「我的通道」弹窗展示用。
  final String? publicKeyB64;

  /// 通道 X25519 私钥（b64，随锁包持久化）：补设锁/改口令时写入新锁包。
  final String? privateKeyB64;

  /// 测试注入用；默认新建（生产路径）。
  final LocalDatabase? db;

  /// 测试注入用（fake api）；默认按 [effectiveServer] 新建（生产路径）。
  final ApiClient? api;

  /// WS 实时开关（测试环境关闭，避免真实连接与重连 Timer）。
  final bool enableWs;

  /// session 过期（401/4401）时自动重新认证的回调（setup_page 注入，
  /// challenge-response 重新签发 token）——MessageRepository/WsRealtimeService 共用。
  final Future<String> Function()? reauth;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

/// 消息流正文（气泡内跟随默认样式的文字）字号（老板 2026-09-15 定：15）。
/// 原样：跟着 Flutter 默认 14，比微信小一圈；试过 16，老板取中间值 15。
/// 只作用于气泡内跟随默认样式的文字——时间戳/焚毁标签/引用块/长按预览行都显式
/// 设了字号，不受影响。
const double kMessageFontSize = 15;

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
  // 视频首帧缩略图缓存（messageId → Future<bytes>）：长按菜单/引用块/引用条共用。
  final Map<String, Future<Uint8List>> _videoThumbCache = {};
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
  // ---- 回执上报（已送达/已读；本轮只打通数据链路，不显示）----
  int _lastReportedDeliveredSeq = 0; // 防抖：已上报过的送达高水位
  int _lastReportedReadSeq = 0; // 防抖：已上报过的已读高水位
  bool _appResumed = true; // 前台才允许把消息标为已读
  /// 对方回执（已送达/已读）本地缓存：渲染自己消息的状态标用（避免每条消息查库）。
  List<PeerReceipt> _peerReceipts = const [];

  /// 正在"点按重发"的消息：messageId → 'speedup'（点的是小飞机）/ 'resend'
  /// （点的是 failed）。点按期间在图标前显示「加速中…」/「重发中…」，完成或
  /// 再次失败后清掉（老板 2026-09-13）。
  final Map<String, String> _retrying = {};

  /// 还没确认（pending）的消息数：离线提示用（老板 2026-09-13）。
  int _unsentCount = 0;

  /// 连续同步失败次数：驱动 ticker 退避 + 离线提示。
  /// 远端不可达（丢包黑洞）时单轮 refresh 可能耗 3×连接超时(10s)≈30s，
  /// 若仍每 3s 发一轮会并发堆积 → 必须重入保护 + 退避。
  int _consecutiveSyncFailures = 0;

  /// 服务器不认这条通道（认证 403 `FORBIDDEN`：后台库被重置 / 本通道未登记）。
  /// **只警告，绝不销毁本地数据**（老板 2026-09-16：运维失误不该导致客户端抹数据）——
  /// 与"通道被明确撤销"（403 `ENTRANCE_REVOKED` / `entrance.revoked` 帧）严格区分：
  /// 只有后者才自毁。库复原后同步成功即自动复位。
  bool _entranceUnrecognized = false;

  /// 已执行过撤销自毁：短路后续网络与重入（`entrance.revoked` 帧与重认证可能同时触发）。
  bool _wiped = false;

  /// ticker 轮询的"上一轮是否还在跑"（重入保护：避免离线时并发堆积）。
  bool _tickerRefreshInFlight = false;

  /// 当前 ticker 周期（用于判断是否需要按退避重设）。
  Duration? _currentTickerInterval;
  _InputMode _inputMode = _InputMode.text; // 输入区模式（文字/提示/录音中/预览）
  // 表情面板展开中（输入栏内联，与键盘互斥：打开时收起键盘；输入框重新获焦时自动收起）
  bool _emojiPanelOpen = false;
  String? _recordingPath; // 本次录音临时文件（录音中/预览态存续，发送或取消后清空）
  final List<double> _voiceSamples = []; // 本次录音振幅采样（录音中实时追加，预览态冻结）
  StreamSubscription<Amplitude>? _ampSub; // 录音振幅流订阅（波形驱动）
  Timer? _recordTimer; // 录音秒数计时（60s 上限自动停）
  int _recordSeconds = 0;
  bool _previewPlaying = false; // 预览态试听播放中
  String? _playingMessageId; // 播放意图（点按即置：含下载解密等待期，按钮变停止）
  String? _audioStartedMessageId; // 音频真正出声的消息（波形进度从此刻起走，
  // 避免下载解密期间进度条空跑——老板要求 2026-09-13）
  // 音频文件时长（messageId → 秒）：播放时从播放器取真实值缓存，仅内存
  // ——发送端探测不到（老消息无标注）时，播放一次后才显示时长
  final Map<String, int> _audioFileDurations = {};
  // 音频播放状态版本号：每变一次 +1。消息流气泡在本页 build 树里（setState 即可），
  // 但长按菜单预览行在另一个路由，页面 setState 重建不到它，靠这个通知同步
  // （老板要求 2026-09-13：菜单里也能播/停并看到波形进度）。
  final ValueNotifier<int> _audioPlaybackVersion = ValueNotifier(0);
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
  late String _uiStyle; // 当前界面主题（'plain'=素雅纯色 / 'gradient'=渐变粉蓝）

  /// 当前附件存储模式：'secured'=不留存明文（默认）/ 'stored'=明文留在本机、直接打开。
  late String _attachmentStorage;
  bool _hasPin = false; // 本机是否已设置启动锁（菜单项「PIN: 已设置/未设置」）
  WsRealtimeService? _ws; // WS 实时（收到 message.new 立即刷新；断线自动重连）
  late String _myPartnerName; // 我的名字（菜单显示；改名后 setState 刷新）
  late String _myEntranceName; // 我的通道名（菜单显示；改名后 setState 刷新）
  late String _myGender; // 我的性别（male/female/''；profile 恢复，个人资料弹窗图标展示）
  late String _peerGender; // 对方性别（male/female/''；profile 恢复，消息气泡配色用）
  int? _mySlot; // 我的身份槽位（0=第一人/创建者，1=第二人；同性别气泡青色判定用）
  int? _peerSlot; // 对方身份槽位（同上）
  Uint8List? _myAvatarBytes; // 我的头像 bytes 缓存（菜单显示；上传后刷新）
  /// 我的 partnerId（头像上传/缓存失效/归属判定用）：向导路径由 widget 传入；
  /// 重启（PIN 解锁/明文直进）路径 widget.partnerId 为空 → 运行时反查补齐
  /// （见 [_loadMyAvatar] / [_refreshProfileFromServer]）。
  String? _myPartnerId;
  late String _peerName; // 对方名字（对话顶部条显示）
  bool _peerOnline = false; // 对方在线状态（last_seen 距今 <60s）
  int? _escrowUpdatedAt; // 本端已知口令更新时间（上线补查对比用；沿用 widget 初值）
  Timer? _peerTicker; // 对方在线轮询（30s）

  /// 阅后即焚档位文案（l10n 映射）。
  String _burnOptionLabel(int seconds, AppLocalizations l10n) {
    switch (seconds) {
      case 0:
        return l10n.burnOptionOff;
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

  /// 常驻提示条（老板 2026-09-16：连不上/未被识别要持续可见，不能只弹一次通知）。
  /// 三档优先级：
  /// - 服务器不认本通道（库被重置）→ 淡红：明确"数据没被清除"，用户可继续读本地消息；
  /// - 有 pending 消息 + 连接异常 → 淡琥珀（原有：解释"小飞机停了很久"）；
  /// - 仅连续同步失败（无 pending）→ 淡琥珀「离线 · 仅可查看本地消息」。
  /// 判定用 `_consecutiveSyncFailures > 0` 而不是 `!_ws.connected`，避免普通重连闪条。
  Widget _buildOfflineHint() {
    final l10n = AppLocalizations.of(context)!;
    if (_entranceUnrecognized) {
      return _hintBanner(
        l10n.chatPageEntranceUnrecognized,
        bg: const Color(0xFFFFEBEE), // 淡红：需要用户知晓的状态（非报错弹窗）
        fg: const Color(0xFFB71C1C),
      );
    }
    final troubled =
        _consecutiveSyncFailures > 0 || (_ws != null && !_ws!.connected.value);
    if (_unsentCount > 0 && troubled) {
      return _hintBanner(
        l10n.chatPageOfflineUnsent(_unsentCount),
        bg: const Color(0xFFFFF3E0), // 淡琥珀：提示而非报错
        fg: const Color(0xFF8A5300),
      );
    }
    if (_consecutiveSyncFailures == 0) return const SizedBox.shrink();
    return _hintBanner(
      l10n.chatPageOfflineLocalOnly,
      bg: const Color(0xFFFFF3E0),
      fg: const Color(0xFF8A5300),
    );
  }

  /// 提示条外观：整宽、单行小字（常驻在状态条下方，不遮挡输入区）。
  Widget _hintBanner(String text, {required Color bg, required Color fg}) {
    return Container(
      width: double.infinity,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(text, style: TextStyle(fontSize: 12, color: fg)),
    );
  }

  /// 自己消息的发送状态小标（老板 2026-09-12）：
  /// - pending → 纸飞机（发送中）
  /// - sent → 单勾（服务端已收下）
  /// - **delivered / read → 单勾**（服务端已收下；这是我同一身份另一条通道发的
  ///   消息同步回来的状态，对方回执到了才升双勾）
  /// - 有对方回执（delivered/read）→ 双勾
  /// - failed → 红色警告（点按重发）
  /// 仅自己、非墓碑消息显示。
  ///
  /// 注意 `sent` 与 `delivered` 都是"服务端已收下"，**不能**只把 `sent` 当已发送：
  /// `delivered` 若因为暂时没有对方回执而掉进末尾的 pending 分支，就会被渲染成
  /// "发送中"蓝飞机 → 用户以为没发出去、去点重发 → 撞上服务端 403 → 变成永久红色
  /// 「点击重发」（老板 2026-09-22 线上实测的完整链条）。
  Widget _buildSendStatusIcon(HistoryMessage m) {
    final l10n = AppLocalizations.of(context)!;
    final subtle = _uiStyle == 'gradient' ? Colors.white70 : Colors.grey;
    final messageId = m.env.messageId;
    final busy = _retrying[messageId];

    // 点按重发期间的前置文案（老板 2026-09-13）：点小飞机 → 「加速中…」；
    // 点 failed → 「重发中…」。完成后按结果回到对应状态：若又失败（服务端明确
    // 拒绝）→ 清掉 busy → 文案回到「点击重发」。
    final busyLabel = switch (busy) {
      'speedup' => l10n.chatPageMsgSpeedingUp,
      'resend' => l10n.chatPageMsgResending,
      _ => null,
    };

    if (m.status == 'failed') {
      // 文字标签 + 红色警告图标（老板 2026-09-13：光一个 ⚠️ 看不出能点）
      return Tooltip(
        message: l10n.chatPageMsgFailed,
        child: GestureDetector(
          onTap: () => _tapRetryMessage(m, asResend: true),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(busyLabel ?? l10n.chatPageMsgFailedTap,
                  style: TextStyle(fontSize: 10, color: Colors.red.shade600)),
              const SizedBox(width: 2),
              Icon(Icons.error_outline, size: 12, color: Colors.red.shade600),
            ],
          ),
        ),
      );
    }

    // 对方已收到（delivered）/已读（read）→ 双勾。read 与 delivered 同图标：
    // 已读暂不展示（老板 2026-09-12）。
    final receipt = MessageRepository.receiptOf(m.env.serverSequence, _peerReceipts);
    if (receipt != null) {
      return Tooltip(
        message: l10n.chatPageMsgDelivered,
        child: Icon(Icons.done_all, size: 12, color: subtle),
      );
    }
    if (m.status == 'sent' || m.status == 'delivered' || m.status == 'read') {
      return Tooltip(
        message: l10n.chatPageMsgSent,
        child: Icon(Icons.check, size: 12, color: subtle),
      );
    }

    // pending（还没确认）：动态小飞机 + 可点按（幂等重发＝去问服务端收到没）。
    // 小飞机用超链接蓝提示可点（老板 2026-09-18）；加速中改用中性色，避免"点了
    // 还提示可点"的矛盾。
    return Tooltip(
      message: l10n.chatPageMsgSendingTap,
      child: GestureDetector(
        onTap: () => _tapRetryMessage(m, asResend: false),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busyLabel != null) ...[
              Text(busyLabel, style: TextStyle(fontSize: 10, color: subtle)),
              const SizedBox(width: 2),
            ],
            _SendingPlane(
              color: busyLabel != null ? subtle : const Color(0xFF2E7CF6),
            ),
          ],
        ),
      ),
    );
  }

  /// 点按状态小标 → 幂等重发（服务端按 message_id 去重），期间显示进行中文案。
  Future<void> _tapRetryMessage(HistoryMessage m, {required bool asResend}) async {
    final messageId = m.env.messageId;
    setState(() => _retrying[messageId] = asResend ? 'resend' : 'speedup');
    try {
      await _repo.retryMessage(messageId);
      await _refreshLocal();
    } finally {
      if (mounted) setState(() => _retrying.remove(messageId));
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
    _myPartnerName = widget.partnerName ?? '';
    _myEntranceName = widget.entranceName ?? '';
    _myGender = ''; // 个人资料弹窗性别图标：由 profile 恢复（向导完成时写入）
    _peerGender = ''; // 消息气泡配色：由 profile 恢复（向导完成时写入）
    _mySlot = null; // 身份槽位（0=第一人/1=第二人）：由 profile 恢复 + /space 校正
    _peerSlot = null;
    _peerName = widget.peerName ?? '';
    _myPartnerId = widget.partnerId; // 向导路径已知；重启路径为 null → 稍后反查补齐
    _refreshPeerOnline();
    _peerTicker = Timer.periodic(const Duration(seconds: 30), (_) => _refreshPeerOnline());
    WidgetsBinding.instance.addObserver(this);
    final db = widget.db ?? LocalDatabase.shared;
    // 名字未由向导传入（如 PIN 解锁后重启进聊天）→ 从本地 profile 恢复。
    // 必须按 spaceId 读：多空间下全局键是所有空间共用的一格，会被别的空间覆写
    // （老板 2026-09-22 实测：新建空间对方还没加入，顶部条却显示原空间的对方名）。
    AppLockService(db).loadProfile(spaceId: widget.spaceId).then((p) {
      if (!mounted) return;
      setState(() {
        if (_myPartnerName.isEmpty) _myPartnerName = p['partnerName'] as String? ?? '';
        if (_myEntranceName.isEmpty) _myEntranceName = p['entranceName'] as String? ?? '';
        if (_peerName.isEmpty) _peerName = p['peerName'] as String? ?? '';
        if (_myGender.isEmpty) _myGender = p['myGender'] as String? ?? '';
        if (_peerGender.isEmpty) _peerGender = p['peerGender'] as String? ?? '';
        _mySlot = p['mySlot'] as int?; // 槽位无"空值语义"问题，直接恢复
        _peerSlot = p['peerSlot'] as int?;
      });
      // 快照可能过期（对方改名 / v2 早期把对方性别写死空串）→ 以服务端为准校正
      // 名字与性别（老板 2026-09-11：App 重启后一直显示旧的对方名字）
      _refreshProfileFromServer();
    });
    _repo = MessageRepository(
      db: db,
      api: widget.api ?? ApiClient(effectiveServer),
      spaceKey: widget.spaceKey,
      spaceId: widget.spaceId,
      entranceId: widget.entranceId,
      keyVersion: widget.keyVersion,
      token: widget.token,
      settings: BurnAfterSettings(db, spaceId: widget.spaceId),
      reauth: widget.reauth == null ? null : _reauthWithRevokedFallback,
      // 本端 partnerId（向导登记时确定）：种入归属判定映射，离线启动也能
      // 按 partner 维度分左右分栏（服务器离线拉不到 entrance→partner 映射）
      partnerId: widget.partnerId,
    );
    // 头像加载要在 _repo 就绪后（重启路径要靠它反查本机 partnerId）
    _loadMyAvatar();
    _loadInitial();
    _scrollController.addListener(_maybeLoadOlder);
    _inputFocusNode.addListener(_onInputFocusChanged);
    _loadBurnLabel();
    _refreshPinStatus();
    // 首帧同步取值（同进程内延续上次选择，避免首帧 LateInitializationError），
    // 随后用持久化值校正（_loadUiStyle 异步）
    _uiStyle = uiStyleNotifier.value;
    _loadUiStyle(); // 恢复界面主题（plain/gradient，默认素雅纯色）
    // 风格切换即时生效（弹窗不关闭也能预览）：notifier 通知 → 重建背景
    uiStyleNotifier.addListener(_onUiStyleChanged);
    _attachmentStorage = attachmentStorageNotifier.value;
    _loadAttachmentStorage(); // 恢复附件存储模式（secured/stored，默认 secured）
    attachmentStorageNotifier.addListener(_onAttachmentStorageChanged);
    // 每 3 秒轮询同步（WS 连接成功后降频为 30s 兜底；断开恢复高频——见 _onWsStatusChanged）
    _restartTicker(_tickerInterval);
    _registerPushToken();
    _registerInstallUid();
    if (widget.enableWs) {
      final ws = WsRealtimeService(
        server: effectiveServer,
        token: widget.token,
        reauth: widget.reauth == null ? null : _reauthWithRevokedFallback,
      );
      _ws = ws;
      ws.connected.addListener(_onWsStatusChanged);
      ws.start(
        // WS 实时新消息：标记为 realtime，允许把消息标为"已读"（下面的补拉路径
        // 只标"已送达"——老板 2026-09-12：补拉的历史不等于人看过）
        onMessageNew: () => _refresh(realtime: true),
        onEntranceRevoked: _onEntranceRevoked,
        onPeerStatus: _onPeerStatus,
        onPassphraseRotated: _onPassphraseRotated,
        onProfileUpdated: _onProfileUpdated,
        onReceiptUpdated: _onReceiptUpdated,
      );
    }
  }

  /// 对端上下线（Server 广播——立即更新对方在线状态，不等 30s 轮询）。
  void _onPeerStatus(WsPeerStatusEvent event) {
    if (event.entranceId == widget.entranceId) return; // 本通道自身的事件忽略
    // 与我同身份的通道（我自己的另一条）不算"对方"（新服务端已不推这类广播，
    // 这里兜住旧服务端——旧 payload 无 partner_id 时按原行为处理）
    if (event.partnerId != null && event.partnerId == widget.partnerId) return;
    final online = event.type == kWsTypePeerOnline;
    // 对方刚上线（多半是刚加入本空间）：initState 那次 /space 只有我一人，
    // 对方的名字/性别/身份槽位都还是空 → 同性别两人气泡会是同一个颜色
    // （老板 2026-09-22 实测）。这里补拉一次把身份补齐。
    if (online && !_peerOnline) unawaited(_refreshProfileFromServer());
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
    // 头像：无论改名还是换头像都刷一次（同一 per-partner 头像文件可能已变）
    _MessageAvatarState.invalidate(event.partnerId);
    _refreshProfileFromServer();
    final name = event.partnerName;
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _peerName = name);
  }

  /// 对方回执更新（Server 广播 receipt.updated）：落库为已送达/已读高水位。
  /// **本轮不显示**——只为把数据打通，供将来 UI 使用（老板 2026-09-12）。
  void _onReceiptUpdated(WsReceiptUpdatedEvent event) {
    unawaited(_repo
        .upsertPeerReceipt(
          partnerId: event.partnerId,
          deliveredUptoSeq: event.deliveredUptoSeq,
          readUptoSeq: event.readUptoSeq,
        )
        .then((_) => _loadPeerReceipts()));
  }

  /// 从服务端校正双方名字与性别（GET /space 的 partnerNames/partnerGenders）。
  /// 本机 profile 只是入网时的快照：对方改名后若没收到广播（或广播前就重启），
  /// App 会一直显示旧名字（老板 2026-09-11 实测）；性别同理（v2 早期把对方性别
  /// 写死空串 → 气泡回退灰色）。启动与收到 profile.updated 时调用
  /// （对齐 CLI 的 _refreshPartnerNames）。
  Future<void> _refreshProfileFromServer() async {
    if (!mounted || widget.token.isEmpty || effectiveServer.isEmpty) return;
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final space = await api.getSpace(widget.token);
      // 重启（PIN 解锁）路径不传 partnerId（main.dart 只还原明文 payload）——
      // 从 /space 的通道表里按 entranceId 反查，否则拿不到"我"，校正无从下手
      var mine = widget.partnerId;
      if (mine == null || mine.isEmpty) {
        for (final d in space.entrances) {
          if (d.entranceId == widget.entranceId) {
            mine = d.partnerId;
            break;
          }
        }
      }
      if (mine == null || mine.isEmpty) return;
      // 反查到的本机 partnerId 落地：头像加载/上传后的缓存失效都要用它
      // （重启路径 widget.partnerId 为空，否则上传头像后消息流不刷新）
      final mineChanged = _myPartnerId != mine;
      _myPartnerId = mine;
      // 启动时没有 partnerId（重启路径）或反查值与服务器不一致 → 重拉头像
      if ((mineChanged || _myAvatarBytes == null) && mounted) unawaited(_loadMyAvatar());
      final myG = space.partnerGenders[mine] ?? '';
      var peerG = '';
      var peerName = '';
      var peerId = '';
      for (final entry in space.partnerNames.entries) {
        if (entry.key == mine) continue;
        peerName = entry.value;
        peerG = space.partnerGenders[entry.key] ?? '';
        peerId = entry.key;
        break;
      }
      final myName = space.partnerNames[mine] ?? '';
      // 身份槽位（0=第一人/创建者，1=第二人）：同性别第二人气泡取青色的判据
      // （老服务端 partner_slots 为空表 → 保持 null，不启用青色）
      final mySlot = space.partnerSlots[mine];
      final peerSlot = peerId.isEmpty ? null : space.partnerSlots[peerId];
      if (!mounted) return;
      setState(() {
        if (myName.isNotEmpty) _myPartnerName = myName;
        if (peerName.isNotEmpty) _peerName = peerName;
        if (myG.isNotEmpty) _myGender = myG;
        if (peerG.isNotEmpty) _peerGender = peerG;
        _mySlot = mySlot;
        _peerSlot = peerSlot;
      });
      // 校正结果回写本地快照：否则下次启动（尤其离线）又用回入网时的旧值
      // （setState 只覆盖非空值，故不会把已有名字写成空）；按 spaceId 写，仅落当前空间
      await AppLockService(widget.db ?? LocalDatabase.shared).saveProfile(
        spaceId: widget.spaceId,
        partnerName: _myPartnerName,
        peerName: _peerName,
        entranceName: _myEntranceName,
        myGender: _myGender,
        peerGender: _peerGender,
        mySlot: _mySlot,
        peerSlot: _peerSlot,
      );
    } catch (_) {
      // 网络失败：保持快照值（下次刷新再试）
    }
  }

  /// 上线补查（离线期间口令被重设）：启动/WS 连接后对比服务端 updated_at，
  /// 服务器更新 = 口令已重设——只发通知不弹窗（修改口令时按需才要求输入新口令）。
  Future<void> _checkEscrowRotated() async {
    if (!mounted || widget.token.isEmpty || effectiveServer.isEmpty) return;
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
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
  ///
  /// 撤销毁数据**只认两个明确信号**（老板 2026-09-16）：
  /// - `ENTRANCE_REVOKED`：服务端明确说"这条通道被撤销了"（涉嫌被盗用）→ [_onEntranceRevoked]
  ///   清空本地数据 → 提示 → 回设置页；
  /// - `entrance.revoked` 帧（见 [_onEntranceRevoked] 的另一挂点）。
  ///
  /// `FORBIDDEN` 只表示"服务器不认这条通道"——**最可能是后台数据库被清空/重置**，
  /// 这是运维失误而非撤销，只置 [_entranceUnrecognized] 让常驻提示条说明情况，
  /// 本地消息仍然可读（此前一律当撤销处理，把本地数据全删了，不可挽回）。
  /// 其他异常原样抛出（调用方退避/提示）。
  Future<String> _reauthWithRevokedFallback() async {
    try {
      return await widget.reauth!();
    } on ApiException catch (e) {
      if (e.code == 'ENTRANCE_REVOKED') {
        await _onEntranceRevoked();
      } else if (e.code == 'FORBIDDEN' && mounted && !_entranceUnrecognized) {
        setState(() => _entranceUnrecognized = true);
      }
      rethrow;
    }
  }

  /// 本通道被撤销（Server 广播 entrance.revoked / 认证 403 ENTRANCE_REVOKED）：
  /// 清理本地数据（锁包+消息库）→ 提示 → 强制回设置页重新配置。
  /// **只有明确撤销走这里**（未登记/连不上只提示，见 [_reauthWithRevokedFallback]）。
  Future<void> _onEntranceRevoked() async {
    if (_wiped) return; // 去重：WS 帧与重认证可能同时触发（两次清理/两次跳转）
    _wiped = true;
    _ticker?.cancel();
    await _ws?.stop();
    if (!mounted) return;
    final db = widget.db ?? LocalDatabase.shared;
    // 逐步 best-effort：此前 6 步共用一个 try，第一步（清锁包）一抛异常，后面三个
    // delete 全被跳过 → 消息明文留在盘上，与"撤销=销毁"的语义相反。
    Future<void> step(Future<void> Function() f) async {
      try {
        await f();
      } catch (_) {
        // 单步失败不阻断其余清理
      }
    }
    // **只清这一个空间**（多空间 2026-09-22）：凭证 + 消息/附件/同步锚点/媒体缓存/
    // 留存明文。PIN 模式下这里没有 pin（也不该在页面里留着 pin），凭证条目会挂
    // pending，下次解锁时再摘——数据此刻已经清干净，其他空间原样保留。
    // 此前是全机 clear() + 删全表，多空间下等于"一个空间被撤销 = 全机数据归零"。
    await step(() => AppLockService(db).removeSpace(widget.spaceId));
    // TODO(M2)：Vault 里还有其他空间时应回 SpaceListPage，而不是 SetupPage。
    if (!mounted) return;
    showTopNotice(context, AppLocalizations.of(context)!.chatPageEntranceRevoked);
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const SetupPage()),
      (route) => false,
    );
  }

  /// 重建轮询 ticker（WS 状态变化时切换间隔）。
  void _restartTicker(Duration interval) {
    _ticker?.cancel();
    _currentTickerInterval = interval;
    _ticker = Timer.periodic(interval, (_) => _onTick());
  }

  /// WS 状态变化：在线 → 降频兜底（30s）；离线 → 恢复高频轮询（3s）。
  void _onWsStatusChanged() {
    final online = _ws?.connected.value ?? false;
    _restartTicker(_tickerInterval); // 基准随 WS 状态变（在线 30s / 离线 3s），再乘退避
    if (mounted) setState(() {}); // 刷新标题红绿灯（在线绿/离线红）
    _refreshPeerOnline(); // 连接恢复时顺带刷新对方在线状态
    if (online) _checkEscrowRotated(); // 上线补查：离线期间口令被重设则发通知
  }

  /// 加载本设备阅后即焚档位秒数（每设备独立，纯本地）。
  Future<void> _loadBurnLabel() async {
    final s = BurnAfterSettings(widget.db ?? LocalDatabase.shared, spaceId: widget.spaceId);
    final seconds = await s.load();
    if (mounted) setState(() => _burnSeconds = seconds);
  }

  /// 顶栏 🌐：切换界面语言（跟随系统/中文/English，即时生效）。
  Future<void> _showLocalePicker() async {
    final settings = LocaleSettings(widget.db ?? LocalDatabase.shared);
    final current = await settings.load();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    var picked = current;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => OptionPickerSheet(
        title: l10n.chatPageMenuLocaleLabel,
        selected: current,
        options: [
          for (final option in kLocaleOptions)
            OptionPickerItem(value: option, label: kLocaleLabels[option]!),
        ],
        onApply: (value) async {
          picked = value;
          await settings.save(value);
        },
      ),
    );
    if (picked == current) return;
    if (!mounted) return;
    showTopNotice(context, AppLocalizations.of(context)!.chatPageLocaleSwitched(kLocaleLabels[picked]!));
  }

  /// 加载持久化的界面主题（默认素雅纯色，保留原有视觉效果）。
  /// 同步回 uiStyleNotifier：弹层选中态读的是 notifier，不回写会导致
  /// 冷启动后"页面是渐变、弹层却选中素雅纯色"的不一致。
  Future<void> _loadUiStyle() async {
    final s = UiStyleSettings(widget.db ?? LocalDatabase.shared);
    final style = await s.load();
    if (!mounted) return;
    setState(() => _uiStyle = style);
    if (uiStyleNotifier.value != style) uiStyleNotifier.value = style;
  }

  /// 风格切换通知（弹窗内点选即触发）：立即重建背景与菜单当前值。
  void _onUiStyleChanged() {
    if (mounted) setState(() => _uiStyle = uiStyleNotifier.value);
  }

  Future<void> _loadAttachmentStorage() async {
    final s = AttachmentStorageSettings(widget.db ?? LocalDatabase.shared, spaceId: widget.spaceId);
    final mode = await s.load();
    if (mounted) setState(() => _attachmentStorage = mode);
  }

  /// 存储模式切换通知：立即重建（附件渲染改用/停用本地副本）。
  void _onAttachmentStorageChanged() {
    if (mounted) setState(() => _attachmentStorage = attachmentStorageNotifier.value);
  }

  /// 顶栏菜单 → 附件存储（安全 / 留存）：本设备设置，两台设备可各选各的。
  /// 切回 secured 时**清空已留存的明文**（否则"安全"名不副实——老板 2026-09-14 定）。
  /// 界面主题名（按当前语言）。
  String _uiStyleLabel(String style, AppLocalizations l10n) =>
      style == 'gradient' ? l10n.chatPageUiStyleGradient : l10n.chatPageUiStylePlain;

  /// 附件存储模式标签（按当前语言）。
  String _attachmentStorageLabel(String mode, AppLocalizations l10n) =>
      mode == 'stored'
          ? l10n.chatPageAttachmentStorageStored
          : l10n.chatPageAttachmentStorageSecured;

  /// 附件存储模式说明（按当前语言）。
  String _attachmentStorageDesc(String mode, AppLocalizations l10n) =>
      mode == 'stored'
          ? l10n.chatPageAttachmentStorageStoredDesc
          : l10n.chatPageAttachmentStorageSecuredDesc;

  /// 附件存储：**单选 + 提交**（不点选即生效——老板 2026-09-14）——切回「远程托管」
  /// 会立刻删掉已留存的明文，是有害操作；选中该项时弹层里给红字警示。
  Future<void> _showAttachmentStoragePicker() async {
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => OptionPickerSheet(
        title: l10n.chatPageMenuAttachmentStorage,
        selected: _attachmentStorage,
        submitLabel: l10n.chatPageAttachmentStorageSubmit,
        // 只在"准备切回远程托管、且当前不是它"时提示（真要删数据）
        warningFor: (v) => (v == 'secured' && _attachmentStorage != 'secured')
            ? l10n.chatPageAttachmentStorageWarnClear
            : null,
        options: [
          for (final mode in kAttachmentStorageOptions)
            OptionPickerItem(
              value: mode,
              label: _attachmentStorageLabel(mode, l10n),
              description: _attachmentStorageDesc(mode, l10n),
            ),
        ],
        onApply: (mode) async {
          await AttachmentStorageSettings(widget.db ?? LocalDatabase.shared, spaceId: widget.spaceId).save(mode);
          if (mode == 'secured') {
            // 切回远程托管：把本机留存的明文附件全部清除
            await AttachmentStore.clear();
          }
        },
      ),
    );
  }

  /// 「切换空间」：弹「选择秘境」弹层（小卡片瀑布流）→ 选中即**直接换到那个空间**（不跳页）。
  /// 弹层底部还有「＋ 新建/加入空间」通往第一屏（需要先过一次锁屏码，见 addSpaceFlow）。
  ///
  /// 不再需要 `onSwitchSpace` / `onManageSpaces` 这类"由入口注入"的回调：切换空间**不需要
  /// 锁屏码**（当前空间落明文键），其它空间的凭证在内存会话 [VaultSession] 里。
  Future<void> _openSpacePicker() async {
    final pick = await showSpacePicker(context, db: widget.db, api: widget.api);
    if (!mounted || pick == null) return;
    if (pick.add) {
      await addSpaceFlow(context, db: widget.db, api: widget.api);
      return;
    }
    final id = pick.spaceId;
    if (id == null || id == widget.spaceId) return; // 选的是当前空间：什么都不做
    await switchToSpace(context, id, db: widget.db);
  }

  /// 顶栏 🎨：切换界面主题（素雅纯色/渐变粉蓝）。弹窗内点选即生效并立即关闭，
  /// 回到对话消息页（老板要求 2026-09-13；此前是保持打开供边看边试）。
  Future<void> _showStylePicker() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => UiStylePickerSheet(
        settings: UiStyleSettings(widget.db ?? LocalDatabase.shared),
      ),
    );
  }

  /// 开通通道：生成一次性 join token（POST /spaces/{id}/join-tokens，Multiverse
  /// v2，24h 一次性、需本人会话认证；旧 v1 createInvite 已废弃，不再生成 v1 邀请码）。
  /// 二维码与展示内容 = 邀请链接（`https://einz.tic.cc/join/<token>`），对方 App/
  /// CLI 可扫码或粘贴链接加入；口令由对方加入时另行输入（降级 B，与 TUI 一致）。
  Future<void> _showInviteDialog() async {
    // 老板决策：点顶栏添加按钮直接生成开通码（不再先弹"开通通道"确认窗）
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      var r = await api.createJoinToken(widget.spaceId, widget.token);
      if (!mounted) return;
      // 「重新生成」进行中的标记（放在 builder 外：StatefulBuilder 用箭头函数，没地方声明）
      var busy = false;
      final l10n = AppLocalizations.of(context)!;
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: Text(l10n.chatPageInviteDialogTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 说明文案作为大标题的补充说明，置于标题与二维码之间（老板 2026-09-13）；
                // 靠左对齐——本弹窗除二维码外其余内容均靠左
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(l10n.chatPageInviteDialogHint,
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ),
                const SizedBox(height: 12),
                // 自绘二维码：QrImageView 的 LayoutBuilder 会触发 AlertDialog
                // 固有尺寸异常（见 _InviteQrCode 注释），此处不用它
                Center(child: _InviteQrCode(data: r.link)),
                const SizedBox(height: 12),
                // 顺序（老板 2026-09-22）：**纯开通码在上、邀请链接在下**——
                // 多数人是直接复制开通码；链接留给『点开看邀请页』的场景。
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(r.joinToken,
                          // 开通码是主体：颜色深（跟随主题 onSurface，浅色下近黑）+ 加粗；
                          // 字号与链接同为 12——老板 2026-09-22：16 号太大，回到 12
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                              color: Theme.of(ctx).colorScheme.onSurface)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 16),
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      tooltip: l10n.chatPageInviteCopyCodeTooltip,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      visualDensity: VisualDensity.compact,
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: r.joinToken));
                        if (!ctx.mounted) return;
                        showTopNotice(ctx, l10n.chatPageInviteCodeCopied);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                // 邀请链接 + 拷贝图标（点击即复制，弹窗不关闭——根 Overlay 通知
                // 在弹窗之上可见，老板 2026-09-11）
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(r.link,
                          // 链接退为次要：字号 14 → 12（保留品牌蓝与加粗，保证小字也看得清）
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF2271F7))),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 16),
                      color: const Color(0xFF2271F7),
                      tooltip: l10n.chatPageInviteCopyLinkTooltip,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      visualDensity: VisualDensity.compact,
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: r.link));
                        if (!ctx.mounted) return;
                        showTopNotice(ctx, l10n.chatPageInviteLinkCopied);
                      },
                    ),
                  ],
                ),
              ],
            ),
            // 只留一个「关闭」（老板 2026-09-23：原来 Copy/Close 两个纯文字按钮没有主次）。
            // 去掉了 Copy —— 它复制的是**链接**，而上面 token / 链接两行各自都有复制图标
            // （带 tooltip 与顶部提示），底部的 Copy 既冗余又没说清复制哪个。
            // 点弹窗外/返回键本来就能关（showDialog 默认 barrierDismissible:true）；
            // 留一个 Close 是给"不知道能点外面"的人一条明路。
            actions: [
              TextButton(
                onPressed: () async {
                  if (busy) return; // 进行中：忽略重复点击
                  setLocal(() => busy = true);
                  try {
                    final fresh = await api.createJoinToken(
                        widget.spaceId, widget.token);
                    if (!ctx.mounted) return;
                    r = fresh; // 就地刷新：二维码 / 开通码 / 链接 ✓
                    setLocal(() {});
                  } catch (e) {
                    if (!ctx.mounted) return;
                    showTopNotice(ctx, l10n.chatPageInviteFailed('$e'));
                  } finally {
                    if (ctx.mounted) setLocal(() => busy = false);
                  }
                },
                child: Text(l10n.chatPageInviteRegenerate),
              ),
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(), child: Text(l10n.close)),
            ],
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showTopNotice(
          context, AppLocalizations.of(context)!.chatPageInviteFailed('$e'));
    }
  }

  /// 补设/重设启动锁（跳过 PIN 后某天想设置时用；复用 PIN 表单）。
  /// 用当前会话的 Space Key 包 setPin 加密落盘（内部会清掉明文副本）。
  Future<void> _showSetLockDialog() async {
    final payload = AppLockPayload(
      spaceId: widget.spaceId,
      entranceId: widget.entranceId,
      spaceKeyB64: base64Encode(widget.spaceKey),
      keyVersion: widget.keyVersion,
      token: widget.token,
      publicKeyB64: widget.publicKeyB64,
      privateKeyB64: widget.privateKeyB64,
    );
    // 弹窗内容抽为 _SetLockDialog（StatefulWidget）：controller 生命周期随 State
    // 卸载同步释放，避免"点设置后 dispose 竞态"（TextField 卸载动画中向已销毁
    // controller 加 listener → debugAssertNotDisposed / _dependents.isEmpty 红屏，
    // 2026-09-05 真机定位）。
    // 是否已设锁屏码**在开弹窗前读好再传进去**（老板 2026-09-14）：弹窗里要据此决定
    // 出不出现"当前锁屏码"验证框，异步读会有毫秒级窗口让验证被跳过
    final db = widget.db ?? LocalDatabase.shared;
    final hasPin = await AppLockService(db).isSetup;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _SetLockDialog(
        payload: payload,
        db: db,
        hasPin: hasPin,
      ),
    );
    if (ok == true && mounted) {
      // 设置或清空成功：不再猜结果（此前写死 _hasPin=true，清空后菜单仍显示
      // 「已设置」——老板 2026-09-15 实测），按落盘后的真实状态刷新菜单
      await _refreshPinStatus();
    }
  }

  /// 刷新本机 PIN 状态（菜单项「PIN: 已设置/未设置」；initState 时读取）。
  Future<void> _refreshPinStatus() async {
    final has = await AppLockService(widget.db ?? LocalDatabase.shared).isSetup;
    if (!mounted || has == _hasPin) return;
    setState(() => _hasPin = has);
  }

  /// 修改口令（escrow 托管口令，空间级）：旧口令验证 → 新口令重加密上传
  /// （本地不落共享口令，与 TUI 对齐）。
  Future<void> _showChangePassphraseDialog() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _ChangePassphraseDialog(
        server: effectiveServer,
        spaceKeyB64: base64Encode(widget.spaceKey),
        spaceId: widget.spaceId,
        keyVersion: widget.keyVersion,
        token: widget.token,
        api: widget.api,
        onPassphraseUpdated: (updatedAt) {
          if (mounted) _escrowUpdatedAt = updatedAt ?? _escrowUpdatedAt;
        },
      ),
    );
    if (changed == true && mounted) {
      showTopNotice(context, AppLocalizations.of(context)!.chatPageChangePassphraseDone);
    }
  }

  /// 打开「关于秘境」页（版本号 / 服务器地址 / 一句话说明）。
  /// 菜单项动作：等菜单关闭动画跑完再开新 route——MenuRoute/DialogRoute 在 Overlay 里
  /// 交叉卸载会触发断言崩溃（2026-09-05 修复），所以统一在这里错峰 300ms。
  void _menuAction(VoidCallback action) {
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      action();
    });
  }

  /// 「高级」底部弹层（二级菜单：修改口令 / 销毁本通道）。两项都只给标题——
  /// 具体后果留给点进去的弹窗说明（弹层本身不解释）。
  ///
  /// 为什么用弹层而不是 MenuAnchor + SubmenuButton 的级联子菜单：手机宽度下
  /// 主菜单 280 + 子菜单约 190 塞不进一屏，级联面板会与主菜单重叠、还会被面板里的
  /// 分隔线横穿（2026-09-19 实测），换弹层最省事。
  Future<void> _showAdvancedSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        final red = Theme.of(ctx).colorScheme.error;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  l10n.advancedMenuTitle,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: Text(l10n.chatPageMenuChangePassphrase),
                onTap: () => Navigator.of(ctx).pop('passphrase'),
              ),
              ListTile(
                leading: Icon(Icons.warning_amber_rounded, color: red),
                title: Text(l10n.advancedDestroyEntrance),
                onTap: () => Navigator.of(ctx).pop('leave'),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    // 与弹层关闭动画错开再开 dialog：Overlay 里两个 route 交叉卸载会触发断言
    // （同 _menuAction 的 2026-09-05 修复）
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    if (picked == 'passphrase') {
      await _showChangePassphraseDialog();
    } else if (picked == 'leave') {
      // 阀门所需的两个输入：通道名（确认清的是这条）与"是否设了锁屏码"（决定要不要验）。
      // 都用 await 取，过一遍 mounted 再传进弹窗。
      final entranceName = await _resolveMyEntranceName();
      final hasPin = await AppLockService(widget.db ?? LocalDatabase.shared).isSetup;
      if (!mounted) return;
      // **空间级**：只退出并清除当前空间，不动本机上的其他空间（老板 2026-09-22 定）。
      // 整台设备的清理由空间列表页的「清除本设备全部数据」负责。
      final left = await confirmLeaveSpace(
        context,
        db: widget.db,
        api: widget.api,
        spaceId: widget.spaceId,
        token: widget.token,
        entranceName: entranceName,
        hasPin: hasPin,
      );
      if (!left || !mounted) return;
      // 退出后：还有别的空间 → 直接切到下一个（VaultPayload.remove 已把 active 让给剩下的
      // 第一个）；一个都不剩 → 回向导。
      final vault = VaultSession.current;
      final database = widget.db ?? LocalDatabase.shared;
      final next = vault == null
          ? null
          : await AppLockService(database).resolveActivePayload(vault);
      if (next == null) {
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const SetupPage()),
          (route) => false,
        );
        return;
      }
      if (!mounted) return;
      await switchToSpace(context, next.spaceId, db: widget.db);
    }
  }

  /// 重置闸门要用的"本机通道名"。
  ///
  /// 不能用 `widget.entranceName`：**只有向导那条路径传它**（setup_page），重启/解锁进
  /// 聊天的路径（main.dart StartupGate）不带——那边的名字由 [_myEntranceName] 从本地
  /// profile 恢复。取不到（旧装机快照里没写 entranceName）时再问一次服务端：通道名是
  /// 入网时自动生成并同步上去的，服务端必定有。都问不出来返回 ''，由重置弹窗退化为
  /// 固定确认词——本地快照缺字段不该让人永远重置不了（老板 2026-09-21 安卓实测）。
  Future<String> _resolveMyEntranceName() async {
    final local = _myEntranceName.trim();
    if (local.isNotEmpty) return local;
    if (widget.token.isEmpty || effectiveServer.isEmpty) return '';
    try {
      final rows = await (widget.api ?? ApiClient(effectiveServer)).listEntrances(widget.token);
      for (final d in rows) {
        if (d['entrance_id'] == widget.entranceId) {
          return (d['entrance_name'] as String? ?? '').trim();
        }
      }
    } catch (_) {
      // 离线/报错：交给上层退化为确认词
    }
    return '';
  }

  void _openAboutPage() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const AboutPage()),
    );
  }

  /// 对方在线判定：对方有实时 WS 连接（connected_at 非 null）= 在线；
  /// 旧服务器无 connected_at 字段时退回 last_seen 距今 < 60s 兜底
  /// （30s 轮询 + WS 状态变化时刷新）。
  Future<void> _refreshPeerOnline() async {
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final entrances = await api.listEntrances(widget.token);
      final now = DateTime.now().millisecondsSinceEpoch;
      // 在线是"人"维度的：同一 partner 的其它通道是我自己开的通道，不算对方
      // （重启路径不传 partnerId → 从通道表里按本通道反查；查不到才退回按通道判定）
      var mine = widget.partnerId;
      if (mine == null || mine.isEmpty) {
        for (final d in entrances) {
          if (d['entrance_id'] == widget.entranceId) {
            mine = d['partner_id'] as String?;
            break;
          }
        }
      }
      final peer = entrances.where((d) {
        if (d['entrance_id'] == widget.entranceId) return false;
        final pid = d['partner_id'] as String?;
        if (pid == null || mine == null || mine.isEmpty) return true;
        return pid != mine;
      }).toList();
      final online = peer.isNotEmpty && peer.any((d) {
        // 实时 WS 连接 = 真在线（server 重启/未入网时立即准确）；last_seen 会被
        // 轮询 touchLastSeen 持续刷新，不能代表实时连接（修复"未入网却显示绿灯"）。
        if (d.containsKey('connected_at')) return d['connected_at'] != null;
        final last = d['last_seen'];
        if (last is! num) return false;
        return now - last < 60 * 1000;
      });
      // 对方由离线转在线（含"刚加入空间"——WS 事件可能漏，这里兜底）：补拉身份
      if (online && !_peerOnline) unawaited(_refreshProfileFromServer());
      if (mounted && online != _peerOnline) setState(() => _peerOnline = online);
    } catch (_) {
      // 网络失败：保持上次状态
    }
  }

  /// 加载我的头像（异步；未设置/失败 → 保持默认图标）。
  /// partnerId 缺失时（重启路径）从本地持久化的 entrance→partner 映射反查。
  /// 把"本空间对方是谁"（partner_id）落进 per-space 资料，与 peerName 并列。
  ///
  /// 为什么要在 `refreshEntranceMap()` 之后做：对方的 partner_id 只在那份通道表映射里
  /// 出现过（服务端 `GET /space` 的 `entranceId → partnerId`，排掉自己就是对方），
  /// 而映射只在内存 + 一张全局表里，**没有"按空间"的落点**。不落的话，切换秘境弹层的卡片
  /// 就只能显示默认头像——明明有对方名字却不知道对方是谁（老板 2026-09-23 指出）。
  ///
  /// best-effort：拿不到（离线/只有我一人）就什么都不做，卡片保持默认头像。
  Future<void> _persistPeerPartnerId() async {
    final pid = _repo.resolvePeerPartnerId();
    if (pid == null || pid.isEmpty) return;
    try {
      await AppLockService(widget.db ?? LocalDatabase.shared)
          .savePeerPartnerId(spaceId: widget.spaceId, peerPartnerId: pid);
    } catch (_) {
      // 落盘失败不影响聊天；下次刷新再试
    }
  }

  Future<void> _loadMyAvatar() async {
    var pid = _myPartnerId;
    if (pid == null || pid.isEmpty) {
      pid = await _repo.resolveMyPartnerId();
      if (pid == null || pid.isEmpty) return;
      _myPartnerId = pid;
    }
    if (!mounted) return;
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final bytes = await api.getAvatar(pid);
      if (bytes != null && mounted) setState(() => _myAvatarBytes = bytes);
    } catch (_) {
      // 网络失败：保持默认图标
    }
  }

  /// 修改我的头像：选图 → 上传服务端（per-partner 覆盖）→ 本地缓存刷新菜单显示。
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
      final api = widget.api ?? ApiClient(effectiveServer);
      // 服务端在上传响应里回 partner_id：上传方收不到自己的 profile.updated 广播，
      // 这个返回值是失效本端头像缓存最可靠的依据（重启路径 widget.partnerId 为空，
      // 旧实现 invalidate(null) 静默失效失败 — 老板 2026-09-16 报告）
      final partnerId = await api.uploadAvatar(bytes, widget.token);
      // 服务端回的是权威值；响应异常/旧服务端缺字段 → 退到本地反查
      final pid = (partnerId != null && partnerId.isNotEmpty)
          ? partnerId
          : (_myPartnerId ?? await _repo.resolveMyPartnerId());
      if (!mounted) return;
      if (pid != null && pid.isNotEmpty) _myPartnerId = pid;
      // 消息流里的头像走静态缓存：主动失效才会重拉（否则要重启才更新）
      _MessageAvatarState.invalidate(pid);
      setState(() => _myAvatarBytes = bytes);
      showTopNotice(context, l10n.chatPageAvatarUploaded);
    } catch (e) {
      if (!mounted) return;
      showTopNotice(context, l10n.chatPageAvatarFailed('$e'));
    }
  }

  /// 修改我的名字/通道名称（服务端同步 + 本地刷新菜单显示）。
  Future<void> _showRenameDialog({required bool renameEntrance}) async {
    final l10n = AppLocalizations.of(context)!;
    final ctrl = TextEditingController(text: renameEntrance ? _myEntranceName : _myPartnerName);
    // 公钥只读展示（我的通道弹窗）：静态文本控制器，随对话框关闭释放
    final pubKeyCtrl = TextEditingController(
      text: widget.publicKeyB64 ?? l10n.chatPageEntrancePublicKeyFailed,
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
    // 名字/通道名编辑态切换：初始只读透明 + 右侧编辑按钮；点编辑 → 白底可编辑、按钮消失
    final editing = ValueNotifier<bool>(false);
    // 名称输入框焦点：点框内任意位置进编辑态时手动取焦（只读态点击不会自动取焦）
    final nameFocus = FocusNode();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(renameEntrance ? l10n.chatPageRenameEntranceTitle : l10n.chatPageRenameNameTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 本机信息弹窗：说明"名称与公钥只属于当前秘境"——多空间下同一条通道在
            // 每个秘境各有一套（名称可不同、公钥必然不同），不点明会让人以为改的是
            // 全局通道名（老板 2026-09-22 定：承认 per-space，不强行统一）。
            if (renameEntrance) ...[
              Text(
                l10n.chatPageEntranceScopeHint,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(ctx).colorScheme.outline,
                ),
              ),
              const SizedBox(height: 10),
            ],
            // 名字/通道名输入框：初始只读 + 透明背景，右侧「编辑」按钮；点编辑 →
            // 白底可编辑、按钮消失（老板要求 2026-09-09）。
            // 点框内任意位置也进编辑态（老板 2026-09-23）：用 TextField 自带的
            // onTap 派发，不额外套 GestureDetector（会和输入框内部手势抢 arena）
            ValueListenableBuilder<bool>(
              valueListenable: editing,
              builder: (_, isEditing, _) => TextField(
                controller: ctrl,
                focusNode: nameFocus,
                readOnly: !isEditing,
                onTap: () {
                  if (editing.value) return;
                  editing.value = true;
                  nameFocus.requestFocus();
                },
                decoration: InputDecoration(
                  labelText: renameEntrance ? l10n.chatPageRenameEntranceLabel : l10n.chatPageRenameNameLabel,
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
            // 我的通道弹窗：公钥只读展示——放在通道名称之后（textarea 样式，边框
            // 左上角「公钥」标签，右侧拷贝按钮；只读不加背景色，沿用弹窗背景）
            if (renameEntrance) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: pubKeyCtrl,
                readOnly: true,
                maxLines: 2,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Colors.grey),
                decoration: InputDecoration(
                  labelText: l10n.chatPageEntrancePublicKeyLabel,
                  border: const OutlineInputBorder(),
                  // 公钥只读：不加背景色，沿用弹窗背景（可编辑的通道名称才是白底）
                  suffixIcon: IconButton(
                    tooltip: l10n.chatPageCopy,
                    icon: const Icon(Icons.copy, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.publicKeyB64 == null
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: widget.publicKeyB64!));
                            showTopNotice(ctx, l10n.chatPagePublicKeyCopied);
                          },
                  ),
                ),
              ),
            ],
            // 我的个人资料弹窗：性别用与名字输入框同款组件（只读）——「性别」标签
            // 在边框左上角（同「我的名字」），框内显示 男/女 + 性别图标
            // （老板要求 2026-09-09）
            if (!renameEntrance) ...[
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
                // 空/全空格：红字警示并停留（不再静默跳过）；人名与通道名各用各的提示
                nameError.value = renameEntrance
                    ? l10n.chatPageRenameEntranceEmptyError
                    : l10n.chatPageRenameMyselfEmptyError;
                return;
              }
              // 通道名字符白名单 + 长度上限（老板 2026-09-16）：只允许中英文、
              // 数字、`_`、`-`，≤32；不合规提示重输（服务端另有 400 兜底）
              if (renameEntrance) {
                final violation = checkEntranceNamePolicy(name);
                if (violation != null) {
                  nameError.value = violation == EntranceNameViolation.tooLong
                      ? l10n.chatPageRenameEntranceTooLongError(kEntranceNameMaxLength)
                      : l10n.chatPageRenameEntranceInvalidError;
                  return;
                }
              }
              // 用户名称白名单（老板 2026-09-16）：中英文/数字/`_`/`-`/emoji，≤32
              if (!renameEntrance) {
                final violation = checkPartnerNamePolicy(name);
                if (violation != null) {
                  nameError.value = violation == PartnerNameViolation.tooLong
                      ? l10n.chatPageRenameNameTooLongError(kPartnerNameMaxLength)
                      : l10n.chatPageRenameNameInvalidError;
                  return;
                }
              }
              // 不允许改成与对方相同的名字（老板 2026-09-10）
              if (!renameEntrance && widget.peerName != null && name == widget.peerName) {
                nameError.value = l10n.chatPageRenameSameAsPeerError;
                return;
              }
              try {
                final api = widget.api ?? ApiClient(effectiveServer);
                if (renameEntrance) {
                  await api.updateEntranceName(name, widget.token);
                  _myEntranceName = name;
                } else {
                  await api.updatePartnerName(name, widget.token);
                  _myPartnerName = name;
                }
                // 同步本地 profile：重启后 ChatPage 从 profile 恢复新名字
                // （否则 loadProfile 读到向导完成时的旧名——2026-09-07 老板实测
                // app 菜单改名后退出重进回到 partnerB）
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
      nameFocus.dispose();
    });
    if (saved == true && mounted) setState(() {}); // 刷新菜单显示的新名字
  }

  /// 同步当前名字到本地 profile（改名/改通道名后调用——重启从 profile 恢复）。
  /// 按 spaceId 写：多空间下各空间一份，别互相覆写（2026-09-22）。
  Future<void> _saveProfile() async {
    await AppLockService(widget.db ?? LocalDatabase.shared).saveProfile(
      spaceId: widget.spaceId,
      partnerName: _myPartnerName,
      peerName: _peerName,
      entranceName: _myEntranceName,
      myGender: _myGender,
      peerGender: _peerGender,
      mySlot: _mySlot,
      peerSlot: _peerSlot,
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
    String? picked;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => OptionPickerSheet(
        title: l10n.chatPageBurnHeading,
        selected: '$current',
        options: [
          for (final entry in kBurnAfterOptions.entries)
            OptionPickerItem(
              value: '${entry.value}',
              label: _burnOptionLabel(entry.value, l10n),
            ),
        ],
        onApply: (value) async => picked = value,
      ),
    );
    return picked == null ? null : int.parse(picked!);
  }

  /// 顶栏 ⏱：选择阅后即焚档位（保存到本设备设置，发送新消息时生效）。
  Future<void> _showBurnPicker() async {
    final settings = BurnAfterSettings(widget.db ?? LocalDatabase.shared, spaceId: widget.spaceId);
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
                burnManual: seconds > 0, status: x.status, meta: x.meta)
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

  /// 补登安装级标识（POST /entrances/install-uid，幂等）。
  ///
  /// 用途：多空间下服务端要能知道"这台物理设备上挂了哪几个空间"（运维/审计），而
  /// install_uid 是随 create/join 上报的——**存量通道**（多空间上线前入网的那批）不再走
  /// 入网流程，只能在这里补一次。离线/老服务端（无此端点）时静默降级：它只是服务端侧
  /// 认知，不参与任何功能。
  ///
  /// 只写**本空间**那一行：别的空间由客户端在那边进一次时各自补登。
  Future<void> _registerInstallUid() async {
    if (widget.token.isEmpty) return;
    try {
      final uid = await AppLockService(widget.db ?? LocalDatabase.shared).installUid();
      await (widget.api ?? ApiClient(effectiveServer)).registerInstallUid(uid, widget.token);
    } catch (_) {
      // 忽略
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    uiStyleNotifier.removeListener(_onUiStyleChanged);
    attachmentStorageNotifier.removeListener(_onAttachmentStorageChanged);
    _ticker?.cancel();
    _peerTicker?.cancel();
    _recordTimer?.cancel();
    _highlightTimer?.cancel(); // 跳转高亮定时清除（防 dispose 后 setState）
    _ampSub?.cancel();
    _ws?.connected.removeListener(_onWsStatusChanged);
    _ws?.stop();
    _scrollController.removeListener(_maybeLoadOlder);
    _inputFocusNode.removeListener(_onInputFocusChanged);
    _scrollController.dispose();
    _input.dispose();
    _inputFocusNode.dispose();
    _audioPlaybackVersion.dispose();
    super.dispose();
  }

  /// 手动锁屏（顶栏锁图标）：立即推覆盖锁屏 → 解锁成功 pop 回本页（保留消息状态）。
  /// canDismiss=false：返回手势/返回键都被挡，必须输对锁屏码才能回聊天
  /// （老板 2026-09-16 要求"强化安全性"）。
  void _lockNow() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const LockPage(asOverlay: true, canDismiss: false)));
  }

  /// App 生命周期：切后台记时，回前台超过阈值 → 覆盖锁屏（保留聊天页状态）。
  ///
  /// 两条硬规则（老板 2026-09-20 实测报的 bug）：
  /// 1. **没设锁屏码就不要锁**：`_hasPin=false` 时锁屏页只会显示"尚未设置锁屏码"
  ///    提示页，既没意义又让人以为 App 出了问题——直接不锁，并照常补报已读。
  /// 2. **锁上就不能一点退回**：原先走的是默认 `canDismiss: true`，覆盖锁屏左上角
  ///    有返回箭头、点一下就绕过锁屏回到对话（安全漏洞）。改 `canDismiss: false`
  ///    与手动锁屏同口径：必须输对 PIN 才回聊天。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed; // 回执：只有前台才允许标已读
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _lockTimer.recordBackgrounded(DateTime.now());
    } else if (state == AppLifecycleState.resumed) {
      final relock = _lockTimer.shouldRelock(now: DateTime.now());
      _lockTimer.clear();
      // 不需要锁的两条路径：没离开够久（用户一直在看）、或本机压根没设锁屏码。
      // 两种都照常补报已读——别把"未超时不锁"顺手吞掉（原逻辑就在这个分支里报已读）
      if (!relock || !_hasPin || !mounted) {
        _scheduleReadReport();
        return;
      }
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => const LockPage(asOverlay: true, canDismiss: false)));
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
      // 到期焚毁：媒体缓存定点删（尽力而为、不等待——测试/主流程不被文件 I/O 阻塞）
      for (final id in await _repo.tombstoneExpired()) {
        unawaited(MediaCache.deleteFor(widget.spaceId, id));
        unawaited(AttachmentStore.deleteFor(widget.spaceId, id)); // stored 模式的留存明文同样要删
      }
      await _repo.refreshEntranceMap();
      await _persistPeerPartnerId();
      final recent = await _repo.historyRecent(limit: _pageSize);
      if (!mounted) return;
      setState(() => _messages = recent);
      // stored 模式：首屏附件的明文后台落盘（不阻塞首屏）
      unawaited(_autoStoreAttachments(recent));
      // 首次载入即定位到最新消息（老板实测 2026-09-09：原来停在最早消息处，
      // 要等 ticker 自动刷新才滚到底）——直接跳转不播动画，进入即见最新
      _scrollToLatest(animate: false);
      // 首屏回填只上报"已送达"——**不**上报已读（补拉的历史不等于人看过，
      // 老板 2026-09-12）。已读只由「WS 实时到达 + 用户前台看着」或「resume
      // 到前台且列表贴底」推进。
      unawaited(_reportDeliveredIfAdvanced());
      // 载入对方回执 → 自己消息可显示双勾（sync 内已拉过，此处兜底一次）
      unawaited(_loadPeerReceipts());
      // 启动孤儿清理：本地库已无对应消息的缓存 + 历史遗留 temp 文件（不阻塞首屏）。
      // 缓存已按空间分目录 → 只扫本空间，保留名单也只取本空间
      unawaited(_repo.allMessageIds().then((ids) => MediaCache.prune(widget.spaceId, ids)));
    } catch (_) {
      // 网络抖动忽略：本地缓存已上屏，等 ticker 重试
    }
  }

  /// 纯本地增量刷新（不发网络）：把本地新增/变更的消息并入列表——发送后「乐观回显」
  /// 与收到消息先上屏都用它，避免等 sync 网络往返（老板 2026-09-12）。
  /// 合并语义：按 messageId 就地替换（刷新 pending→sent/failed 状态），新 id 追加；
  /// 墓碑单调（本地已删的不会被旧读覆盖复活）；仅在有新消息时滚到底。
  Future<void> _refreshLocal({bool realtime = false}) async {
    if (!_initialLoaded) return;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      // 阅后即焚：到期消息打本地墓碑（纯本地）+ 定点删媒体解密缓存（不等待）
      for (final id in await _repo.tombstoneExpired(now: now)) {
        unawaited(MediaCache.deleteFor(widget.spaceId, id));
        unawaited(AttachmentStore.deleteFor(widget.spaceId, id));
      }
      final fresh = await _repo.historySince(afterSequence: _lastLoadedSequence);
      // stored 模式：新到附件的明文**收到即落盘**（消息流里点开就能看）
      unawaited(_autoStoreAttachments(fresh));
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
      // 回执：本端确实收到了对方的这些消息 → 上报"已送达"（补拉/首屏也算）。
      // "已读"只在 [realtime]（WS 实时到达）时才报——补拉的历史不等于人看过
      // （老板 2026-09-12）。
      unawaited(_reportDeliveredIfAdvanced());
      unawaited(_loadUnsentCount());
      if (realtime && added.isNotEmpty) _scheduleReadReport();
    } catch (_) {
      // 本地读取失败忽略，下次刷新重试
    }
  }

  /// 本端已加载的"对方消息"里最大的 serverSequence（未同步/无 seq 的忽略）。
  int get _maxLoadedPeerSeq {
    var maxSeq = 0;
    for (final m in _messages) {
      if (m.sender != 'peer') continue;
      final s = m.env.serverSequence;
      if (s != null && s > maxSeq) maxSeq = s;
    }
    return maxSeq;
  }

  /// 上报"已送达"（单调 + 防抖；失败忽略，下次会再报——重复上报服务端幂等）。
  Future<void> _reportDeliveredIfAdvanced() async {
    final seq = _maxLoadedPeerSeq;
    if (seq <= _lastReportedDeliveredSeq) return;
    // 成功才推进防抖标记：否则一次失败就再也不会重报（服务端永远缺这一档）
    if (await _reportReceiptQuietly(deliveredUptoSeq: seq)) {
      _lastReportedDeliveredSeq = seq;
    }
  }

  /// 上报"已读"：**仅当** App 在前台、本页是最上层（未被锁屏/弹层盖住）、且列表
  /// 贴底（用户确实看到了最新消息）时才报——避免把没看过的消息标已读。
  /// post-frame 执行：setState 刚提交时布局未完成，extentAfter 不可信。
  void _scheduleReadReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_appResumed) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      if (!_scrollController.hasClients) return;
      if (_scrollController.position.extentAfter > 48) return; // 上滑看历史 → 不标已读
      final seq = _maxLoadedPeerSeq;
      if (seq <= _lastReportedReadSeq) return;
      // 同上：成功才推进防抖标记
      unawaited(_reportReceiptQuietly(readUptoSeq: seq).then((ok) {
        if (ok) _lastReportedReadSeq = seq;
      }));
    });
  }

  /// 上报回执；返回是否成功（失败时调用方保留重试机会）。
  Future<bool> _reportReceiptQuietly({int? deliveredUptoSeq, int? readUptoSeq}) async {
    try {
      await _repo.reportReceipts(
        deliveredUptoSeq: deliveredUptoSeq,
        readUptoSeq: readUptoSeq,
      );
      return true;
    } catch (_) {
      // 网络抖动忽略；下次刷新会再报（单调，重复上报无害）
      return false;
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
      meta: fresh.meta,
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
  Future<void> _refresh({bool realtime = false}) async {
    if (_wiped) return; // 已撤销自毁：不再发起任何网络请求（页面正在被替换）
    await _refreshLocal(realtime: realtime);
    try {
      await _repo.sync();
      await _repo.refreshEntranceMap();
      await _persistPeerPartnerId();
      // 同步时顺带拉了对方回执（repo.sync 内）→ 载入渲染缓存
      await _loadPeerReceipts();
      await _refreshLocal(realtime: realtime);
      _onSyncSucceeded();
    } catch (_) {
      // 网络抖动忽略，下次轮询重试（并按连续失败次数退避）
      _onSyncFailed();
    }
  }

  /// 同步成功：复位退避（周期回到基准），并清掉"服务器不认本通道"的常驻提示
  /// （后台库被复原后应自动恢复正常，无需用户干预）。
  void _onSyncSucceeded() {
    if (_entranceUnrecognized && mounted) {
      setState(() => _entranceUnrecognized = false);
    }
    if (_consecutiveSyncFailures == 0) return;
    _consecutiveSyncFailures = 0;
    _ensureTickerInterval();
  }

  /// 同步失败：累加退避计数并重设 ticker 周期。
  void _onSyncFailed() {
    if (_consecutiveSyncFailures < 10) _consecutiveSyncFailures++;
    _ensureTickerInterval();
    if (mounted) setState(() {}); // 让离线提示及时出现
  }

  /// 基准轮询周期：WS 在线 30s（推送兜底），离线 3s（尽快恢复）。
  Duration get _baseTickerInterval =>
      (_ws?.connected.value ?? false)
          ? const Duration(seconds: 30)
          : const Duration(seconds: 3);

  /// 实际轮询周期 = 基准 × 2^(连续失败次数)，上限 60s。
  /// 目的：离线期间把"每 3s 一轮、每轮最多 30s"的请求风暴收敛为"每分钟一次"。
  Duration get _tickerInterval {
    if (_consecutiveSyncFailures == 0) return _baseTickerInterval;
    final growth = 1 << _consecutiveSyncFailures.clamp(0, 5);
    final seconds = _baseTickerInterval.inSeconds * growth;
    return Duration(seconds: seconds.clamp(3, 60));
  }

  /// 按当前退避算出应有的周期，变了才重设 ticker。
  void _ensureTickerInterval() {
    if (!mounted) return;
    final want = _tickerInterval;
    if (_currentTickerInterval == want) return;
    _restartTicker(want);
  }

  /// 轮询触发：**上一轮没跑完就跳过本次**（离线时单轮可能耗 30s，若不跳过会
  /// 并发堆积大量请求，耗电/耗流量/刷日志——老板 2026-09-13 提出）。
  void _onTick() {
    if (_tickerRefreshInFlight) return;
    _tickerRefreshInFlight = true;
    _refresh().whenComplete(() {
      _tickerRefreshInFlight = false;
      _ensureTickerInterval();
    });
  }

  /// 刷新"还没确认"的消息数（离线提示用；COUNT 查询，开销可忽略）。
  Future<void> _loadUnsentCount() async {
    try {
      final n = await _repo.pendingCount;
      if (mounted && n != _unsentCount) setState(() => _unsentCount = n);
    } catch (_) {
      // 忽略：下次刷新再取
    }
  }

  /// 载入对方回执到渲染缓存（内容未变则不 setState，避免每次轮询都重建列表）。
  Future<void> _loadPeerReceipts() async {
    try {
      final rows = await _repo.peerReceipts();
      if (!mounted) return;
      final changed = rows.length != _peerReceipts.length ||
          Iterable.generate(rows.length).any((i) =>
              rows[i].partnerId != _peerReceipts[i].partnerId ||
              rows[i].deliveredUptoSeq != _peerReceipts[i].deliveredUptoSeq ||
              rows[i].readUptoSeq != _peerReceipts[i].readUptoSeq);
      if (changed) setState(() => _peerReceipts = rows);
    } catch (_) {
      // 读取失败忽略：下次刷新再载
    }
  }

  /// 取走当前引用目标并生成引用快照（同时收起输入栏引用条）。
  /// 文字/语音/图片/视频/音频/文件**所有发送路径共用**（老板要求 2026-09-13）：
  /// 只要引用条挂着，不论下一条新消息是什么类型，都一起提交并在气泡里呈现引用。
  Map<String, dynamic>? _takeQuoteSnapshot() {
    final quote = _quoteTarget;
    if (quote == null) return null;
    setState(() => _quoteTarget = null);
    return {
      'messageId': quote.env.messageId,
      'preview': _quotePreview(quote.plaintext),
      // 原消息类型：引用块据此把图片渲染成缩略图（老板要求 2026-09-13）
      'type': quote.env.type,
      // 语音/音频时长：引用块据此画波形 + 秒数（原消息未加载也能显示）
      if (quote.env.type == 'voice' || quote.env.type == 'audio')
        'seconds': _audioDurationSeconds(quote),
    };
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final quote = _takeQuoteSnapshot();
    _input.clear();
    try {
      await _repo.send(
        text,
        quote: quote,
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

  // ---------- 表情面板：输入栏内联展开，与键盘互斥 ----------

  /// 展开表情面板：先收键盘（二者互斥，否则面板被顶在键盘上方）。
  void _openEmojiPanel() {
    // 录音中/预览态（有未发送录音）不打断——面板只服务文字输入
    if (_inputMode == _InputMode.recording || _inputMode == _InputMode.preview) return;
    if (_inputMode == _InputMode.hint) setState(() => _inputMode = _InputMode.text);
    _inputFocusNode.unfocus();
    setState(() => _emojiPanelOpen = true);
  }

  /// 收起面板回到键盘（面板上的键盘键；点输入框走 _onInputFocusChanged 等价路径）。
  void _closeEmojiPanel() {
    if (!_emojiPanelOpen) return;
    setState(() => _emojiPanelOpen = false);
    _inputFocusNode.requestFocus();
  }

  /// 输入框重新获焦（键盘弹出）→ 自动收起面板。
  void _onInputFocusChanged() {
    if (_inputFocusNode.hasFocus && _emojiPanelOpen) {
      setState(() => _emojiPanelOpen = false);
    }
  }

  /// 在光标处插入文字（表情面板选中的 emoji）：面板展开时键盘收起、看不到光标，
  /// 仍按当前 selection 位置插入，插完光标后移一位，可连续点选。
  void _insertText(String insert) {
    final old = _input.text;
    final selection = _input.selection;
    // 从未聚焦过时 selection 无效（offset=-1）：插到末尾
    final start = selection.isValid ? selection.start.clamp(0, old.length) : old.length;
    final end = selection.isValid ? selection.end.clamp(0, old.length) : old.length;
    _setInputValue(old.replaceRange(start, end, insert), start + insert.length);
  }

  /// 退格：删光标前一个字符（emoji 多为 UTF-16 代理对，要整对删）；有选区时删选区。
  void _deleteBackward() {
    final old = _input.text;
    if (old.isEmpty) return;
    final selection = _input.selection;
    final end = selection.isValid ? selection.end.clamp(0, old.length) : old.length;
    if (end == 0) return;
    final start = (selection.isValid && !selection.isCollapsed)
        ? selection.start.clamp(0, old.length)
        : _charStartBefore(old, end);
    _setInputValue(old.replaceRange(start, end, ''), start);
  }

  void _setInputValue(String text, int caretOffset) {
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caretOffset),
    );
  }

  /// 下标 end 前一个字符的起始位置：代理对（emoji）占 2 个 code unit。
  int _charStartBefore(String text, int end) {
    if (end >= 2) {
      final high = text.codeUnitAt(end - 2);
      final low = text.codeUnitAt(end - 1);
      if (high >= 0xD800 && high <= 0xDBFF && low >= 0xDC00 && low <= 0xDFFF) return end - 2;
    }
    return end - 1;
  }

  /// 发送附件（语音/图片/视频/文件）：本地落库即回显，再刷新状态。
  Future<void> _sendAttachmentOptimistic({
    required Uint8List fileBytes,
    required String fileName,
    required String type,
    String? caption,
    Map<String, dynamic>? meta, // 附加数据（如音频时长），进密文载荷
  }) async {
    // 引用快照在此统一取走：语音/图片/视频/音频/文件全都带上（老板要求 2026-09-13），
    // 发完引用条即收起（此前只有文字发送会带，其他类型把引用条留在了输入框上方）
    final quote = _takeQuoteSnapshot();
    await _repo.sendAttachment(
      fileBytes: fileBytes,
      fileName: fileName,
      type: type,
      caption: caption,
      quote: quote,
      meta: meta,
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
            // 老板要求 2026-09-10）；底色与被引消息的引用块同款浅灰，代替原来
            // 的分隔横线（老板要求 2026-09-13）
            _buildMessagePreviewRow(m),
            // 操作项改为圆角方形卡片（图标 + 文字），不再是列表式 ListTile
            // （老板要求 2026-09-13）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: _buildActionCardGrid([
                _buildActionCard(
                  icon: Icons.format_quote,
                  label: l10n.chatPageActionQuote,
                  onTap: () => Navigator.of(ctx).pop('quote'),
                ),
                // 单条消息阅后即焚：可新设/调整档位、选「无限」取消（老板要求 2026-09-10）
                _buildActionCard(
                  icon: Icons.timer_outlined,
                  label: l10n.chatPageActionBurn,
                  onTap: () => Navigator.of(ctx).pop('burn'),
                ),
                _buildActionCard(
                  icon: Icons.delete_outline,
                  label: l10n.chatPageActionDelete,
                  destructive: true,
                  onTap: () => Navigator.of(ctx).pop('delete'),
                ),
              ]),
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

  /// 底部菜单操作项布局：圆角方形卡片，一行最多 4 个。总数不超过 4 个时等距
  /// 均匀铺开；超过 4 个时每行 4 个、向左对齐（老板要求 2026-09-13）。卡片宽度
  /// 以「一行 4 个」为基准计算并设上限，保证尺寸不随数量或屏幕宽度剧烈变化。
  /// 长按消息菜单与输入栏「+」附件菜单共用。
  Widget _buildActionCardGrid(List<Widget> cards) {
    const maxPerRow = 4;
    const spacing = 12.0;
    const maxCardWidth = 96.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fourColumnWidth =
            (constraints.maxWidth - spacing * (maxPerRow - 1)) / maxPerRow;
        final cardWidth =
            fourColumnWidth < maxCardWidth ? fourColumnWidth : maxCardWidth;
        final items = [
          for (final card in cards) SizedBox(width: cardWidth, child: card),
        ];
        if (cards.length <= maxPerRow) {
          // 不超过 4 个：等距分布、卡片等高分栏
          return IntrinsicHeight(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: items,
            ),
          );
        }
        // 超过 4 个：每行 4 个一组、向左对齐摆放
        final rows = <Widget>[];
        for (var i = 0; i < items.length; i += maxPerRow) {
          final chunk = items.sublist(
            i,
            i + maxPerRow > items.length ? items.length : i + maxPerRow,
          );
          rows.add(IntrinsicHeight(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var j = 0; j < chunk.length; j++) ...[
                  if (j > 0) const SizedBox(width: spacing),
                  chunk[j],
                ],
              ],
            ),
          ));
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: spacing),
              rows[i],
            ],
          ],
        );
      },
    );
  }

  /// 底部菜单的操作卡片：圆角方形，内含图标与文字；destructive 用红色标示
  /// 删除等不可逆操作。长按消息菜单与输入栏「+」附件菜单共用。
  Widget _buildActionCard({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool destructive = false,
  }) {
    final foreground = destructive ? Colors.red.shade400 : null;
    return Material(
      color: Colors.black.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 26, color: foreground),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 长按菜单顶部的消息预览行：发言人头像 + 按性别气泡风格的正文。
  /// 正文单行截断不溢出（老板要求 2026-09-10）；头像左右位置与消息流一致
  /// （我的在右、对方在左）；附件消息无正文时显示消息类型作占位。语音/音频文件
  /// 消息直接复用消息流的音频条（播放键 + 波形 + 时长，可点按播放/停止，
  /// 老板要求 2026-09-13）。
  /// Row 撑满整行并按消息流对齐（对方靠左、我的靠右）——此前 mainAxisSize.min
  /// 短消息整行收缩被弹窗居中，长消息撑满贴边，视觉效果不稳定（老板要求
  /// 2026-09-10 修复）。
  Widget _buildMessagePreviewRow(HistoryMessage m) {
    final mine = m.sender == 'me';
    final avatarPartnerId =
        m.env.senderPartnerId ?? _repo.partnerIdOfEntrance(m.env.senderEntranceId);
    final preview = m.plaintext.trim();
    // 音频类（语音/音频文件）与消息流一致：播放键 + 波形图 + 时长，可点按播放
    // （老板要求 2026-09-13）；文件消息显示文件图标 + 文件名（老板要求 2026-09-15）；
    // 其余类型沿用单行文本（空正文显示类型占位）。
    final Widget bubbleContent;
    switch (m.env.type) {
      case 'voice':
      case 'audio':
        bubbleContent = _buildAudioBar(m, waveformWidth: 88);
        break;
      case 'image':
        bubbleContent = _buildImageThumb(m, size: 48);
        break;
      case 'video':
        bubbleContent = _buildVideoThumb(m, size: 48);
        break;
      case 'file':
        // 附件消息明文自带 📎 前缀（发送端兜底文案）；预览行已有文件图标，去掉
        var fileName = preview;
        if (fileName.startsWith('📎')) fileName = fileName.replaceFirst('📎', '').trim();
        bubbleContent = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file, size: 20,
                color: _uiStyle == 'gradient' ? Colors.white : null),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                fileName.isEmpty ? m.env.type : fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
        break;
      default:
        bubbleContent = Text(
          preview.isEmpty ? m.env.type : preview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          // 预览条背景色已清空（老板 2026-09-15 试用效果：去掉浅灰底，只留气泡本身）。
          // 弹窗始终跟随浅色主题，不随 gradient 气泡风格变白。
          color: Colors.transparent,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            key: const ValueKey('messagePreviewRow'), // 测试断言对齐用（项目惯例）
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment:
                mine ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              if (!mine) ...[
                _MessageAvatar(
                    partnerId: avatarPartnerId, server: effectiveServer, api: widget.api),
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
                    child: bubbleContent,
                  ),
                ),
              ),
              if (mine) ...[
                const SizedBox(width: 8),
                _MessageAvatar(
                    partnerId: avatarPartnerId, server: effectiveServer, api: widget.api),
              ],
            ],
          ),
        ),
        // 预览条底部的淡灰分隔线（老板 2026-09-15：底色清空后用线与菜单项分层）
        const Divider(height: 1, thickness: 0.5, color: Color(0x14000000)),
      ],
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
        meta: m.meta,
      );

  /// 删除消息：确认弹窗 → 本机打墓碑标记（内容隐藏、时间+焚毁记录保留；
  /// 对方通道不受影响；重启后记录仍在、内容仍隐藏）。
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
    await MediaCache.deleteFor(widget.spaceId, m.env.messageId); // 定点删媒体解密缓存
    unawaited(AttachmentStore.deleteFor(widget.spaceId, m.env.messageId)); // 留存明文同样删
    if (!mounted) return;
    setState(() {
      _messages = [
        for (final x in _messages)
          if (x.env.messageId == m.env.messageId) _asDeleted(x) else x,
      ];
    });
  }

  /// 引用预览截断（60 字内）。
  ///
  /// 附件消息明文自带 📎 前缀（发送端的兜底文案），引用条里已有缩略图，别针图标
  /// 重复且多余——去掉（老板要求 2026-09-13）。
  String _quotePreview(String text) {
    var t = text.trim();
    if (t.startsWith('📎')) t = t.replaceFirst('📎', '').trim();
    return t.length > 60 ? '${t.substring(0, 60)}…' : t;
  }

  /// 已加载消息里按 messageId 找原消息（引用块显示缩略图用）；未加载到返回 null
  /// ——此时引用块退回文字预览，点它跳转会把原消息补载进来（补载后自动变缩略图）。
  HistoryMessage? _messageById(String messageId) {
    if (messageId.isEmpty) return null;
    final index = _messages.indexWhere((x) => x.env.messageId == messageId);
    return index < 0 ? null : _messages[index];
  }

  /// 语音/音频引用的只读外观：**波形图 + 秒数**（不带播放键——引用条/引用块只做
  /// 展示）。波形与消息流气泡同源（seed=messageId，形状一致）、时长未知时不显示
  /// 秒数，与气泡规则相同（老板要求 2026-09-13：录音消息到处一个样）。
  Widget _buildVoiceQuoteRow({
    required String messageId,
    required int seconds,
    required bool isVoice,
    required Color color,
    double waveformWidth = 96,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _VoiceWaveform(
          playing: false,
          durationSeconds: seconds,
          seed: messageId,
          activeColor: color,
          inactiveColor: color.withValues(alpha: 0.4),
          width: waveformWidth,
        ),
        if (seconds > 0) ...[
          const SizedBox(width: 6),
          Text(
            isVoice ? _formatVoiceDuration(seconds) : _formatHmsDuration(seconds),
            style: TextStyle(fontSize: 12, color: color),
          ),
        ],
      ],
    );
  }

  /// 引用块内容：原消息是图片/视频就显示它的缩略图（视频取首帧 + 播放三角，
  /// 老板要求 2026-09-15）、是语音/音频就显示波形图 + 秒数（老板要求
  /// 2026-09-13）、是文件就显示文件图标 + 文件名（老板要求 2026-09-15），
  /// 其余（含原消息尚未加载/无附件）沿用文字预览。
  Widget _buildQuoteBlockContent(Map<String, dynamic> quote) {
    final type = quote['type'] as String?;
    if (type == 'image') {
      final quoted = _messageById(quote['messageId'] as String? ?? '');
      if (quoted != null) return _buildImageThumb(quoted, size: 40);
    }
    if (type == 'video') {
      final quoted = _messageById(quote['messageId'] as String? ?? '');
      if (quoted != null) return _buildVideoThumb(quoted, size: 40);
    }
    if (type == 'file') {
      // 原消息已加载 → 用消息流同款文件名片（图标 + 名字/尺寸）；未加载时退回
      // preview 文本（剥 📎 前缀）+ 文件图标——引用快照的 preview 就是文件名
      var fileName = _quotePreview(quote['preview'] as String? ?? '');
      if (fileName.startsWith('📎')) fileName = fileName.replaceFirst('📎', '').trim();
      final quoted = _messageById(quote['messageId'] as String? ?? '');
      if (quoted != null) return _buildFileCard(quoted);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file, size: 16,
              color: _uiStyle == 'gradient' ? Colors.white70 : Colors.grey.shade700),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              fileName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  color: _uiStyle == 'gradient' ? Colors.white70 : Colors.grey.shade700),
            ),
          ),
        ],
      );
    }
    if (type == 'voice' || type == 'audio') {
      final seconds =
          (quote['seconds'] is num) ? (quote['seconds'] as num).round() : 0;
      return _buildVoiceQuoteRow(
        messageId: quote['messageId'] as String? ?? '',
        seconds: seconds,
        isVoice: type == 'voice',
        color: _uiStyle == 'gradient'
            ? Colors.white70
            : Theme.of(context).colorScheme.primary,
      );
    }
    return Text(
      _quotePreview(quote['preview'] as String? ?? ''),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
          fontSize: 12,
          color: _uiStyle == 'gradient' ? Colors.white70 : Colors.grey.shade700),
    );
  }

  /// 输入栏引用条：被引用消息预览 + 取消按钮。
  ///
  /// 配色**两种界面主题一致**（老板 2026-09-14）：此前 gradient 下用「白 12% 底 +
  /// white70 字/图标」，而 gradient 的输入栏本身就是 85% 白悬浮条——白底上的淡白
  /// 字几乎看不见。改为与素雅纯色同款：黑 6% 半透明底 + 灰字/灰图标（顺带与气泡里
  /// 的引用框保持同一族颜色）；蓝色左边缘也已在 2026-09-13 去掉。
  Widget _buildQuoteBanner(HistoryMessage quote) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        // 与气泡引用框同色（_buildQuoteBlockContent 所在的引用块）
        color: Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          // 引用图片/视频时显示原附件缩略图（否则双引号图标）——与发送后的
          // 引用块一致（视频显示首帧 + 播放三角，老板要求 2026-09-15）
          quote.env.type == 'image'
              ? _buildImageThumb(quote, size: 24)
              : quote.env.type == 'video'
                  ? _buildVideoThumb(quote, size: 24)
                  : const Icon(Icons.format_quote, size: 14, color: Colors.grey),
          const SizedBox(width: 6),
          // 语音/音频：波形图 + 秒数（与气泡/发送后的引用块一致，不再显示「语音」
          // 这类文字——老板要求 2026-09-13）
          if (quote.env.type == 'voice' || quote.env.type == 'audio') ...[
            _buildVoiceQuoteRow(
              messageId: quote.env.messageId,
              seconds: _audioDurationSeconds(quote),
              isVoice: quote.env.type == 'voice',
              color: Theme.of(context).colorScheme.primary,
            ),
            const Spacer(), // 取消按钮仍靠右（与文字引用时一致）
          ] else
            Expanded(
              child: Text(
                // 双引号图标已足够表达引用，不再加「引用：」前缀（老板要求 2026-09-09）
                _quotePreview(quote.plaintext),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ),
          InkWell(
            onTap: () => setState(() => _quoteTarget = null),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close, size: 16, color: Colors.grey),
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
      // 键盘键=放弃录音回文字输入（与发送键一致）；X 键才回录音等待态
      unawaited(_cancelVoice(backToTextInput: true));
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
    // 预览态（刚录完、波形已冻结）不再开录：此时长按波形图/录音条什么也不做，
    // 避免误触从头重录、冲掉刚录好的那条。只有前面的播放键和后面的 X 可点；
    // 点 X（_cancelVoice）回到等待录音的提示态，就又能长按开录了
    // （老板要求 2026-09-13）。
    if (_inputMode == _InputMode.recording || _inputMode == _InputMode.preview) {
      return;
    }
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
      if (_audioStartedMessageId != null) _audioStartedMessageId = null;
      await _player?.stop();
      final recorder = (_recorder ??= AudioRecorder());
      // 安卓端 start() 不会自动申请 RECORD_AUDIO 运行时权限（manifest 静态声明
      // 不够，Android 6.0+ 需动态授权），必须先 hasPermission() 显式申请，
      // 否则无权限设备上 AudioRecord 初始化失败：要么 start 抛错（无波形），
      // 要么读到全零数据（波形极小、文件 0 字节发不出）。
      if (!await recorder.hasPermission()) {
        if (!mounted) return;
        showTopNotice(context, AppLocalizations.of(context)!.chatPageVoicePermissionDenied);
        return;
      }
      final path = '${Directory.systemTemp.path}/einz_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await recorder.start(const RecordConfig(), path: path);
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
      // 空录音（权限被系统拒后仍可能走到这里）不再静默回文字态，给明确反馈
      if (!ok) showTopNotice(context, AppLocalizations.of(context)!.chatPageVoiceEmpty);
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
    // 语音说明只留标签（老板 2026-09-11）；时长改走载荷 meta 同步给对端
    // （老板 2026-09-13），明文不再塞时长。须在 await 前取好（避免 async gap 用 context）
    final caption = AppLocalizations.of(context)!.chatPageVoiceLabel;
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
        meta: {kMetaAudioDurationSeconds: _recordSeconds},
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

  /// 预览态取消：删临时文件。默认回到**等待录音的提示态**（再长按即可重录，
  /// 老板要求 2026-09-13）；[backToTextInput]=true 时回文字输入框（点键盘键/发送）。
  Future<void> _cancelVoice({bool backToTextInput = false}) async {
    if (_inputMode != _InputMode.preview) return;
    final path = _recordingPath;
    _previewPlaying = false;
    await _player?.stop();
    if (!mounted) return;
    setState(() {
      _inputMode = backToTextInput ? _InputMode.text : _InputMode.hint;
      _recordingPath = null;
      _recordSeconds = 0; // 提示态是干净的起点，不该留着上一次的秒数
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
    // 录音上限 60s：左侧直接数秒（00 → 60），不必写成分秒（老板要求 2026-09-13）
    final elapsed = _recordSeconds.toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: recording ? Colors.green.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: recording ? Colors.green.shade200 : Colors.grey.shade300),
      ),
      child: recording
          ? Row(
              children: [
                Text(elapsed,
                    style: const TextStyle(
                        color: Colors.green, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 10),
                Expanded(
                    child: _WaveformBars(
                        samples: _voiceLastSamples(40), color: Colors.green)),
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
                      child: LayoutBuilder(builder: (context, constraints) {
                        // 试听：波形按进度从左往右高亮（与气泡里的语音波形一致，
                        // 老板要求 2026-09-13）——用本次真实振幅采样，宽度撑满可用区
                        return _VoiceWaveform(
                          playing: _previewPlaying,
                          durationSeconds: _recordSeconds,
                          samples: _voiceSamples,
                          width: constraints.maxWidth,
                          activeColor: Theme.of(context).colorScheme.primary,
                          inactiveColor: Colors.grey.shade400,
                        );
                      }),
                    ),
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
      _updateAudioPlayback(() {
        _playingMessageId = null;
        _audioStartedMessageId = null;
      });
      return;
    }
    try {
      final player = _player ??= AudioPlayer();
      _previewPlaying = false; // 与预览态试听互斥
      _updateAudioPlayback(() {
        _playingMessageId = m.env.messageId;
        _audioStartedMessageId = null; // 旧波形进度先复位
      });
      final ext = m.env.type == 'voice' ? 'm4a' : _extOf(m.plaintext);
      // 与图片/视频一致走 [_attachmentBytes]：发送端优先用**本地密文**解密——
      // 上传还在传（没拿到 server_sequence）时文件本来就在本机，点了就该能播
      // （老板 2026-09-15）；此前这里直连 fetchAttachment 走网络 → 落"音频播放失败"
      Future<Uint8List> load() => _attachmentBytes(m);
      // 解密落盘：确定性路径按 messageId 复用——重复播放不再重复下载解密
      // stored 模式放长期目录（跨会话保留），否则临时缓存（系统可清）
      final tmp = (_storeAttachments
              ? await AttachmentStore.ensure(widget.spaceId, m.env.messageId, ext, load)
              : null) ??
          await MediaCache.ensure(widget.spaceId, m.env.messageId, ext, load);
      await player.stop();
      await player.play(DeviceFileSource(tmp.path));
      // 真正出声才开始走波形进度（此前是下载解密等待期）
      _updateAudioPlayback(() => _audioStartedMessageId = m.env.messageId);
      // 音频文件：顺手记下播放器给的真实时长（老消息/探测失败的兜底显示）
      if (m.env.type != 'voice') {
        final total = await player.getDuration();
        final seconds = total?.inSeconds ?? 0;
        if (seconds > 0) {
          _updateAudioPlayback(() => _audioFileDurations[m.env.messageId] = seconds);
        }
      }
      player.onPlayerComplete.first.then((_) {
        _updateAudioPlayback(() {
          _playingMessageId = null;
          _audioStartedMessageId = null;
        });
      }).catchError((_) {});
    } catch (e) {
      if (!mounted) return;
      _updateAudioPlayback(() {
        _playingMessageId = null;
        _audioStartedMessageId = null;
      });
      showTopNotice(context, AppLocalizations.of(context)!.chatPageAudioPlayFailed('$e'));
    }
  }

  /// 音频播放状态变更：setState 刷新本页（消息流气泡）+ 版本号 +1 通知跨路由
  /// 监听者（长按菜单预览行）。已 dispose 则只留字段值，不触发重建。
  void _updateAudioPlayback(void Function() update) {
    update();
    if (!mounted) return;
    setState(() {});
    _audioPlaybackVersion.value++;
  }

  // ---------- 图像/视频/音频/文件：选择 → 加密上传 → 发送 ----------

  Future<void> _showAttachmentSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final kind = await showModalBottomSheet<_AttachmentKind>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _buildActionCardGrid([
            // 拍照/拍摄仅移动端有（桌面无相机采集，见 [_hasCameraCapture]）
            if (_hasCameraCapture) ...[
              _buildActionCard(
                icon: Icons.photo_camera,
                label: l10n.chatPageAttachPhoto,
                onTap: () => Navigator.of(ctx).pop(_AttachmentKind.photo),
              ),
            ],
            _buildActionCard(
              icon: Icons.photo_library,
              label: l10n.chatPageAttachGalleryImage,
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.galleryImage),
            ),
            if (_hasCameraCapture) ...[
              _buildActionCard(
                icon: Icons.videocam,
                label: l10n.chatPageAttachVideoCamera,
                onTap: () => Navigator.of(ctx).pop(_AttachmentKind.videoCamera),
              ),
            ],
            _buildActionCard(
              icon: Icons.movie,
              label: l10n.chatPageAttachVideoGallery,
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.videoGallery),
            ),
            _buildActionCard(
              icon: Icons.music_note,
              label: l10n.chatPageAttachAudioFile,
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.audioFile),
            ),
            _buildActionCard(
              icon: Icons.insert_drive_file,
              label: l10n.chatPageAttachAnyFile,
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.anyFile),
            ),
            // 表情符放最后（老板 2026-09-15）：附件优先，表情不是附件
            _buildActionCard(
              icon: Icons.emoji_emotions_outlined,
              label: l10n.chatPageAttachEmoji,
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.emoji),
            ),
          ]),
        ),
      ),
    );
    if (kind == null) return;
    if (kind == _AttachmentKind.emoji) {
      _openEmojiPanel(); // 不发附件：只展开输入栏表情面板
      return;
    }
    await _sendMedia(kind);
  }

  Future<void> _sendMedia(_AttachmentKind kind) async {
    try {
      final XFile? image;
      String? fileName;
      String? type;
      switch (kind) {
        case _AttachmentKind.emoji:
          return; // 已在 _showAttachmentSheet 中分流（展开表情面板），不走上传
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
          // 发送前读一遍时长（audioplayers 设源取总时长，不播放），放进载荷
          // meta 随消息同步，对端开箱即显示（老板要求 2026-09-13）；读不到就不带
          final audioSeconds = await _probeAudioDuration(audioBytes);
          await _sendAttachmentOptimistic(
            fileBytes: audioBytes,
            fileName: audioName,
            type: 'audio',
            caption: audioName,
            meta: audioSeconds > 0 ? {kMetaAudioDurationSeconds: audioSeconds} : null,
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
    return FutureBuilder<Uint8List>(
      future: _videoBytes(m),
      builder: (context, snap) {
        if (snap.hasData) {
          return _VideoPreview(
              bytes: snap.data!, spaceId: widget.spaceId, messageId: m.env.messageId);
        }
        if (snap.hasError) {
          return GestureDetector(
            onTap: () => _retryAttachment(m),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.download_outlined, size: 16),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    AppLocalizations.of(context)!.chatPageAttachmentTapToDownload,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        }
        return const SizedBox(
            width: 60, height: 60, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
      },
    );
  }

  /// 视频明文（同 [_imageBytes]）：按 messageId 缓存 future，内联预览与首帧
  /// 缩略图共用同一次解密。
  Future<Uint8List> _videoBytes(HistoryMessage m) =>
      _videoCache.putIfAbsent(m.env.messageId, () => _attachmentBytes(m));

  /// 视频首帧缩略图（JPEG，长边 128）：复用内联预览的解密缓存文件（同一条消息
  /// 只解密、只落盘一次）→ 原生取帧；按 messageId 缓存（老板要求 2026-09-15：
  /// 长按菜单/引用条/引用块里视频也显示缩略图，而不是别针 + 文件名）。
  Future<Uint8List> _videoThumbBytes(HistoryMessage m) =>
      _videoThumbCache.putIfAbsent(m.env.messageId, () async {
        final file =
            await MediaCache.ensure(widget.spaceId, m.env.messageId, 'mp4', () => _videoBytes(m));
        final thumb = await VideoThumbnail.thumbnailData(
          video: file.path,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 128,
          quality: 75,
        );
        if (thumb == null) throw StateError('视频缩略图取帧失败');
        return thumb;
      });

  /// 附件明文：发送端优先本地密文解密（上传完成前/失败后也能即时显示），
  /// 无本地密文（接收端）走服务端拉取。
  Future<Uint8List> _attachmentBytes(HistoryMessage m) async {
    final att = m.attachment;
    if (att == null) throw StateError('附件元数据缺失');
    // stored 模式：本机留存的明文优先（零网络、零解密），拿到即返回
    final stored = await _storedFile(m);
    if (stored != null) return stored.readAsBytes();
    final bytes = await _repo.attachmentBytes(att);
    if (_storeAttachments) {
      // 顺手落长期目录（下次打开消息流直接命中）
      unawaited(AttachmentStore.ensure(
          widget.spaceId, m.env.messageId, _attachmentExtOf(m), () async => bytes));
    }
    return bytes;
  }

  /// 是否"留存"模式（附件明文长期留在本机）。
  bool get _storeAttachments => _attachmentStorage == 'stored';

  /// 附件在长期目录里的扩展名（语音固定 m4a，其余按正文后缀）。
  String _attachmentExtOf(HistoryMessage m) =>
      m.env.type == 'voice' ? 'm4a' : _extOf(m.plaintext);

  /// 本机留存的明文副本（stored 模式且文件仍在）→ 直接读；否则 null。
  Future<File?> _storedFile(HistoryMessage m) async {
    if (!_storeAttachments) return null;
    final f = await AttachmentStore.pathFor(widget.spaceId, m.env.messageId, _attachmentExtOf(m));
    if (f == null || !await f.exists()) return null;
    return f;
  }

  /// 重新下载某条附件（清掉缓存 future → 下次渲染重新拉取）。
  void _retryAttachment(HistoryMessage m) {
    _imageCache.remove(m.env.messageId);
    _videoCache.remove(m.env.messageId);
    _videoThumbCache.remove(m.env.messageId);
    setState(() {});
  }

  /// stored 模式：新到附件的明文**收到即落盘**（消息流里点开就能看，不用等下载）。
  /// 已有的跳过；失败静默——不打扰，用户点消息还能重新下载。
  Future<void> _autoStoreAttachments(List<HistoryMessage> msgs) async {
    if (!_storeAttachments) return;
    for (final m in msgs) {
      try {
        await _attachmentBytes(m);
      } catch (_) {
        // 单个失败不影响其它（网络抖动/元数据未就绪）
      }
    }
  }

  /// 图片明文（发送端本地密文解密 / 接收端服务端拉取）：按 messageId 缓存 future，
  /// 气泡、长按菜单预览行、引用块缩略图共用同一次加载。
  Future<Uint8List> _imageBytes(
      HistoryMessage m) =>
      _imageCache.putIfAbsent(m.env.messageId, () => _attachmentBytes(m));

  /// 图片消息：本地密文（发送端即时显示/上传失败兜底）或服务端拉取 →
  /// 缩略展示；点击全屏查看。
  Widget _buildImage(
      HistoryMessage m) {
    final att = m.attachment;
    if (att == null) return Text('📷 ${m.plaintext}');
    return FutureBuilder<Uint8List>(
      future: _imageBytes(m),
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
          return GestureDetector(
            onTap: () => _retryAttachment(m),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.download_outlined, size: 16),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    AppLocalizations.of(context)!.chatPageAttachmentTapToDownload,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        }
        return const SizedBox(width: 60, height: 60, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
      },
    );
  }

  /// 全屏查看图片（品牌粉蓝渐变大图 + 双指缩放 + 右上角关闭，与头像全屏一致）。
  /// useSafeArea:false + 直角 shape：背景铺满整屏，不留圆角和上下安全区空隙。
  /// 背景 = kBrandGradient（老板 2026-09-15：全屏查看用首屏同款渐变，更有品牌感）。
  Future<void> _showFullImage(Uint8List bytes) async {
    await withImmersiveFullscreen(() => showDialog<void>(
          context: context,
          barrierDismissible: true,
          useSafeArea: false,
          builder: (ctx) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            // SizedBox.expand：渐变底严格铺满整屏（含状态栏与刘海区域）
            child: SizedBox.expand(
              child: DecoratedBox(
                decoration: const BoxDecoration(gradient: kBrandGradient),
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
                      // SafeArea：万一系统栏没隐藏（某平台不支持），关闭键也不会被压在下面
                      child: SafeArea(
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ));
  }

  /// 小尺寸图片缩略图（长按菜单预览行 / 引用块 / 输入栏引用条用）：正方形 cover
  /// 裁剪；加载中转圈，失败（无附件/解密失败）显示破图标占位。
  /// 老板要求 2026-09-13：引用与长按菜单里看缩略图，而不是文件名。
  Widget _buildImageThumb(
      HistoryMessage m, {double size = 40}) {
    return FutureBuilder<Uint8List>(
      future: _imageBytes(m),
      builder: (context, snap) {
        if (snap.hasData) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(snap.data!,
                width: size, height: size, fit: BoxFit.cover),
          );
        }
        return Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(6),
          ),
          child: snap.hasError
              ? Icon(Icons.broken_image_outlined,
                  size: size * 0.5, color: Colors.grey)
              : SizedBox(
                  width: size * 0.45,
                  height: size * 0.45,
                  child: const CircularProgressIndicator(strokeWidth: 2)),
        );
      },
    );
  }

  /// 小尺寸视频缩略图（长按菜单预览行 / 引用块 / 输入栏引用条用）：首帧 + 播放
  /// 三角，正方形 cover 裁剪；加载中转圈，失败（无附件/解密失败/平台无取帧能力）
  /// 显示摄像机占位（老板要求 2026-09-15）。
  Widget _buildVideoThumb(HistoryMessage m, {double size = 40}) {
    return FutureBuilder<Uint8List>(
      future: _videoThumbBytes(m),
      builder: (context, snap) {
        if (snap.hasData) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Image.memory(snap.data!,
                    width: size, height: size, fit: BoxFit.cover),
                Icon(Icons.play_circle_fill,
                    size: size * 0.5, color: Colors.white70),
              ],
            ),
          );
        }
        return Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(6),
          ),
          child: snap.hasError
              ? Icon(Icons.videocam_outlined, size: size * 0.5, color: Colors.grey)
              : SizedBox(
                  width: size * 0.45,
                  height: size * 0.45,
                  child: const CircularProgressIndicator(strokeWidth: 2)),
        );
      },
    );
  }

  /// 消息气泡底色：按发言人性别——男天蓝 / 女品牌粉（浅色 tint 便于阅读）；
  /// 性别未登记（旧配置）回退原默认色（本人 indigo.shade100 / 对方 grey.shade200）。
  /// gradient 风格改用深色气泡（男深蓝 #2271F7 / 女深粉 #B83D80，白字醒目——
  /// 浅 tint 在渐变背景上区分度不足，老板要求 2026-09-09）。
  /// 两人同性别时第二个人（slot=1）取青色（2026-09-17 老板要求）——
  /// 槽位未知（老服务端/未拉取）或性别不同/未登记时不启用。
  Color _bubbleColor({required bool mine}) {
    final gender = mine ? _myGender : _peerGender;
    final slot = mine ? _mySlot : _peerSlot;
    final otherSlot = mine ? _peerSlot : _mySlot;
    final bothGendersKnown =
        (_myGender == 'male' || _myGender == 'female') &&
        (_peerGender == 'male' || _peerGender == 'female');
    final sameGenderSecond = bothGendersKnown &&
        _myGender == _peerGender &&
        slot != null &&
        otherSlot != null &&
        slot != otherSlot &&
        slot == 1;
    if (_uiStyle == 'gradient') {
      if (sameGenderSecond) return const Color(0xFF00838F); // 深青（同性别第二人）
      if (gender == 'female') return const Color(0xFFB83D80); // 深粉（品牌粉加深）
      if (gender == 'male') return const Color(0xFF2271F7); // 品牌深蓝
      return mine ? const Color(0xFF2271F7) : const Color(0xFF64748B); // 性别未登记
    }
    if (sameGenderSecond) return const Color(0xFF26C6DA).withValues(alpha: 0.22); // 青色 tint
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

  /// 音频气泡：语音（录音）=播放键 + 固定波形图 + 秒数（25s）；音频文件=播放键
  /// + 文件名 + h/m/s 时长（零的部分省略）。点击下载解密后播放
  /// （老板要求 2026-09-13）。
  ///
  /// 消息流气泡与长按菜单预览行共用（后者 [waveformWidth] 小一点，避免挤爆
  /// 弹窗）：外层监听播放状态版本，菜单在独立路由、页面 setState 重建不到它。
  Widget _buildAudioBar(
      HistoryMessage m, {double waveformWidth = 120}) {
    return ValueListenableBuilder<int>(
      valueListenable: _audioPlaybackVersion,
      builder: (context, _, child) =>
          _buildAudioBarBody(m, waveformWidth: waveformWidth),
    );
  }

  Widget _buildAudioBarBody(
      HistoryMessage m, {required double waveformWidth}) {
    final playing = _playingMessageId == m.env.messageId;
    final onBubble = _uiStyle == 'gradient'
        ? Colors.white
        : Theme.of(context).colorScheme.primary; // 气泡上的前景色（波形/图标）
    if (m.env.type != 'voice') {
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
                  : '🎵 ${m.plaintext}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_audioDurationSeconds(m) > 0) ...[
            const SizedBox(width: 6),
            Text(_formatHmsDuration(_audioDurationSeconds(m)),
                style: const TextStyle(fontSize: 12)),
          ],
        ],
      );
    }
    final seconds = _audioDurationSeconds(m);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(playing ? Icons.stop_circle : Icons.play_circle),
          onPressed: () => _playAudioMessage(m),
          visualDensity: VisualDensity.compact,
        ),
        // 固定波形图：形状由 messageId 决定（同一条消息每次渲染一致），
        // 播放时已播部分染高亮色 + 竖线从左往右走，走完复原。
        _VoiceWaveform(
          playing: _audioStartedMessageId == m.env.messageId,
          durationSeconds: seconds,
          seed: m.env.messageId,
          width: waveformWidth,
          activeColor: onBubble,
          inactiveColor: onBubble.withValues(alpha: 0.4),
        ),
        // 时长未知时不显示任何文字（播放键 + 波形已足够表达"这是录音"，
        // 老板要求 2026-09-13）
        if (seconds > 0) ...[
          const SizedBox(width: 6),
          Text(_formatVoiceDuration(seconds), style: const TextStyle(fontSize: 12)),
        ],
      ],
    );
  }

  /// 录音时长：只用秒（25s；录音上限 60s，老板要求 2026-09-13）。
  String _formatVoiceDuration(int totalSeconds) => '${totalSeconds}s';

  /// 音频文件时长：h/m/s，为零的部分不显示（如 3s、1m 15s、2h 5s）。
  String _formatHmsDuration(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final parts = <String>[
      if (hours > 0) '${hours}h',
      if (minutes > 0) '${minutes}m',
      if (seconds > 0) '${seconds}s',
    ];
    return parts.isEmpty ? '0s' : parts.join(' ');
  }

  /// 音频（语音/音频文件）时长秒数：以载荷 meta（老板 2026-09-13）为准；发送端
  /// 探测失败时退而用播放器给的真实值（内存缓存，播放一次后才有）。
  /// 产品未上线，不兼容老数据——取不到就是 0，气泡不显示时长。
  int _audioDurationSeconds(HistoryMessage m) {
    final fromMeta = m.meta?[kMetaAudioDurationSeconds];
    if (fromMeta is int) return fromMeta;
    if (fromMeta is num) return fromMeta.round();
    return _audioFileDurations[m.env.messageId] ?? 0;
  }

  /// 读本地音频文件的总时长（audioplayers 设源后取时长，不播放）；失败返回 0。
  Future<int> _probeAudioDuration(Uint8List bytes) async {
    final player = AudioPlayer();
    try {
      await player.setSource(BytesSource(bytes));
      return (await player.getDuration())?.inSeconds ?? 0;
    } catch (_) {
      return 0;
    } finally {
      await player.dispose().catchError((_) => player);
    }
  }


  /// 文件消息：文件图标 + 文件信息（上=文件名、下=尺寸）。整块正文可点按
  /// （含文件图标），触摸即下载/打开（本机有留存副本则直接用系统应用打开；
  /// 老板 2026-09-15：实测点文件名就能打开，下载图标不必要，删掉）。
  Widget _buildFileCard(
      HistoryMessage m) {
    final size = (m.attachment?['size'] as int?) ?? 0;
    final subtitleColor = _uiStyle == 'gradient' ? Colors.white70 : Colors.grey;
    // 附件消息明文是「📎 文件名」（发送端兜底文案）；名片里已有文件图标，前缀去掉
    var name = m.plaintext.trim();
    if (name.startsWith('📎')) name = name.replaceFirst('📎', '').trim();
    return GestureDetector(
      onTap: () => _downloadFile(m),
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file, size: 30),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name, overflow: TextOverflow.ellipsis),
                Text(_formatSize(size),
                    style: TextStyle(fontSize: 11, color: subtitleColor)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  /// 文件附件：留存模式下**本机已有就直接打开**（零网络），否则下载后打开。
  /// secured 模式下沿用原来的"下载保存到应用文档目录 + 提示路径"。
  Future<void> _downloadFile(
      HistoryMessage m) async {
    final l10n = AppLocalizations.of(context)!;
    final att = m.attachment;
    if (att == null) {
      if (!mounted) return;
      showTopNotice(context, l10n.chatPageAttachmentMetaMissing);
      return;
    }
    // 留存副本还在 → 直接交给系统应用打开
    final stored = await _storedFile(m);
    if (stored != null) {
      await _openFileWith(stored.path);
      return;
    }
    try {
      final bytes = await _repo.fetchAttachment(
        attachmentId: att['attachment_id'] as String,
        keyVersion: att['key_version'] as int,
        nonce: base64Decode(att['nonce'] as String),
      );
      if (_storeAttachments) {
        final file = await AttachmentStore.ensure(
            widget.spaceId, m.env.messageId, _attachmentExtOf(m), () async => bytes);
        if (file != null) {
          await _openFileWith(file.path);
          return;
        }
      }
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${m.plaintext}');
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      showTopNotice(context, l10n.chatPageSaved(file.path));
    } catch (e) {
      if (!mounted) return;
      showTopNotice(context, l10n.chatPageDownloadFailed('$e'));
    }
  }

  /// 用系统应用打开本地文件（iOS 走预览/分享，Android 走 FileProvider）。
  Future<void> _openFileWith(String path) async {
    final res = await OpenFilex.open(path);
    if (!mounted) return;
    if (res.type != ResultType.done) {
      showTopNotice(context, AppLocalizations.of(context)!.chatPageFileOpenFailed(res.message));
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
          // 锁屏（老板要求 2026-09-16）：一键立即锁屏，放在下拉菜单图标左侧。
          // 仅在已设置锁屏码时出现——没设 PIN 时锁屏不激活（LockPage 只会显示
          // "尚未设置锁屏码"提示页），摆一个按了没用的按钮反而误导。
          if (_hasPin)
            IconButton(
              icon: const Icon(Icons.lock_outline),
              tooltip: l10n.chatPageLockNow,
              onPressed: _lockNow,
            ),
          // 顶栏统一入口：语言/阅后即焚/开通码/本机 PIN（显示各功能当前值）
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu),
            tooltip: l10n.chatPageMenuMore,
            onSelected: (value) {
              switch (value) {
                case 'locale':
                  _menuAction(_showLocalePicker);
                case 'style':
                  _menuAction(_showStylePicker);
                case 'storage':
                  _menuAction(_showAttachmentStoragePicker);
                case 'burn':
                  _menuAction(_showBurnPicker);
                case 'invite':
                  _menuAction(_showInviteDialog);
                case 'advanced':
                  _menuAction(_showAdvancedSheet);
                case 'pin':
                  _menuAction(_showSetLockDialog);
                case 'about':
                  _menuAction(_openAboutPage);
                case 'name':
                  _menuAction(() => _showRenameDialog(renameEntrance: false));
                case 'avatar':
                  _menuAction(_showAvatarUpload);
                case 'devname':
                  _menuAction(() => _showRenameDialog(renameEntrance: true));
                case 'switchspace':
                  _menuAction(_openSpacePicker);
                case 'exit':
                  _menuAction(_showExitAppDialog);
              }
            },
            itemBuilder: (context) {
              // 语言当前值：取实际生效 locale 的语言码 → 中文/English 名
              final langCode = Localizations.localeOf(context).languageCode;
              // 行内左侧标签用稍淡色，与右侧当前值文字（默认 onSurface 深色）区分
              // 左侧标签 = **备注级**（淡色小字，不抢戏）；右侧"当前值" = 深色大字（老板 2026-09-23 定：
              // 左侧相当于备注，不用强调，右侧才是用户要看的东西 ✓）。
              // 显式钉死 13，与 captionStyle 一致——否则没写 fontSize 会落到平台默认
              // （macOS 偏大），同一菜单里纯标签行（头像/生成开通码/高级安全/关于/切换/退出）
              // 会比带值的行（我的身份/语言/主题/通道名称/阅后即焚/附件/锁屏码）显大一号
              final labelStyle = TextStyle(
                  fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant);
              final captionStyle = TextStyle(
                  fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant);
              final valueStyle = TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w500);
              return [
                // 菜单分组（老板 2026-09-22 定；2026-09-24 语言/界面主题并入①组）：
                //   ①「我」：我的身份 / 我的头像 / 语言 / 界面主题（关于"我这个人"）
                //   ②「本通道」：通道名称 / 生成开通码（关于"本机在这个秘境里的通道"）
                //   ③ 安全：阅后即焚 / 附件存储 / 锁屏码 / 高级安全
                //   ④ 结尾：关于秘境 / 切换秘境 / 退出本应用
                PopupMenuItem(
                  height: kMenuRowHeight,
                  value: 'name',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuMyNameLabel, style: captionStyle),
                      const Spacer(),
                      Text(_myPartnerName.isEmpty ? l10n.chatPageNameUnset : _myPartnerName, style: valueStyle),
                    ],
                  ),
                ),
                PopupMenuItem(
                  height: kMenuRowHeight,
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
                // 语言 / 界面主题（2026-09-24 老板定：并入①「我」组）
                PopupMenuItem(
                  height: kMenuRowHeight,
                  value: 'locale',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuLocaleLabel, style: captionStyle),
                      const Spacer(),
                      Text(kLocaleLabels[langCode] ?? langCode, style: valueStyle),
                    ],
                  ),
                ),
                PopupMenuItem(
                  height: kMenuRowHeight,
                  value: 'style',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuStyleLabel, style: captionStyle),
                      const Spacer(),
                      Text(_uiStyleLabel(_uiStyle, l10n), style: valueStyle),
                    ],
                  ),
                ),
                // ①「我」与②「本通道」之间（老板 2026-09-22 要求单独一行）
                const PopupMenuDivider(height: kMenuDividerHeight),
                PopupMenuItem(
                  height: kMenuRowHeight,
                  value: 'devname',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuEntranceNameLabel, style: captionStyle),
                      const Spacer(),
                      Text(_myEntranceName.isEmpty ? l10n.chatPageNameUnset : _myEntranceName, style: valueStyle),
                    ],
                  ),
                ),
                PopupMenuItem(
                  height: kMenuRowHeight,
                  value: 'invite',
                  child: Text(l10n.chatPageMenuInvite, style: labelStyle),
                ),
                const PopupMenuDivider(height: kMenuDividerHeight), // 分隔：以下是安全相关设置（老板要求 2026-09-10）
                PopupMenuItem(
                  height: kMenuRowHeight,
                  value: 'burn',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuBurnLabel, style: captionStyle),
                      const Spacer(),
                      // 不设期限（0）不显示档位值，菜单项只显示「阅后即焚」；
                      // 选了具体时长才在右侧显示（老板 2026-09-15）
                      if (_burnSeconds > 0)
                        Text(_burnOptionLabel(_burnSeconds, l10n), style: valueStyle),
                    ],
                  ),
                ),
                PopupMenuItem(
                  height: kMenuRowHeight,
                  value: 'storage',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuAttachmentStorage, style: captionStyle),
                      const Spacer(),
                      Text(_attachmentStorageLabel(_attachmentStorage, l10n), style: valueStyle),
                    ],
                  ),
                ),
                PopupMenuItem(
                  height: kMenuRowHeight,
                  value: 'pin',
                  child: Row(
                    children: [
                      Text(l10n.chatPagePinLabel, style: captionStyle),
                      const Spacer(),
                      // 未设置时只显示「锁屏码」，不显示「未设置」尾缀（老板 2026-09-15）
                      if (_hasPin) Text(l10n.chatPagePinSetValue, style: valueStyle),
                    ],
                  ),
                ),
                // 高级（二级菜单走底部弹层）——归在安全组
                PopupMenuItem(
                  height: kMenuRowHeight,
                  value: 'advanced',
                  child: Row(
                    children: [
                      Text(l10n.advancedMenuTitle, style: labelStyle),
                      const Spacer(),
                      Icon(Icons.chevron_right, size: 18, color: labelStyle.color),
                    ],
                  ),
                ),
                const PopupMenuDivider(height: kMenuDividerHeight),
                // 关于与退出一组（都在分割线下方，退出垫底）
                PopupMenuItem(
                  height: kMenuRowHeight,
                  value: 'about',
                  child: Text(l10n.chatPageMenuAbout, style: labelStyle),
                ),
                // 空间组：紧贴「退出」上方（老板 2026-09-22：切换空间属"离开当前空间"
                // 一类操作，放在关于之下、退出之上）。回调由入口注入——聊天页自己不读
                // Vault（PIN 模式下读/写 Vault 都要 pin，而它刻意不持有 PIN）。
                // 「切换空间」：唯一的空间入口（2026-09-22 由「切换空间 / 空间管理」合并，
                // 两者本来就指向同一个页面）。两个回调实际只会有一个非空（取决于谁注入）。
                PopupMenuItem(
                    height: kMenuRowHeight,
                    value: 'switchspace',
                    child: Text(l10n.spaceListSwitch, style: labelStyle),
                  ),
                PopupMenuItem(
                  height: kMenuRowHeight,
                  value: 'exit',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuExit, style: labelStyle),
                      const Spacer(),
                      // 右侧退出图标：比纯文字更明确的「离开」信号（老板 2026-09-18）
                      Icon(Icons.logout, size: 18, color: labelStyle.color),
                    ],
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // 界面主题背景层：gradient=品牌粉蓝渐变（首屏/向导同款）；plain=不铺
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
                    if (_myPartnerName.isNotEmpty) ...[
                      Text(_myPartnerName,
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
          // 离线提示条（老板 2026-09-13）：只在"有还没确认的消息 **且** 连接有问题"
          // 时出现——正常发送时 pending 只存在百毫秒，不会闪。
          _buildOfflineHint(),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (context, i) {
                final m = _messages[i];
                final mine = m.sender == 'me';
                // 头像 partnerId：信封字段优先，缺失（旧版附件/语音消息）用通道映射兜底
                final avatarPartnerId =
                    m.env.senderPartnerId ?? _repo.partnerIdOfEntrance(m.env.senderEntranceId);
                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 每条消息前放置发送者头像（点击有头像时放大全屏查看）
                      if (!mine)
                        _MessageAvatar(
                            partnerId: avatarPartnerId, server: effectiveServer, api: widget.api),
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
                            // plain 浅色气泡不合并颜色（保持默认深色文字/图标）。
                            // 正文字号 [kMessageFontSize]（老板 2026-09-15：原来跟着
                            // Flutter 默认 14 走，比微信小一圈）——气泡内所有跟随默认
                            // 样式的文字（正文、文件名）一起变大；时间戳/焚毁标签/
                            // 引用块各自显式设了小字号，不受影响
                            style: TextStyle(
                                color: _uiStyle == 'gradient' ? Colors.white : null,
                                fontSize: kMessageFontSize),
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
                                        // 中间/后面，无法一眼看出"这条发出去没"）。
                                        // 墓碑消息（删除/焚毁）**同样显示**（老板
                                        // 2026-09-13）：删除/焚毁只是"在本设备隐藏正文"，
                                        // 不影响消息在服务器与对方的路径——所以状态与
                                        // 点按重发都该照旧可用。
                                        if (mine) ...[
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
                                          // 替代原来的时钟图标，避免与发送中混淆）；
                                          // 已焚毁/已删除 → 静态空沙漏（不再翻转）
                                          _BurnHourglass(burned: m.deleted),
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
                                          child: _buildQuoteBlockContent(m.quote!),
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
                            partnerId: avatarPartnerId, server: effectiveServer, api: widget.api),
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
                              color:
                                  _inputMode == _InputMode.recording ? Colors.green : null),
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
                                // 多行输入框：文字到达宽度后自动折行，输入框随之增高，
                                // 最多 8 行；超过 8 行不再增高，转为内部纵向滚动
                                // （老板要求 2026-09-13：原先单行 + 横向滚动体验差）。
                                // 非文字态（录音提示/录音/预览）把隐藏输入框按单行布局，
                                // 录音条 Positioned.fill 才不会跟着草稿高度撑到 8 行高
                                // （草稿保留在 controller 里，切回文字态自动恢复增高）
                                minLines: 1,
                                maxLines: _inputMode == _InputMode.text ? 8 : 1,
                                // 多行折行；回车键仍为「发送」（键盘右下角显示「发送」，
                                // iOS 按系统语言本地化），不插入换行——与微信一致
                                keyboardType: TextInputType.multiline,
                                textInputAction: TextInputAction.send,
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
                              // 进入录音态后此层不重建，松手能正常触发停止；预览态由
                              // _startVoice 直接忽略（长按不重录，防误触冲掉刚录好的一条）
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
                      // 纸飞机**朝上**（老板 2026-09-14）——消息流在输入框上方，朝上才
                      // 表达"发进上面的消息流"；Material 的 Icons.send 本身朝右，
                      // 逆时针转 90° 摆正。Transform 不改变占位，按钮布局不变
                      IconButton.filled(
                        onPressed: _inputMode == _InputMode.preview
                            ? _sendVoice
                            : (_inputMode == _InputMode.text ? _send : null),
                        icon: Transform.rotate(
                          angle: -math.pi / 2,
                          child: const Icon(Icons.send),
                        ),
                      ),
                    ],
                  ),
                  // 表情面板：展开时占据输入行下方（键盘已收起），可连续点选插入
                  if (_emojiPanelOpen)
                    EmojiPanel(
                      onEmojiSelected: _insertText,
                      onBackspace: _deleteBackward,
                      onDismiss: _closeEmojiPanel,
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
  const _SetLockDialog({
    required this.payload,
    required this.db,
    required this.hasPin,
  });

  final AppLockPayload payload;
  final LocalDatabase db;

  /// 打开弹窗**之前**读好的"本机是否已设锁屏码"（开弹窗前读、不在弹窗里异步读，
  /// 避免毫秒级窗口里验证被跳过）。
  final bool hasPin;

  @override
  State<_SetLockDialog> createState() => _SetLockDialogState();
}

class _SetLockDialogState extends State<_SetLockDialog> {
  final _oldCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String? _error;
  // 已设锁屏码 → 出「当前锁屏码」验证框（老板 2026-09-14）
  bool get _hasPin => widget.hasPin;
  bool _busy = false; // 当前锁屏码校验中（Argon2id）：防连点重复提交

  @override
  void dispose() {
    _oldCtrl.dispose();
    _pinCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (_busy) return;
    final oldPin = _oldCtrl.text;
    final pin = _pinCtrl.text;
    final confirm = _confirmCtrl.text;

    // 已设锁屏码：修改与清空都必须先验证当前锁屏码（老板 2026-09-14 定）——
    // 否则"清空 → 重设"两步即可绕过验证；手机被他人短暂拿到就能装一个自己的 PIN。
    // 验证走 AppLockService.unlock（与锁屏同一套防爆破：连错 5 次锁 30 秒）。
    if (_hasPin) {
      if (oldPin.isEmpty) {
        setState(() => _error = l10n.chatPageSetLockOldRequired);
        return;
      }
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        await AppLockService(widget.db).unlock(oldPin);
      } on AppLockLockedException catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = l10n.lockPageTooManyAttempts(e.remainingSeconds);
        });
        return;
      } on AppLockException {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = l10n.setPinDialogOldWrong;
        });
        return;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = l10n.setPinDialogSetupFailed('$e');
        });
        return;
      }
      if (!mounted) return;
      setState(() => _busy = false);
    }

    // 两空 = 清空锁屏码（Space Key 转明文保存，与向导"不设置锁屏码"一致）
    if (pin.isEmpty && confirm.isEmpty) {
      // 本来就没设锁屏码：没有可清的东西——不调后台、不改动，只提示一句（老板 2026-09-14）；
      // 先关弹窗再顶部提示（老板 2026-09-23）：通知浮在弹窗上不合理
      if (!_hasPin) {
        // async gap 前同步捕获 overlay（根 Overlay 在路由 pop 后仍存活）
        final overlay = Overlay.of(context, rootOverlay: true);
        Navigator.of(context).pop(); // 无改动：不回 true（菜单不做无谓刷新）
        showTopNoticeOn(overlay, l10n.chatPageSetLockNoPinNotice);
        return;
      }
      // async gap 前同步捕获 overlay（根 Overlay 在路由 pop 后仍存活），避免 use_build_context_synchronously
      final overlay = Overlay.of(context, rootOverlay: true);
      // 显性确认：清空锁屏码（防误触——清空是降级操作）
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
    // 新旧码相同 → 红字提示，不真去设置（老板 2026-09-14）。放在旧码校验之后：
    // 先验完旧码再比，避免把"你猜对了当前锁屏码"当成提示漏出去
    if (_hasPin && pin == oldPin) {
      setState(() => _error = l10n.chatPageSetLockSameAsOld);
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
    if (pin != confirm) {
      setState(() => _error = l10n.setPinDialogPinMismatch);
      return;
    }
    // async gap 前同步捕获 overlay（根 Overlay 在路由 pop 后仍存活），避免 use_build_context_synchronously
    final overlay = Overlay.of(context, rootOverlay: true);
    // 设置/重设不再弹二次确认（老板 2026-09-14：新码/确认两栏已足够，多一次确认多余）
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
          // 提示：设置后，每次进入秘境都要解锁，更安全。已设锁屏码时另有说明（修改/清空需验旧码）。大标题下、输入框上方——老板要求
          Text(
            _hasPin ? l10n.chatPageSetLockClearHint : l10n.chatPageSetLockHintNoPin,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 10),
          // 已设锁屏码：先输当前锁屏码（修改/清空都要验证）
          if (_hasPin) ...[
            TextField(
              controller: _oldCtrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              autofocus: _hasPin, // 已设锁屏码时这是第一个框
              decoration: InputDecoration(
                labelText: l10n.chatPageSetLockOldLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: _pinCtrl,
            obscureText: true,
            keyboardType: TextInputType.number,
            autofocus: !_hasPin, // 未设锁屏码时 PIN 是第一个框
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
        FilledButton(onPressed: _busy ? null : _submit, child: Text(l10n.setPinDialogSetPin)),
      ],
    );
  }
}

/// 修改口令弹窗（StatefulWidget）。两种情形：
/// ① 服务器有密保箱 → 旧口令验证（fetch 解密）→ 新口令重加密上传；
/// ② 服务器**无**密保箱（数据丢失）→ 无从校验旧口令，跳过校验直接用新口令
///    重建（通道已认证且持有 Space Key，不新增权限）。
/// 本地一律不落共享口令（与 TUI 对齐；服务器为唯一真相源）。
class _ChangePassphraseDialog extends StatefulWidget {
  const _ChangePassphraseDialog({
    required this.server,
    required this.spaceKeyB64,
    required this.spaceId,
    required this.keyVersion,
    required this.token,
    required this.onPassphraseUpdated,
    this.api, // 测试注入（fake api，不触网）；默认按 server 新建
  });

  final String server;
  final ApiClient? api;
  final String spaceKeyB64;
  final String spaceId;
  final int keyVersion;
  final String token;

  /// 上传成功后回传服务端 updated_at（聊天页记录已知时间，防下次补查误报自己改了口令）。
  final ValueChanged<int?> onPassphraseUpdated;

  @override
  State<_ChangePassphraseDialog> createState() => _ChangePassphraseDialogState();
}

class _ChangePassphraseDialogState extends State<_ChangePassphraseDialog> {
  final _oldCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  // 与创建向导共用同一策略（shared 的 passphrase_policy.dart）
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
    // 口令策略（唯一来源 shared/passphrase_policy.dart）：只要求最短 8 位，
    // 字符种类不限（老板 2026-09-15：复杂度交给用户自己决定）
    if (checkPassphrasePolicy(newPass) != null) {
      setState(() => _error = l10n.wizardPassphraseTooShort);
      return;
    }
    if (newPass != confirm) {
      setState(() => _error = l10n.chatPageChangePassphraseMismatch);
      return;
    }
    // 先取服务端密保箱状态：决定是否需要旧口令、以及确认文案。
    // 无包（服务端数据丢失）时旧口令无从校验——直接重建，不新增权限。
    final api = widget.api ?? ApiClient(effectiveServer);
    final escrow = KeyEscrowService(api);
    setState(() => _busy = true);
    PassphraseEnvelope? serverFile;
    try {
      serverFile = (await api.getKeyEscrow(widget.token)).file;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.chatPageChangePassphraseFailed('$e');
      });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final rebuilding = serverFile == null;
    // 旧口令没填 → 先报第一个框的错（老板 2026-09-23：三框全空报"请设置共享口令"
    // 不合理，第一个空的是当前口令）。重建路径（无密保箱）不需要旧口令，不拦。
    if (!rebuilding && oldPass.isEmpty) {
      setState(() => _error = l10n.chatPageChangePassphraseOldRequired);
      return;
    }
    // 新口令与旧口令相同 → 红字提示，不真去改（老板 2026-09-14）。放在拿到服务端状态
    // 之后：无密保箱（重建路径）本就不用旧口令，那种情况下不该拦（用户可能只是重填同一个口令重建）
    if (!rebuilding && oldPass == newPass) {
      setState(() => _error = l10n.chatPageChangePassphraseSame);
      return;
    }
    // 不再弹第二个确认弹窗（老板 2026-09-15：两个叠着累赘）——校验都过了就直接改：
    // 口令已在三个输入框里输过一遍，本身就是确认；有错一律在弹窗内红字报出。
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 1) 有密保箱才校验旧口令；无包 = 重建路径，跳过校验
      if (!rebuilding) {
        try {
          await escrow.openPackage(passphrase: oldPass, envelope: serverFile);
        } on FormatException {
          if (!mounted) return;
          setState(() => _error = l10n.chatPageChangePassphraseOldWrong);
          return;
        }
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
      // 3) 记录本端已知口令更新时间（避免下次上线补查误报"对方重设"——
      //    其实是自己刚改的）。本地不存口令（服务器为唯一真相源）。
      int? serverUpdatedAt;
      try {
        serverUpdatedAt = (await api.getKeyEscrow(widget.token)).updatedAt;
      } catch (_) {
        // 记录失败不影响结果（下次上线补查再对比）
      }
      widget.onPassphraseUpdated(serverUpdatedAt); // 聊天页记录已知时间
      if (!mounted) return;
      Navigator.of(context).pop(true);
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
          // 说明文字（与创建向导**共用同一句** wizardPassphraseHint，老板 2026-09-15
          // 要求统一口径；样式与开通码 / PIN 弹窗一致：大标题下小字说明）
          Text(
            l10n.wizardPassphraseHint,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 12),
          // 旧口令/新口令可临时查看明文（点眼睛，3 秒后自动回暗码）；
          // **确认新口令不给眼睛**——确认框是用来复核的，给"看一眼"反而容易顺手点开
          // （老板 2026-09-15）。
          PassphraseField(
            controller: _oldCtrl,
            labelText: l10n.chatPageChangePassphraseOldLabel,
            revealTip: l10n.chatPagePassphraseRevealTip,
            autofocus: true, // 改口令弹窗第一个框
          ),
          const SizedBox(height: 8),
          PassphraseField(
            controller: _newCtrl,
            labelText: l10n.chatPageChangePassphraseNewLabel,
            hintText: l10n.wizardPassphraseMinLengthHint,
            revealTip: l10n.chatPagePassphraseRevealTip,
          ),
          const SizedBox(height: 8),
          PassphraseField(
            controller: _confirmCtrl,
            labelText: l10n.chatPageChangePassphraseConfirmLabel,
            showReveal: false,
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
          child: Text(l10n.chatPageChangePassphraseSubmit),
        ),
      ],
    );
  }
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

/// 语音波形图（老板要求 2026-09-13）：长方形区域里一排等宽竖条。
///
/// 竖条振幅二选一：[samples] 给了就用真实录音采样（录音条预览态，按 [width]
/// 重采样成对应的条数）；否则用 [seed]（气泡里的 messageId）确定性生成——
/// 同一条消息每次进页面形状一致（接收端拿不到对方录音的振幅）。
///
/// 播放时按时间比例把已播过的条染成 [activeColor]（阴影从左往右扩散），并在
/// 进度位置画一根竖线走过去；走完/停止即复原。时长未知时改为循环扫掠的波浪动画。
/// 进度只用一个 AnimationController 的 value 驱动，重绘仅限这个 CustomPaint。
class _VoiceWaveform extends StatefulWidget {
  const _VoiceWaveform({
    required this.playing,
    required this.durationSeconds,
    required this.activeColor,
    required this.inactiveColor,
    this.samples,
    this.seed,
    this.width = 120,
  });

  final bool playing;
  final int durationSeconds;
  final Color activeColor;
  final Color inactiveColor;
  final List<double>? samples; // 真实振幅采样（非空时优先于 seed）
  final String? seed;
  final double width;

  @override
  State<_VoiceWaveform> createState() => _VoiceWaveformState();
}

class _VoiceWaveformState extends State<_VoiceWaveform>
    with SingleTickerProviderStateMixin {
  static const double _barWidth = 3;
  static const double _barGap = 2;
  static const double _height = 28;

  late final AnimationController _progress;
  late List<double> _amplitudes;

  @override
  void initState() {
    super.initState();
    _amplitudes = _resolveAmplitudes();
    _progress = AnimationController(vsync: this, duration: _animationDuration);
    _sync();
  }

  @override
  void didUpdateWidget(covariant _VoiceWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing ||
        oldWidget.durationSeconds != widget.durationSeconds) {
      _sync();
    }
    if (oldWidget.width != widget.width ||
        oldWidget.samples?.length != widget.samples?.length) {
      _amplitudes = _resolveAmplitudes();
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  /// 竖条数由宽度决定（3px 条 + 2px 间隔）。
  int get _barCount =>
      math.max(4, ((widget.width + _barGap) / (_barWidth + _barGap)).floor());

  /// 动画时长：时长已知=按时长走一遍；未知=2s 循环扫掠。
  Duration get _animationDuration => widget.durationSeconds > 0
      ? Duration(milliseconds: widget.durationSeconds * 1000)
      : const Duration(seconds: 2);

  void _sync() {
    if (!widget.playing) {
      _progress.stop();
      _progress.value = 0;
      return;
    }
    _progress.duration = _animationDuration;
    if (widget.durationSeconds > 0) {
      _progress.forward(from: 0);
    } else {
      _progress.repeat(); // 时长未知：反复扫掠（动态波浪效果）
    }
  }

  /// 竖条振幅：有真实采样就重采样到 [_barCount]，否则按 seed 确定性生成。
  List<double> _resolveAmplitudes() {
    final samples = widget.samples;
    if (samples != null && samples.isNotEmpty) return _resample(samples, _barCount);
    return _buildAmplitudes(widget.seed ?? '');
  }

  /// 把任意长度的采样压成 [count] 根条（每根取该区间的均值）。
  List<double> _resample(List<double> samples, int count) {
    if (samples.length == count) return samples;
    return List<double>.generate(count, (index) {
      final start = (index * samples.length / count).floor();
      final end = math.max(start + 1, ((index + 1) * samples.length / count).floor());
      var sum = 0.0;
      for (var i = start; i < end && i < samples.length; i++) {
        sum += samples[i];
      }
      return sum / (end - start);
    });
  }

  /// 按 seed 生成竖条振幅：中间高两头低的包络 + 确定性伪随机抖动。
  List<double> _buildAmplitudes(String seed) {
    var hash = 2166136261; // FNV-1a 起点
    for (final unit in seed.codeUnits) {
      hash = (hash ^ unit) * 16777619;
    }
    final random = math.Random(hash & 0x7fffffff);
    final count = _barCount;
    return List<double>.generate(count, (index) {
      final envelope = math.sin(math.pi * (index + 1) / (count + 1));
      return (0.35 + 0.65 * random.nextDouble()) * (0.45 + 0.55 * envelope);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) => CustomPaint(
        size: Size(widget.width, _height),
        painter: _WaveformPainter(
          amplitudes: _amplitudes,
          progress: _progress.value,
          activeColor: widget.activeColor,
          inactiveColor: widget.inactiveColor,
        ),
      ),
    );
  }
}

/// 波形绘制：progress 左侧的条 + 进度竖线用高亮色，其余用底色。
class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.amplitudes,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  static const double _barWidth = 3;
  static const double _barGap = 2;

  final List<double> amplitudes;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  @override
  void paint(Canvas canvas, Size size) {
    final playedTo = progress * size.width;
    final paint = Paint()..style = PaintingStyle.fill;
    for (var index = 0; index < amplitudes.length; index++) {
      final left = index * (_barWidth + _barGap);
      final height = 4 + amplitudes[index] * (size.height - 4);
      paint.color = left + _barWidth <= playedTo ? activeColor : inactiveColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, (size.height - height) / 2, _barWidth, height),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
    if (progress > 0 && progress < 1) {
      paint.color = activeColor;
      canvas.drawRect(
        Rect.fromLTWH((playedTo - 1).clamp(0.0, size.width - 2), 0, 2, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.inactiveColor != inactiveColor;
}

/// 消息发送者头像：按 partnerId 从服务端加载（静态缓存避免重复请求），
/// 未设置/加载失败显示默认图标；点击有头像时放大到全屏查看。
class _MessageAvatar extends StatefulWidget {
  const _MessageAvatar({this.partnerId, required this.server, this.api});

  final String? partnerId;
  final String server;
  final ApiClient? api;

  @override
  State<_MessageAvatar> createState() => _MessageAvatarState();
}

class _MessageAvatarState extends State<_MessageAvatar> {
  static final Map<String, Uint8List> _cache = {}; // partnerId → 头像 bytes

  /// 头像失效广播（partnerId）：通知当前在树上的头像重拉——否则静态缓存只在
  /// 进程内有效，换了头像要重启 App 才看得到（老板 2026-09-11）。
  static final ValueNotifier<String?> invalidated = ValueNotifier<String?>(null);

  /// 让某人的头像失效：上传本人头像 / 收到对方 profile.updated 时调用。
  static void invalidate(String? partnerId) {
    if (partnerId == null || partnerId.isEmpty) return;
    invalidated.value = partnerId;
  }

  Uint8List? get _bytes => widget.partnerId == null ? null : _cache[widget.partnerId];

  @override
  void initState() {
    super.initState();
    final pid = widget.partnerId;
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
    final pid = widget.partnerId;
    if (pid == null || invalidated.value != pid) return;
    _load(pid); // 覆盖旧缓存后再 setState（不先清空——避免闪成默认图标）
  }

  Future<void> _load(String partnerId) async {
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final bytes = await api.getAvatar(partnerId);
      if (bytes == null) return;
      // 缓存写入不看 mounted：失效广播时未挂载的实例（滚出屏幕被回收）若丢弃结果，
      // 静态缓存会一直留着旧图，滚动回来 initState 见缓存命中也不再重拉
      _cache[partnerId] = bytes;
      if (mounted) setState(() {});
    } catch (_) {
      // 网络失败：保持默认图标
    }
  }

  /// 全屏查看头像（品牌粉蓝渐变大图 + 右上角关闭；隐藏系统状态栏 = 沉浸感）。
  /// 背景 = kBrandGradient，与图片全屏一致（老板 2026-09-15）。
  Future<void> _showFullscreen() async {
    final bytes = _bytes;
    if (bytes == null) return;
    await withImmersiveFullscreen(() => showDialog<void>(
          context: context,
          barrierDismissible: true,
          useSafeArea: false,
          builder: (_) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            child: SizedBox.expand(
              child: DecoratedBox(
                decoration: const BoxDecoration(gradient: kBrandGradient),
                child: Stack(
                  children: [
                    Positioned.fill(child: Image.memory(bytes, fit: BoxFit.contain)),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: SafeArea(
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ));
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

/// 邀请链接二维码（自绘，替代 QrImageView）。
///
/// QrImageView（qr_flutter 4.1.0）两个坑（2026-09-08 老板真机报告：生成开通码
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
  const _VideoPreview(
      {required this.bytes, required this.spaceId, required this.messageId});

  final Uint8List bytes;
  final String spaceId; // 缓存按空间分目录（与服务端 files/<space_id>/ 同构）
  final String messageId; // 解密缓存确定性键：重复预览复用同一缓存文件

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
    if (_failed && mounted) setState(() => _failed = false); // 重试：先清掉上次的失败态
    try {
      // 解密缓存：确定性路径按 messageId 复用（重复打开预览不再重复落盘解密）
      final tmp = await MediaCache.pathFor(widget.spaceId, widget.messageId, 'mp4');
      if (!await tmp.exists()) {
        await tmp.writeAsBytes(widget.bytes, flush: true);
      }
      final c = VideoPlayerController.file(tmp);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (e) {
      // 留痕：此前这里静默成空白，桌面端排查时完全看不出线索（老板 2026-09-20
      // 报「视频在消息流里是空白」就是这么藏了很久）
      debugPrint('视频预览初始化失败（${widget.messageId}）：$e');
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
    // 初始化失败：给可点重试的明确错误态，而不是一个没有内容的空白框
    // （三种状态都带同一个 key：测试按 key 定位视频气泡，不受具体控件类型影响）
    if (_failed) {
      return GestureDetector(
        key: const ValueKey('videoPreview'),
        onTap: _init,
        child: Container(
          width: 180,
          height: 100,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined, size: 26),
              const SizedBox(height: 6),
              Text(AppLocalizations.of(context)!.chatPageVideoLoadFailed,
                  style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      );
    }
    // 初始化中：显示进度（与失败态分开，避免"转圈"和"空白"看起来一样）
    if (c == null) {
      return SizedBox(
          key: const ValueKey('videoPreview'),
          width: 180,
          height: 100,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)));
    }
    return GestureDetector(
      key: const ValueKey('videoPreview'),
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
    await withImmersiveFullscreen(() => showDialog<void>(
          context: context,
          barrierDismissible: true,
          useSafeArea: false,
          builder: (ctx) => Dialog(
            // 与图片全屏一致：品牌渐变底 + 铺满全屏 + 隐藏系统状态栏（老板要求
            // 2026-09-12 / 2026-09-15——视频全屏也应是渐变大画面，且背景要盖到
            // 屏幕最顶端，而不是默认半透明遮罩下的圆角小卡）
            backgroundColor: Colors.transparent,
            insetPadding: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            child: SizedBox.expand(
              child: DecoratedBox(
                decoration: const BoxDecoration(gradient: kBrandGradient),
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
                      child: SafeArea(
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ));
    await c.pause();
  }
}

/// 「发送中」的**动态**小飞机（老板 2026-09-13）：轻微上下浮动 + 左右小幅平移 +
/// 一点点俯仰，读起来像"飞行中"。原来是个静态图标，看不出"正在动"。
///
/// 无障碍/测试友好：`MediaQuery.disableAnimations` 为真时退化为静态图标——
/// 既尊重"减少动态效果"的系统偏好，也让 widget 测试里的 `pumpAndSettle` 不会
/// 被这个常驻动画卡住（常驻动画会让 pumpAndSettle 一直等到超时）。
class _SendingPlane extends StatefulWidget {
  const _SendingPlane({this.color});

  final Color? color;

  @override
  State<_SendingPlane> createState() => _SendingPlaneState();
}

class _SendingPlaneState extends State<_SendingPlane>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.send, size: 11, color: widget.color);
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return icon;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value * 2 * math.pi;
        return Transform.translate(
          offset: Offset(math.sin(t) * 1.5, -math.cos(t) * 1.2),
          child: Transform.rotate(angle: math.sin(t) * 0.15, child: child),
        );
      },
      child: icon,
    );
  }
}

/// 阅后即焚「沙漏」小图标（老板 2026-09-12）：未焚毁时在 hourglass_top ↔
/// hourglass_bottom 之间缓慢翻转，暗示倒计时在流逝；**已焚毁（[burned]）时改为
/// 静态空沙漏**——沙漏已经漏完了，还在翻转不符合直觉（老板 2026-09-12）。
/// 颜色不指定 → 继承 IconTheme（渐变风格下为白系，与相邻的时间/时长文字一致）。
class _BurnHourglass extends StatelessWidget {
  const _BurnHourglass({this.burned = false});

  /// 该消息是否已被焚毁/删除（到期或手动删除）——是则显示静态空沙漏。
  final bool burned;

  @override
  Widget build(BuildContext context) {
    // 已焚毁：静态空沙漏（不创建动画控制器，避免无谓的逐帧重建）
    if (burned) return const Icon(Icons.hourglass_empty, size: 11);
    return const _HourglassFlip();
  }
}

class _HourglassFlip extends StatefulWidget {
  const _HourglassFlip();

  @override
  State<_HourglassFlip> createState() => _HourglassFlipState();
}

class _HourglassFlipState extends State<_HourglassFlip>
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
