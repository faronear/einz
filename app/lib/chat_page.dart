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

import 'widgets/linkified_text.dart';
import 'package:image_picker/image_picker.dart';
import 'package:einz_shared/einz_shared.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'widgets/about_sheet.dart';
import 'brand_logo.dart';
import 'data/attachment_storage_settings.dart';
import 'data/attachment_store.dart';
import 'data/burn_after_settings.dart';
import 'data/notify_settings.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'data/server_config.dart';
import 'error_text.dart';
import 'data/locale_settings.dart';
import 'data/lock_timer.dart';
import 'data/media_cache.dart';
import 'data/message_repository.dart';
import 'data/space_session.dart';
import 'data/ui_style_settings.dart';
import 'data/ws_realtime_service.dart';
import 'data/voice_call_service.dart';
import 'l10n/app_localizations.dart';
import 'lock_page.dart';
import 'setup_page.dart';
import 'voice_call_sheet.dart';
import 'widgets/reset_entrance.dart';
import 'widgets/space_switcher.dart';
import 'widgets/scrollable_card_area.dart';
import 'data/vault_session.dart';
import 'widgets/emoji_panel.dart';
import 'widgets/immersive_fullscreen.dart';
import 'widgets/passphrase_field.dart';
import 'widgets/option_picker_sheet.dart';
import 'widgets/top_notice.dart';
import 'widgets/ui_style_picker.dart';
import 'widgets/clickable.dart';

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

/// 「通道列表」卡片间距 + 每行张数（与「切换我的秘境」弹层同口径：一行正好 3 张，
/// 老板 2026-09-25；边长按可用宽度反算，桌面大窗口设上限）。
const double _entranceCardSpacing = 12;
const int _entranceCardsPerRow = 3;

/// 弹层**内容区**的最大宽度：modal bottom sheet 在 M3 下把内容限在 640，窗口再宽也不再长
/// （实测 800 / 1600 宽的视口，内容区都是 640、居中）。
const double _entranceSheetMaxWidth = 640;

/// 弹层内容区左右的内边距（下面 Padding 的 16）。
const double _entranceSheetHPadding = 16;

/// 卡片边长上限 = **弹层最大宽度**下"一行 3 张"的边长：
/// 640 − 左右各 16 = 608 可用，减去两条 12 的间距，再均分 3 份 = 194.67
/// （`_entranceCardSizeFor` 向下取整到 194，右边最多余 2px）。
///
/// 老板 2026-09-26：桌面窗口拉宽到弹层不再增长之后，卡片也不能先停止增长——原来上限
/// 硬写 160，宽窗口下三张卡只铺到 504，右边空一大截（弹层 640 里空 100+）。
/// 手机上可用宽度够不到这个上限（< 3*160+2*12 = 504），不影响"一行正好 3 张"。
/// 「切换我的秘境」弹层有一份同口径的 `_kCardMaxSize`（space_switcher.dart），改一处要改两处。
const double _entranceCardMaxSize = (_entranceSheetMaxWidth -
        _entranceSheetHPadding * 2 -
        _entranceCardSpacing * (_entranceCardsPerRow - 1)) /
    _entranceCardsPerRow;

double _entranceCardSizeFor(double availableWidth) {
  final raw =
      (availableWidth - _entranceCardSpacing * (_entranceCardsPerRow - 1)) /
          _entranceCardsPerRow;
  return raw.floorToDouble().clamp(64.0, _entranceCardMaxSize).toDouble();
}

/// 「我的通道」弹层标题行右端「刷新」按钮的占位/按钮边长（标题居中靠它配平）。
const double _entranceRefreshSize = 40;

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
    this.memberName, // 我的名字（登记时设置；菜单显示/修改）
    this.entranceName, // 我的通道名（登记时自动获取；菜单显示/修改）
    this.memberId, // 我的 memberId（头像上传/获取用）
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
  final String? memberName;

  /// 我的通道名（向导登记时自动获取设备型号；顶栏菜单显示/修改，服务端同步）。
  final String? entranceName;

  /// 我的 memberId（向导登记时确定；头像上传/消息身份标识用）。
  final String? memberId;

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

/// 消息流正文（气泡内跟随默认样式的文字）字号（老板 2026-09-25 定：16）。
/// 演变：原样跟 Flutter 默认 14（比微信小一圈）→ 2026-09-15 取中间值 15 →
/// 2026-09-25 老板看 15 仍偏小，定 16。
/// 只作用于气泡内跟随默认样式的文字——时间戳/焚毁标签/引用块/长按预览行都显式
/// 设了字号，不受影响。
const double kMessageFontSize = 16;

