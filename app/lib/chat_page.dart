import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:onlyspace_shared/onlyspace_shared.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

import 'data/local_database.dart';
import 'data/lock_timer.dart';
import 'data/message_repository.dart';
import 'lock_page.dart';

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
  List<({MessageEnvelope env, String plaintext, String sender, Map<String, dynamic>? attachment})> _messages = [];
  Timer? _ticker;
  bool _recording = false;
  String? _recordingPath;
  String? _playingMessageId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _repo = MessageRepository(
      db: widget.db ?? LocalDatabase(),
      api: widget.api ?? ApiClient(widget.server),
      spaceKey: widget.spaceKey,
      spaceId: widget.spaceId,
      deviceId: widget.deviceId,
      keyVersion: widget.keyVersion,
      token: widget.token,
    );
    _refresh();
    // 每 3 秒轮询同步（准实时；正式版用 WS listen 推送）
    _ticker = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
    _registerPushToken();
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

  Future<void> _refresh() async {
    try {
      await _repo.sync();
      final hist = await _repo.history();
      if (!mounted) return;
      setState(() => _messages = hist);
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

  // ---------- 语音播放：下载解密 → 临时文件 → audioplayers ----------

  Future<void> _playVoice(
      ({MessageEnvelope env, String plaintext, String sender, Map<String, dynamic>? attachment}) m) async {
    final att = m.attachment;
    if (att == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('语音附件元数据缺失')));
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
      final tmp = File('${Directory.systemTemp.path}/onlyspace_voice_${m.env.messageId}.m4a');
      await tmp.writeAsBytes(bytes);
      await player.stop();
      await player.play(DeviceFileSource(tmp.path));
      player.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _playingMessageId = null);
      }).catchError((_) {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _playingMessageId = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('语音播放失败: $e')));
    }
  }

  // ---------- 图像/视频：拍照/拍摄/相册 → 加密上传 → 发送 ----------

  Future<void> _showAttachmentSheet() async {
    final choice = await showModalBottomSheet<(ImageSource, bool)>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('拍照'),
              onTap: () => Navigator.of(ctx).pop((ImageSource.camera, false)),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('相册图片'),
              onTap: () => Navigator.of(ctx).pop((ImageSource.gallery, false)),
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('拍摄视频'),
              onTap: () => Navigator.of(ctx).pop((ImageSource.camera, true)),
            ),
            ListTile(
              leading: const Icon(Icons.movie),
              title: const Text('相册视频'),
              onTap: () => Navigator.of(ctx).pop((ImageSource.gallery, true)),
            ),
          ],
        ),
      ),
    );
    if (choice != null) await _sendMedia(choice.$1, choice.$2);
  }

  Future<void> _sendMedia(ImageSource source, bool isVideo) async {
    try {
      final XFile? file = isVideo
          ? await _picker.pickVideo(source: source, maxDuration: const Duration(minutes: 1))
          : await _picker.pickImage(source: source, maxWidth: 1600);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      await _repo.sendAttachment(
        fileBytes: bytes,
        fileName: isVideo ? 'video.mp4' : 'image.jpg',
        type: isVideo ? 'video' : 'image',
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败: $e')));
    }
  }

  // ---------- 视频：下载解密 → 临时文件 → video_player 播放 ----------

  /// 视频消息：播放按钮 + 说明文字；点击下载解密后全屏播放。
  Widget _buildVideo(
      ({MessageEnvelope env, String plaintext, String sender, Map<String, dynamic>? attachment}) m) {
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
      ({MessageEnvelope env, String plaintext, String sender, Map<String, dynamic>? attachment}) m) async {
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
      ({MessageEnvelope env, String plaintext, String sender, Map<String, dynamic>? attachment}) m) {
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

  /// 消息内容按类型渲染（text 文本 / voice 播放条 / image、video 占位待 #4/#5）。
  Widget _buildMessageContent(
      ({MessageEnvelope env, String plaintext, String sender, Map<String, dynamic>? attachment}) m) {
    switch (m.env.type) {
      case 'voice':
        final playing = _playingMessageId == m.env.messageId;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(playing ? Icons.stop_circle : Icons.play_circle),
              onPressed: () => _playVoice(m),
              visualDensity: VisualDensity.compact,
            ),
            Text(playing ? '播放中…' : '🎤 语音'),
          ],
        );
      case 'image':
        return _buildImage(m);
      case 'video':
        return _buildVideo(m);
      default:
        return Text(m.plaintext);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('OnlySpace · ${widget.spaceId}')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
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
                    child: _buildMessageContent(m),
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
