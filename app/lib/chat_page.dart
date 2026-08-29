import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:onlyspace_shared/onlyspace_shared.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

import 'data/burn_after_settings.dart';
import 'data/local_database.dart';
import 'data/lock_timer.dart';
import 'data/message_repository.dart';
import 'lock_page.dart';

/// 附件类型（选择弹层返回）：图像/视频用 image_picker，音频/文件用 file_picker。
enum _AttachmentKind { photo, galleryImage, videoCamera, videoGallery, audioFile, anyFile }

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
  });

  final String server;
  final String spaceId;
  final String deviceId;
  final Uint8List spaceKey;
  final int keyVersion;
  final String token;

  /// 测试注入用；默认新建（生产路径）。
  final LocalDatabase? db;

  /// 测试注入用（fake api）；默认按 [server] 新建（生产路径）。
  final ApiClient? api;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  late final MessageRepository _repo;
  final _input = TextEditingController();
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
  bool _recording = false;
  String? _recordingPath;
  String? _playingMessageId;
  String _burnLabel = '无限'; // 当前阅后即焚档位文字（顶栏 tooltip）

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final db = widget.db ?? LocalDatabase();
    _repo = MessageRepository(
      db: db,
      api: widget.api ?? ApiClient(widget.server),
      spaceKey: widget.spaceKey,
      spaceId: widget.spaceId,
      deviceId: widget.deviceId,
      keyVersion: widget.keyVersion,
      token: widget.token,
      settings: BurnAfterSettings(db),
    );
    _loadInitial();
    _scrollController.addListener(_maybeLoadOlder);
    _loadBurnLabel();
    // 每 3 秒轮询同步（准实时；正式版用 WS listen 推送）
    _ticker = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
    _registerPushToken();
  }

  /// 加载本设备阅后即焚档位（每设备独立，纯本地）。
  Future<void> _loadBurnLabel() async {
    final s = BurnAfterSettings(widget.db ?? LocalDatabase());
    final seconds = await s.load();
    final label = kBurnAfterOptions.entries.firstWhere(
      (e) => e.value == seconds,
      orElse: () => const MapEntry('无限', 0),
    ).key;
    if (mounted) setState(() => _burnLabel = label);
  }

  /// 顶栏 ⏱：选择阅后即焚档位（保存到本设备设置）。
  Future<void> _showBurnPicker() async {
    final settings = BurnAfterSettings(widget.db ?? LocalDatabase());
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
              child: Text('阅后即焚（仅本设备生效）', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final entry in kBurnAfterOptions.entries)
              ListTile(
                title: Text(entry.key),
                trailing: entry.value == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(ctx).pop(entry.key),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final seconds = kBurnAfterOptions[picked]!;
    await settings.save(seconds);
    if (!mounted) return;
    setState(() => _burnLabel = picked);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(seconds == 0 ? '阅后即焚已关闭（消息永久保留）' : '消息将在 $picked 后自动删除')),
    );
  }

  /// iOS：认证后把 APNs device token 注册到 Server（PROTOCOL.md §7.3）。
  /// 推送只发"有新消息"提示；注册失败不影响聊天（WS/轮询兜底）。
  Future<void> _registerPushToken() async {
    if (!Platform.isIOS) return;
    try {
      const channel = MethodChannel('onlyspace/apns');
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
    _scrollController.dispose();
    _input.dispose();
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败: $e')));
    }
  }

  // ---------- 语音：按住录音 → 加密上传（type=voice）→ 发送 ----------

  Future<void> _startVoice() async {
    if (_recording) return;
    try {
      final path = '${Directory.systemTemp.path}/onlyspace_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await (_recorder ??= AudioRecorder()).start(const RecordConfig(), path: path);
      setState(() {
        _recording = true;
        _recordingPath = path;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('录音启动失败: $e')));
    }
  }

  Future<void> _stopVoice() async {
    if (!_recording) return;
    final path = _recordingPath;
    setState(() {
      _recording = false;
      _recordingPath = null;
    });
    try {
      await _recorder?.stop();
      if (path != null) {
        final f = File(path);
        if (await f.exists() && await f.length() > 0) {
          await _repo.sendAttachment(
            fileBytes: await f.readAsBytes(),
            fileName: 'voice.m4a',
            type: 'voice',
          );
          await _refresh();
        }
        await f.delete().catchError((_) => f);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('录音失败: $e')));
    }
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('音频附件元数据缺失')));
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
      setState(() => _playingMessageId = m.env.messageId);
      final bytes = await _repo.fetchAttachment(
        attachmentId: att['attachment_id'] as String,
        keyVersion: att['key_version'] as int,
        sha256: att['sha256'] as String,
        nonce: base64Decode(att['nonce'] as String),
      );
      final ext = m.env.type == 'voice' ? 'm4a' : _extOf(m.plaintext);
      final tmp = File('${Directory.systemTemp.path}/onlyspace_audio_${m.env.messageId}.$ext');
      await tmp.writeAsBytes(bytes);
      await player.stop();
      await player.play(DeviceFileSource(tmp.path));
      player.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _playingMessageId = null);
      }).catchError((_) {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _playingMessageId = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('音频播放失败: $e')));
    }
  }

  // ---------- 图像/视频/音频/文件：选择 → 加密上传 → 发送 ----------

  Future<void> _showAttachmentSheet() async {
    final kind = await showModalBottomSheet<_AttachmentKind>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('拍照'),
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.photo),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('相册图片'),
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.galleryImage),
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('拍摄视频'),
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.videoCamera),
            ),
            ListTile(
              leading: const Icon(Icons.movie),
              title: const Text('相册视频'),
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.videoGallery),
            ),
            ListTile(
              leading: const Icon(Icons.music_note),
              title: const Text('音频文件（mp3 等）'),
              onTap: () => Navigator.of(ctx).pop(_AttachmentKind.audioFile),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: const Text('任意文件'),
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败: $e')));
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('视频附件元数据缺失')));
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
      final tmp = File('${Directory.systemTemp.path}/onlyspace_video_${m.env.messageId}.mp4');
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('视频播放失败: $e')));
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
        if (snap.hasError) return Text('📷 ${m.plaintext}\n（加载失败）');
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
            playing ? '播放中…' : (m.env.type == 'voice' ? '🎤 语音' : '🎵 ${m.plaintext}'),
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('附件元数据缺失')));
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已保存: ${file.path}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('下载失败: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('OnlySpace · ${widget.spaceId}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.timer_outlined),
            tooltip: '阅后即焚：$_burnLabel',
            onPressed: _showBurnPicker,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (context, i) {
                final m = _messages[i];
                final mine = m.sender == 'me';
                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: mine ? Colors.indigo.shade100 : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (m.expiresAt != null)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 2),
                            child: Text('⏱ 阅后即焚', style: TextStyle(fontSize: 10, color: Colors.grey)),
                          ),
                        _buildMessageContent(m),
                      ],
                    ),
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
                  // 语音：按住说话（松开发送）
                  GestureDetector(
                    onLongPressStart: (_) => _startVoice(),
                    onLongPressEnd: (_) => _stopVoice(),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        _recording ? Icons.mic : Icons.mic_none,
                        color: _recording ? Colors.red : null,
                      ),
                    ),
                  ),
                  if (_recording)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Text('录音中…松开发送', style: TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      decoration: const InputDecoration(hintText: '输入消息…', isDense: true),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(onPressed: _send, icon: const Icon(Icons.send)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
