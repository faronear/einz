// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'OnlySpace';

  @override
  String get cancel => '取消';

  @override
  String get ok => '确定';

  @override
  String get send => '发送';

  @override
  String get confirm => '确认';

  @override
  String get delete => '删除';

  @override
  String get settings => '设置';

  @override
  String get loading => '加载中…';

  @override
  String get skip => '跳过';

  @override
  String get setupPageTitle => 'OnlySpace · 设备配置';

  @override
  String get setupPageHeading => '一次性配置';

  @override
  String get setupPageInstructions =>
      '1) 生成设备密钥 → 公钥加入服务器白名单（config.json）并重启\n2) 粘贴对方用你公钥密封的 Space Key 副本 → 认证';

  @override
  String get setupPageDeviceIdLabel => '设备 ID';

  @override
  String get setupPageSpaceIdLabel => 'Space ID';

  @override
  String get setupPageSealedKeyLabel => '密封的 Space Key（base64）';

  @override
  String get setupPageSealedKeyHint => '粘贴 sealed 副本（sealed-*.txt 内容）';

  @override
  String setupPageKeyInfo(String deviceId, String publicKey) {
    return '设备 ID: $deviceId\n公钥: $publicKey\n（把公钥加入 config.json 后重启服务器）';
  }

  @override
  String get setupPageGenerateKey => '① 生成设备密钥';

  @override
  String get setupPageImportAuth => '② 导入并认证';

  @override
  String get setupPageEscrowLabel => '接入口令（新设备凭它接入，可跳过）';

  @override
  String get setupPageEscrowHelper => '口令托管：Server 只存密文（KEY_ESCROW.md）';

  @override
  String get setupPageEscrowAccess => '③ 凭口令接入（无需 sealed 副本）';

  @override
  String get setupPageGenerateSpaceKey => '自建空间（一键生成 Space Key）';

  @override
  String get setupPageNeedPassphrase => '⚠️ 请先在上方填写接入口令（对方凭它接入）';

  @override
  String get joinDialogTitle => '邀请对方加入';

  @override
  String get joinDialogHint => '对方安装 App 后点“③ 凭口令接入”，扫码或粘贴下方信息即可加入';

  @override
  String joinDialogSpace(String spaceId) {
    return '空间: $spaceId';
  }

  @override
  String joinDialogPassphrase(String passphrase) {
    return '口令: $passphrase';
  }

  @override
  String get joinDialogCopy => '复制加入信息';

  @override
  String get joinDialogCopied => '加入信息已复制，发给对方即可';

  @override
  String get joinDialogContinue => '我已分享，进入聊天';

  @override
  String get scanJoinTooltip => '扫码加入';

  @override
  String get scanJoinTitle => '扫码加入';

  @override
  String get scanJoinHint => '扫描对方的加入二维码';

  @override
  String get scanJoinFound => '已识别加入信息，空间与口令已自动填入';

  @override
  String get wizardRoleTitle => '选择你的情况';

  @override
  String get wizardRoleCreate => '我是第一个使用者，创建新空间';

  @override
  String get wizardRoleJoin => '我要加入对方的空间';

  @override
  String get wizardRoleAdvanced => '高级：导入 sealed 密钥副本';

  @override
  String get wizardNext => '下一步';

  @override
  String get wizardBack => '上一步';

  @override
  String get wizardDone => '完成';

  @override
  String get wizardStepDevice => '设备名称';

  @override
  String get wizardStepWhitelist => '加入服务器白名单';

  @override
  String get wizardStepPassphrase => '设置接入口令';

  @override
  String get wizardStepPin => '设置启动锁';

  @override
  String get wizardStepShare => '邀请对方加入';

  @override
  String get wizardStepJoin => '加入空间';

  @override
  String get wizardStepSealed => '导入 sealed 密钥';

  @override
  String get wizardStepDone => '完成';

  @override
  String get setupPageKeyGenerated => '✅ 密钥已生成';

  @override
  String get wizardWhitelistHint => '把下方公钥加入服务器白名单（config.json）并重启，然后继续';

  @override
  String get wizardPassphraseHint => '对方凭此口令加入——下一步将生成二维码分享给对方';

  @override
  String get wizardPinHint => '每次启动需输入此 PIN 解锁';

  @override
  String get wizardDoneText => '✅ 设置完成！';

  @override
  String get wizardShareHint => '对方扫码或粘贴下方信息即可加入';

  @override
  String get wizardJoinHint => '扫描对方发的二维码，或粘贴对方发给你的加入信息';

  @override
  String setupPageKeyGenFailed(String error) {
    return '❌ 密钥生成失败: $error';
  }

  @override
  String get setupPageGenKeyFirst => '⚠️ 先生成设备密钥';

  @override
  String get setupPagePasteSealed => '⚠️ 请粘贴密封的 Space Key 副本（base64）';

  @override
  String setupPageImportFailed(String error) {
    return '❌ 导入/认证失败: $error';
  }

  @override
  String get setupPageEscrowGenKeyFirst => '⚠️ 请先生成设备密钥（①），并把公钥加入服务器白名单';

  @override
  String get setupPageEscrowFillAll => '⚠️ 请填写 Space ID 与接入口令';

  @override
  String get setupPageNoEscrow => '❌ Server 无口令托管包（请先在对端设置接入口令）';

  @override
  String setupPageEscrowFailed(String error) {
    return '❌ 口令接入失败: $error';
  }

  @override
  String get setPinDialogTitle => '设置启动锁';

  @override
  String get setPinDialogRecoveryTitle => '保存恢复码';

  @override
  String get setPinDialogEnterChat => '我已保存，进入聊天';

  @override
  String get setPinDialogIntro => '每次启动需输入 PIN 才能查看消息；Space Key 将被 PIN 加密保护。';

  @override
  String get setPinDialogPinLabel => 'PIN（至少 4 位）';

  @override
  String get setPinDialogConfirmLabel => '确认 PIN';

  @override
  String get setPinDialogEscrowLabel => '接入口令（可选，换设备凭它接入）';

  @override
  String get setPinDialogEscrowHelper =>
      '口令托管：Server 只存密文，无口令解不开（KEY_ESCROW.md）';

  @override
  String get setPinDialogSetPin => '设置 PIN';

  @override
  String get setPinDialogPinTooShort => 'PIN 至少 4 位';

  @override
  String get setPinDialogPinMismatch => '两次输入的 PIN 不一致';

  @override
  String setPinDialogSetupFailed(String error) {
    return '设置失败: $error';
  }

  @override
  String get setPinDialogEscrowUploaded => '✅ 接入口令已上传托管（换设备可凭口令接入）';

  @override
  String setPinDialogEscrowUploadFailed(String error) {
    return '⚠️ 托管上传失败: $error（可稍后在聊天页重试）';
  }

  @override
  String get setPinDialogRecoveryIntro => '请离线保存以下恢复码（PIN 丢失时用它解锁）：';

  @override
  String get setPinDialogRecoveryWarning => '恢复码与 PIN 分开保存；丢失恢复码且忘记 PIN 将无法解锁。';

  @override
  String chatPageLocaleSwitched(String label) {
    return '已切换：$label';
  }

  @override
  String get chatPageBurnHeading => '阅后即焚（仅本设备生效）';

  @override
  String get chatPageBurnOff => '阅后即焚已关闭（消息永久保留）';

  @override
  String chatPageBurnWillDelete(String duration) {
    return '消息将在 $duration 后自动删除';
  }

  @override
  String chatPageBurnTooltip(String label) {
    return '阅后即焚：$label';
  }

  @override
  String get chatPageBurnBadge => '⏱ 阅后即焚';

  @override
  String chatPageSendFailed(String error) {
    return '发送失败: $error';
  }

  @override
  String chatPageVoiceStartFailed(String error) {
    return '录音启动失败: $error';
  }

  @override
  String chatPageVoiceFailed(String error) {
    return '录音失败: $error';
  }

  @override
  String get chatPageRecordingHint => '录音中…松开发送';

  @override
  String get chatPageInputHint => '输入消息…';

  @override
  String get chatPageAudioMetaMissing => '音频附件元数据缺失';

  @override
  String chatPageAudioPlayFailed(String error) {
    return '音频播放失败: $error';
  }

  @override
  String get chatPageAttachPhoto => '拍照';

  @override
  String get chatPageAttachGalleryImage => '相册图片';

  @override
  String get chatPageAttachVideoCamera => '拍摄视频';

  @override
  String get chatPageAttachVideoGallery => '相册视频';

  @override
  String get chatPageAttachAudioFile => '音频文件（mp3 等）';

  @override
  String get chatPageAttachAnyFile => '任意文件';

  @override
  String get chatPageVideoMetaMissing => '视频附件元数据缺失';

  @override
  String chatPageVideoPlayFailed(String error) {
    return '视频播放失败: $error';
  }

  @override
  String chatPageImageLoadFailed(String plaintext) {
    return '$plaintext\n（加载失败）';
  }

  @override
  String get chatPagePlaying => '播放中…';

  @override
  String get chatPageVoiceLabel => '语音';

  @override
  String get chatPageAttachmentMetaMissing => '附件元数据缺失';

  @override
  String chatPageSaved(String path) {
    return '已保存: $path';
  }

  @override
  String chatPageDownloadFailed(String error) {
    return '下载失败: $error';
  }

  @override
  String get chatPageDeviceRevoked => '设备已被撤销，本地数据已清除，请重新配置';

  @override
  String get burnOptionUnlimited => '无限';

  @override
  String get burnOption1Minute => '1 分钟';

  @override
  String get burnOption5Minutes => '5 分钟';

  @override
  String get burnOption30Minutes => '30 分钟';

  @override
  String get burnOption1Hour => '1 小时';

  @override
  String get burnOption1Day => '1 天';

  @override
  String get burnOption7Days => '7 天';

  @override
  String get lockPageTitle => 'OnlySpace 已锁定';

  @override
  String get lockPagePinPrompt => '输入 PIN 解锁';

  @override
  String lockPageLockedSeconds(int seconds) {
    return '已锁定 $seconds 秒';
  }

  @override
  String get lockPagePinLabel => 'PIN';

  @override
  String get lockPageUnlock => '解锁';

  @override
  String get lockPageUseRecovery => '忘记 PIN？使用恢复码';

  @override
  String get lockPageRecoveryLabel => '12 词恢复码';

  @override
  String get lockPageRecoveryUnlock => '用恢复码解锁';

  @override
  String get lockPageBackToPin => '返回输入 PIN';

  @override
  String lockPageTooManyAttempts(int seconds) {
    return '尝试次数过多，请 $seconds 秒后再试';
  }

  @override
  String lockPageUnlockFailed(String error) {
    return '解锁失败: $error';
  }

  @override
  String lockPageRecoveryFailed(String error) {
    return '恢复失败: $error';
  }
}