/// **引用里**图片/视频缩略图的边长：输入栏引用条与气泡里的引用块**同尺寸**
/// （老板 2026-09-27：引用条里已经不显示文件名了，有的是空间，放大到和引用块一样）。
/// 改这里两处一起变——此前引用条 24、引用块 40，两处各写各的。
const double kQuoteThumbSize = 40;

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {

  late final MessageRepository _repo;

  /// 本空间的会话（**本页唯一权威 token**）：所有带鉴权的请求都走 `_withAuth`，
  /// 由它保证"401 → 续期 → 重试"。别再直接把 `widget.token` 塞给 ApiClient——
  /// 那是构造时的死副本，24h 后必 401（2026-09-26 老板线上实测的头像上传 bug）。
  late final SpaceSession _session;
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
  /// 邮件通知状态（菜单项右侧值 + 弹窗内容）。null = 还没拉到/离线拉不到→菜单只显示标签，
  /// 不猜状态（猜错比不显示更糟：他会以为已经开了）。
  NotifyEmailStatus? _notifyEmail;
  /// 只在"待确认"期间跑的轮询（20s）：确认是**在 App 外面点邮件链接**完成的，服务端
  /// 没有任何通道能通知 App 它翻转了——不轮询的话只有重启才能看到（老板 2026-10-01 实测）。
  Timer? _notifyTicker;
  WsRealtimeService? _ws; // WS 实时（收到 message.new 立即刷新；断线自动重连）
  VoiceCallService? _voiceCall; // 语音通话（前台通话；信令走 WS，PROTOCOL.md §8.4）
  late String _myMemberName; // 我的名字（菜单显示；改名后 setState 刷新）
  late String _myEntranceName; // 我的通道名（菜单显示；改名后 setState 刷新）
  late String _myGender; // 我的性别（male/female/''；profile 恢复，个人资料弹窗图标展示）
  late String _peerGender; // 对方性别（male/female/''；profile 恢复，消息气泡配色用）
  int? _mySlot; // 我的身份槽位（0=第一人/创建者，1=第二人；同性别气泡青色判定用）
  int? _peerSlot; // 对方身份槽位（同上）
  Uint8List? _myAvatarBytes; // 我的头像 bytes 缓存（菜单显示；上传后刷新）
  /// 我的 memberId（头像上传/缓存失效/归属判定用）：向导路径由 widget 传入；
  /// 重启（PIN 解锁/明文直进）路径 widget.memberId 为空 → 运行时反查补齐
  /// （见 [_loadMyAvatar] / [_refreshProfileFromServer]）。
  String? _myMemberId;
  late String _peerName; // 对方名字（对话顶部条显示）
  bool _peerOnline = false; // 对方在线状态（last_seen 距今 <60s）
  String? _peerMemberId; // 对方 memberId（状态条头像用；来自 /space 成员表）
  Uint8List? _peerAvatarBytes; // 对方头像 bytes（状态条显示；拿不到就默认人形）
  /// 状态条要显示的「上线 / 下线时刻」（ms；null = 还不知道，不显示）：
  /// 对方与我方各一份，口径与「更多通道」卡片一致（见 [_sinceOfRow]）。
  int? _peerSinceMs;
  int? _mySinceMs;
  /// 我的通道总数（含本机这条，按 member 维度）：通道轮询（_refreshPeerOnline）
  /// 顺带维护，汉堡菜单「更多通道」项的 devices 图标旁显示（老板 2026-09-28）。
  /// null = 还没拉到（离线/未轮询过），菜单里就不显示数字。
  int? _myEntranceCount;

  /// 群聊一期（2026-10-03）：
  /// 本空间**全部成员**：member_id → 槽位（/space 的 member_slots——含还没设置
  /// 名字的成员；member_names 只收有名字的，不能拿来数人头）。槽位用于按加入
  /// 顺序列名单。
  final Map<String, int> _memberSlots = {};
  /// member_id → 显示名（/space 的 member_names；群空间里逐条消息标注"谁说的"）。
  final Map<String, String> _memberNames = {};
  /// 空间模式（'duo' | 'group'，/space 下发）。**不靠"成员数 ≥3"猜**——duo 满员
  /// 签发 invite 后、第三人还没加入时 mode 已经是 group（那时就得停用通话了）。
  String _spaceMode = 'duo';
  /// 本服务器单空间成员上限（/space 下发；0=不限）。满员时隐藏邀请入口用。
  int _maxMembers = 0;

  /// 群聊判定：直接读服务端下发的 mode（不靠"成员数 ≥3"猜——duo 满员后签发
  /// invite 的那一刻就已升格，此时第三人还没进来，但通话必须立刻停用）。
  bool get _isGroup => _spaceMode == 'group';

  /// 顶部条那一格的主文案（群聊一期 2026-10-03）：
  /// - duo：沿用"对方名字"（两人世界里这一格就是那一个人）；
  /// - group：**其他成员的名字列表**（"A、B、C"），按槽位（入群先后）排、过长
  ///   由 Text 的省略号截断。不再假装有"唯一一个对方"。
  String get _statusTitle {
    if (!_isGroup) return _peerName;
    final others = _memberSlots.entries
        .where((e) => e.key != _myMemberId)
        .toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final names = others
        .map((e) => _memberNames[e.key] ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
    if (names.isEmpty) return _peerName; // 还没拉到名单：退回旧值，别闪成空白
    return names.join('、');
  }

  /// 本空间成员数（身份数，同身份多通道只算一个）。
  int get _memberCount => _memberSlots.length;

  /// 还能不能再邀请新成员（满员 = 服务端上限已达；0=不限）。
  bool get _canInviteMore => _maxMembers <= 0 || _memberCount < _maxMembers;

  /// 是否在气泡旁显示发送者头像：group 默认开、duo 默认关；
  /// `--dart-define=SHOW_MESSAGE_AVATARS=true` 强制开（含 duo）。
  bool get _showMessageAvatars => kShowMessageAvatarsOverride || _isGroup;

  /// 发送者显示名（群内逐条标注）：成员表里的名字，查不到回落"未命名"。
  String _senderNameOf(String? memberId) {
    if (memberId == null) return '';
    final name = _memberNames[memberId];
    return (name == null || name.isEmpty) ? '' : name;
  }

  /// **其它**空间（非当前）的未读数：spaceId → 条数。用于顶部「切换秘境」旁的汇总角标。
  final Map<String, int> _otherUnread = {};
  Timer? _unreadTimer;
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

  /// 顶栏阅后即焚标记的档位文字：**只用量纲单位** d/h/m/s（老板 2026-09-24：
  /// 不用中文单位——横向更省，也不随界面语言变化）。取能整除的最大单位。
  String _burnBadgeText(int seconds) {
    if (seconds >= 86400 && seconds % 86400 == 0) return '${seconds ~/ 86400}d';
    if (seconds >= 3600 && seconds % 3600 == 0) return '${seconds ~/ 3600}h';
    if (seconds >= 60 && seconds % 60 == 0) return '${seconds ~/ 60}m';
    return '${seconds}s';
  }

  /// 顶栏的阅后即焚标记：沙漏 + 档位（如 `⧗ 1h`）。**点击直接进档位弹层**
  /// （与菜单里的「阅后即焚」是同一个动作，只是把这个"会丢消息"的状态提到明面上）。
  ///
  /// 图标与消息气泡里同族（`_BurnHourglass`），并同样**动态翻转**（老板 2026-09-28：
  /// 菜单里是动态的，顶栏这个静态的显得不一致，一并动态化）；尺寸 24 = 锁屏等
  /// 顶栏图标同大（老板 2026-09-24，火苗太小时改）。未焚毁态才有翻转，
  /// `burned: false` 恒真——顶栏标记只在焚毁**生效前**显示。
  /// 配色不单独指定：跟锁屏等顶栏图标同色。
  Widget _buildBurnBadge(AppLocalizations l10n) {
    return Tooltip(
      message: l10n.chatPageBurnHeading,
      child: InkWell(mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(16),
        onTap: _showBurnPicker,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _BurnHourglass(burned: false, size: 24),
              const SizedBox(width: 2),
              Text(_burnBadgeText(_burnSeconds),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  /// 消息发送时间标注：当天 HH:MM / 当年 mm-dd HH:MM / 跨年 yyyy-mm-dd HH:MM。
  String _messageTimeLabel(HistoryMessage m) => _timeStampLabel(m.createdAt);

  /// 时间戳标注（消息 / 通道列表共用）：当天 HH:MM / 当年 mm-dd HH:MM / 跨年 yyyy-mm-dd HH:MM。
  String _timeStampLabel(int ms) {
    final local = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
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

  /// 气泡时间行里的快捷动作小按钮（老板 2026-10-02）：**只留图标**（文字版实测
  /// 每条消息都带字，视觉太重），尺寸/颜色同时间戳淡色档，点击直接执行动作——
  /// 不用进长按菜单。悬浮/点击背景效果同状态栏电话/设备图标（Material+InkWell）。
  Widget _bubbleQuickAction(
    HistoryMessage m, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final subtle = _uiStyle == 'gradient' ? Colors.white70 : Colors.grey;
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(), // 圆形背景（老板 2026-10-02：同状态栏电话图标）
      clipBehavior: Clip.antiAlias,
      child: Tooltip(
        message: label,
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          // 悬浮/点击背景（老板 2026-10-02）：与状态栏电话/设备图标同档
          // hover/highlight 色，浅灰淡染——gradient 深色气泡下黑 alpha 同样可见
          hoverColor: Colors.black.withValues(alpha: 0.05),
          highlightColor: Colors.black.withValues(alpha: 0.08),
          onTap: onTap,
          child: Padding(
            // 热区：padding 4（老板 2026-10-02：6 会撑大气泡，收到 4），
            // 相邻动作另加 2 间隔
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 12, color: subtle),
          ),
        ),
      ),
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
        child: Clickable(
          onTap: () => _tapRetryMessage(m, asResend: true),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(busyLabel ?? l10n.chatPageMsgFailedTap,
                  style: TextStyle(fontSize: 11, color: Colors.red.shade600)),
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
      child: Clickable(
        onTap: () => _tapRetryMessage(m, asResend: false),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busyLabel != null) ...[
              Text(busyLabel, style: TextStyle(fontSize: 11, color: subtle)),
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
    // **会话先建**：下面每一步（含 initState 里就发起的 _refreshPeerOnline）
    // 都可能读 `_session.token`，late final 没赋值就抛 LateInitializationError
    // （2026-09-26 加会话时踩过一次：被 catch 吞掉 → 对方在线/「邀请加入」全失效）。
    final db = widget.db ?? LocalDatabase.shared;
    _session = SpaceSessions.of(
      spaceId: widget.spaceId,
      token: widget.token,
      // 续期用注入的 challenge-response（chat_entry 从锁包密钥对拼的）；
      // 旧锁包没有密钥对 → reauth 为 null → 会话续不了期，401 照抛
      refresh: widget.reauth,
      db: db,
    );
    _myMemberName = widget.memberName ?? '';
    _myEntranceName = widget.entranceName ?? '';
    _myGender = ''; // 个人资料弹窗性别图标：由 profile 恢复（向导完成时写入）
    _peerGender = ''; // 消息气泡配色：由 profile 恢复（向导完成时写入）
    _mySlot = null; // 身份槽位（0=第一人/1=第二人）：由 profile 恢复 + /space 校正
    _peerSlot = null;
    _peerName = widget.peerName ?? '';
    _myMemberId = widget.memberId; // 向导路径已知；重启路径为 null → 稍后反查补齐
    _refreshPeerOnline();
    _peerTicker = Timer.periodic(const Duration(seconds: 30), (_) => _refreshPeerOnline());
    WidgetsBinding.instance.addObserver(this);
    // 名字未由向导传入（如 PIN 解锁后重启进聊天）→ 从本地 profile 恢复。
    // 必须按 spaceId 读：多空间下全局键是所有空间共用的一格，会被别的空间覆写
    // （老板 2026-09-22 实测：新建空间对方还没加入，顶部条却显示原空间的对方名）。
    AppLockService(db).loadProfile(spaceId: widget.spaceId).then((p) {
      if (!mounted) return;
      setState(() {
        if (_myMemberName.isEmpty) _myMemberName = p['memberName'] as String? ?? '';
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
      // 本端 memberId（向导登记时确定）：种入归属判定映射，离线启动也能
      // 按 member 维度分左右分栏（服务器离线拉不到 entrance→member 映射）
      memberId: widget.memberId,
    );
    // 头像加载要在 _repo 就绪后（重启路径要靠它反查本机 memberId）
    _loadMyAvatar();
    _loadInitial();
    _scrollController.addListener(_maybeLoadOlder);
    _inputFocusNode.addListener(_onInputFocusChanged);
    _loadBurnLabel();
    _refreshPinStatus();
    _refreshNotifyEmail(); // 菜单项「邮件通知」的当前值（拉不到就保持 null，不显示）
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
    _startRealtime();
    // 其它空间的未读：30s 问一次（WS 只管当前空间，别的收不到实时事件）
    _unreadTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => unawaited(_refreshOtherUnread()));
    unawaited(_refreshOtherUnread());
  }

  /// 顶部栏的通话按钮：发起呼叫（振铃界面由状态监听弹出）。
  void _startVoiceCall() {
    unawaited(_voiceCall?.invite());
  }

  /// 通话信令（Server 哑转发 call.*，PROTOCOL.md §8.4）：交给通话服务处理。
  void _onCallSignal(WsCallEvent event) {
    unawaited(_voiceCall?.handleRemote(event));
  }

  bool _callSheetShown = false;

  /// 通话状态变化：振铃（来电/去电）时弹出通话界面；结束由界面自己关。
  void _onVoiceCallStateChanged() {
    final call = _voiceCall;
    final s = call?.state.value;
    if (call == null || s == null) return;
    final shouldShow =
        s.phase == VoiceCallPhase.calling || s.phase == VoiceCallPhase.ringing;
    if (!shouldShow || _callSheetShown) return;
    _callSheetShown = true;
    unawaited(
      showVoiceCallDialog(context, call: call, peerName: _peerName)
          .whenComplete(() => _callSheetShown = false),
    );
  }

  /// 通话结束：顶部提示条说明怎么结束的（未接/拒接/忙线/结束），并回到空闲。
  ///
  /// 注意：不做后台呼入，所以「对方没接」是常态——文案必须说清是"没接"而不是"坏了"。
  void _onCallEnded(VoiceCallEndReason reason, bool wasCaller, Duration? duration) {
    final l10n = AppLocalizations.of(context)!;
    final message = switch (reason) {
      VoiceCallEndReason.hungUp => l10n.voiceCallEnded,
      VoiceCallEndReason.canceled => l10n.voiceCallEndedCanceled,
      VoiceCallEndReason.declined => l10n.voiceCallEndedDeclined,
      VoiceCallEndReason.busy => l10n.voiceCallEndedBusy,
      VoiceCallEndReason.timeout => l10n.voiceCallEndedNoAnswer,
      VoiceCallEndReason.failed => l10n.voiceCallEndedFailed,
    };
    final overlay = Overlay.of(context, rootOverlay: true);
    showTopNoticeOn(overlay, message);
    unawaited(_recordCallInChat(reason, wasCaller, duration));
    _voiceCall?.reset();
  }

  /// 通话记录：往聊天流发一条 `system` 消息（对端靠正常同步看到，即"双向同步"）。
  ///
  /// **一通电话只发一条**，否则两端各插一条就成了双份。分工：
  /// - 主叫方（`wasCaller`）负责：正常结束、取消、超时未接、连接失败；
  /// - 被叫方负责：拒接与忙线——这两件事只有他自己知道，主叫只看到"没接"。
  ///
  /// 明文留空：**文案由各自客户端按自己的语言渲染**（meta 里只放结果与时长），
  /// 不然就把一方的语言塞给了另一方。
  Future<void> _recordCallInChat(
    VoiceCallEndReason reason,
    bool wasCaller,
    Duration? duration,
  ) async {
    final state = switch (reason) {
      VoiceCallEndReason.hungUp => kCallStateCompleted,
      VoiceCallEndReason.canceled => kCallStateCanceled,
      VoiceCallEndReason.timeout => kCallStateMissed,
      VoiceCallEndReason.failed => kCallStateFailed,
      VoiceCallEndReason.declined => kCallStateDeclined,
      VoiceCallEndReason.busy => kCallStateBusy,
    };
    final mine = switch (reason) {
      // 拒接/忙线只有被叫方知情 → 由被叫方发
      VoiceCallEndReason.declined || VoiceCallEndReason.busy => !wasCaller,
      _ => wasCaller,
    };
    if (!mine) return;
    try {
      await _repo.send(
        '',
        type: 'system',
        meta: <String, dynamic>{
          kMetaCallState: state,
          if (duration != null) kMetaCallDurationSeconds: duration.inSeconds,
        },
        onPersisted: (_) => _refreshLocal(),
      );
      await _refreshLocal();
    } catch (_) {
      // 记录没写进去不影响通话本身（也不该为此弹错误打扰用户）
    }
  }

  /// 对端上下线（Server 广播——立即更新对方在线状态，不等 30s 轮询）。
  void _onPeerStatus(WsPeerStatusEvent event) {
    if (event.entranceId == widget.entranceId) return; // 本通道自身的事件忽略
    // 与我同身份的通道（我自己的另一条）不算"对方"（新服务端已不推这类广播，
    // 这里兜住旧服务端——旧 payload 无 member_id 时按原行为处理）
    if (event.memberId != null && event.memberId == widget.memberId) return;
    final online = event.type == kWsTypePeerOnline;
    // 对方刚上线（多半是刚加入本空间）：initState 那次 /space 只有我一人，
    // 对方的名字/性别/身份槽位都还是空 → 同性别两人气泡会是同一个颜色
    // （老板 2026-09-22 实测）。这里补拉一次把身份补齐。
    if (online && !_peerOnline) unawaited(_refreshProfileFromServer());
    if (mounted && online != _peerOnline) setState(() => _peerOnline = online);
  }

  /// 群聊一期：新**身份**入网（member.joined）——成员数 +1，立刻重拉 /space 刷新
  /// 成员名单与顶部条（否则要等下一次轮询/重启才看到新人）。
  void _onMemberJoined(WsMemberJoinedEvent event) {
    unawaited(_refreshProfileFromServer());
  }

  /// 群聊一期：duo → group 升格（space.upgraded）——单向不可逆、通话停用。
  ///
  /// 升格只有发起邀请的那一方看到确认弹窗，其他成员靠这一帧知情。
  /// **文案落顶部提示而不是聊天流**：消息是 E2EE，服务端伪造不了密文，客户端
  /// 也没有"本地-only 系统消息"的落库通路（硬造一条会污染 seq/同步语义）——
  /// 与 passphrase.rotated 同口径（2026-10-04 定）。待二期有本地系统消息设施
  /// 再升格为常驻消息。
  void _onSpaceUpgraded(WsSpaceUpgradedEvent event) {
    if (!mounted) return;
    setState(() => _spaceMode = 'group');
    showTopNotice(context, AppLocalizations.of(context)!.chatPageMembersUpgraded);
    unawaited(_refreshProfileFromServer());
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
    // 头像：无论改名还是换头像都刷一次（同一 per-member 头像文件可能已变）
    _MessageAvatarState.invalidate(event.memberId);
    unawaited(_loadPeerAvatar()); // 状态条那份（自己存 bytes，不走上面那个缓存）
    _refreshProfileFromServer();
    final name = event.memberName;
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _peerName = name);
  }

  /// 对方回执更新（Server 广播 receipt.updated）：落库为已送达/已读高水位。
  /// **本轮不显示**——只为把数据打通，供将来 UI 使用（老板 2026-09-12）。
  void _onReceiptUpdated(WsReceiptUpdatedEvent event) {
    unawaited(_repo
        .upsertPeerReceipt(
          memberId: event.memberId,
          deliveredUptoSeq: event.deliveredUptoSeq,
          readUptoSeq: event.readUptoSeq,
        )
        .then((_) => _loadPeerReceipts()));
  }

  /// 从服务端校正双方名字与性别（GET /space 的 memberNames/memberGenders）。
  /// 本机 profile 只是入网时的快照：对方改名后若没收到广播（或广播前就重启），
  /// App 会一直显示旧名字（老板 2026-09-11 实测）；性别同理（v2 早期把对方性别
  /// 写死空串 → 气泡回退灰色）。启动与收到 profile.updated 时调用
  /// （对齐 CLI 的 _refreshMemberNames）。
  Future<void> _refreshProfileFromServer() async {
    if (!mounted || _session.token.isEmpty || effectiveServer.isEmpty) return;
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final space = await _withAuth((t) => api.getSpace(t));
      // 重启（PIN 解锁）路径不传 memberId（main.dart 只还原明文 payload）——
      // 从 /space 的通道表里按 entranceId 反查，否则拿不到"我"，校正无从下手
      var mine = widget.memberId;
      if (mine == null || mine.isEmpty) {
        for (final d in space.entrances) {
          if (d.entranceId == widget.entranceId) {
            mine = d.memberId;
            break;
          }
        }
      }
      if (mine == null || mine.isEmpty) return;
      // 反查到的本机 memberId 落地：头像加载/上传后的缓存失效都要用它
      // （重启路径 widget.memberId 为空，否则上传头像后消息流不刷新）
      final mineChanged = _myMemberId != mine;
      _myMemberId = mine;
      // 启动时没有 memberId（重启路径）或反查值与服务器不一致 → 重拉头像
      if ((mineChanged || _myAvatarBytes == null) && mounted) unawaited(_loadMyAvatar());
      final myG = space.memberGenders[mine] ?? '';
      var peerG = '';
      var peerName = '';
      var peerId = '';
      for (final entry in space.memberNames.entries) {
        if (entry.key == mine) continue;
        peerName = entry.value;
        peerG = space.memberGenders[entry.key] ?? '';
        peerId = entry.key;
        break;
      }
      final myName = space.memberNames[mine] ?? '';
      // 群聊一期（2026-10-03）：全成员资料快照——群空间的顶部条名单、逐条消息
      // 的发送者名字、成员管理弹层都从这里取；duo 的 _peerName/_peerGender 原
      // 字段继续走原逻辑（下方"第一个非我成员"对 duo 仍等价于唯一对方）。
      _memberSlots
        ..clear()
        ..addAll(space.memberSlots); // 含未命名成员（memberNames 会漏）
      _memberNames
        ..clear()
        ..addAll(space.memberNames);
      _spaceMode = space.mode;
      _maxMembers = space.maxMembers;
      // 身份槽位（0=第一人/创建者，1=第二人）：同性别第二人气泡取青色的判据
      // （老服务端 member_slots 为空表 → 保持 null，不启用青色）
      final mySlot = space.memberSlots[mine];
      final peerSlot = peerId.isEmpty ? null : space.memberSlots[peerId];
      if (!mounted) return;
      setState(() {
        if (myName.isNotEmpty) _myMemberName = myName;
        if (peerName.isNotEmpty) _peerName = peerName;
        if (peerId.isNotEmpty && peerId != _peerMemberId) {
          _peerMemberId = peerId; // 状态条头像要用
          unawaited(_loadPeerAvatar());
        }
        if (myG.isNotEmpty) _myGender = myG;
        if (peerG.isNotEmpty) _peerGender = peerG;
        _mySlot = mySlot;
        _peerSlot = peerSlot;
      });
      // 校正结果回写本地快照：否则下次启动（尤其离线）又用回入网时的旧值
      // （setState 只覆盖非空值，故不会把已有名字写成空）；按 spaceId 写，仅落当前空间
      await AppLockService(widget.db ?? LocalDatabase.shared).saveProfile(
        spaceId: widget.spaceId,
        memberName: _myMemberName,
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
    if (!mounted || _session.token.isEmpty || effectiveServer.isEmpty) return;
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final snap = await _withAuth((t) => api.getKeyEscrow(t));
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

  /// 本页所有**带鉴权**的请求的统一入口：走本空间的会话（401 自动续期 + 重试一次），
  /// 并把"被撤销 / 服务器不认这条通道"的副作用补上（会话层只负责续期，不碰 UI 与数据清理）。
  ///
  /// 为什么必须有它：会话 24h 过期后，只有同步/WS 会续期（各写自己那份 token），
  /// 而头像上传/改名/开通码/更多通道/未读角标这些**直接请求**原来拿的是构造时固化的
  /// `widget.token` → 全部 401「invalid session」且重启不恢复（2026-09-26 老板实测）。
  Future<T> _withAuth<T>(Future<T> Function(String token) fn) async {
    try {
      return await _session.call(fn);
    } on ApiException catch (e) {
      await _handleAuthError(e);
      rethrow;
    }
  }

  /// 续期失败时的副作用（`ENTRANCE_REVOKED` → 自毁；`FORBIDDEN` → 常驻提示），
  /// 由 [_withAuth] 与 [_reauthWithRevokedFallback] 共用。
  Future<void> _handleAuthError(ApiException e) async {
    if (e.code == 'ENTRANCE_REVOKED') {
      await _onEntranceRevoked();
    } else if (e.code == 'FORBIDDEN' && mounted && !_entranceUnrecognized) {
      setState(() => _entranceUnrecognized = true);
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
  ///
  /// 去重（同时多处 401 只发一次 challenge）在 [SpaceSession.renew] 里。
  Future<String> _reauthWithRevokedFallback() async {
    try {
      return await _session.renew();
    } on ApiException catch (e) {
      await _handleAuthError(e);
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
    SpaceSessions.forget(widget.spaceId); // 凭证已删：会话（含 refresh 闭包）一并丢掉
    if (!mounted) return;
    showTopNotice(context, AppLocalizations.of(context)!.chatPageEntranceRevoked);
    // 还有其他空间 → 切到下一个；一个都不剩 → 回向导（2026-09-24：不再一律回向导，
    // 多空间下被撤销的只是一条通道，其他秘境应当照常可用）。
    final vault = VaultSession.current;
    final next = vault == null
        ? null
        : await AppLockService(db).resolveActivePayload(vault);
    if (!mounted) return;
    if (next == null) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SetupPage()),
        (route) => false,
      );
      return;
    }
    await switchToSpace(context, next.spaceId, db: widget.db);
  }

  /// 重建轮询 ticker（WS 状态变化时切换间隔）。
  void _restartTicker(Duration interval) {
    _ticker?.cancel();
    _currentTickerInterval = interval;
    _ticker = Timer.periodic(interval, (_) => _onTick());
  }

  /// 其它空间未读的合计（顶部角标显示这个）。
  int get _otherUnreadTotal =>
      _otherUnread.values.fold(0, (int sum, int n) => sum + n);

  /// 拉取**其它空间**的未读数（当前空间不算——它正在眼前，不需要角标提醒）。
  ///
  /// 为什么要单独拉：WS 只连着当前空间，其它空间的消息**收不到实时事件**，
  /// 只能定时问一次（30s）。未读角标不需要秒级实时，这个延迟可以接受。
  ///
  /// 只更角标、**不再响提示音**（老板 2026-09-27：取消其它空间来消息的声音）。
  Future<void> _refreshOtherUnread() async {
    final vault = VaultSession.current;
    final spaces = vault?.spaces ?? const <AppLockPayload>[];
    if (spaces.length < 2) return; // 只有一个空间就没什么"其它"可言
    final client = widget.api ?? ApiClient(effectiveServer);
    for (final space in spaces) {
      if (space.spaceId == widget.spaceId) continue;
      if ((space.token ?? '').isEmpty) continue;
      // 走**各空间的会话**（不是裸 token）：会话 24h 过期，直接用 Vault 里的旧
      // token 会 401 → 未读静默变 0（space_switcher 里同样处理过，2026-09-26 修）
      final count = await SpaceSessions.ofPayload(space, db: widget.db)
          .call((t) => client.unreadCount(t))
          .catchError((_) => 0);
      _otherUnread[space.spaceId] = count;
    }
    if (!mounted) return;
    setState(() {});
  }

  /// 建立 / 重连实时链路（WS + 通话服务）。
  ///
  /// 首次进入与**回到前台**都走这里（后台时我们主动断开，见
  /// [didChangeAppLifecycleState]）。[VoiceCallService] **只创建一次**——它持有
  /// 通话状态与 WebRTC 连接，重建会把正在进行的通话弄丢。
  void _startRealtime() {
    if (!widget.enableWs) return;
    final ws = _ws ??
        WsRealtimeService(
          server: effectiveServer,
          token: widget.token,
          reauth: widget.reauth == null ? null : _reauthWithRevokedFallback,
        );
    _ws = ws;
    if (_voiceCall == null) {
      ws.connected.addListener(_onWsStatusChanged);
      final call = VoiceCallService(ws: ws)..onEnded = _onCallEnded;
      _voiceCall = call;
      call.state.addListener(_onVoiceCallStateChanged);
    }
    ws.start(
      // WS 实时新消息：标记为 realtime，允许把消息标为"已读"（下面的补拉路径
      // 只标"已送达"——老板 2026-09-12：补拉的历史不等于人看过）
      onMessageNew: () => _refresh(realtime: true),
      onEntranceRevoked: _onEntranceRevoked,
      onPeerStatus: _onPeerStatus,
      onPassphraseRotated: _onPassphraseRotated,
      onProfileUpdated: _onProfileUpdated,
      onReceiptUpdated: _onReceiptUpdated,
      onCall: _onCallSignal,
      // 群聊一期（2026-10-03）：新身份入网 / 空间升格为群聊
      onMemberJoined: _onMemberJoined,
      onSpaceUpgraded: _onSpaceUpgraded,
    );
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
    await showOptionPickerSheet<void>(
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
    await showOptionPickerSheet<void>(
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

  /// 菜单行右侧「当前值」：超过 [kMenuValueMaxWidth] 即省略号、右对齐。
  ///
  /// 名字 / 通道名是用户可任意填的长文本，原先直接 `Text(value)` 无上限 → 撑破
  /// PopupMenu（老板 2026-09-24 实测 `right overflowed by 69 pixels`）。这里收口：
  /// **整菜单所有带值的行共用同一个上限**，不逐行各设一个数。
  Widget _menuValue(String value, TextStyle style) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kMenuValueMaxWidth),
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.end,
          style: style,
        ),
      );

  

  /// 是否有 2 个及以上空间（决定要不要给「切换秘境」入口）。
  ///
  /// 取自内存里已解锁的 [VaultSession]（不触安全存储、不需要 PIN）；取不到时
  /// （如测试直接构造 ChatPage）按单空间处理——最保守：单空间往往就是想和一个人用，
  /// 别暗示这里能切（老板 2026-09-24 定）。
  bool get _multiSpace => (VaultSession.current?.spaces.length ?? 0) > 1;

  /// 顶栏的「品牌名（+ 下拉箭头）」这一块。
  ///
  /// 多空间时整块可点 → 打开「切换我的秘境」弹层，箭头紧贴在标题文字右侧
  /// （老板 2026-09-28：原先是独立 IconButton，自带的 8px 内边距把箭头推得很远，
  /// 不像和标题是一体的）。单空间时不画箭头、也不可点（别暗示这里能切）。
  Widget _brandTitle() {
    final l10n = AppLocalizations.of(context)!;
    final titleRow = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(l10n.chatPageTitleBrand,
                style: const TextStyle(fontSize: 17),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          // 颜色继承 AppBar 的 IconTheme（AppBar 给整个 toolbar 套了 IconTheme.merge）
          if (_multiSpace) ...[
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ],
      ),
    );
    if (!_multiSpace) return titleRow;
    return Tooltip(
      message: l10n.spaceListSwitch,
      child: InkWell(mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(10),
        onTap: _openSpacePicker,
        child: titleRow,
      ),
    );
  }

  /// 状态条上的头像。
  ///
  /// 边长 = [kStatusAvatarSize]：跟随"名字 + 红绿灯"两行的高度，**上下不留白**，
  /// 看着像嵌在胶囊两端（老板 2026-09-26）。
  ///
  /// - 没设头像时，底色按**性别**取淡粉/淡蓝（与空间卡片、状态芯片同一组色），
  ///   未登记性别回退淡灰；
  /// - 有头像时可点开**全屏大图**（老板 2026-09-26）。
  Widget _statusAvatar({Uint8List? bytes, String gender = '', VoidCallback? onTap}) {
    return _StatusAvatar(
      bytes: bytes,
      tint: _genderTint(gender),
      // 默认：有头像才可点（看大图）；本人那头像由调用方传入 onTap（空头像也能点）
      onTap: onTap ??
          (bytes == null ? null : () => unawaited(_showAvatarFullscreen(bytes))),
    );
  }

  /// 性别底色：淡粉（女）/ 淡蓝（男）/ 淡灰（未登记）。
  /// 用**预乘到白的不透明色**，与状态芯片、空间卡片同一组（品牌粉 #D6529C /
  /// 品牌天蓝 #3BAFFD 的 18% tint）——半透明 tint 叠在 85% 白的胶囊上会透出背景
  /// 混色、观感发脏（老板 2026-09-25 模拟器实测）。
  Color _genderTint(String gender) {
    if (gender == 'female') return const Color(0xFFF8E0ED);
    if (gender == 'male') return const Color(0xFFDCF1FF);
    return const Color(0xFFF1F1F1);
  }

  /// 全屏看头像大图（点状态条上的头像触发）。
  ///
  /// [allowReplace]：**本人的**头像为 true → 大图底部多一个「更换头像」按钮
  /// （点了关掉大图再进选图流程）。这样"点头像"这一个动作既能看、也能换，
  /// 不用再回菜单里找那一项（老板 2026-09-26）。对方的头像不给这个按钮——
  /// 我们没有权限改别人的头像。
  Future<void> _showAvatarFullscreen(Uint8List bytes, {bool allowReplace = false}) async {
    await withImmersiveFullscreen(() => showDialog<void>(
          context: context,
          barrierDismissible: true,
          useSafeArea: false,
          builder: (ctx) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            child: SizedBox.expand(
              child: DecoratedBox(
                decoration: const BoxDecoration(gradient: kBrandGradient),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Clickable(
                        onTap: () => Navigator.of(ctx).pop(),
                        child: InteractiveViewer(
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Image.memory(bytes, fit: BoxFit.contain),
                            ),
                          ),
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
                    if (allowReplace)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 32,
                        child: Center(
                          child: FilledButton.icon(
                            // 先关大图再进选图：不关的话选图弹层会叠在它上面，
                            // 取消选图后回到一张"已经没意义"的大图（头像还没换）
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              unawaited(_showAvatarUpload());
                            },
                            icon: const Icon(Icons.photo_camera_outlined),
                            label: Text(
                                AppLocalizations.of(ctx)!.chatPageAvatarChange),
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

  /// 状态灯 + 时刻（老板 2026-09-26 新设计）：**绿灯旁是上线时间、红灯旁是下线时间**。
  ///
  /// [sinceMs] 缺失（还没问到 / 服务端没给）就只留灯：宁可少显示，也不摆一个假的
  /// 00:00。格式复用 [_timeStampLabel]——当天 `HH:MM`、当年 `mm-dd HH:MM`、跨年带年份。
  /// [label] 用于"既不在线也不是普通离线"的状态（当前只有**对方尚未加入**）：
  /// 灯变灰、右侧显示这个短标签而不是时间（老板 2026-09-26：未加入时时间没有意义，
  /// 摆一个"上次离线时间"反而误导）。
  Widget _statusLine({
    required bool online,
    required Color offlineColor,
    int? sinceMs,
    String? label,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 8,
            color: label != null ? Colors.grey : (online ? Colors.green : offlineColor)),
        if (label != null) ...[
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),
        ] else if (sinceMs != null && sinceMs > 0) ...[
          const SizedBox(width: 4),
          Text(
            _timeStampLabel(sinceMs),
            style: TextStyle(
              fontSize: 11,
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),
        ],
      ],
    );
  }

  /// 顶栏状态条左侧的「对方」这一块。
  ///
  /// - **2 个及以上空间** → 做成可按芯片（底色按对方性别取**淡粉/淡蓝** + 右侧圆角
  ///   + 下拉箭头），一点打开「选择秘境」弹层（老板 2026-09-24：省掉「☰ → 眼扫菜单 →
  ///   点切换」，与微信「左上角返回→选人」同一肌肉记忆）。位置放**对方名字**旁：空间
  ///   卡片上显示的就是对方名字，语义同源。
  /// - **只有 1 个空间** → 纯"圆点 + 名字"，**不给箭头、不给底色**（老板 2026-09-24：
  ///   单空间往往就是想和一个人用，别暗示这里能切；真要加空间去汉堡菜单里找）。
  ///
  /// 空间数取自内存里已解锁的 [VaultSession]（不触安全存储、不需要 PIN）；
  /// 取不到时（如测试直接构造 ChatPage）按单空间处理——最保守，入口仍在菜单里。
  Widget _buildPeerStatus(AppLocalizations l10n) {
    // 左/上/下都 0：这一格以**头像**打头，头像要**三面贴住胶囊内壁**（老板
    // 2026-09-26）；右 10 给箭头/右缘留白。行高由头像决定，头像即贴边。
    const pad = EdgeInsets.fromLTRB(0, 0, 10, 0);
    // 芯片内容**只到箭头为止**（老板 2026-09-25）：「邀请加入」链接在芯片外
    // 并排（见本方法末尾）——否则点它到底是邀请还是切换空间说不清。
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 对方头像放**最左**（老板 2026-09-26 新设计）；没设头像时底色按性别
        _statusAvatar(bytes: _peerAvatarBytes, gender: _peerGender),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_statusTitle.isNotEmpty)
                Flexible(
                  child: Text(_statusTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // 15 号：要**明显大于**下面的状态行（11）但不喧宾夺主——
                      // 名字是这一格的主信息，原来 13 与 11 几乎看不出主次
                      // （老板 2026-09-26）
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                ),
              const SizedBox(height: 1),
              // 绿灯旁是上线时间、红灯旁是下线时间（老板 2026-09-26 设计）；
              // **对方尚未加入**时灯变灰、右侧显示「待加入 / Waiting」——时间对
              // 未加入的人没有意义，摆个"上次离线时间"反而误导（老板 2026-09-26）
              _statusLine(
                online: _peerOnline,
                offlineColor: Colors.red,
                sinceMs: _peerSinceMs,
                label: _peerJoined == false ? l10n.spaceListPeerPending : null,
              ),
            ],
          ),
        ),
        // 切换秘境的入口**不在这里**——已挪到顶部标题栏「logo + 我的秘境」右侧
        // （老板 2026-09-26：挂在对方名字旁边，点它等于"要换掉对方"，有点伤人）。
      ],
    );

    final Widget inviteLink = _peerJoined != false
        ? const SizedBox.shrink()
        : Material(
            color: Colors.transparent,
            shape: const StadiumBorder(), // 胶囊：随状态条高度自适应（写死 24 会变圆角矩形）
            clipBehavior: Clip.antiAlias, // 让 ink 跟着圆角裁
            child: InkWell(mouseCursor: SystemMouseCursors.click,
              // 群聊一期（2026-10-03）：purpose 必传——这一块是"邀请对方来这个
              // 秘境"，必须是 invite（开新身份）。漏传会退化成 channel（绑定
              // 我自己的身份），对方拿去加入就变成"我"（2026-10-04 审查实测）。
              onTap: () => _showInviteDialog(purpose: 'invite'),
              // 与「我的」状态芯片同一档（那块也没有常驻底色）
              hoverColor: Colors.black.withValues(alpha: 0.05),
              highlightColor: Colors.black.withValues(alpha: 0.08),
              child: Padding(
                // **不能共用左块的 `pad`**（那个是给头像定制的：左/上/下都是 0，
                // 好让头像三面贴住胶囊内壁）。共用会让这里的左内边距变成 0——
                // 按住时的底色紧贴着 "I"（老板 2026-09-26 实测）。
                // 文字链接用左右**匀称**的留白，底色两边都留得出来。
                padding: const EdgeInsets.symmetric(horizontal: 12),
                // 背景高度取控件的统一值（32）而不是头像的 40：胶囊形是满高直边，
                // 撑到 40 会直接贴住状态条的上下边缘（老板 2026-09-26 实测）
                child: SizedBox(
                  height: kStatusControlSize,
                  child: Center(
                    child: Text(l10n.chatPageInviteJoinLink,
                        style: const TextStyle(
                            fontSize: 12,
                            // 链接蓝 = 品牌深蓝 #2271F7，与开通码弹窗里那条邀请链接
                            // （本文件 `_showInviteDialog`）同一个蓝，语义同源。
                            color: Color(0xFF2271F7))),
                  ),
                ),
              ),
            ),
          );
    // 「语音通话」：对方**已加入**才挂（未加入时这块位置让给「邀请加入」——
    // 两个互斥，见下面的 `trailing`）。与 invite 同口径：常态无底色、同一档
    // hover/highlight、同一个 `pad`、同一个 24 圆角；蓝色电话图标（品牌深蓝
    // #2271F7 与 invite 链接同源），文字省掉——电话图标语义够明确，状态条也挤。
    //
    // 群聊一期（2026-10-03）：**群空间不挂**——群内通话一期不做，服务端也会
    // 静默丢弃 call.* 信令（挂出来点了没人接，只能干等超时）。
    final Widget callButton = _peerJoined == true && !_isGroup
        ? Tooltip(
            message: l10n.voiceCallMenuCall,
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(), // 真圆：状态条加高后 24 圆角成了圆角矩形
              clipBehavior: Clip.antiAlias,
              child: InkWell(mouseCursor: SystemMouseCursors.click,
                onTap: _startVoiceCall,
                hoverColor: Colors.black.withValues(alpha: 0.05),
                highlightColor: Colors.black.withValues(alpha: 0.08),
                child: const SizedBox(
                  width: kStatusAvatarSize,
                  height: kStatusAvatarSize,
                  child: Icon(Icons.call_outlined,
                      size: 20, color: Color(0xFF2271F7)),
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    // 芯片右侧挂一块：**未加入=邀请加入 / 已加入=语音通话**（老板 2026-09-26）。
    // 对方加入状态未知（null）时两块都不挂——与 invite 原本的口径一致，
    // 避免进页面先闪一下。
    final Widget trailing = _peerJoined == false ? inviteLink : callButton;

    // 芯片包 Flexible：本 Row 处于状态条 Flexible 的有界宽度里，非 flex 子项会被
    // Row 放到无界宽度 → 长名字不再被省略、冲出胶囊（长名字回归测试 2026-09-24）。
    // Flexible 让芯片先让出链接的宽度，剩下的给芯片内部继续省略。
    // 芯片**已去掉**（老板 2026-09-26）：对方这一格不再是"整块可按 + 常驻底色"的
    // 芯片，切换空间的入口交给箭头自己（见 content 里那个箭头按钮）。这样底色不再
    // 与头像的性别底色打架，也不会让人误以为点名字/头像能切换空间。
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: Padding(padding: pad, child: content)),
      // 与「名字/状态」的间距：靠 pad.right(10) + Invite 自带的内边距(12) = 22px。
      // **两侧要一样宽**（老板 2026-09-26）——此前这里额外加了 12px，导致对方一侧
      // 的间距（34）明显比我方（22）宽，看着不匀。
      trailing,
    ]);
  }

  /// 「切换空间」：弹「选择秘境」弹层（小卡片瀑布流）→ 选中即**直接换到那个空间**（不跳页）。
  /// 弹层底部还有「＋ 新建/加入空间」通往第一屏（需要先过一次锁屏码，见 addSpaceFlow）。
  ///
  /// 不再需要 `onSwitchSpace` / `onManageSpaces` 这类"由入口注入"的回调：切换空间**不需要
  /// 锁屏码**（当前空间落明文键），其它空间的凭证在内存会话 [VaultSession] 里。
  Future<void> _openSpacePicker() async {
    final pick = await showSpacePicker(context, db: widget.db, api: widget.api);
    // 弹层关掉后刷新一次未读（可能刚切过空间，也可能只是看了看）
    unawaited(_refreshOtherUnread());
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
      // 允许用满窗高（与「我的通道」等弹层同口径，老板 2026-10-02）
      isScrollControlled: true,
      builder: (_) => UiStylePickerSheet(
        settings: UiStyleSettings(widget.db ?? LocalDatabase.shared),
      ),
    );
  }

  /// 开通通道：生成一次性 join token（POST /spaces/{id}/join-tokens，Multiverse
  /// v2，24h 一次性、需本人会话认证；旧 v1 createInvite 已废弃，不再生成 v1 邀请码）。
  /// 二维码与展示内容 = 邀请链接（`https://einz.tic.cc/join/<token>`），对方 App/
  /// CLI 可扫码或粘贴链接加入；口令由对方加入时另行输入（降级 B，与 TUI 一致）。
  ///
  /// [purpose]（群聊一期 2026-10-03）：`invite` = 邀请新成员（开新身份；duo 满员
  /// 后签发即自动升格 group）；`channel` = 我本人在另一台设备接入（绑定我的身份）。
  /// **必传**：两种码语义相反，share 错一种等于把对方变成我（2026-10-04 审查
  /// 实测的 P0）。弹窗内「重新生成」必须沿用同一个 purpose。
  Future<void> _showInviteDialog({required String purpose}) async {
    // 老板决策：点顶栏添加按钮直接生成开通码（不再先弹"开通通道"确认窗）
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      var r = await _withAuth((t) => api.createJoinToken(widget.spaceId, t, purpose: purpose));
      if (!mounted) return;
      // 「重新生成」进行中的标记（放在 builder 外：StatefulBuilder 用箭头函数，没地方声明）
      var busy = false;
      final l10n = AppLocalizations.of(context)!;
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            // 标题居中（老板 2026-09-25：菜单下的弹窗标题一律居中，不居左）——
            // 与底部弹层的标题口径一致（Center；正文/字段仍靠左）
            title: Center(child: Text(l10n.chatPageInviteDialogTitle)),
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
                    final fresh = await _withAuth(
                        (t) => api.createJoinToken(widget.spaceId, t, purpose: purpose));
                    if (!ctx.mounted) return;
                    r = fresh; // 就地刷新：二维码 / 开通码 / 链接 ✓
                    setLocal(() {});
                  } on ApiException catch (e) {
                    if (!ctx.mounted) return;
                    showTopNotice(
                        ctx, backendError(l10n, l10n.chatPageInviteFailed(e.message)));
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
    } on ApiException catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      showTopNotice(context, backendError(l10n, l10n.chatPageInviteFailed(e.message)));
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
      token: _session.token, // 会话里的**当前** token（不写旧副本进锁包）
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

  /// 「邮件通知」菜单项右侧的当前值（没设置/没拉到 → null，不显示）。
  Widget? _notifyMenuValue(AppLocalizations l10n, TextStyle valueStyle) {
    final status = _notifyEmail;
    if (status == null || status.isNone) return null;
    if (status.isVerified) return _menuValue(l10n.chatPageNotifyOnValue, valueStyle);
    if (status.isPending) return _menuValue(l10n.chatPageNotifyPendingValue, valueStyle);
    return _menuValue(l10n.chatPageNotifyOffValue, valueStyle); // inactive（已退订/硬退信）
  }

  /// 拉取邮件通知状态（GET /notify/email）。best-effort：拉不到就保持原值/null——
  /// 它是菜单上一个装饰性的当前值，不值得为它弹任何错误（老板 2026-09 定的
  /// "可观测性放代码里，不放 UI"）。
  ///
  /// 刷新时机（**翻转只可能发生在 App 外面**，所以光靠 initState 一次不够）：
  ///   · initState
  ///   · 从后台回到前台（去浏览器点链接再回来，是最常见的那条路径）
  ///   · 打开设置弹窗前
  ///   · 保存/停用之后
  ///   · 还停在"待确认"时每 20s 轮询一次（见 [_syncNotifyTicker]，翻了就停）
  Future<void> _refreshNotifyEmail() async {
    if (!mounted || _session.token.isEmpty || effectiveServer.isEmpty) return;
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final status = await _withAuth((t) => api.getNotifyEmail(t));
      if (!mounted) return;
      setState(() => _notifyEmail = status);
      _syncNotifyTicker();
    } catch (_) {
      // 离线/服务端未启用：保持未知
    }
  }

  /// 只在 `pending` 期间挂着 20s 的轮询：等那封确认邮件被点开。
  /// 一旦翻转（生效/没设置/已关闭）就撤掉——不给一个只在极少数时候有用的值常驻轮询。
  void _syncNotifyTicker() {
    final pending = _notifyEmail?.isPending ?? false;
    if (pending && _notifyTicker == null) {
      _notifyTicker = Timer.periodic(const Duration(seconds: 20), (_) {
        unawaited(_refreshNotifyEmail());
      });
    } else if (!pending && _notifyTicker != null) {
      _notifyTicker?.cancel();
      _notifyTicker = null;
    }
  }

  /// 把邮箱通知设置**扇出到本机所有空间**（老板 2026-10-01 定：通知按设备共享，
  /// 不按空间各设各的）。逐空间走它自己的会话调 [action]（PUT/DELETE），
  /// 全部 best-effort：某个空间会话过期/离线拉不到就跳过，不影响其它空间，
  /// 也不打扰用户（与 _refreshNotifyEmail 同一条"装饰性功能不弹错"原则）。
  ///
  /// 服务端按**地址**聚合验证状态（notify_emails.verified_at），同一地址在别的
  /// 空间已验证过时 PUT 直接返回 verified、不重发确认信——扇出因此是便宜的。
  Future<void> _fanoutNotifyEmail(Future<void> Function(String token) action) async {
    final vault = VaultSession.current;
    final spaces = vault?.spaces ?? const <AppLockPayload>[];
    if (spaces.length < 2) return;
    for (final space in spaces) {
      if (space.spaceId == widget.spaceId) continue; // 当前空间已由调用方处理
      if ((space.token ?? '').isEmpty) continue;
      try {
        // 走各空间的会话（同 _refreshOtherUnread）：直接用 Vault 里的旧 token 会 401
        await SpaceSessions.ofPayload(space, db: widget.db).call(action);
      } catch (_) {
        // 单个空间失败不阻塞其余空间
      }
    }
  }

  /// 邮件通知设置（菜单项，2026-10-01）：填邮箱 → 服务端发一封确认信 → 点信里链接生效。
  ///
  /// **必须把"已填但没确认"这一档显示出来**：否则用户填完以为已经开了，其实一封也收不到。
  /// 已设置时额外给一个「停用」（DELETE），不给"改地址"以外的第二入口（改地址＝重填再保存）。
  Future<void> _showNotifyDialog() async {
    final l10n = AppLocalizations.of(context)!;
    // 开弹窗前先拉一次最新状态：它可能已经在 App 外面被翻转（确认邮件点过了），
    // 而缓存的 `_notifyEmail` 还停在旧值上——照旧值弹窗会把用户带偏（比如又显示一遍
    // "待确认"，或者输入框里填着已经被删掉的地址）。
    await _refreshNotifyEmail();
    if (!mounted) return;
    final before = _notifyEmail;
    final ctrl = TextEditingController(text: before?.email ?? '');
    // 红字警示（空/格式不对/后台失败）与提交中标记，都只在弹窗内有效
    final error = ValueNotifier<String?>(null);
    final busy = ValueNotifier<bool>(false);
    // 「已设置 ↔ 未设置」两阶段（老板 2026-10-02）：已设置时输入框只读、只给「停用」；
    // 停用成功不关弹窗，原地切成空白可编辑输入框 + 「保存」。初始值取开弹窗时的状态。
    final active = ValueNotifier<bool>(!(before?.isNone ?? true));
    // 应用范围勾选（老板 2026-10-02）：回显上次勾选的持久化偏好（默认勾选＝
    // 保存/停用同步扇出到本机所有秘境，2026-10-01 起的既有行为）；不勾＝只作用于
    // 当前秘境，且新建空间不再自动继承（_inheritNotifyEmail 读同一份偏好）。
    // 服务端本来就是地址级验证 + 空间级绑定，扇不扇出纯客户端决定，不冲突。
    final allSpaces = ValueNotifier<bool>(true);
    unawaited(NotifyAllSpacesPref(widget.db ?? LocalDatabase.shared)
        .load()
        .then((v) => allSpaces.value = v));
    // 正文语言：服务端不知道收件人读哪种语言，按本机界面语言上报（zh / 其它一律 en）
    final lang = Localizations.localeOf(context).languageCode == 'zh' ? 'zh' : 'en';

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Center(child: Text(l10n.chatPageNotifyTitle)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.chatPageNotifyHint,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(ctx).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 10),
            // 已设置 → 只读（停用后由 active 切回可编辑）；未设置 → 正常输入
            ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (_, isActive, _) => TextField(
                controller: ctrl,
                readOnly: isActive,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: l10n.chatPageNotifyEmailLabel,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (error.value != null) error.value = null;
                },
              ),
            ),
            // 应用范围勾选（老板 2026-10-02）：默认勾选＝保存/停用同步到本机所有秘境
            // （原静态文案「保存后应用于本机所有秘境。」升级为可选项）。
            // 放在 Email 输入框下方（老板 2026-10-02）
            ValueListenableBuilder<bool>(
              valueListenable: allSpaces,
              builder: (_, all, _) => CheckboxListTile(
                value: all,
                onChanged: (v) {
                  final next = v ?? true;
                  allSpaces.value = next;
                  // 勾选即落盘：它是设备级默认策略（新空间继承钩子也读它），
                  // 不等点保存——关掉弹窗也应该记住
                  unawaited(NotifyAllSpacesPref(widget.db ?? LocalDatabase.shared)
                      .save(next));
                },
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  l10n.chatPageNotifyAllSpaces,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.outline,
                  ),
                ),
              ),
            ),
            // 已填但还没点链接：这一档不点明，用户会以为已经生效
            if (before?.isPending ?? false) ...[
              const SizedBox(height: 10),
              Text(
                l10n.chatPageNotifyStatePending,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(ctx).colorScheme.outline,
                ),
              ),
            ],
            ValueListenableBuilder<String?>(
              valueListenable: error,
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
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
          // 按钮互斥（老板 2026-10-02）：已设置只给「停用」，未设置只给「保存」。
          ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, isActive, _) => isActive
                ? ValueListenableBuilder<bool>(
                    valueListenable: busy,
                    builder: (_, isBusy, _) => TextButton(
                      onPressed: isBusy
                          ? null
                          : () async {
                              busy.value = true;
                              try {
                                final api = widget.api ?? ApiClient(effectiveServer);
                                await _withAuth((t) => api.deleteNotifyEmail(t));
                                if (!mounted) return;
                                // 勾选「应用于本机所有秘境」才扇出（老板 2026-10-02）；
                                // 不勾＝只停当前秘境，其它秘境的绑定原样保留
                                if (allSpaces.value) {
                                  unawaited(_fanoutNotifyEmail(
                                      (t) => api.deleteNotifyEmail(t))); // 其它空间同步撤，best-effort
                                }
                                await _refreshNotifyEmail();
                                // 不关弹窗：原地切回"未设置"态（空白可编辑 + 保存）
                                ctrl.clear();
                                active.value = false;
                              } on ApiException catch (e) {
                                if (ctx.mounted) {
                                  error.value =
                                      backendError(l10n, l10n.chatPageNotifyFailed(e.message));
                                }
                              } catch (e) {
                                if (ctx.mounted) error.value = l10n.chatPageNotifyFailed('$e');
                              } finally {
                                busy.value = false;
                              }
                            },
                      // busy 期间请求要好几秒才回，换旋转图标，同保存按钮（老板 2026-10-01）
                      child: isBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2.4),
                            )
                          : Text(l10n.chatPageNotifyStop),
                    ),
                  )
                : ValueListenableBuilder<bool>(
                    valueListenable: busy,
                    builder: (_, isBusy, _) => FilledButton(
                      onPressed: isBusy
                          ? null
                          : () async {
                              final email = ctrl.text.trim();
                              if (email.isEmpty) {
                                error.value = l10n.chatPageNotifyEmptyError;
                                return;
                              }
                              // 本机先粗筛（服务端另有 400 兜底）：只卡"有 @ 且两段都非空、不含空格"
                              if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
                                error.value = l10n.chatPageNotifyInvalidError;
                                return;
                              }
                              busy.value = true;
                              try {
                                final api = widget.api ?? ApiClient(effectiveServer);
                                final status =
                                    await _withAuth((t) => api.setNotifyEmail(email, t, lang: lang));
                                if (!mounted) return;
                                // 勾选「应用于本机所有秘境」才扇出（老板 2026-10-02）；
                                // 不勾＝只绑当前秘境，其它秘境不动
                                if (allSpaces.value) {
                                  unawaited(_fanoutNotifyEmail(
                                      (t) => api.setNotifyEmail(email, t, lang: lang))); // 其它空间同步绑，best-effort
                                }
                                await _refreshNotifyEmail();
                                if (ctx.mounted) Navigator.of(ctx).pop(true);
                                if (mounted) {
                                  showTopNotice(
                                    context,
                                    status.isVerified
                                        ? l10n.chatPageNotifyDone(email)
                                        : l10n.chatPageNotifySent(email),
                                  );
                                }
                              } on ApiException catch (e) {
                                if (ctx.mounted) {
                                  error.value =
                                      backendError(l10n, l10n.chatPageNotifyFailed(e.message));
                                }
                              } catch (e) {
                                if (ctx.mounted) error.value = l10n.chatPageNotifyFailed('$e');
                              } finally {
                                busy.value = false;
                              }
                            },
                      // busy 期间请求要好几秒才回（服务端要发确认信），换成旋转图标，
                      // 否则按钮灰着没动静，用户会以为没点上（老板 2026-10-01）
                      child: isBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2.4),
                            )
                          : Text(l10n.chatPageEmailSubmit),
                    ),
                  ),
          ),
        ],
      ),
    );
    // 对话框 route 关闭动画完成后才 dispose（与改名弹窗同款：立刻 dispose 会触发
    // TextField 卸载后向已销毁 controller 加 listener 的红屏断言）
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      ctrl.dispose();
      error.dispose();
      busy.dispose();
      active.dispose();
      allSpaces.dispose();
    });
    if (saved == true && mounted) await _refreshNotifyEmail();
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
        session: _session,
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

  /// 「通道列表」底部弹层：**当前通道（带绿勾、列第一位）+ 我本人在本空间的其他通道**
  /// （老板 2026-09-25：多设备登录时一眼看到"我还有哪些线挂着、在不在线"；
  /// 即使只有自己一条通道也要显示自己；对方 member 的通道不列）。
  /// 每条通道 = **卡片**（边框 + 名称 + 状态红绿灯；本机那张右上角一个**绿勾**、恒列第一位）；
  /// 列表下方「新建通道」（与「切换我的秘境」弹层的「添加秘境」同款外观：
  /// 常态淡灰底、图标+文字居中）→ 生成开通码弹窗（_showInviteDialog）。
  ///
  /// 数据源 = GET /entrances（在线判定与顶栏同源：connected_at 非 null 即在线，
  /// 旧服务端无该字段时退回 last_seen<60s）。红绿灯：绿=在线 红=离线 灰=已撤销
  /// （已撤销的通道照列，并给整卡蒙版 + 右上角阻止图标）。
  /// 时间行：在线显示上线时刻，离线/已撤销显示**下线时刻**
  /// （max(last_seen, offline_since)，见卡片内注释）。
  /// 服务端拉不到时仍显示当前通道（离线不影响"我是谁"），只把其他通道区换成失败提示。
  ///
  /// **标题右端的「刷新」**（老板 2026-09-26）：就地重拉 /entrances 重建卡片——只想看
  /// "现在谁在线"时不用退出弹层，也不用等 30s 的对方在线轮询。为它把弹层主体套进
  /// StatefulBuilder（卡片/失败提示读它承载的可变状态），拉取逻辑收在 `load()` 里
  /// 供"初次打开"与"刷新"共用。
  /// 空间成员（群聊一期 2026-10-03）：成员名单 + 两种邀请入口。
  ///
  /// 入口语义（aimemo/groupChatDesign.md）：
  /// - **邀请伴侣 / 邀请新成员** = `invite` token（开**新身份**）。伴侣还没入网时
  ///   就是"邀请伴侣"（不升格）；已入网仍是 duo 时点它 → 先弹升格确认（升级后禁用
  ///   语音通话、最多 N 人、不可逆），确认后生成。
  /// - **在其他设备加入我的账号** = `channel` token（绑定**我自己的**身份，仅本人
  ///   可用，杜绝"任选他人身份加通道"的冒充面）。
  /// - 满员（服务端 maxMembersPerSpace 已达）→ 只留一行说明，不给按钮。
  /// - **无退出入口**（一期：入群即不退群）。
  Future<void> _showMembersSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final api = widget.api ?? ApiClient(effectiveServer);
    // 每个成员挂了几条通道（/entrances 现拉；失败就不显示数字，不拦别的）
    Map<String, int>? entranceCounts;
    try {
      final rows = await _withAuth((t) => api.listEntrances(t));
      final counts = <String, int>{};
      for (final d in rows) {
        final id = d['member_id'] as String?;
        if (id == null || id.isEmpty) continue;
        if (d['status'] != null && d['status'] != 'active') continue; // 已撤销的不算
        counts[id] = (counts[id] ?? 0) + 1;
      }
      entranceCounts = counts;
    } catch (_) {
      entranceCounts = null;
    }
    if (!mounted) return;
    // 成员名单按槽位（入群先后）排；本机那份资料可能还没拉到 → 至少列"我"
    final entries = _memberSlots.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final partnerJoined = _memberCount >= 2;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true, // 与「我的通道」等弹层同口径（老板 2026-10-02）
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Center(
                    child: Text(l10n.chatPageMembersTitle,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 16)),
                  ),
                ),
                // 成员名单（/space 快照；离线时至少有我）
                for (final e in entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: scheme.secondaryContainer,
                          child: Text(
                            (_memberNames[e.key] ?? '').isNotEmpty
                                ? _memberNames[e.key]!.characters.first
                                : '?',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            (_memberNames[e.key] ?? '').isNotEmpty
                                ? _memberNames[e.key]!
                                : l10n.chatPageMembersUnnamed,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        // 通道数（该身份挂了几台设备）
                        if (entranceCounts?[e.key] != null) ...[
                          Icon(Icons.devices, size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Text('${entranceCounts![e.key]}',
                              style: TextStyle(
                                  fontSize: 13, color: scheme.onSurfaceVariant)),
                          const SizedBox(width: 8),
                        ],
                        if (e.key == _myMemberId)
                          Text(l10n.chatPageMembersMe,
                              style: TextStyle(
                                  fontSize: 12, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                // 邀请入口：满员 → 只留说明；duo 且伴侣已入网 → 升格确认；其余直接生成
                if (!_canInviteMore)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      // 给"按钮去哪了"一个说法（设计文档的风险表：入口直接消失会
                      // 让人以为坏了）——人数是服务端 maxMembersPerSpace 卡的
                      _maxMembers > 0
                          ? l10n.chatPageMembersFullWithMax(_memberCount, _maxMembers)
                          : l10n.chatPageMembersFull,
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  )
                else
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.person_add_alt_1, size: 18),
                    label: Text(partnerJoined && !_isGroup
                        ? l10n.chatPageMembersInviteNew
                        : l10n.chatPageMembersInvitePartner),
                    onPressed: () async {
                      Navigator.of(ctx).pop();
                      // duo 满 2 人签 invite 会触发服务端升格（方案 C）——
                      // 升格代价（通话停用/不可逆）先确认
                      if (partnerJoined && !_isGroup) {
                        final ok = await _confirmGroupUpgrade();
                        if (!ok || !mounted) return;
                      }
                      if (!mounted) return;
                      await _showInviteDialog(purpose: 'invite');
                    },
                  ),
                const SizedBox(height: 8),
                // channel 入口：绑定自己身份的新设备接入
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.devices, size: 18),
                  label: Text(l10n.chatPageMembersChannelToken),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    unawaited(_showInviteDialog(purpose: 'channel'));
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 升格确认（方案 C）：说明"最多 N 人 + 通话停用 + 不可逆"，返回是否继续。
  /// [l10n.chatPageMembersUpgradeConfirmBody] 带上限数字（maxMembersPerSpace > 0
  /// 时）；服务器不限制人数（0）则用不限版文案。
  Future<bool> _confirmGroupUpgrade() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Center(child: Text(l10n.chatPageMembersUpgradeConfirmTitle)),
        content: Text(_maxMembers > 0
            ? l10n.chatPageMembersUpgradeConfirmBody(_maxMembers)
            : l10n.chatPageMembersUpgradeConfirmBodyNoLimit),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _showEntranceListSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final api = widget.api ?? ApiClient(effectiveServer);
    // 弹层内的可变状态（StatefulBuilder 重建时读它；标题右端的「刷新」就地重拉）
    List<Map<String, dynamic>>? rows;
    // "我是谁"（_myMemberId 可能为 null：离线且 profile 未缓存）：兜底反查一次
    String? myMemberId = _myMemberId;
    int localSinceMs = 0;
    bool refreshing = false;

    /// 拉一次 /entrances 并算好展示所需的状态；失败 → rows = null
    /// （弹层里只显示当前通道 + 「无法获取其他通道」提示）。初次打开与点「刷新」共用。
    Future<void> load() async {
      List<Map<String, dynamic>>? fetched;
      try {
        // 先落到**非空**局部：直接赋给可空变量的话，_withAuth 的 T 会被推成可空，
        // 后面的空提升就断了（analyze 的 unchecked_use_of_nullable_value）
        final fresh = await _withAuth((t) => api.listEntrances(t));
        fetched = fresh;
        // 局部副本：myMemberId 是被闭包改写的捕获变量，Dart 不对它做空提升
        final known = myMemberId;
        if (known == null || known.isEmpty) {
          for (final d in fresh) {
            if (d['entrance_id'] == widget.entranceId) {
              myMemberId = d['member_id'] as String?;
              break;
            }
          }
        }
      } catch (_) {
        fetched = null; // 离线/出错：当前通道照列，其他通道区显示失败提示
      }
      // 本机卡片的 since = 服务端自己这一行的上线时刻（online_since，兜底 connected_at；
      // 服务端拉不到时 0 → 不显示，避免显示"当前时刻"这种假上线时间）
      var since = 0;
      if (fetched != null) {
        for (final d in fetched) {
          if (d['entrance_id'] == widget.entranceId) {
            since = (d['online_since'] as num?)?.toInt() ??
                (d['connected_at'] is num ? (d['connected_at'] as num).toInt() : 0);
            break;
          }
        }
      }
      rows = fetched;
      localSinceMs = since;
    }

    await load();
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      // 允许弹层用到满窗高：默认上限是 9/16 屏，窗口矮时标题/备注/「新建通道」
      // 这些固定项之和就可能超过它，Flexible 缩到 0 也不够 → 底部黑黄条纹
      // "Bottom overflowed"（老板 2026-10-02 mac 实测）。开起来后只有窗口矮到
      // 固定项本身装不下（<约 180px）才会溢出，正常窗口都由中间卡片区内部滚动吸收。
      isScrollControlled: true,
      // StatefulBuilder：「刷新」按钮要就地重建卡片（老板 2026-09-26）——关掉弹层
      // 再开一次会有"收起+展开"两段动画，看着像卡了一下
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final scheme = Theme.of(ctx).colorScheme;
          final now = DateTime.now().millisecondsSinceEpoch;
          // 局部 final：rows / myMemberId 是被 load() 改写的捕获变量，Dart 不做空提升
          final loaded = rows;
          final myId = myMemberId ?? '';
          // 行 = 当前通道（必有，标「本机」）+ 我本人的其他通道（同 member，排除当前）
          final myRows = <Map<String, dynamic>>[
            {
              'entrance_id': widget.entranceId,
              'entrance_name': _myEntranceName,
              'member_id': myId,
              'connected_at': DateTime.now().millisecondsSinceEpoch,
              'status': 'active',
              '_local': true,
            },
            if (loaded != null)
              for (final d in loaded)
                if (d['entrance_id'] != widget.entranceId &&
                    myId.isNotEmpty &&
                    d['member_id'] == myId)
                  d,
          ];
          return SafeArea(
            child: Padding(
              // 顶边 0：标题自己的 Padding 负责上 14 留白（同参照弹层）
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题**居中**、上 14 下 5（与「界面语言」等弹层标题的居中与
                  // 留白口径对齐）。右端挂「刷新」：就地重拉 /entrances 重建卡片，
                  // 不用退出弹层、也不用等 30s 轮询。横向 padding 由 16 收到 0，
                  // 让刷新按钮与下面的卡片**右对齐**；左边放同宽占位，标题仍在弹层
                  // 正中（不会被按钮推歪）。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 4, 0, 5),
                    child: Row(
                      children: [
                        const SizedBox(width: _entranceRefreshSize),
                        Expanded(
                          child: Center(
                            child: Text(l10n.chatPageMenuEntranceList,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 16)),
                          ),
                        ),
                        SizedBox(
                          width: _entranceRefreshSize,
                          height: _entranceRefreshSize,
                          // 拉取中换成同尺寸的转圈：位置与大小都不跳
                          child: refreshing
                              ? const Center(
                                  child: SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)),
                                )
                              : IconButton(
                                  icon: const Icon(Icons.refresh, size: 20),
                                  tooltip: l10n.chatPageEntranceListRefresh,
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () async {
                                    setSheetState(() => refreshing = true);
                                    await load();
                                    // 弹层可能在这期间被关掉 → 不能再 setState
                                    if (!ctx.mounted) return;
                                    setSheetState(() => refreshing = false);
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                  // 标题下备注行：沿用原「当前通道」弹窗的说明文案，式样同「阅后即焚」
                  // 弹层标题下的说明（淡色小字、居中）。
                  Center(
                    child: Text(
                      l10n.chatPageEntranceScopeHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(ctx).colorScheme.outline),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // 通道卡片：**一行 3 张**（与秘境卡片同口径，边长按可用宽度反算，
                  // 老板 2026-09-25）。卡片 = 边框 + 名称 + 状态红绿灯（绿在线/红离线/
                  // 灰已撤销）+ 时间（在线→上线时刻；离线/已撤销→下线时刻；无数据不显示）；
                  // 右上角固定角标：本机=编辑图标（点击改名）、已撤销=阻止图标+整卡蒙版
                  // （老板 2026-10-02：当前通道改名改从本机卡片进，弹层不再放改名行）
                  // 通道多 + 窗口矮 → 随中间整块在外层 ScrollableCardArea 里滚动。
                  ScrollableCardArea(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final size = _entranceCardSizeFor(constraints.maxWidth);
                        return Wrap(
                          spacing: _entranceCardSpacing,
                          runSpacing: _entranceCardSpacing,
                          children: [
                            for (final d in myRows)
                              () {
                                final name = (d['entrance_name'] as String? ?? '').trim();
                                final entranceId = d['entrance_id'] as String? ?? '';
                                final isLocal = d['_local'] == true;
                                final revoked = !isLocal &&
                                    d['status'] != null &&
                                    d['status'] != 'active';
                                final connectedAt = d['connected_at'];
                                final last = d['last_seen'];
                                final online = !revoked &&
                                    (d.containsKey('connected_at')
                                        ? connectedAt != null
                                        : (last is num && now - last < 60 * 1000));
                                // 时间戳：在线 → 上线时刻（online_since 兜底 connected_at）；
                                // 离线/已撤销 → **下线时刻**（老板 2026-09-26）＝
                                // max(last_seen, offline_since)：offline_since 是服务端断开
                                // 那一刻落的（干净下线时 last_seen 归零，只剩它有值）；
                                // last_seen 会被心跳/REST 刷新，服务端重启这类"close 没跑到"
                                // 的情况反而是更新的证据 → 取两者较晚者最准。都是 0 才不显示。
                                final sinceMs = (d['online_since'] as num?)?.toInt() ??
                                    (connectedAt is num ? connectedAt.toInt() : null);
                                final offlineSince =
                                    (d['offline_since'] as num?)?.toInt() ?? 0;
                                final lastSeen = last is num ? last.toInt() : 0;
                                final int stamp;
                                if (isLocal) {
                                  stamp = localSinceMs;
                                } else if (online) {
                                  stamp = sinceMs ?? 0;
                                } else {
                                  stamp = lastSeen > offlineSince
                                      ? lastSeen
                                      : offlineSince;
                                }
                                // 右上角固定角标：本机 = 绿勾、已撤销 = 阻止图标
                                // 两者互斥（revoked 已含 !isLocal）→ 共用一个角标位
                                final hasBadge = isLocal || revoked;
                                return SizedBox(
                                  width: size,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                          color:
                                              Colors.black.withValues(alpha: 0.12)),
                                      // 已撤销：极淡灰底 —— "这张卡失效了"的第一层蒙版
                                      // （第二层是整个内容降透明度，见下面的 Opacity）
                                      color: revoked
                                          ? Colors.black.withValues(alpha: 0.04)
                                          : null,
                                    ),
                                    // Stack：内容照常流式排布，角标**固定**在卡片右上角
                                    // （老板 2026-09-26：绿勾原先紧贴名称，位置随名字长短跑）
                                    child: Stack(
                                      children: [
                                        Opacity(
                                          opacity: revoked ? 0.55 : 1,
                                          child: Padding(
                                            padding: const EdgeInsets.all(8),
                                            // mainAxisSize.min：Wrap 给子项的高度约束无限，
                                            // 不能用 Spacer/flex（RenderFlex 断言）
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                // 第一行：名称（角标位由右上角预留）
                                                Padding(
                                                  // 有角标的卡让出角标宽度，长名字不会钻到
                                                  // 图标底下
                                                  padding: EdgeInsets.only(
                                                      right: hasBadge ? 18 : 0),
                                                  child: Text(
                                                    name.isNotEmpty
                                                        ? name
                                                        : entranceId,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        fontSize: 13,
                                                        fontWeight:
                                                            FontWeight.w500),
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                // 第二行：状态红绿灯 + 时间（绿在线/红离线/
                                                // 灰已撤销）。时间**恒定占一行**：没有时间可显示
                                                // 时给一个空格（不是空串——空串在部分平台量出 0
                                                // 高），否则这张卡会比别的矮一截
                                                // （老板 2026-09-26 实测：离线卡没有文字时矮一截）
                                                Row(
                                                  children: [
                                                    Icon(Icons.circle, size: 8,
                                                        color: revoked
                                                            ? Colors.black
                                                                    .withValues(
                                                                        alpha: 0.30)
                                                            : (online
                                                                ? Colors.green
                                                                : Colors.red)),
                                                    const SizedBox(width: 6),
                                                    Expanded(
                                                      // 直接写时间，不带 "since" 前缀
                                                      // （老板 2026-09-26：太占地方）
                                                      child: Text(
                                                          stamp > 0
                                                              ? _timeStampLabel(stamp)
                                                              : ' ',
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: TextStyle(
                                                              fontSize: 11,
                                                              color:
                                                                  scheme.outline)),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        if (hasBadge)
                                          Positioned(
                                            top: 6,
                                            right: 6,
                                            // 本机 = 编辑图标（老板 2026-10-02：当前通道
                                            // 改名从这张卡进——点击关掉弹层，错峰弹改名
                                            // 弹窗）；已撤销 = 阻止图标。编辑角标**显式**
                                            // Material 圆形底 + 6 内边距（老板 2026-10-02：
                                            // IconButton 默认底衬是圆角矩形不是纯圆，
                                            // padding 0 时图标贴边更难看）。
                                            child: isLocal
                                                ? Tooltip(
                                                    message: l10n.chatPageEdit,
                                                    child: Material(
                                                      color:
                                                          Colors.transparent,
                                                      shape: const CircleBorder(),
                                                      clipBehavior:
                                                          Clip.antiAlias,
                                                      child: InkWell(
                                                        customBorder:
                                                            const CircleBorder(),
                                                        onTap: () {
                                                          // 先收起弹层再开弹窗（与
                                                          // 「新建通道」同款错峰，避免
                                                          // Overlay 交叉卸载断言）
                                                          Navigator.of(ctx).pop();
                                                          _menuAction(
                                                              _showRenameEntranceDialog);
                                                        },
                                                        child: const Padding(
                                                          padding:
                                                              EdgeInsets.all(6),
                                                          child: Icon(
                                                              Icons.edit,
                                                              size: 14),
                                                        ),
                                                      ),
                                                    ),
                                                  )
                                                : Icon(
                                                    Icons.block,
                                                    size: 14,
                                                    color: Colors.black
                                                        .withValues(alpha: 0.45),
                                                  ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              }(),
                          ],
                        );
                      },
                    ),
                  ),
                  if (loaded == null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(l10n.chatPageEntranceListFailed,
                          style: TextStyle(fontSize: 13, color: scheme.outline)),
                    ),
                  // 卡片与「新建通道」之间的留白（老板 2026-09-25：原先紧挨着）
                  const SizedBox(height: 12),
                  // 「新建通道」：与「切换我的秘境」弹层的「添加秘境」同款外观——常态淡灰底
                  // 提示可点、图标+文字居中（老板 2026-09-25）；点击生成开通码
                  Material(
                    color: Colors.black.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias, // 让 ink 跟着圆角裁
                    child: InkWell(mouseCursor: SystemMouseCursors.click,
                      // 点「新建通道」：**先收起通道列表弹层**，再弹开通码
                      // （老板 2026-09-25）；_menuAction 内部 300ms 错峰，等弹层
                      // 收起动画跑完再 show（同菜单项开新 route 的口径，避免
                      // Overlay 交叉卸载断言）
                      onTap: () {
                        Navigator.of(ctx).pop();
                        // 「新建通道」= 我本人在另一台设备接入 → channel token
                        // （绑定我的身份）。邀**新成员**才是 invite，别搞反。
                        _menuAction(() => _showInviteDialog(purpose: 'channel'));
                      },
                      hoverColor: Colors.black.withValues(alpha: 0.10),
                      highlightColor: Colors.black.withValues(alpha: 0.14),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.add),
                            const SizedBox(width: 6),
                            Text(l10n.chatPageEntranceListNew),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
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
      // 允许用满窗高（与「我的通道」等弹层同口径，老板 2026-10-02）
      isScrollControlled: true,
      builder: (ctx) {
        final red = Theme.of(ctx).colorScheme.error;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题**居中**、上 14 下 10（老板 2026-09-25：与「界面语言」/「更多通道」
              // 等弹层标题口径一致——原来是自己一套 left + all 12 + 无字号）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Center(
                  child: Text(l10n.advancedMenuTitle,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 16)),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: Text(l10n.chatPageMenuChangePassphrase),
                onTap: () => Navigator.of(ctx).pop('passphrase'),
              ),
              // 「删除所有消息」（老板 2026-10-02）：清本通道的消息+附件，通道保留。
              // 破坏性递进：排在本通道销毁（更彻底）之前
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: Text(l10n.advancedClearMessages),
                onTap: () => Navigator.of(ctx).pop('clear'),
              ),
              ListTile(
                leading: Icon(Icons.warning_amber_rounded, color: red),
                title: Text(l10n.advancedDestroyEntrance),
                onTap: () => Navigator.of(ctx).pop('leave'),
              ),
              // 底部留白：与「切换我的秘境」弹层一致（那边是外层 Padding 的 bottom 16），
              // 这里标题只包了 12 的 Padding → 单独给末行留 16，不然紧贴屏幕底边
              const SizedBox(height: 16),
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
    } else if (picked == 'clear') {
      // 「删除所有消息」（老板 2026-10-02 定稿：**纯本机删除**，服务端不删）：
      // 只清本机这份历史，服务端与对方设备上的消息原样保留——本通道继续从原
      // 同步锚点收新消息。确认闸门与销毁通道同一条（通道名 + 已设时的锁屏码），
      // 弹窗备注按老板文案说明"通道保留、继续收新消息、其他通道不受影响"。
      final entranceName = await _resolveMyEntranceName();
      final hasPin = await AppLockService(widget.db ?? LocalDatabase.shared).isSetup;
      if (!mounted) return;
      final ok = await confirmClearMessages(
        context,
        db: widget.db,
        entranceName: entranceName,
        hasPin: hasPin,
      );
      if (!ok || !mounted) return;
      try {
        // 本机清：消息行 + 附件元数据行 + stored 模式的明文副本 + 媒体缓存。
        // 刻意**不动 sync_state 锚点**：服务端消息仍在，锚点＝已同步到的最新序号，
        // 新消息继续从锚点之后增量同步（清零会让下次 sync 整表重拉服务端历史，
        // 恰好违背"本机删除"的意图）。
        await _repo.clearLocalHistory();
        unawaited(AttachmentStore.clearSpace(widget.spaceId));
        if (!mounted) return;
        setState(() {
          // 内存列表立即清屏（老板 2026-10-02 实测缺陷：只清库不清内存，要切空间
          // 再切回来才消失——_refreshLocal 是增量合并，拉不到"新"消息，冲不掉
          // 还在内存里的旧列表）。分页游标一并复位：本地库已空，没有更早历史；
          // 引用条若正引用被删的消息一并撤掉（悬挂引用会把已删内容带进下一条发送）。
          _messages = [];
          _hasMoreOlder = false;
          _quoteTarget = null;
          _imageCache.clear();
          _videoCache.clear();
          _videoThumbCache.clear();
        });
        await _refreshLocal();
        if (mounted) showTopNotice(context, l10n.clearMessagesDone);
      } catch (e) {
        if (!mounted) return;
        showTopNotice(context, backendError(l10n, l10n.clearMessagesFailed('$e')));
      }
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
        session: _session,
        entranceName: entranceName,
        hasPin: hasPin,
      );
      if (!left || !mounted) return;
      SpaceSessions.forget(widget.spaceId); // 凭证已随 removeSpace 删掉，会话一并丢掉
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
    if (_session.token.isEmpty || effectiveServer.isEmpty) return '';
    try {
      final rows = await _withAuth((t) => (widget.api ?? ApiClient(effectiveServer)).listEntrances(t));
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

  /// 打开「关于秘境」底部弹层（版本号 / 服务器地址 / 一句话说明）。
  void _openAboutPage() {
    AboutSheet.show(context);
  }

  /// 对方是否已加入本空间（有**在用**通道）。**null = 还没问到**，此时不显示
  /// 「邀请加入」——首帧与离线（请求失败）都停在 null，不会误挂一个链接。
  /// 未加入时状态条对方芯片右侧显示「邀请加入」链接（老板 2026-09-25）。
  bool? _peerJoined;

  /// 对方在线判定：对方有实时 WS 连接（connected_at 非 null）= 在线；
  /// 旧服务器无 connected_at 字段时退回 last_seen 距今 < 60s 兜底
  /// （30s 轮询 + WS 状态变化时刷新）。
  /// 一行通道是否在线：有实时 WS 连接即在线（server 重启/未入网时立即准确）；
  /// 没有 `connected_at` 字段的老服务端回退看 `last_seen`（60s 内算在线）——
  /// last_seen 会被轮询 touchLastSeen 持续刷新，不能单独代表实时连接
  /// （修复"未入网却显示绿灯"）。
  bool _isRowOnline(Map<String, dynamic> d, int now) {
    if (d.containsKey('connected_at')) return d['connected_at'] != null;
    final last = d['last_seen'];
    if (last is! num) return false;
    return now - last < 60 * 1000;
  }

  /// 一行通道数据里"当前状态的时刻"（ms；0/缺失 → null）——与「更多通道」卡片
  /// 同一口径（那里有详细注释）：在线取 `online_since`（兜底 `connected_at`）；
  /// 离线取 `max(last_seen, offline_since)`（干净下线时 last_seen 归零，只剩
  /// offline_since；服务端重启等"close 没跑到"的情况反而 last_seen 更新）。
  int? _sinceOfRow(Map<String, dynamic> d, {required bool online}) {
    if (online) {
      final connectedAt = d['connected_at'];
      return (d['online_since'] as num?)?.toInt() ??
          (connectedAt is num ? connectedAt.toInt() : null);
    }
    final lastSeen = (d['last_seen'] as num?)?.toInt() ?? 0;
    final offlineSince = (d['offline_since'] as num?)?.toInt() ?? 0;
    final stamp = lastSeen > offlineSince ? lastSeen : offlineSince;
    return stamp > 0 ? stamp : null;
  }

  Future<void> _refreshPeerOnline() async {
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final entrances = await _withAuth((t) => api.listEntrances(t));
      final now = DateTime.now().millisecondsSinceEpoch;
      // 在线是"人"维度的：同一 member 的其它通道是我自己开的通道，不算对方
      // （重启路径不传 memberId → 从通道表里按本通道反查；查不到才退回按通道判定）
      var mine = widget.memberId;
      if (mine == null || mine.isEmpty) {
        for (final d in entrances) {
          if (d['entrance_id'] == widget.entranceId) {
            mine = d['member_id'] as String?;
            break;
          }
        }
      }
      final peer = entrances.where((d) {
        if (d['entrance_id'] == widget.entranceId) return false;
        final pid = d['member_id'] as String?;
        if (pid == null || mine == null || mine.isEmpty) return true;
        return pid != mine;
      }).toList();
      final online = peer.isNotEmpty && peer.any((d) => _isRowOnline(d, now));
      // 对方由离线转在线（含"刚加入空间"——WS 事件可能漏，这里兜底）：补拉身份
      if (online && !_peerOnline) unawaited(_refreshProfileFromServer());
      // 「对方已加入」= 有**在用**通道。撤销不会删行，只把 status 标成 revoked
      // （server/src/entrances.ts）——拿"行存在"当已加入，会让密友重置设备/通道被撤
      // 之后反而不给邀请入口，恰恰丢了最该邀请的那一刻。status 缺省（老服务端）按
      // 在用算，与通道列表弹层的 revoked 判定同口径。
      final joined = peer.any((d) {
        final status = d['status'];
        return status == null || status == 'active';
      });
      // 状态条上的「上线/下线时刻」：对方取"在线的那条通道"（没有就取第一条），
      // 我方取本机通道；口径统一走 _sinceOfRow。
      final peerOnlineRow = peer.where((d) => _isRowOnline(d, now)).firstOrNull;
      final peerRow = peerOnlineRow ?? (peer.isEmpty ? null : peer.first);
      final int? peerSince = peerRow == null
          ? null
          : _sinceOfRow(peerRow, online: peerOnlineRow != null);
      int? mySince;
      for (final d in entrances) {
        if (d['entrance_id'] != widget.entranceId) continue;
        mySince = _sinceOfRow(d, online: _ws?.connected.value ?? false);
        break;
      }
      // 我的通道总数（member 维度，含本机这条）——与通道列表弹层的过滤同口径
      // （本机 + member_id 等于我的其它行）；轮询拿不到 mine 时保持旧值。
      final myCount = (mine != null && mine.isNotEmpty)
          ? entrances.where((d) => d['member_id'] == mine).length
          : _myEntranceCount;
      if (mounted &&
          (online != _peerOnline ||
              joined != _peerJoined ||
              peerSince != _peerSinceMs ||
              mySince != _mySinceMs ||
              myCount != _myEntranceCount)) {
        setState(() {
          _peerOnline = online;
          _peerJoined = joined;
          _peerSinceMs = peerSince;
          _mySinceMs = mySince;
          _myEntranceCount = myCount;
        });
      }
    } catch (_) {
      // 网络失败：保持上次状态
    }
  }

  /// 加载我的头像（异步；未设置/失败 → 保持默认图标）。
  /// memberId 缺失时（重启路径）从本地持久化的 entrance→member 映射反查。
  /// 把"本空间对方是谁"（member_id）落进 per-space 资料，与 peerName 并列。
  ///
  /// 为什么要在 `refreshEntranceMap()` 之后做：对方的 member_id 只在那份通道表映射里
  /// 出现过（服务端 `GET /space` 的 `entranceId → memberId`，排掉自己就是对方），
  /// 而映射只在内存 + 一张全局表里，**没有"按空间"的落点**。不落的话，切换秘境弹层的卡片
  /// 就只能显示默认头像——明明有对方名字却不知道对方是谁（老板 2026-09-23 指出）。
  ///
  /// 落两份结论：对方的 member_id（有的话）+ **对方是否已入网**（[savePeerPresence]）。
  /// 后者让空间卡片能显示「待加入」——只有这里分得清"对方还没来"与"来了但没设头像"。
  ///
  /// best-effort，但**前提是通道表新鲜**：本方法只在 `refreshEntranceMap()` 成功之后调用，
  /// 表非空才说明"排掉我之后没有别人"是确定结论；表为空（离线/还没拉过）时状态未知，
  /// 直接返回、什么都不写（否则卡片会误报「待加入」）。
  Future<void> _persistPeerMemberId() async {
    if (!_repo.hasEntranceMap) return;
    try {
      await AppLockService(widget.db ?? LocalDatabase.shared).savePeerPresence(
        spaceId: widget.spaceId,
        peerMemberId: _repo.resolvePeerMemberId(),
      );
    } catch (_) {
      // 落盘失败不影响聊天；下次刷新再试
    }
  }

  Future<void> _loadMyAvatar() async {
    var pid = _myMemberId;
    if (pid == null || pid.isEmpty) {
      pid = await _repo.resolveMyMemberId();
      if (pid == null || pid.isEmpty) return;
      _myMemberId = pid;
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

  /// 加载对方头像（状态条显示用）。
  ///
  /// 为什么不复用消息流的 [_MessageAvatar]：那个直径写死 16（radius 16，是消息头像的
  /// 尺寸），状态条这里要更大，所以自己存一份 bytes 自己画。失败/未设置就保持默认人形。
  Future<void> _loadPeerAvatar() async {
    final pid = _peerMemberId;
    if (pid == null || pid.isEmpty) return;
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final bytes = await api.getAvatar(pid);
      if (!mounted) return;
      setState(() => _peerAvatarBytes = bytes);
    } catch (_) {
      // 网络失败：保持默认图标
    }
  }

  /// 修改我的头像：选图 → 上传服务端（per-member 覆盖）→ 本地缓存刷新菜单显示。
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
      // 服务端在上传响应里回 member_id：上传方收不到自己的 profile.updated 广播，
      // 这个返回值是失效本端头像缓存最可靠的依据（重启路径 widget.memberId 为空，
      // 旧实现 invalidate(null) 静默失效失败 — 老板 2026-09-16 报告）
      final memberId = await _withAuth((t) => api.uploadAvatar(bytes, t));
      // 服务端回的是权威值；响应异常/旧服务端缺字段 → 退到本地反查
      final pid = (memberId != null && memberId.isNotEmpty)
          ? memberId
          : (_myMemberId ?? await _repo.resolveMyMemberId());
      if (!mounted) return;
      if (pid != null && pid.isNotEmpty) _myMemberId = pid;
      // 消息流里的头像走静态缓存：主动失效才会重拉（否则要重启才更新）
      _MessageAvatarState.invalidate(pid);
      setState(() => _myAvatarBytes = bytes);
      showTopNotice(context, l10n.chatPageAvatarUploaded);
    } on ApiException catch (e) {
      if (!mounted) return;
      showTopNotice(context, backendError(l10n, l10n.chatPageAvatarFailed(e.message)));
    } catch (e) {
      if (!mounted) return;
      showTopNotice(context, l10n.chatPageAvatarFailed('$e'));
    }
  }

  /// 保存通道名（改名弹窗与「我的通道」弹层共用）：校验白名单 → PUT → 更新本地
  /// profile。返回 null = 成功；否则返回已本地化的错误文案（调用方自行展示——
  /// 弹窗走红字、弹层走顶部通知）。
  Future<String?> _applyEntranceName(String rawName, AppLocalizations l10n) async {
    final name = rawName.trim();
    if (name.isEmpty) return l10n.chatPageRenameEntranceEmptyError;
    // 通道名字符白名单 + 长度上限（老板 2026-09-16）：只允许中英文、数字、
    // `_`、`-`，≤32；不合规提示重输（服务端另有 400 兜底）
    final violation = checkEntranceNamePolicy(name);
    if (violation != null) {
      return violation == EntranceNameViolation.tooLong
          ? l10n.chatPageRenameEntranceTooLongError(kEntranceNameMaxLength)
          : l10n.chatPageRenameEntranceInvalidError;
    }
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      await _withAuth((t) => api.updateEntranceName(name, t));
      _myEntranceName = name;
      // 同步本地 profile：重启后 ChatPage 从 profile 恢复新名字
      // （否则 loadProfile 读到向导完成时的旧名——2026-09-07 老板实测
      // app 菜单改名后退出重进回到 memberB）
      await _saveProfile();
      return null;
    } on ApiException catch (e) {
      return backendError(l10n, l10n.chatPageRenameFailed(e.message));
    } catch (e) {
      return l10n.chatPageRenameFailed('$e');
    }
  }

  /// 修改通道名称（服务端同步 + 本地刷新）——「我的通道」弹层里本机卡片右上角的
  /// 编辑角标进入（老板 2026-10-02：改名入口从弹层顶部的行挪回弹窗）。内容即
  /// 原合并前的「当前通道」弹窗（标题/通道名称输入框/说明文案），公钥展示不再要
  /// （5b74cf4 已删）。校验与提交走 [_applyEntranceName]（与弹层行内改名同一条逻辑）。
  Future<void> _showRenameEntranceDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final ctrl = TextEditingController(text: _myEntranceName);
    // 名称为空/不合规警示（红字显示在输入框下方；开始填写即消）
    final nameError = ValueNotifier<String?>(null);
    // 名字/通道名编辑态切换：初始只读透明 + 右侧编辑按钮；点编辑 → 白底可编辑、按钮消失
    final editing = ValueNotifier<bool>(false);
    // 名称输入框焦点：点框内任意位置进编辑态时手动取焦（只读态点击不会自动取焦）
    final nameFocus = FocusNode();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // 标题居中（老板 2026-09-25：菜单下的弹窗标题一律居中）
        title: Center(child: Text(l10n.chatPageRenameEntranceTitle)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 大标题下的备注（老板 2026-10-02）：点明这里改的是什么、上限多少
            Text(
              l10n.chatPageRenameEntranceHint,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(ctx).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 10),
            // 通道名称输入框：初始只读 + 透明背景，右侧「编辑」按钮；点编辑 →
            // 白底可编辑、按钮消失。点框内任意位置也进编辑态（老板 2026-09-23）
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
                  labelText: l10n.chatPageEntranceListThisDevice,
                  border: const OutlineInputBorder(),
                  filled: isEditing, // 编辑态白底；只读态透明（沿用弹窗背景）
                  fillColor: Colors.white,
                  counterText: '',
                  suffixIcon: isEditing
                      ? null
                      : IconButton(
                          tooltip: l10n.chatPageEdit,
                          icon: const Icon(Icons.edit, size: 18),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => editing.value = true,
                        ),
                ),
                // 输入框里直接拦住超长（老板 2026-09-28）：上限用 shared 策略里的
                // 同一个常量（这里的拦截不替代提交时的白名单校验）
                maxLength: kEntranceNameMaxLength,
                // 开始填写即清除警示（与向导输入框一致）
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
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
          FilledButton(
            onPressed: () async {
              final err = await _applyEntranceName(ctrl.text, l10n);
              if (err != null) {
                // 错误**就地显示**：红字挂在输入框下方（与 PIN 修改弹窗同款），
                // 不再弹弹窗外的顶部通知条（老板 2026-10-02）
                nameError.value = err;
                return; // 校验/保存失败：留在弹窗里改
              }
              if (ctx.mounted) Navigator.of(ctx).pop(true);
            },
            child: Text(l10n.chatPageRenamingSubmit),
          ),
        ],
      ),
    );
    // 对话框 route 关闭动画完成后才 dispose（TextField 卸载后不再依赖
    // controller；立即 dispose 会触发红屏断言 _dependents.isEmpty）
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      ctrl.dispose();
      nameError.dispose();
      editing.dispose();
      nameFocus.dispose();
    });
    if (saved == true && mounted) setState(() {}); // 刷新弹层/菜单显示的新名字
  }

  /// 修改我的名字（服务端同步 + 本地刷新菜单显示）。
  /// （原「当前通道」改名弹窗 2026-10-02 并入「我的通道」弹层，公钥展示一并删除。）
  Future<void> _showRenameDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final ctrl = TextEditingController(text: _myMemberName);
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
        // 标题居中（老板 2026-09-25：菜单下的弹窗标题一律居中）
        title: Center(child: Text(l10n.chatPageRenameNameTitle)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 名字输入框：初始只读 + 透明背景，右侧「编辑」按钮；点编辑 →
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
                  labelText: l10n.chatPageRenameNameLabel,
                  border: const OutlineInputBorder(),
                  filled: isEditing, // 编辑态白底；只读态透明（沿用弹窗背景）
                  fillColor: Colors.white,
                  // 不显示 "3/32" 计数器（老板 2026-09-28）：上限只是防超长，
                  // 弹窗里不必多一行；下面 maxLength 才是硬拦
                  counterText: '',
                  suffixIcon: isEditing
                      ? null
                      : IconButton(
                          tooltip: l10n.chatPageEdit,
                          icon: const Icon(Icons.edit, size: 18),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => editing.value = true,
                        ),
                ),
                // 输入框里直接拦住超长（老板 2026-09-28）：以前能一直敲、点保存才被
                // 策略拒（白敲一通）。上限用 shared 策略里的同一个常量
                // （这里的拦截不替代提交时的白名单校验）。
                maxLength: kMemberNameMaxLength,
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
            // 性别用与名字输入框同款组件（只读）——「性别」标签
            // 在边框左上角（同「我的名字」），框内显示 男/女 + 性别图标
            // （老板要求 2026-09-09）
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
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
          FilledButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isEmpty) {
                // 空/全空格：红字警示并停留（不再静默跳过）
                nameError.value = l10n.chatPageRenameMyselfEmptyError;
                return;
              }
              // 用户名称白名单（老板 2026-09-16）：中英文/数字/`_`/`-`/emoji，≤32
              final violation = checkMemberNamePolicy(name);
              if (violation != null) {
                nameError.value = violation == MemberNameViolation.tooLong
                    ? l10n.chatPageRenameNameTooLongError(kMemberNameMaxLength)
                    : l10n.chatPageRenameNameInvalidError;
                return;
              }
              // 不允许改成与对方相同的名字（老板 2026-09-10）
              if (widget.peerName != null && name == widget.peerName) {
                nameError.value = l10n.chatPageRenameSameAsPeerError;
                return;
              }
              try {
                final api = widget.api ?? ApiClient(effectiveServer);
                await _withAuth((t) => api.updateMemberName(name, t));
                _myMemberName = name;
                // 同步本地 profile：重启后 ChatPage 从 profile 恢复新名字
                // （否则 loadProfile 读到向导完成时的旧名——2026-09-07 老板实测
                // app 菜单改名后退出重进回到 memberB）
                await _saveProfile();
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              } on ApiException catch (e) {
                if (ctx.mounted) {
                  showTopNotice(ctx, backendError(l10n, l10n.chatPageRenameFailed(e.message)));
                }
              } catch (e) {
                if (ctx.mounted) {
                  showTopNotice(ctx, l10n.chatPageRenameFailed('$e'));
                }
              }
            },
            child: Text(l10n.chatPageRenamingSubmit),
          ),
        ],
      ),
    );
    // 对话框 route 关闭动画完成后才 dispose（TextField 卸载后不再依赖
    // controller；立即 dispose 会触发红屏断言 _dependents.isEmpty）
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      ctrl.dispose();
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
      memberName: _myMemberName,
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
        // 标题居中（老板 2026-09-25：菜单下的弹窗标题一律居中）
        title: Center(child: Text(l10n.chatPageExitTitle)),
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
    await showOptionPickerSheet<void>(
      context: context,
      builder: (ctx) => OptionPickerSheet(
        title: l10n.chatPageBurnHeading,
        // 标题下居中一行说明这层是干什么的（老板 2026-09-25）
        note: l10n.chatPageBurnNote,
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
        await _withAuth((t) => _repo.api.registerPushToken('ios', apnsToken, t));
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
    if (_session.token.isEmpty) return;
    try {
      final uid = await AppLockService(widget.db ?? LocalDatabase.shared).installUid();
      await _withAuth((t) => (widget.api ?? ApiClient(effectiveServer)).registerInstallUid(uid, t));
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
    _notifyTicker?.cancel(); // 邮件通知"待确认"期间的那一路轮询
    _recordTimer?.cancel();
    _highlightTimer?.cancel(); // 跳转高亮定时清除（防 dispose 后 setState）
    _ampSub?.cancel();
    _ws?.connected.removeListener(_onWsStatusChanged);
    _ws?.stop();
    _voiceCall?.state.removeListener(_onVoiceCallStateChanged);
    _voiceCall?.dispose();
    _unreadTimer?.cancel();
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
      // 进后台（含息屏）：**主动**断开 WS，让对端几秒内就看到离线。
      // 不这么做的话要等服务端的 30s 心跳超时、再等对端 30s 轮询，最长约 90 秒里
      // 对方还以为你在线（老板 2026-09-26）。
      //
      // **通话中绝不停**：贴耳通话必然息屏，停了就直接把通话掐断——通话期间靠
      // iOS 的 audio 后台模式 + 常亮维持，本来也不会进到这里断链。
      if (state == AppLifecycleState.paused && _voiceCall?.state.value.inCall != true) {
        unawaited(_ws?.stop());
      }
    } else if (state == AppLifecycleState.resumed) {
      // 回到前台：把后台时停掉的 WS 接回来（通话中的那次没停，这里幂等重连）
      _startRealtime();
      unawaited(_refreshOtherUnread());
      // 邮件通知：确认链接是在 App 外面（浏览器）点的，回前台正是最该重查的时刻
      unawaited(_refreshNotifyEmail());
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
      await _persistPeerMemberId();
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
      await _persistPeerMemberId();
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
              rows[i].memberId != _peerReceipts[i].memberId ||
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
      // 文件大小：引用块据此显示尺寸（老板 2026-09-27——与时长同理，原消息未加载
      // 也能显示）。老快照没这个字段 → 尺寸那行不显示，产品未上线不必兼容。
      if (quote.env.type == 'file')
        'size': (quote.attachment?['size'] as int?) ?? 0,
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
    } on ApiException catch (e) {
      // 后台：服务端明确拒绝（4xx）——气泡已标 failed，这里把服务端给的理由说出来
      if (!mounted) return;
      showTopNotice(
          context,
          backendError(AppLocalizations.of(context)!,
              AppLocalizations.of(context)!.chatPageSendFailed(e.message)));
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
      // 允许用满窗高（与「我的通道」等弹层同口径，老板 2026-10-02）
      isScrollControlled: true,
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
                // 文字消息才有「拷贝」（媒体消息无文本可拷）
                if (m.env.type == 'text')
                  _buildActionCard(
                    icon: Icons.copy_outlined,
                    label: l10n.chatPageCopy,
                    onTap: () => Navigator.of(ctx).pop('copy'),
                  ),
                // 媒体消息才有「保存」（老板 2026-10-02）：图片/视频/音频/文件
                // 存到本机（系统保存对话框选位置）；放「引用」后面
                if (m.attachment != null)
                  _buildActionCard(
                    icon: Icons.save_alt,
                    label: l10n.chatPageActionSave,
                    onTap: () => Navigator.of(ctx).pop('save'),
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
    } else if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: m.plaintext.trim()));
      if (mounted) showTopNotice(context, l10n.setupCreateCopied);
    } else if (action == 'save') {
      await _saveAttachment(m);
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
      child: InkWell(mouseCursor: SystemMouseCursors.click,
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
    final avatarMemberId =
        m.env.senderMemberId ?? _repo.memberIdOfEntrance(m.env.senderEntranceId);
    final preview = m.plaintext.trim();
    // 音频类（语音/音频文件）与消息流一致：播放键 + 波形图 + 时长（+ 音频文件的
    // 文件名一行），可点按播放（老板要求 2026-09-13）；文件消息**复用消息流那张
    // 文件名片**（图标 + 文件名 + 尺寸，老板 2026-09-27），整块可点打开。
    // 其余类型沿用单行文本（空正文显示类型占位）。
    final Widget bubbleContent;
    switch (m.env.type) {
      case 'voice':
      case 'audio':
        bubbleContent =
            _buildAudioBar(m, waveformWidth: 88, foreground: _mediaForegroundOnBubble);
        break;
      case 'image':
        bubbleContent = _buildImageThumb(m, size: 48);
        break;
      case 'video':
        bubbleContent = _buildVideoThumb(m, size: 48);
        break;
      case 'system':
        // 通话记录：明文为空，内容在 meta 里——复用消息流那条的渲染
        bubbleContent = _buildSystemHint(m);
        break;
      case 'file':
        // 与音频条同一套：直接用消息流那张**文件名片**（图标 + 文件名 + 尺寸），
        // 整块可点 = 用系统应用打开（老板 2026-09-27）。不再自己拼一个"图标 + 文件名"
        // 的只读行——那样既跟气泡长得不一样，点了也没反应。
        bubbleContent = _buildFileCard(m, foreground: _mediaForegroundOnBubble);
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
                    memberId: avatarMemberId, server: effectiveServer, api: widget.api),
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
                    memberId: avatarMemberId, server: effectiveServer, api: widget.api),
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
        title: Center(child: Text(l10n.chatPageDeleteConfirmTitle)),
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

  /// 语音/音频引用的**兜底**外观：波形图 + 秒数（不带播放键）。
  ///
  /// 只在**原消息还没加载进内存**时用（引用块手里只有引用快照：messageId + seconds），
  /// 点它会跳到原消息、补载后就换成 [_buildAudioBar] 那条完整音频条。波形与消息流
  /// 同源（seed=messageId，形状一致）、时长未知时不显示秒数（老板要求 2026-09-13：
  /// 录音消息到处一个样）。
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
  /// 老板要求 2026-09-15）；语音/音频**复用消息流那条音频条**、文件**复用消息流那张
  /// 文件名片**（图标 + 文件名 + 尺寸）——老板 2026-09-27：引用块要和原始气泡一个样。
  /// 原消息**尚未加载**时才退回只读的简版（引用快照里只有 messageId / preview /
  /// seconds / size）。其余沿用文字预览。
  Widget _buildQuoteBlockContent(Map<String, dynamic> quote) {
    final type = quote['type'] as String?;
    if (type == 'image') {
      final quoted = _messageById(quote['messageId'] as String? ?? '');
      if (quoted != null) return _buildImageThumb(quoted, size: kQuoteThumbSize);
    }
    if (type == 'video') {
      final quoted = _messageById(quote['messageId'] as String? ?? '');
      if (quoted != null) return _buildVideoThumb(quoted, size: kQuoteThumbSize);
    }
    if (type == 'file') {
      // 原消息已加载 → **复用消息流那张文件名片**（图标 + 文件名 + 尺寸），与菜单
      // 预览条同一个 widget（老板 2026-09-27）。
      // tappable:false —— 引用块的单击是"跳到原消息"，不能被"整块打开"抢掉；
      // 文件**图标**本身仍可点 = 打开（与音频条的播放键对称）。
      final quoted = _messageById(quote['messageId'] as String? ?? '');
      if (quoted != null) {
        return _buildFileCard(
          quoted,
          tappable: false,
          foreground: _uiStyle == 'gradient'
              ? Colors.white70
              : Theme.of(context).colorScheme.primary,
        );
      }
      // 原消息不在已加载范围：只有引用快照（preview 就是文件名，可能还有 size）
      var fileName = _quotePreview(quote['preview'] as String? ?? '');
      if (fileName.startsWith('📎')) fileName = fileName.replaceFirst('📎', '').trim();
      final size = (quote['size'] is num) ? (quote['size'] as num).round() : 0;
      final detailColor =
          _uiStyle == 'gradient' ? Colors.white70 : Colors.grey.shade700;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file, size: 16, color: detailColor),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: detailColor),
                ),
                // 尺寸随引用快照一起走（老快照没有 size 字段 → 不显示这一行）
                if (size > 0)
                  Text(_formatSize(size),
                      style: TextStyle(fontSize: 11, color: detailColor)),
              ],
            ),
          ),
        ],
      );
    }
    if (type == 'voice' || type == 'audio') {
      // 原消息已加载 → **复用消息流那条音频条**（播放键 + 波形 + 时长，音频文件还有
      // 文件名一行），与菜单预览条同一个 widget（老板 2026-09-27）。
      // tappable:false —— 引用块的单击是"跳到原消息"，不能被播放抢掉；播放键
      // 本身仍可点（它只是内层 IconButton）。
      final quoted = _messageById(quote['messageId'] as String? ?? '');
      if (quoted != null) {
        return _buildAudioBar(
          quoted,
          waveformWidth: 88,
          foreground: _uiStyle == 'gradient'
              ? Colors.white70
              : Theme.of(context).colorScheme.primary,
          tappable: false,
        );
      }
      // 原消息不在已加载范围：只有引用快照（messageId + seconds），退回只读的
      // 波形 + 秒数（点它仍然跳过去，跳到后会自动补载成上面那条完整音频条）
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
    final isAudio = quote.env.type == 'voice' || quote.env.type == 'audio';
    final isFile = quote.env.type == 'file';
    final isImage = quote.env.type == 'image';
    final isVideo = quote.env.type == 'video';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        // 与气泡引用框同色（_buildQuoteBlockContent 所在的引用块）
        color: Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        // spaceBetween：音频条/文件名片**贴合内容靠左**、取消按钮**贴右边框**，
        // 空余留在两者中间（老板 2026-09-27 指出：macOS 宽窗口下 X 离右边框一大段，
        // 还随文件名长短浮动）。
        // 不能用 `Flexible + Spacer` 来顶：两个都是 flex 子项，剩余空间被**平分**，
        // X 前面永远留着约一半空余；而内容越长、剩余越少 → 空隙跟着文件名浮动。
        // 文字引用那条是 Expanded（tight），本来就撑满整行，不受影响。
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 引用图片/视频时显示原附件缩略图（否则双引号图标）——与发送后的
          // 引用块一致（视频显示首帧 + 播放三角，老板要求 2026-09-15）。
          // 语音/音频、文件**不加**引号图标：下面那条音频条/文件名片自带图标，
          // 再挂一个引号既重复又把行撑宽（老板 2026-09-27）
          // 图片/视频**只放缩略图**（文件名已按老板要求删掉），尺寸与气泡引用块
          // 一致（[kQuoteThumbSize]）；后面没有别的预览内容，不再留 6px 间距
          if (isImage)
            _buildImageThumb(quote, size: kQuoteThumbSize)
          else if (isVideo)
            _buildVideoThumb(quote, size: kQuoteThumbSize)
          else if (!isAudio && !isFile) ...[
            const Icon(Icons.format_quote, size: 14, color: Colors.grey),
            const SizedBox(width: 6),
          ],
          // 语音/音频/文件：**复用消息流那条音频条 / 那张文件名片**（老板 2026-09-27：
          // 与菜单预览条一个样）。整块可点——音频是播放，文件是用系统应用打开。
          // Flexible 是必须的：Row 的非 flex 子项宽度**无界**，不套一层的话长歌名/
          // 长文件名会撑破整条引用条（框架行为，见 _buildFileCard 里的注释）。
          // 颜色用主题蓝——引用条是 6% 黑的浅底，跟着气泡走白的话在这里看不见。
          if (isAudio) ...[
            Flexible(
              child: _buildAudioBar(
                quote,
                waveformWidth: 88,
                foreground: Theme.of(context).colorScheme.primary,
              ),
            ),
          ] else if (isFile) ...[
            Flexible(
              child: _buildFileCard(
                quote,
                foreground: Theme.of(context).colorScheme.primary,
              ),
            ),
          ] else if (!isImage && !isVideo)
            // 图片/视频**只显示缩略图，不再显示文件名**：发送端写进明文的本来就是
            // 硬编码的 `image.jpg` / `video.mp4`（见 _sendMedia），不是真名——显示
            // 一个假名字还不如不显示（老板 2026-09-27）。
            Expanded(
              child: Text(
                // 双引号图标已足够表达引用，不再加「引用：」前缀（老板要求 2026-09-09）
                _quotePreview(quote.plaintext),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ),
          InkWell(mouseCursor: SystemMouseCursors.click,
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
    } on ApiException catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      showTopNotice(context, backendError(l10n, l10n.chatPageVoiceFailed(e.message)));
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
      // 允许用满窗高（与「我的通道」等弹层同口径，老板 2026-10-02）
      isScrollControlled: true,
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

  /// 选择器给出的文件名：**相册/文件库里是真名**（`IMG_1234.HEIC`、`假期.mp4`），
  /// 拍照/录像则是选择器自己的临时名（没有"原名"可言，各家插件给的形如
  /// `image_picker_2F3A…jpg`）。取不到（路径为空）才用 [fallback] 占位名。
  ///
  /// 它写进**消息明文**（`📎 <fileName>`，见 `MessageRepository.sendAttachment`），
  /// 于是引用快照、附件落盘的扩展名（`_attachmentExtOf` 按明文后缀取）都跟它走——
  /// 这就是为什么此前硬编码 `image.jpg`/`video.mp4` 会让引用条显示假名（老板
  /// 2026-09-27 发现）。产品未上线，老的假名消息不必迁移。
  String _pickedFileName(XFile file, {required String fallback}) =>
      file.name.isNotEmpty ? file.name : fallback;

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
          fileName = _pickedFileName(image, fallback: 'image.jpg');
          type = 'image';
          await _sendAttachmentOptimistic(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.galleryImage:
          image = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1600);
          if (image == null) return;
          fileName = _pickedFileName(image, fallback: 'image.jpg');
          type = 'image';
          await _sendAttachmentOptimistic(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.videoCamera:
          image = await _picker.pickVideo(source: ImageSource.camera, maxDuration: const Duration(minutes: 1));
          if (image == null) return;
          fileName = _pickedFileName(image, fallback: 'video.mp4');
          type = 'video';
          await _sendAttachmentOptimistic(fileBytes: await image.readAsBytes(), fileName: fileName, type: type);
        case _AttachmentKind.videoGallery:
          image = await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(minutes: 1));
          if (image == null) return;
          fileName = _pickedFileName(image, fallback: 'video.mp4');
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
    } on ApiException catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      showTopNotice(context, backendError(l10n, l10n.chatPageSendFailed(e.message)));
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
          return Clickable(
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

  /// 保存媒体附件到本机（长按菜单「保存」，老板 2026-10-02）：弹出系统保存
  /// 对话框（桌面）选位置 / 写应用文档目录（移动）。文件名用消息正文里的原名；
  /// 写入失败弹顶部通知（下载/解密失败同口径）。
  Future<void> _saveAttachment(HistoryMessage m) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final bytes = await _attachmentBytes(m);
      // 原名兜底：语音固定 .m4a；其余从正文取后缀
      final ext = _attachmentExtOf(m);
      final base = m.env.type == 'voice'
          ? 'voice-${m.env.messageId.substring(0, 8)}'
          : m.plaintext.trim().isEmpty
              ? m.env.messageId.substring(0, 8)
              : m.plaintext.trim();
      final fileName = base.contains('.') || ext.isEmpty ? base : '$base.$ext';
      // file_picker 12.x：saveFile 同 pickFiles 一样是静态方法（返回目标 Uri，取消为 null）
      final target = await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
      );
      if (!mounted) return;
      // 用户取消（null）不算失败，静默返回
      if (target == null) return;
      showTopNotice(context, l10n.chatPageAttachmentSaved);
    } catch (e) {
      if (!mounted) return;
      showTopNotice(context, l10n.chatPageFileSaveFailed('$e'));
    }
  }

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
          return Clickable(
            onTap: () => _showFullImage(snap.data!),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(snap.data!, width: 180, height: 180, fit: BoxFit.cover),
            ),
          );
        }
        if (snap.hasError) {
          return Clickable(
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
  /// 群聊一期（2026-10-03）：[senderMemberId] 非空**且**空间是 group 时，按
  /// member_id 的稳定哈希取色板（不按 slot 轮换——槽位复用/空槽会让颜色漂移）；
  /// duo 空间**原配色规则原样保留**（含同性别第二人取青色，老板 2026-09-17 定）。
  Color _bubbleColor({required bool mine, String? senderMemberId}) {
    if (!mine && senderMemberId != null && _isGroup) {
      final palette = _uiStyle == 'gradient'
          ? _groupBubblePaletteGradient
          : _groupBubblePalettePlain;
      return palette[_groupColorIndex(senderMemberId)];
    }
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

  /// 群空间气泡色板——gradient（深色、白字）与 plain（浅 tint）各 4 色：沿用
  /// duo 的品牌色系（蓝/粉/青/紫），饱和度对齐两人空间的视觉基调。
  ///
  /// 为什么不用 slot 取模：槽位是内部实现（新身份分配最小空槽、存量库还有
  /// pending 行），同一成员在不同设备/不同时刻算出来的颜色必须一致 → 用
  /// member_id 哈希（恒定）。
  static const List<Color> _groupBubblePaletteGradient = [
    Color(0xFF2271F7), // 品牌深蓝
    Color(0xFFB83D80), // 深粉
    Color(0xFF00838F), // 深青
    Color(0xFF6A4FB6), // 紫
  ];
  static const List<Color> _groupBubblePalettePlain = [
    Color(0x2E3BAFFD), // 天蓝 tint（alpha 0.18——与 duo 的素雅档同深度）
    Color(0x2ED6529C), // 品牌粉 tint（同上）
    Color(0x3826C6DA), // 青 tint（alpha 0.22——与 duo 同性别第二人同深度）
    Color(0x389575CD), // 紫 tint
  ];

  /// member_id → 色板下标：取 id 的稳定哈希（FNV-1a 32 位）模色板长度。
  static int _groupColorIndex(String memberId) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < memberId.length; i++) {
      hash ^= memberId.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash % _groupBubblePaletteGradient.length;
  }

  /// **气泡上**的媒体前景色（音频播放键/波形、文件图标）：gradient 深色气泡用白，
  /// 素雅浅色 tint 用主题蓝。
  ///
  /// 消息流气泡与**长按菜单预览条**共用——菜单里那条也是按性别配的同款气泡底色，
  /// 只是波形窄一点，配色必须跟气泡一致（2026-09-27 踩过：预览条漏了这层 → 图标黑、
  /// 气泡里白）。**改配色改这里，两处一起变。**
  /// 引用条/引用块底色不同（6% 黑的浅底），各自传自己的颜色，不走这个 getter。
  Color get _mediaForegroundOnBubble => _uiStyle == 'gradient'
      ? Colors.white
      : Theme.of(context).colorScheme.primary;

  /// 消息内容按类型渲染（text 文本 / voice、audio 播放条 / image、video、file 各自卡片）。
  Widget _buildMessageContent(
      HistoryMessage m) {
    switch (m.env.type) {
      case 'voice':
      case 'audio':
        return _buildAudioBar(m, foreground: _mediaForegroundOnBubble);
      case 'image':
        return _buildImage(m);
      case 'video':
        return _buildVideo(m);
      case 'file':
        // 与音频条同一套前景色（气泡里 gradient 白 / 素雅主题蓝）：此前文件图标
        // 靠 ambient IconTheme，素雅模式下是默认黑，跟旁边音频播放键的蓝不是一个色
        return _buildFileCard(m, foreground: _mediaForegroundOnBubble);
      case 'system':
        return _buildSystemHint(m);
      default:
        // 文本消息：自动扫描明文里的 URL 渲染成可点链接（方案1，老板 2026-09-28）。
        // gradient 深色气泡下链接用白色（正文同色系），素雅气泡用品牌蓝（组件默认）。
        return LinkifiedText(m.plaintext,
            linkColor: _uiStyle == 'gradient' ? Colors.white : const Color(0xFF2271F7));
    }
  }

  /// 系统提示条（当前只有通话记录）：灰字 + 小图标的一行，不显示明文
  /// （明文是空的——文案由本端按自己的语言渲染）。
  Widget _buildSystemHint(HistoryMessage m) {
    final l10n = AppLocalizations.of(context)!;
    final meta = m.meta;
    final state = meta?[kMetaCallState] as String?;
    final seconds = meta?[kMetaCallDurationSeconds];
    final text = switch (state) {
      kCallStateCompleted => l10n.voiceCallRecordDuration(_formatCallDuration(seconds)),
      kCallStateMissed => l10n.voiceCallEndedNoAnswer,
      kCallStateDeclined => l10n.voiceCallEndedDeclined,
      kCallStateBusy => l10n.voiceCallEndedBusy,
      kCallStateCanceled => l10n.voiceCallEndedCanceled,
      kCallStateFailed => l10n.voiceCallEndedFailed,
      _ => m.plaintext,
    };
    final icon = switch (state) {
      kCallStateMissed || kCallStateDeclined || kCallStateBusy => Icons.call_missed_outlined,
      kCallStateFailed || kCallStateCanceled => Icons.call_end_outlined,
      _ => Icons.call_outlined,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: Colors.black54),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ),
      ],
    );
  }

  /// 通话时长 `mm:ss`（超过 1 小时时分钟位继续累加，如 `83:20`）。
  String _formatCallDuration(Object? seconds) {
    final total = seconds is int ? seconds : (seconds is num ? seconds.round() : 0);
    final mm = (total ~/ 60).toString().padLeft(2, '0');
    final ss = (total % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  /// 音频条：播放键 + 固定波形图 + 时长（录音只写秒数 `25s`，上限 60s；音频文件
  /// 用 h/m/s，零的部分省略）。音频文件**多一行文件名**，与波形左对齐（老板
  /// 2026-09-27）。点击下载解密后播放（老板要求 2026-09-13）；**整块**可点（含
  /// 时长、文件名），不必非点中播放键（老板 2026-09-27）。
  ///
  /// 消息流气泡、长按菜单预览行、输入栏引用条、气泡里的引用块**共用这一个 widget**
  /// （老板 2026-09-27：这几处要一个样）。
  /// - [foreground] 由**调用方**给：四处底色不同（深色气泡 / 6% 黑引用条 / 引用块），
  ///   靠 ambient 主题必然有一处看不见（已踩过：菜单里图标变黑）。
  /// - [tappable] 为 false 时不挂整块点击：**气泡引用块的单击是"跳到原消息"**，不能
  ///   被"点哪都播放"抢掉；播放键本身仍可点（内层 IconButton 照旧）。
  ///
  /// 外层监听播放状态版本：菜单在独立路由、页面 setState 重建不到它。
  Widget _buildAudioBar(
      HistoryMessage m,
      {double waveformWidth = 120,
      required Color foreground,
      bool tappable = true}) {
    return ValueListenableBuilder<int>(
      valueListenable: _audioPlaybackVersion,
      builder: (context, _, child) => _buildAudioBarBody(m,
          waveformWidth: waveformWidth,
          foreground: foreground,
          tappable: tappable),
    );
  }

  Widget _buildAudioBarBody(
      HistoryMessage m,
      {required double waveformWidth,
      required Color foreground,
      required bool tappable}) {
    final playing = _playingMessageId == m.env.messageId;
    final seconds = _audioDurationSeconds(m);
    final isVoice = m.env.type == 'voice';
    final Widget playButton = IconButton(
      // 图标颜色**显式给**（跟波形同源 [foreground]，不再依赖外部 IconTheme）：
      // 消息气泡有 IconTheme.merge 把图标染白，而长按菜单预览条**没有**那一层
      // → 同一条音频条在两处两个颜色（老板 2026-09-27 实测：气泡白、弹窗黑）。
      icon: Icon(playing ? Icons.stop_circle : Icons.play_circle, color: foreground),
      onPressed: () => _playAudioMessage(m),
      visualDensity: VisualDensity.compact,
    );
    // 波形图 + 时长：**录音与音频文件共用同一段**（老板 2026-09-27）。波形只是
    // "形状由 messageId 决定"的装饰（不是真实波形），两种消息都能用。
    final Widget waveformRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 固定波形图：形状由 messageId 决定（同一条消息每次渲染一致），
        // 播放时已播部分染高亮色 + 竖线从左往右走，走完复原。
        _VoiceWaveform(
          playing: _audioStartedMessageId == m.env.messageId,
          durationSeconds: seconds,
          seed: m.env.messageId,
          width: waveformWidth,
          activeColor: foreground,
          inactiveColor: foreground.withValues(alpha: 0.4),
        ),
        // 时长未知时不显示任何文字（播放键 + 波形已足够表达"这是音频"，
        // 老板要求 2026-09-13）。录音只写秒数（上限 60s），音频文件用 h/m/s
        // （几个小时的音频写 "7200s" 没法看）。
        if (seconds > 0) ...[
          const SizedBox(width: 6),
          Text(
            isVoice ? _formatVoiceDuration(seconds) : _formatHmsDuration(seconds),
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ],
    );
    final Widget body;
    if (isVoice) {
      body = Row(
        mainAxisSize: MainAxisSize.min,
        children: [playButton, waveformRow],
      );
    } else {
      // 音频文件：播放键独占左列，右边一列两行（老板 2026-09-27）——上行波形+时长、
      // 下行文件名。**文件名与波形左对齐**靠这个"左列/右列"结构天然保证，不用
      // 量播放键宽度再去凑缩进（之前那版第二行贴着气泡左边缘，跟播放键不齐）。
      // 乐符图标已按老板要求删掉：文件名本身就是"这是一首歌"的最好说明。
      body = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          playButton,
          // Flexible 包住右列：它是这个 Row 里唯一的 flex 子项 → 拿到**有界**宽度
          // （父给的上限减去播放键），里面那行文件名才会按 ellipsis 截断。
          // 少了这一层，右列变成非 flex 子项、宽度**无界**，长歌名直接撑破气泡
          // （老板 2026-09-27 实测四处都破）。
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                waveformRow,
                // 单行 + 截断：Flexible 放在 Row 里才管**宽度**（放 Column 里变成管高度）
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        m.plaintext.trim().isEmpty ? m.env.type : m.plaintext.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    }
    // 气泡引用块（[tappable] = false）：不挂整块点击，把单击让给外层的"跳到原消息"。
    if (!tappable) return body;
    // 整块可点 = 播放/停止：**不必非点中那个播放键**，时长、文件名都在范围里
    // （老板 2026-09-27，与图片"点消息本体就是看大图"对齐）。播放键保留（它仍能点）。
    // behavior=opaque：否则容器自身不参与命中测试，只有子控件占的那几块能点——
    // 播放键与波形之间的空隙、两行之间的空隙都会漏掉（文件卡片同理）。
    return Clickable(
      onTap: () => _playAudioMessage(m),
      behavior: HitTestBehavior.opaque,
      child: body,
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


  /// 文件消息名片：文件图标 + 文件信息（上=文件名、下=尺寸）。
  ///
  /// 消息流气泡、长按菜单预览条、输入栏引用条、气泡里的引用块**共用这一个 widget**
  /// （老板 2026-09-27：与音频条同样处理）。
  /// - [tappable] 为 true（气泡/菜单预览条/引用条）：**整块**可点 = 下载/打开
  ///   （本机有留存副本则直接用系统应用打开；老板 2026-09-15）。
  /// - [tappable] 为 false（**气泡引用块**）：整块单击让给外层的"跳到原消息"，
  ///   只有**文件图标**本身可点 = 打开（老板 2026-09-27）。
  /// 图标颜色**显式给**：复用它的几处 ambient IconTheme 不一样（踩过"菜单里变黑"）。
  Widget _buildFileCard(
      HistoryMessage m, {bool tappable = true, Color? foreground}) {
    final size = (m.attachment?['size'] as int?) ?? 0;
    final subtitleColor = _uiStyle == 'gradient' ? Colors.white70 : Colors.grey;
    // 附件消息明文是「📎 文件名」（发送端兜底文案）；名片里已有文件图标，前缀去掉
    var name = m.plaintext.trim();
    if (name.startsWith('📎')) name = name.replaceFirst('📎', '').trim();
    // 图标**单独可点**（整块不可点时——引用块——就只剩它能打开）。
    // opaque：整个 30×30 的方块都可点，不只落在字形上的那几个像素。
    final Widget icon = Clickable(
      onTap: () => _downloadFile(m),
      behavior: HitTestBehavior.opaque,
      child: Icon(Icons.insert_drive_file, size: 30, color: foreground),
    );
    // Flexible 套右列：它是 Row 里唯一的 flex 子项，拿到的是**有界**宽度（父给的
    // 上限减去图标），文件名才能按 maxLines:1 + ellipsis 截断。去掉它 → 右列变成
    // 非 flex 子项、宽度无界 → 长文件名撑破气泡（老板 2026-09-27 实测）。
    final Widget card = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // maxLines:1 + ellipsis：长文件名**压成一行**，不换行、不撑破区域
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(_formatSize(size),
                  style: TextStyle(fontSize: 11, color: subtitleColor)),
            ],
          ),
        ),
      ],
    );
    if (!tappable) return card;
    return Clickable(
      onTap: () => _downloadFile(m),
      behavior: HitTestBehavior.opaque,
      child: card,
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
    } on ApiException catch (e) {
      if (!mounted) return;
      showTopNotice(context, backendError(l10n, l10n.chatPageDownloadFailed(e.message)));
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
        // titleSpacing 8 + 内边距 8 = 原来的 16：logo 位置不变，
        // 但按住高亮的左缘退到 8（老板 2026-09-24）
        titleSpacing: 8,
        // 抬头只显示品牌名+slogan（不暴露空间 ID，对普通用户无意义）；
        // 在线状态由对话顶部条双灯呈现（「我的」灯三态：灰=未连接服务/绿=已连接/红=断线）
        //
        // 顶栏左半边现在分成**两个**点击对象（老板 2026-09-28）：
        //   ① logo 一块 → 「关于秘境」弹层；
        //   ② 标题「我的秘境」+ 下拉箭头 一块 → 「切换我的秘境」弹层，箭头紧挨着
        //      标题文字（原先是独立 IconButton，离文字一个图标按钮那么远）。
        //      只在 2 个及以上空间时给：单空间别暗示这里能切（2026-09-24 定），
        //      此时标题不可点。
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: l10n.aboutPageTitle,
              child: InkWell(mouseCursor: SystemMouseCursors.click,
                borderRadius: BorderRadius.circular(10),
                onTap: _openAboutPage,
                child: const Padding(
                  // 给按住/长按的半透明高亮留出边距（否则会紧贴 logo 边缘）
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  child: BrandLogo(),
                ),
              ),
            ),
            Flexible(child: _brandTitle()),
            // 其它秘境有未读 → 汇总角标（老板 2026-09-26）：不打开「选择秘境」
            // 也能一眼看到"别的秘境来消息了"。
            if (_otherUnreadTotal > 0) _UnreadBadge(count: _otherUnreadTotal),
          ],
        ),
        actions: [
          // （语音通话按钮在**状态条**里、对方芯片旁边——已加入才显示；
          //  未加入时那块位置显示「邀请加入」。见 _buildPeerChip 的 trailing）
          // 阅后即焚生效时的小标记（火苗 + 档位）：点击**直接**进档位弹层。
          // 放最左（锁屏按钮 / 汉堡菜单的左侧）。老板 2026-09-24：开了焚毁是一个
          // "会丢消息"的状态，值得在顶栏一直看得见，而不是藏进菜单里才发现。
          if (_burnSeconds > 0) _buildBurnBadge(l10n),
          // 锁屏（老板要求 2026-09-16）：一键立即锁屏，放在下拉菜单图标左侧。
          // 仅在已设置锁屏码时出现——没设 PIN 时锁屏不激活（LockPage 只会显示
          // "尚未设置锁屏码"提示页），摆一个按了没用的按钮反而误导。
          if (_hasPin)
            IconButton(
              icon: const Icon(Icons.lock_outline),
              tooltip: l10n.chatPageLockNow,
              onPressed: _lockNow,
            ),
          // 顶栏统一入口：语言/阅后即焚/本机 PIN（显示各功能当前值）
          PopupMenuButton<String>(
            // 菜单按钮：框架内部用 InkWell 且不接受 mouseCursor 参数，只能自己包一层
            // （覆盖视觉上的可点区＝图标本身；外圈 12px 留白仍是箭头）
            icon: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: const Icon(Icons.menu),
            ),
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
                case 'advanced':
                  _menuAction(_showAdvancedSheet);
                case 'notify':
                  _menuAction(_showNotifyDialog);
                case 'pin':
                  _menuAction(_showSetLockDialog);
                case 'about':
                  _menuAction(_openAboutPage);
                case 'name':
                  _menuAction(_showRenameDialog);
                case 'avatar':
                  _menuAction(_showAvatarUpload);
                case 'members':
                  _menuAction(_showMembersSheet);
                case 'entrancelist':
                  _menuAction(_showEntranceListSheet);
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
              // （macOS 偏大），同一菜单里纯标签行（头像/高级安全/关于/切换/退出）
              // 会比带值的行（我的身份/语言/主题/通道名称/阅后即焚/附件/锁屏码）显大一号
              final labelStyle = TextStyle(
                  fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant);
              final captionStyle = TextStyle(
                  fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant);
              final valueStyle = TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w500);
              // 「邮件通知」右侧值：没拉到（null）或没设置（none）时**不显示**——
              // 与「锁屏码」同款处理（老板 2026-09-15），静默比瞎显示"未设置"好
              final notifyValue = _notifyMenuValue(l10n, valueStyle);
              return [
                // 菜单分组（老板 2026-09-24 定；2026-09-25 删「生成开通码」项，
                // 改由「通道列表」弹层里的「新建通道」按钮承担）：
                //   ① 外观与锁：界面语言 / 界面主题 / 锁屏码
                //   ② 身份·通道·内容：我的身份 / 我的头像 / 当前通道 / 通道列表 /
                //      阅后即焚 / 附件存储 / 高级安全
                //   ③ 结尾：关于秘境 / 切换我的秘境 / 退出本应用
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'locale',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuLocaleLabel, style: captionStyle),
                      const Spacer(),
                      _menuValue(kLocaleLabels[langCode] ?? langCode, valueStyle),
                    ],
                  ),
                ),
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'style',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuStyleLabel, style: captionStyle),
                      const Spacer(),
                      _menuValue(_uiStyleLabel(_uiStyle, l10n), valueStyle),
                    ],
                  ),
                ),
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'pin',
                  child: Row(
                    children: [
                      Text(l10n.chatPagePinLabel, style: captionStyle),
                      const Spacer(),
                      // 未设置时只显示「锁屏码」，不显示「未设置」尾缀（老板 2026-09-15）
                      if (_hasPin) _menuValue(l10n.chatPagePinSetValue, valueStyle),
                    ],
                  ),
                ),
                const PopupMenuDivider(height: kMenuDividerHeight),
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'name',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuMyNameLabel, style: captionStyle),
                      const Spacer(),
                      _menuValue(_myMemberName.isEmpty ? l10n.chatPageNameUnset : _myMemberName, valueStyle),
                    ],
                  ),
                ),
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
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
                // 邮件通知（2026-10-01）：没进应用商店 → 没有后台推送，用邮件把离线的
                // 人拉回来。2026-10-02 起挪到「我的头像」之后（老板定），属分组②
                // （身份·通道·内容）。
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'notify',
                  child: Row(
                    children: [
                      Text(l10n.chatPageNotifyLabel, style: captionStyle),
                      const Spacer(),
                      // 图标在值文字左边、图标+文字整体靠右（老板 2026-10-02；
                      // 与 devices/沙漏行同款右簇排布），尺寸同族 18
                      Icon(Icons.mark_email_unread_outlined,
                          size: 18, color: labelStyle.color),
                      if (notifyValue != null) ...[
                        const SizedBox(width: 4),
                        notifyValue,
                      ],
                    ],
                  ),
                ),
                // 「空间成员」（群聊一期 2026-10-03）：成员名单 + 邀请新成员 /
                // 「在其他设备加入我的账号」。紧挨「我的通道」——一个是"这个空间
                // 里有谁"，一个是"我在这个空间挂了几条线"，同属身份·通道分组。
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'members',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuMembers, style: captionStyle),
                      const Spacer(),
                      // 右簇：人数 + group 图标（与「我的通道」的 devices + 数字同款）
                      if (_memberCount > 0) ...[
                        Text('$_memberCount', style: valueStyle),
                        const SizedBox(width: 4),
                      ],
                      Icon(Icons.group_outlined, size: 18, color: labelStyle.color),
                    ],
                  ),
                ),
                // 「通道列表」：我本人在本空间的其他通道（老板 2026-09-25：多设备登录
                // 时看一眼"我还有哪些线挂着、在不在线"）。2026-10-02 合并原「当前通道」
                // 菜单项：改名入口收进弹层顶部的当前通道行，菜单只留这一项「我的通道」
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'entrancelist',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuEntranceList, style: captionStyle),
                      const Spacer(),
                      // 右侧 devices 图标 + 通道总数：与状态条「更多通道」入口同族
                      // （老板 2026-09-28）；数量是 member 维度（含本机），
                      // 轮询没拉到（离线）就不显示，不占位
                      Icon(Icons.devices, size: 18, color: labelStyle.color),
                      if (_myEntranceCount != null) ...[
                        const SizedBox(width: 4),
                        _menuValue('$_myEntranceCount', valueStyle),
                      ],
                    ],
                  ),
                ),
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'burn',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuBurnLabel, style: captionStyle),
                      const Spacer(),
                      // 沙漏图标与顶栏标记同族（_BurnHourglass，老板 2026-09-28）：
                      // 未焚毁态是翻转动画的实沙漏；尺寸与 devices 图标一致（18）
                      const _BurnHourglass(burned: false, size: 18),
                      const SizedBox(width: 4),
                      // 不设期限（0）不显示档位值，菜单项只显示「阅后即焚」；
                      // 选了具体时长才在右侧显示（老板 2026-09-15）
                      if (_burnSeconds > 0)
                        _menuValue(_burnOptionLabel(_burnSeconds, l10n), valueStyle),
                    ],
                  ),
                ),
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'storage',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuAttachmentStorage, style: captionStyle),
                      const Spacer(),
                      _menuValue(_attachmentStorageLabel(_attachmentStorage, l10n), valueStyle),
                    ],
                  ),
                ),
                // 高级（二级菜单走底部弹层）
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
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
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                  height: kMenuRowHeight,
                  value: 'about',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuAbout, style: labelStyle),
                      const Spacer(),
                      // 右侧品牌 logo：与 devices/沙漏图标同大小（18，老板 2026-09-28）
                      const BrandLogo(size: 18),
                    ],
                  ),
                ),
                // 空间组：紧贴「退出」上方（老板 2026-09-22：切换空间属"离开当前空间"
                // 一类操作，放在关于之下、退出之上）。回调由入口注入——聊天页自己不读
                // Vault（PIN 模式下读/写 Vault 都要 pin，而它刻意不持有 PIN）。
                // 「切换空间」：唯一的空间入口（2026-09-22 由「切换空间 / 空间管理」合并，
                // 两者本来就指向同一个页面）。两个回调实际只会有一个非空（取决于谁注入）。
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
                    height: kMenuRowHeight,
                    value: 'switchspace',
                    child: Row(
                      children: [
                        Text(l10n.spaceListSwitch, style: labelStyle),
                        const Spacer(),
                        // 右侧 dynamic_feed 多窗口叠加：表达"多个空间"（老板
                        // 2026-09-28 定稿：layers/collections 对比后选回 dynamic_feed）
                        Icon(Icons.dynamic_feed, size: 18, color: labelStyle.color),
                      ],
                    ),
                  ),
                PopupMenuItem(mouseCursor: SystemMouseCursors.click,
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
            // 内边距不再挂在胶囊上，改由左右两块各自持有——这样左侧那块能**上/下/左
            // 三边完全贴合**胶囊边框（老板 2026-09-24）；clip 让它的方角被胶囊圆角裁掉。
            clipBehavior: Clip.antiAlias,
            // IntrinsicHeight：给这行一个确定高度，左侧那块才能用 stretch 撑满
            //（父级 Column 不限高，直接 stretch 会得到 Infinity 高度）
            child: IntrinsicHeight(
              child: Row(
                // spaceBetween + 两侧都 Flexible：名字短时左边贴左、右边贴右；名字长时
                // 各自最多占一半、超出「…」（老板 2026-09-24 实测：长名字会越过中线、
                // 冲出胶囊条）。圆点与箭头是固定项，永不被压掉。
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                // 子项撑满高度 → 左侧那块上下与胶囊贴合
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 对方（左）：圆点 + 名字（多空间时再加下拉箭头与可按底色；
                  // 对方未加入时紧跟其后的「邀请加入」链接，见 _buildPeerStatus）
                  Flexible(child: _buildPeerStatus(l10n)),
                  // 我的（右）：名字 + 状态灯/时刻 + 头像（老板 2026-09-26 新设计：
                  // 状态条加高到能放头像，**我方头像在最右**，文字在头像左侧）。
                  // 名字为空则不显示文本，只留灯与时刻。
                  //
                  // 「更多通道」的入口改成**名字左侧那个箭头**（老板 2026-09-26）：
                  // 舍弃原来的"整块可按 + 悬浮底色"的芯片效果——那一块现在只负责
                  // 展示（名字 + 状态灯/时刻），点它没有任何动作。
                  // Align 把内容收到实际宽度：不加的话会被 Flexible 撑满右半边、
                  // 内容与头像之间空一大段。
                  Flexible(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        // 右/上/下都 0：我方头像三面贴住胶囊内壁（与左侧对称）；
                        // 左 12 是"与左边那块之间的最小间隔"（名字很长被压缩时的兜底）
                        padding: const EdgeInsets.fromLTRB(12, 0, 0, 0),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 箭头：独立可点 → 「更多通道」弹层（我的各条通道列表）
                            Material(
                              color: Colors.transparent,
                              shape: const CircleBorder(),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                mouseCursor: SystemMouseCursors.click,
                                onTap: _showEntranceListSheet,
                                hoverColor: Colors.black.withValues(alpha: 0.05),
                                highlightColor: Colors.black.withValues(alpha: 0.08),
                                child: Tooltip(
                                  // 桌面端悬停提示：光看图标不一定看得出是"多设备"
                                  message: l10n.chatPageMenuEntranceList,
                                  child: SizedBox(
                                    // 正圆：非正方形会被 CircleBorder 拉成椭圆、顶到
                                    // 状态条上下边缘（与 invite 同源的问题）。
                                    // 边长与呼叫图标同源（kStatusAvatarSize=40）：
                                    // 32 的背景圈偏小、间距发紧（老板 2026-09-28）
                                    width: kStatusAvatarSize,
                                    height: kStatusAvatarSize,
                                    // 「手机 + 显示器」并排：比下拉箭头更能表达
                                    // "我有多条通道/设备"（老板 2026-09-26）
                                    child: Icon(Icons.devices,
                                        size: 20,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant),
                                  ),
                                ),
                              ),
                            ),
                            // 与「名字/时间」的间距 16px：加上图标在 32 宽容器里的
                            // 居中余量（(32-20)/2 = 6），到图标**视觉边缘**正好 22px，
                            // 与对方一侧（Invite 文字 22px）一致（老板 2026-09-26）
                            const SizedBox(width: 16),
                            // Flexible 要包在**Column 外面**（老板 2026-09-28 实测的溢出：
                            // 名字长到 44 字时，这一行要 767px、只给 376px →
                            // "overflowed by 391 pixels on the right"）。
                            // 里面的 Flexible 只管**上下**（名字与状态行挤不开时压名字）；
                            // 横向不给任何约束 —— 名字有多长，Column 就有多宽。
                            // 对方那半格一直是外侧包 Flexible 的写法（2026-09-24 修的），
                            // 我方这半漏了。
                            Flexible(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  if (_myMemberName.isNotEmpty)
                                    Flexible(
                                      child: Text(_myMemberName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.end,
                                          // 与对方一侧同号（15），两侧视觉对称
                                          style: const TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w500)),
                                    ),
                                  const SizedBox(height: 1),
                                  _statusLine(
                                    online: _ws?.connected.value ?? false,
                                    offlineColor:
                                        _ws == null ? Colors.grey : Colors.red,
                                    sinceMs: _mySinceMs,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            _statusAvatar(
                              bytes: _myAvatarBytes,
                              gender: _myGender,
                              // 空头像：点它没有大图可看 → 直接进换头像流程；
                              // 有头像：开大图，大图里再给「更换头像」按钮
                              onTap: _myAvatarBytes == null
                                  ? () => unawaited(_showAvatarUpload())
                                  : () => unawaited(_showAvatarFullscreen(
                                      _myAvatarBytes!,
                                      allowReplace: true)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
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
                // 发送者 memberId：信封字段优先，缺失（旧版附件/语音消息）用通道映射兜底。
                // 群聊一期：group 空间的**气泡配色**与**发送者名字**都要它，不能只在
                // 头像开关打开时才算（配色永远按 member 走）。
                final senderMemberId =
                    m.env.senderMemberId ?? _repo.memberIdOfEntrance(m.env.senderEntranceId);
                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 气泡旁的头像：duo 默认**关**（状态条里已有双方头像，逐条再挂
                      // 一个是重复——老板 2026-09-26）；**group 默认开**（"这句是谁
                      // 说的"必须逐条标注，注释里预留的场景已到来）。
                      // `--dart-define=SHOW_MESSAGE_AVATARS=true` 可强制开（含 duo）。
                      if (_showMessageAvatars && !mine) ...[
                        _MessageAvatar(
                            memberId: senderMemberId,
                            server: effectiveServer,
                            api: widget.api),
                        const SizedBox(width: 6),
                      ],
                      Clickable(
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
                                // 群聊一期：group 空间按发送者 member 取哈希色板
                                // （duo 走原来的性别/槽位规则，一字未改）
                                : _bubbleColor(mine: mine, senderMemberId: senderMemberId),
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
                                  // 群聊一期（2026-10-03）：群空间里"这句是谁说的"
                                  // 逐条标注——放在气泡内、时间行上方（duo 不显示：
                                  // 两人世界里只有"对方"，状态条已经写着了）。
                                  if (!mine && _isGroup && !m.deleted) ...[
                                    Text(
                                      _senderNameOf(senderMemberId),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: _uiStyle == 'gradient'
                                            ? Colors.white
                                            : Colors.grey.shade700,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                  ],
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
                                                fontSize: 11,
                                                color: _uiStyle == 'gradient'
                                                    ? Colors.white70
                                                    : Colors.grey)),
                                        // 快捷动作（老板 2026-10-02）：时间后、焚毁
                                        // 指示前——引用 + 拷贝（拷贝仅文字消息）。
                                        // 点击直接执行，不用进长按菜单；墓碑消息
                                        // 无内容可操作，不显示
                                        if (!m.deleted) ...[
                                          // 时间戳 → 引用图标：比动作间间隔多 4（补齐
                                          // 图标自身 padding 造成的不对称，老板 2026-10-02）
                                          const SizedBox(width: 6),
                                          _bubbleQuickAction(
                                            m,
                                            icon: Icons.format_quote,
                                            label: l10n.chatPageActionQuote,
                                            onTap: () {
                                              setState(() => _quoteTarget = m);
                                              _inputFocusNode.requestFocus();
                                            },
                                          ),
                                          const SizedBox(width: 2),
                                          // 拷贝仅文字消息；媒体消息（图片/视频/音频/
                                          // 文件）换成「保存」——直接写本机，同长按
                                          // 菜单「保存」（老板 2026-10-02）
                                          if (m.env.type == 'text')
                                            _bubbleQuickAction(
                                              m,
                                              icon: Icons.copy_outlined,
                                              label: l10n.chatPageCopy,
                                              onTap: () async {
                                                await Clipboard.setData(
                                                    ClipboardData(text: m.plaintext.trim()));
                                                if (!mounted) return;
                                                showTopNotice(
                                                    this.context, l10n.setupCreateCopied);
                                              },
                                            ),
                                          if (m.attachment != null)
                                            _bubbleQuickAction(
                                              m,
                                              icon: Icons.save_alt,
                                              label: l10n.chatPageActionSave,
                                              onTap: () => _saveAttachment(m),
                                            ),
                                        ],
                                        if (m.expiresAt != null) ...[
                                          const SizedBox(width: 4),
                                          // 沙漏=阅后即焚倒计时（老板 2026-09-12，
                                          // 替代原来的时钟图标，避免与发送中混淆）；
                                          // 已焚毁/已删除 → 静态空沙漏（不再翻转）。
                                          // 可点（老板 2026-10-02）：点击进档位设置
                                          // 弹层（同长按菜单「阅后即焚」）——仅活消息；
                                          // 墓碑无内容可操作，保持纯显示
                                          if (!m.deleted)
                                            Material(
                                              color: Colors.transparent,
                                              // 长条控件（沙漏+时长）用圆角矩形背景，
                                              // 不跟快捷图标走圆形（老板 2026-10-02）
                                              borderRadius: BorderRadius.circular(12),
                                              clipBehavior: Clip.antiAlias,
                                              child: InkWell(
                                                mouseCursor: SystemMouseCursors.click,
                                                // 悬浮/点击背景同快捷动作/状态栏图标
                                                hoverColor: Colors.black.withValues(alpha: 0.05),
                                                highlightColor:
                                                    Colors.black.withValues(alpha: 0.08),
                                                onTap: () => _setMessageBurn(m),
                                                child: Padding(
                                                  padding: const EdgeInsets.all(4),
                                                  child: Row(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      _BurnHourglass(burned: m.deleted),
                                                      const SizedBox(width: 2),
                                                      // 时钟标签：手动设置 → ⏰ <修改时间>+<时长>
                                                      // （如 ⏰ 20:47+5m）；全局设置 → 只标时长（⏰ 5m）
                                                      Text(_burnTagLabel(m.expiresAt, m.burnAfterSeconds,
                                                              manual: m.burnManual),
                                                          style: TextStyle(
                                                              fontSize: 11,
                                                              color: _uiStyle == 'gradient'
                                                                  ? Colors.white70
                                                                  : Colors.grey)),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            )
                                          else ...[
                                            // 墓碑（已焚毁/已删除）：纯显示不可点。
                                            // 前面多补 4（老板 2026-10-02）：活消息那路
                                            // 沙漏带 4 padding，墓碑裸排会窄一截
                                            const SizedBox(width: 4),
                                            _BurnHourglass(burned: m.deleted),
                                            const SizedBox(width: 2),
                                            Text(_burnTagLabel(m.expiresAt, m.burnAfterSeconds,
                                                    manual: m.burnManual),
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    color: _uiStyle == 'gradient'
                                                        ? Colors.white70
                                                        : Colors.grey)),
                                          ],
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
                                      Clickable(
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
                      if (_showMessageAvatars && mine) ...[
                        const SizedBox(width: 6),
                        _MessageAvatar(
                            memberId: senderMemberId,
                            server: effectiveServer,
                            api: widget.api),
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
                      Clickable(
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
                                  hintText: l10n.chatPageInputHint,
                                  isDense: true,
                                  // 边框到文字的间距：主题里默认 16/16（那是给
                                  // 口令、名字这类表单用的，字段少、留白宽好读），
                                  // 聊天输入框是"反复打字、希望一行多放字"的场景，
                                  // 左右收到 12（左右各省 4px），垂直同步收到 12——
                                  // 顺带让输入框高度更贴近两侧按钮（老板 2026-09-26）
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 12),
                                ),
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
                                child: Clickable(
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
          title: Center(child: Text(l10n.chatPageClearLockTitle)),
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
      title: Center(child: Text(l10n.chatPageSetLockTitle)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        // 正文（小字提示/输入框）保持靠左——居中的只是标题（老板 2026-09-25）
        crossAxisAlignment: CrossAxisAlignment.start,
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
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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
    required this.session,
    required this.onPassphraseUpdated,
    this.api, // 测试注入（fake api，不触网）；默认按 server 新建
  });

  final String server;
  final ApiClient? api;
  final String spaceKeyB64;
  final String spaceId;
  final int keyVersion;

  /// 本空间的会话（**不是裸 token**）：改口令要连发两次带鉴权请求（读密保箱 + 上传），
  /// 拿裸 token 的话 24h 后这两步都会 401「invalid session」（见 data/space_session.dart）。
  final SpaceSession session;

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
      serverFile = (await widget.session.call((t) => api.getKeyEscrow(t))).file;
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = backendError(l10n, l10n.chatPageChangePassphraseFailed(e.message));
      });
      return;
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
      await widget.session.call((t) => escrow.upload(
            passphrase: newPass,
            spaceKeyB64: widget.spaceKeyB64,
            spaceId: widget.spaceId,
            keyVersion: widget.keyVersion,
            token: t,
            rotated: true,
          ));
      // 3) 记录本端已知口令更新时间（避免下次上线补查误报"对方重设"——
      //    其实是自己刚改的）。本地不存口令（服务器为唯一真相源）。
      int? serverUpdatedAt;
      try {
        serverUpdatedAt =
            (await widget.session.call((t) => api.getKeyEscrow(t))).updatedAt;
      } catch (_) {
        // 记录失败不影响结果（下次上线补查再对比）
      }
      widget.onPassphraseUpdated(serverUpdatedAt); // 聊天页记录已知时间
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = backendError(l10n, l10n.chatPageChangePassphraseFailed(e.message)));
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
      title: Center(child: Text(l10n.chatPageChangePassphraseTitle)),
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

/// 消息发送者头像：按 memberId 从服务端加载（静态缓存避免重复请求），
/// 未设置/加载失败显示默认图标；点击有头像时放大到全屏查看。
/// 是否在每条消息气泡旁显示发送者头像（编译期开关，`--dart-define` 可覆盖）。
///
/// 群聊一期（2026-10-03）起**按空间类型自动**（见 [_ChatPageState._showMessageAvatars]）：
/// duo 默认关（状态条已有双方头像）、group 默认开（必须逐条标注是谁说的）；
/// `--dart-define=SHOW_MESSAGE_AVATARS=true` 强制全开（临时验证用）。
///
/// 用 `bool.fromEnvironment`（编译期常量、但分析器不知道值）而不是写死 false：
/// 写死会让整段 `if` 被判定为死代码，将来改开关时反而不好维护。
const bool kShowMessageAvatarsOverride = bool.fromEnvironment('SHOW_MESSAGE_AVATARS');

/// 状态条里**操作控件**（电话图标 / 下拉箭头 / 邀请链接）的背景高度。
///
/// 比头像（[kStatusAvatarSize]=40）矮：圆形控件的圆弧在上下顶点附近会收窄，
/// 视觉上"离胶囊边缘有距离"；而胶囊形（邀请链接）是**满高的直边**——同样给 40
/// 就直接顶住状态条上下边缘（老板 2026-09-26 实测）。所以统一的背景高度取 32。
const double kStatusControlSize = 32;

/// 状态条上的头像边长（= 名字 + 红绿灯两行的高度）。头像**上下不留白**，
/// 三面贴住胶囊内壁（老板 2026-09-26）。
const double kStatusAvatarSize = 40;

/// 顶部「切换秘境」旁的**未读汇总角标**（其它空间的未读总数）。
///
/// 数字变化时用 [AnimatedSwitcher] 缩放一下（老板 2026-09-26 要的"闪动"）——
/// key 取数字本身，数字一变就重建 child、触发一次缩放动画。
/// 只有**多空间**时才可能出现（单空间没有"其它空间"）。
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      transitionBuilder: (child, animation) =>
          ScaleTransition(scale: animation, child: child),
      child: Container(
        key: ValueKey<int>(count),
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: theme.colorScheme.error,
          borderRadius: BorderRadius.circular(10),
        ),
        // 与空间卡片上的角标同口径：>99 折成 "99+"
        child: Text(
          count > 99 ? '99+' : '$count',
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 状态条上的头像（可点开全屏大图）。
///
/// **桌面端的悬浮反馈**（老板 2026-09-26）：鼠标移上去变手型 + 头像轻微放大（1.06，
/// 用 [ClipOval] 关住，避免放大后顶出胶囊被裁）+ 压暗一层。触屏没有 hover，
/// 这些层不会出现，等于零影响。
class _StatusAvatar extends StatefulWidget {
  const _StatusAvatar({this.bytes, required this.tint, this.onTap});

  final Uint8List? bytes;
  final Color tint;
  final VoidCallback? onTap;

  @override
  State<_StatusAvatar> createState() => _StatusAvatarState();
}

class _StatusAvatarState extends State<_StatusAvatar> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      backgroundColor: widget.tint,
      backgroundImage: widget.bytes != null ? MemoryImage(widget.bytes!) : null,
      child: widget.bytes == null ? const Icon(Icons.person, size: 22) : null,
    );
    final body = SizedBox(
      width: kStatusAvatarSize,
      height: kStatusAvatarSize,
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedScale(
              scale: _hovered ? 1.06 : 1,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: avatar,
            ),
            // 悬浮压暗一层（**只留遮罩**，不放放大镜图标——老板 2026-09-26）
            if (widget.onTap != null)
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _hovered ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (widget.onTap == null) return body;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Clickable(onTap: widget.onTap, child: body),
    );
  }
}

class _MessageAvatar extends StatefulWidget {
  const _MessageAvatar({this.memberId, required this.server, this.api});

  final String? memberId;
  final String server;
  final ApiClient? api;

  @override
  State<_MessageAvatar> createState() => _MessageAvatarState();
}

class _MessageAvatarState extends State<_MessageAvatar> {
  static final Map<String, Uint8List> _cache = {}; // memberId → 头像 bytes

  /// 头像失效广播（memberId）：通知当前在树上的头像重拉——否则静态缓存只在
  /// 进程内有效，换了头像要重启 App 才看得到（老板 2026-09-11）。
  static final ValueNotifier<String?> invalidated = ValueNotifier<String?>(null);

  /// 让某人的头像失效：上传本人头像 / 收到对方 profile.updated 时调用。
  static void invalidate(String? memberId) {
    if (memberId == null || memberId.isEmpty) return;
    invalidated.value = memberId;
  }

  Uint8List? get _bytes => widget.memberId == null ? null : _cache[widget.memberId];

  @override
  void initState() {
    super.initState();
    final pid = widget.memberId;
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
    final pid = widget.memberId;
    if (pid == null || invalidated.value != pid) return;
    _load(pid); // 覆盖旧缓存后再 setState（不先清空——避免闪成默认图标）
  }

  Future<void> _load(String memberId) async {
    try {
      final api = widget.api ?? ApiClient(effectiveServer);
      final bytes = await api.getAvatar(memberId);
      if (bytes == null) return;
      // 缓存写入不看 mounted：失效广播时未挂载的实例（滚出屏幕被回收）若丢弃结果，
      // 静态缓存会一直留着旧图，滚动回来 initState 见缓存命中也不再重拉
      _cache[memberId] = bytes;
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
    return Clickable(
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
      return Clickable(
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
    return Clickable(
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
/// 尺寸默认 11（消息气泡时间行的小标）；汉堡菜单等大号场景传 [size] 覆盖
/// （老板 2026-09-28：菜单里与 devices 图标同大小）。
class _BurnHourglass extends StatelessWidget {
  const _BurnHourglass({this.burned = false, this.size = 11});

  /// 该消息是否已被焚毁/删除（到期或手动删除）——是则显示静态空沙漏。
  final bool burned;

  /// 图标边长。
  final double size;

  @override
  Widget build(BuildContext context) {
    // 已焚毁：静态空沙漏（不创建动画控制器，避免无谓的逐帧重建）
    if (burned) return Icon(Icons.hourglass_empty, size: size);
    return _HourglassFlip(size: size);
  }
}

class _HourglassFlip extends StatefulWidget {
  const _HourglassFlip({this.size = 11});

  final double size;

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
        size: widget.size,
      ),
    );
  }
}
