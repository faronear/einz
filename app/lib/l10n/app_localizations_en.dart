// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'OnlySpace';

  @override
  String get cancel => 'Cancel';

  @override
  String get ok => 'OK';

  @override
  String get send => 'Send';

  @override
  String get confirm => 'Confirm';

  @override
  String get delete => 'Delete';

  @override
  String get settings => 'Settings';

  @override
  String get loading => 'Loading...';

  @override
  String get skip => 'Skip';

  @override
  String get setupPageTitle => 'OnlySpace · Device Setup';

  @override
  String get setupPageHeading => 'One-time setup';

  @override
  String get setupPageInstructions =>
      '1) Generate device key → add the public key to the server whitelist (config.json) and restart\n2) Paste the Space Key sealed with your public key → authenticate';

  @override
  String get setupPageDeviceIdLabel => 'Device ID';

  @override
  String get setupPageSpaceIdLabel => 'Space ID';

  @override
  String get setupPageSealedKeyLabel => 'Sealed Space Key (base64)';

  @override
  String get setupPageSealedKeyHint =>
      'Paste the sealed copy (contents of sealed-*.txt)';

  @override
  String setupPageKeyInfo(String deviceId, String publicKey) {
    return 'Device ID: $deviceId\nPublic key: $publicKey\n(Add the public key to config.json and restart the server)';
  }

  @override
  String get setupPageGenerateKey => '① Generate device key';

  @override
  String get setupPageImportAuth => '② Import & authenticate';

  @override
  String get setupPageEscrowLabel =>
      'Access passphrase (new devices can join with it, optional)';

  @override
  String get setupPageEscrowHelper =>
      'Key escrow: the server only stores ciphertext (KEY_ESCROW.md)';

  @override
  String get setupPageEscrowAccess =>
      '③ Join with passphrase (no sealed copy needed)';

  @override
  String get setupPageGenerateSpaceKey => 'Create space (one-tap generate key)';

  @override
  String get setupPageNeedPassphrase =>
      '⚠️ Set an access passphrase above first (your partner joins with it)';

  @override
  String get joinDialogTitle => 'Invite your partner';

  @override
  String get joinDialogHint =>
      'They install the app, tap ③ Join with passphrase, then scan this code or paste the info below.';

  @override
  String joinDialogSpace(String spaceId) {
    return 'Space: $spaceId';
  }

  @override
  String joinDialogPassphrase(String passphrase) {
    return 'Passphrase: $passphrase';
  }

  @override
  String get joinDialogCopy => 'Copy join info';

  @override
  String get joinDialogCopied => 'Join info copied — send it to your partner';

  @override
  String get joinDialogContinue => 'I shared it, enter chat';

  @override
  String get scanJoinTooltip => 'Scan to join';

  @override
  String get scanJoinTitle => 'Scan to join';

  @override
  String get scanJoinHint => 'Scan your partner\'s join QR code';

  @override
  String get scanJoinFound =>
      'Join info recognized — space & passphrase filled in';

  @override
  String get wizardRoleTitle => 'How do you want to set up?';

  @override
  String get wizardRoleCreate => 'I\'m the first user — create a new space';

  @override
  String get wizardRoleJoin => 'I want to join an existing space';

  @override
  String get wizardRoleAdvanced => 'Advanced: import a sealed key copy';

  @override
  String get wizardAppBarCreate => 'Create a new space';

  @override
  String get wizardAppBarJoin => 'Join your partner\'s space';

  @override
  String get wizardAppBarAdvanced => 'Import sealed key';

  @override
  String get wizardNext => 'Next';

  @override
  String get wizardBack => 'Back';

  @override
  String get wizardDone => 'Done';

  @override
  String get wizardStepDevice => 'Device name';

  @override
  String get wizardStepWhitelist => 'Server whitelist';

  @override
  String get wizardStepPassphrase => 'Access passphrase';

  @override
  String get wizardStepPin => 'App lock';

  @override
  String get wizardStepShare => 'Invite your partner';

  @override
  String get wizardStepJoin => 'Join space';

  @override
  String get wizardStepSealed => 'Import sealed key';

  @override
  String get wizardStepDone => 'Complete';

  @override
  String get setupPageKeyGenerated => '✅ Key generated';

  @override
  String get wizardWhitelistHint =>
      'Add the public key below to the server whitelist (config.json) and restart, then continue.';

  @override
  String get wizardPassphraseHint =>
      'Your partner joins with this passphrase — share it via QR code on the next step.';

  @override
  String get wizardPinHint =>
      'You\'ll enter this PIN at every startup to unlock.';

  @override
  String get wizardDoneText => '✅ Setup complete!';

  @override
  String get wizardShareHint =>
      'Your partner scans this code or pastes the info to join.';

  @override
  String get wizardJoinHint =>
      'Scan the QR code from your partner, or paste the join info they sent you.';

  @override
  String setupPageKeyGenFailed(String error) {
    return '❌ Key generation failed: $error';
  }

  @override
  String get setupPageGenKeyFirst => '⚠️ Generate the device key first';

  @override
  String get setupPagePasteSealed =>
      '⚠️ Paste the sealed Space Key copy (base64)';

  @override
  String setupPageImportFailed(String error) {
    return '❌ Import/authentication failed: $error';
  }

  @override
  String get setupPageEscrowGenKeyFirst =>
      '⚠️ Generate the device key first (①) and add its public key to the server whitelist';

  @override
  String get setupPageEscrowFillAll =>
      '⚠️ Fill in Space ID and the access passphrase';

  @override
  String get setupPageNoEscrow =>
      '❌ No escrow package on the server (set an access passphrase on the other device first)';

  @override
  String setupPageEscrowFailed(String error) {
    return '❌ Passphrase join failed: $error';
  }

  @override
  String get setPinDialogTitle => 'Set up app lock';

  @override
  String get setPinDialogRecoveryTitle => 'Save recovery code';

  @override
  String get setPinDialogEnterChat => 'I saved it, enter chat';

  @override
  String get setPinDialogIntro =>
      'You must enter the PIN at every startup to view messages; the Space Key is encrypted with the PIN.';

  @override
  String get setPinDialogPinLabel => 'PIN (at least 4 characters)';

  @override
  String get setPinDialogConfirmLabel => 'Confirm PIN';

  @override
  String get setPinDialogEscrowLabel =>
      'Access passphrase (optional, for joining on new devices)';

  @override
  String get setPinDialogEscrowHelper =>
      'Key escrow: the server only stores ciphertext, it cannot be opened without the passphrase (KEY_ESCROW.md)';

  @override
  String get setPinDialogSetPin => 'Set PIN';

  @override
  String get setPinDialogPinTooShort => 'PIN must be at least 4 characters';

  @override
  String get setPinDialogPinMismatch => 'The two PINs do not match';

  @override
  String setPinDialogSetupFailed(String error) {
    return 'Setup failed: $error';
  }

  @override
  String get setPinDialogEscrowUploaded =>
      '✅ Access passphrase uploaded to escrow (join with it on new devices)';

  @override
  String setPinDialogEscrowUploadFailed(String error) {
    return '⚠️ Escrow upload failed: $error (you can retry later in chat)';
  }

  @override
  String get setPinDialogRecoveryIntro =>
      'Save the following recovery code offline (use it to unlock if the PIN is lost):';

  @override
  String get setPinDialogRecoveryWarning =>
      'Keep the recovery code and PIN separately; if you lose the code and forget the PIN, you cannot unlock.';

  @override
  String chatPageLocaleSwitched(String label) {
    return 'Switched to $label';
  }

  @override
  String get chatPageBurnHeading => 'Burn-after (only affects this device)';

  @override
  String get chatPageBurnOff => 'Burn-after is off (messages are kept forever)';

  @override
  String chatPageBurnWillDelete(String duration) {
    return 'Messages will be auto-deleted after $duration';
  }

  @override
  String chatPageBurnTooltip(String label) {
    return 'Burn-after: $label';
  }

  @override
  String get chatPageBurnBadge => '⏱ Burn-after';

  @override
  String chatPageSendFailed(String error) {
    return 'Send failed: $error';
  }

  @override
  String chatPageVoiceStartFailed(String error) {
    return 'Recording start failed: $error';
  }

  @override
  String chatPageVoiceFailed(String error) {
    return 'Recording failed: $error';
  }

  @override
  String get chatPageRecordingHint => 'Recording… release to send';

  @override
  String get chatPageInputHint => 'Type a message…';

  @override
  String get chatPageAudioMetaMissing => 'Audio attachment metadata missing';

  @override
  String chatPageAudioPlayFailed(String error) {
    return 'Audio playback failed: $error';
  }

  @override
  String get chatPageAttachPhoto => 'Take photo';

  @override
  String get chatPageAttachGalleryImage => 'Gallery image';

  @override
  String get chatPageAttachVideoCamera => 'Record video';

  @override
  String get chatPageAttachVideoGallery => 'Gallery video';

  @override
  String get chatPageAttachAudioFile => 'Audio file (mp3 etc.)';

  @override
  String get chatPageAttachAnyFile => 'Any file';

  @override
  String get chatPageVideoMetaMissing => 'Video attachment metadata missing';

  @override
  String chatPageVideoPlayFailed(String error) {
    return 'Video playback failed: $error';
  }

  @override
  String chatPageImageLoadFailed(String plaintext) {
    return '$plaintext\n(failed to load)';
  }

  @override
  String get chatPagePlaying => 'Playing…';

  @override
  String get chatPageVoiceLabel => 'Voice';

  @override
  String get chatPageAttachmentMetaMissing => 'Attachment metadata missing';

  @override
  String chatPageSaved(String path) {
    return 'Saved: $path';
  }

  @override
  String chatPageDownloadFailed(String error) {
    return 'Download failed: $error';
  }

  @override
  String get chatPageDeviceRevoked =>
      'Device revoked — local data cleared, please set up again';

  @override
  String get burnOptionUnlimited => 'Unlimited';

  @override
  String get burnOption1Minute => '1 minute';

  @override
  String get burnOption5Minutes => '5 minutes';

  @override
  String get burnOption30Minutes => '30 minutes';

  @override
  String get burnOption1Hour => '1 hour';

  @override
  String get burnOption1Day => '1 day';

  @override
  String get burnOption7Days => '7 days';

  @override
  String get lockPageTitle => 'OnlySpace Locked';

  @override
  String get lockPagePinPrompt => 'Enter PIN to unlock';

  @override
  String lockPageLockedSeconds(int seconds) {
    return 'Locked for $seconds seconds';
  }

  @override
  String get lockPagePinLabel => 'PIN';

  @override
  String get lockPageUnlock => 'Unlock';

  @override
  String get lockPageUseRecovery => 'Forgot PIN? Use recovery code';

  @override
  String get lockPageRecoveryLabel => '12-word recovery code';

  @override
  String get lockPageRecoveryUnlock => 'Unlock with recovery code';

  @override
  String get lockPageBackToPin => 'Back to PIN';

  @override
  String lockPageTooManyAttempts(int seconds) {
    return 'Too many attempts, try again in ${seconds}s';
  }

  @override
  String lockPageUnlockFailed(String error) {
    return 'Unlock failed: $error';
  }

  @override
  String lockPageRecoveryFailed(String error) {
    return 'Recovery failed: $error';
  }
}
