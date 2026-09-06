// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'Einz';

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
  String get setupPageTitle => 'Einz · 设备配置';

  @override
  String get setupPageHeading => '一次性配置';

  @override
  String get setupPageInstructions =>
      '1) 生成设备密钥 → 自动登记入网（无需任何白名单）\n2) 创建或加入私密空间 → 设置启动锁';

  @override
  String get setupPageSpaceIdLabel => 'Space ID';

  @override
  String get setupPageSealedKeyLabel => '密封的 Space Key（base64）';

  @override
  String get setupPageSealedKeyHint => '粘贴 sealed 副本（sealed-*.txt 内容）';

  @override
  String setupPageKeyInfo(String deviceId, String publicKey) {
    return '设备 ID: $deviceId\n公钥: $publicKey\n（下一步将自动登记设备，无需任何白名单）';
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
  String get wizardDetectTitle => '正在检测服务器状态…';

  @override
  String setupPageServerBar(Object server) {
    return '服务器：$server';
  }

  @override
  String get wizardDetectHint => '自动判断你是第几个用户（首个设备将创建空间）';

  @override
  String get wizardDetectFailed => '无法连接服务器，请在上方输入地址后重试';

  @override
  String get wizardNameHint => '这是你的第一个设备，先告诉我们要怎么称呼你（之后可随时 /改名）。';

  @override
  String get wizardNameLabel => '你的名字';

  @override
  String get wizardNameHintInput => '例如 Lukas（可选，之后可改）';

  @override
  String get wizardIdentityHint => '这个空间已有用户——请选择你的身份：';

  @override
  String get wizardIdentityCreator => '第一个用户（创建者）';

  @override
  String get wizardIdentityPartner => '第二个用户（伴侣）';

  @override
  String get wizardIdentityFirst => '⚠️ 请先选择你的身份（创建者或伴侣）';

  @override
  String get wizardInviteHint => '输入对方提供的一次性邀请码（由创建者 /invite 生成，24 小时内有效）';

  @override
  String get wizardRoleCreate => '我是第一个使用者，创建新空间';

  @override
  String get wizardRoleJoin => '我要加入对方的空间';

  @override
  String get wizardRoleAdvanced => '高级：导入 sealed 密钥副本';

  @override
  String get wizardRecoverTitle => '从备份恢复';

  @override
  String get wizardRecoverHint =>
      '全部设备丢失？粘贴导出的密钥备份（EINZ-BACKUP: 开头）并输入口令；口令正确将重置空间并恢复本设备';

  @override
  String get wizardRecoverBackupLabel => '备份文本（EINZ-BACKUP: 开头）';

  @override
  String get wizardRecoverPassphraseLabel => '备份口令';

  @override
  String get wizardRecoverStart => '恢复';

  @override
  String get wizardRecoverInvalidFormat => '备份格式无效（需以 EINZ-BACKUP: 开头）';

  @override
  String get wizardRecoverBadPassphrase => '口令错误或备份损坏';

  @override
  String wizardRecoverFailed(String error) {
    return '恢复失败: $error';
  }

  @override
  String get wizardRecoverEnrolling => '正在登记本设备…';

  @override
  String get wizardRecoverDone => '✅ 已恢复：本设备已入网，请设置 PIN 完成';

  @override
  String get wizardAppBarCreate => '创建新空间';

  @override
  String get wizardAppBarJoin => '加入你的空间';

  @override
  String get wizardAppBarAdvanced => '导入 sealed 密钥';

  @override
  String get wizardNext => '下一步';

  @override
  String get wizardBack => '上一步';

  @override
  String get wizardDone => '完成';

  @override
  String get wizardStepName => '你的名字';

  @override
  String get wizardStepIdentity => '你的身份';

  @override
  String get wizardStepInvite => '输入邀请码';

  @override
  String get wizardStepEnroll => '登记设备';

  @override
  String get wizardStepPassphrase => '设置接入口令';

  @override
  String get wizardStepPin => '设置启动锁';

  @override
  String get wizardStepJoin => '加入空间';

  @override
  String get wizardStepSealed => '导入 sealed 密钥';

  @override
  String get wizardStepDone => '完成';

  @override
  String get setupPageKeyGenerated => '✅ 密钥已生成';

  @override
  String get wizardEnrollHint =>
      '服务器已全自动登记（无需手动白名单）。点击下方登记本设备——若这是服务器的第一台设备，将自动创建私密空间。';

  @override
  String get wizardEnrollAction => '登记本设备';

  @override
  String get wizardEnrollDoneStatus => '✅ 登记成功，可继续';

  @override
  String wizardEnrollDone(String deviceId, String spaceId) {
    return '✅ 登记成功\n设备: $deviceId\n空间: $spaceId';
  }

  @override
  String get wizardEnrollExists =>
      '该服务器已有空间（由其他设备创建）。请改用“加入”向导，凭对方提供的一次性邀请码加入。';

  @override
  String get wizardEnrollGoJoin => '改用“加入”向导';

  @override
  String wizardEnrollFailed(String error) {
    return '❌ 登记失败: $error';
  }

  @override
  String get wizardEnrollFirst => '⚠️ 请先完成设备登记（点上方按钮）';

  @override
  String get wizardPassphraseHint => '对方凭此口令加入——下一步将生成二维码分享给对方';

  @override
  String get wizardPinHint => '每次启动需输入此 PIN 解锁';

  @override
  String get wizardDoneText => '✅ 设置完成！';

  @override
  String get wizardJoinHint => '扫描对方的二维码（含邀请码与口令）即可一键加入；也可粘贴文本或手动填写下方信息';

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
  String get setupPageEscrowFillAll => '⚠️ 请填写 Space ID、接入口令与邀请码';

  @override
  String get setupPageInviteLabel => '邀请码（一次性）';

  @override
  String get setupPageInviteHint => '扫码后自动填入；手动加入时粘贴对方提供的一次性邀请码';

  @override
  String get setupPageNeedInvite => '⚠️ 请填写一次性邀请码（由已认证设备生成）';

  @override
  String get setupPageNoEscrow => '❌ Server 无口令托管包（请先在对端设置接入口令）';

  @override
  String setupPageEscrowFailed(String error) {
    return '❌ 口令接入失败: $error';
  }

  @override
  String get setPinDialogPinLabel => 'PIN（至少 4 位）';

  @override
  String get setPinDialogConfirmLabel => '确认 PIN';

  @override
  String get setPinDialogSetPin => '设置 PIN';

  @override
  String get setupPageSkipPinTitle => '暂不设置启动锁？';

  @override
  String get setupPageSkipPinMessage => '不设启动锁则本设备密钥包不会加密保存，重启后需重新设置。确定跳过？';

  @override
  String get setPinDialogPinTooShort => 'PIN 至少 4 位';

  @override
  String get setPinDialogPinMismatch => '两次输入的 PIN 不一致';

  @override
  String setPinDialogSetupFailed(String error) {
    return '设置失败: $error';
  }

  @override
  String chatPageLocaleSwitched(String label) {
    return '已切换：$label';
  }

  @override
  String get chatPageSetLockTitle => '设置启动锁';

  @override
  String get chatPageSetLockTooltip => '设置启动锁';

  @override
  String get chatPageSetLockDone => '启动锁已设置，下次启动需 PIN 解锁';

  @override
  String chatPageMenuLocale(String value) {
    return '界面语言：$value';
  }

  @override
  String chatPageMenuBurn(String value) {
    return '阅后即焚：$value';
  }

  @override
  String get chatPageMenuInvite => '邀请码';

  @override
  String get chatPageMenuExport => '导出密钥备份';

  @override
  String get chatPageExportTitle => '导出密钥备份';

  @override
  String get chatPageExportPassphraseLabel => '备份口令（加密备份文件；与备份分开保管）';

  @override
  String get chatPageExportGenerate => '生成备份';

  @override
  String get chatPageExportGenerated => '加密备份文本（请与口令分开离线保存）：';

  @override
  String get chatPageExportCopy => '复制';

  @override
  String get chatPageExportCopied => '备份文本已复制';

  @override
  String get chatPageExportHint => '全部设备丢失时：用此备份 + 口令恢复（需服务端已托管口令）';

  @override
  String get chatPagePinSet => 'PIN: 已设置';

  @override
  String get chatPagePinUnset => 'PIN: 未设置';

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
  String get lockPageTitle => 'Einz 已锁定';

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
  String lockPageTooManyAttempts(int seconds) {
    return '尝试次数过多，请 $seconds 秒后再试';
  }

  @override
  String lockPageUnlockFailed(String error) {
    return '解锁失败: $error';
  }
}
