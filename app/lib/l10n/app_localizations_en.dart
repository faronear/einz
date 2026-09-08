// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Einz';

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
  String get setupPageTitle => 'Einz · Device Setup';

  @override
  String get setupPageHeading => 'One-time setup';

  @override
  String get setupPageInstructions =>
      '1) Generate device key → the device registers automatically (no whitelist needed)\n2) Create or join the private space → set up the app lock';

  @override
  String get setupPageSpaceIdLabel => 'Space ID';

  @override
  String get setupPageEnvelopeKeyLabel => 'Key envelope (base64)';

  @override
  String get setupPageEnvelopeKeyHint =>
      'Paste the key envelope (contents of envelope-*.txt)';

  @override
  String setupPageKeyInfo(String deviceId, String publicKey) {
    return 'Device ID: $deviceId\nPublic key: $publicKey\n(The device will register automatically on the next step — no whitelist needed)';
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
      '③ Join with passphrase (no envelope needed)';

  @override
  String get setupPageGenerateSpaceKey => 'Create space (one-tap generate key)';

  @override
  String get setupPageNeedPassphrase =>
      '⚠️ Set an access passphrase above first (your partner joins with it)';

  @override
  String get setupEnrollBoundNotice => 'New device bound to my private space';

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
  String wizardMenuLocale(String value) {
    return 'Language: $value';
  }

  @override
  String get wizardDetectTitle => 'Checking server status…';

  @override
  String setupPageServerBar(Object server) {
    return 'Server: $server';
  }

  @override
  String get wizardDetectHint =>
      'We\'ll detect whether you\'re the first user (first device creates the space)';

  @override
  String get wizardDetectFailed =>
      'Cannot reach server — enter the address above and retry';

  @override
  String get wizardNameHint =>
      'This is your first device. Tell us what to call you (you can rename anytime).';

  @override
  String get wizardStepPeerName => 'Partner\'s name';

  @override
  String get wizardPeerNameHint =>
      'This is your partner (second user) — how should we call them? You can change it later.';

  @override
  String get wizardPeerNameLabel => 'Partner\'s name';

  @override
  String get wizardPeerNameHintInput => 'e.g. Steffi';

  @override
  String get wizardNameRequired => 'Please enter your name first';

  @override
  String get wizardPeerNameRequired => 'Please enter your partner\'s name';

  @override
  String get wizardNameLabel => 'Your name';

  @override
  String get wizardNameHintInput => 'e.g. Lukas (optional, change later)';

  @override
  String get wizardIdentityHint =>
      'This space already has users — choose your identity:';

  @override
  String get wizardIdentityCreator => 'First user (creator)';

  @override
  String get wizardIdentityPartner => 'Second user (partner)';

  @override
  String get wizardIdentityFirst =>
      '⚠️ Choose your identity first (creator or partner)';

  @override
  String get wizardInviteHint =>
      'Enter the one-time invite code from the creator (generated by /invite, valid 24h)';

  @override
  String get wizardRoleCreate => 'I\'m the first user — create a new space';

  @override
  String get wizardRoleJoin => 'I want to join an existing space';

  @override
  String get wizardRoleOffline => 'Offline: import a key envelope';

  @override
  String get wizardRecoverTitle => 'Restore from backup';

  @override
  String get wizardRecoverHint =>
      'Lost all devices? Enter the passphrase set when enabling key escrow; a correct passphrase resets the space and restores this device (no backup text needed)';

  @override
  String get wizardRecoverPassphraseLabel => 'Passphrase';

  @override
  String get wizardRecoverStart => 'Restore';

  @override
  String get wizardRecoverBadPassphrase =>
      'Wrong passphrase, or this space has no escrow passphrase uploaded';

  @override
  String get wizardRecoverArchiveTitle => 'Restore from full backup (archive)';

  @override
  String get wizardRecoverArchiveHint =>
      'Paste the exported full-backup text and enter the archive passphrase to restore the space key and chat history (server must be reachable)';

  @override
  String get wizardRecoverArchiveTextLabel =>
      'Archive text (starts with EINZ-BACKUP:)';

  @override
  String get wizardRecoverArchivePassphraseLabel => 'Archive passphrase';

  @override
  String get wizardRecoverArchiveStart => 'Restore archive';

  @override
  String get wizardRecoverArchiveBad =>
      'Wrong archive passphrase or corrupted archive';

  @override
  String wizardRecoverFailed(String error) {
    return 'Restore failed: $error';
  }

  @override
  String get wizardRecoverEnrolling => 'Enrolling this device…';

  @override
  String get wizardRecoverDone =>
      '✅ Restored: device enrolled — set a PIN to finish';

  @override
  String get wizardAppBarCreate => 'Einz Space at Creating';

  @override
  String get wizardAppBarJoin => 'Eins Space at Joining';

  @override
  String get wizardAppBarOffline => 'Import key envelope';

  @override
  String get wizardNext => 'Next';

  @override
  String get wizardBack => 'Back';

  @override
  String get wizardDone => 'Done';

  @override
  String get wizardStepName => 'Your name';

  @override
  String get wizardStepIdentity => 'Your identity';

  @override
  String get wizardStepInvite => 'Enter invite code';

  @override
  String get wizardStepEnroll => 'Register device';

  @override
  String get wizardStepPassphrase => 'Access passphrase';

  @override
  String get wizardStepJoinPassphrase => 'Verify entry passphrase';

  @override
  String get wizardStepPin => 'App lock';

  @override
  String get wizardStepShortName => 'Name';

  @override
  String get wizardStepShortPeerName => 'Peer name';

  @override
  String get wizardStepShortPassphrase => 'Passphrase';

  @override
  String get wizardStepShortPin => 'PIN';

  @override
  String get wizardStepShortDone => 'Done';

  @override
  String get wizardStepShortIdentity => 'Identity';

  @override
  String get wizardStepShortInvite => 'Invite code';

  @override
  String get wizardStepShortEnvelope => 'Envelope';

  @override
  String get wizardStepJoin => 'Join space';

  @override
  String get wizardStepEnvelope => 'Import key envelope';

  @override
  String get wizardStepDone => 'Complete';

  @override
  String get setupPageKeyGenerated => '✅ Key generated';

  @override
  String get wizardEnrollHint =>
      'Registration is fully automatic now (no manual whitelist). Tap below to register this device — the first device on the server auto-creates the private space.';

  @override
  String get wizardEnrollAction => 'Register this device';

  @override
  String wizardEnrollDone(String deviceId, String spaceId) {
    return '✅ Registered\nDevice: $deviceId\nSpace: $spaceId';
  }

  @override
  String get wizardEnrollExists =>
      'This server already hosts a space (created by another device). Switch to the Join flow and use the one-time invite code from your partner.';

  @override
  String get wizardEnrollGoJoin => 'Switch to Join flow';

  @override
  String wizardEnrollFailed(String error) {
    return '❌ Registration failed: $error';
  }

  @override
  String get wizardEnrollFirst =>
      '⚠️ Register the device first (tap the button above)';

  @override
  String get wizardPassphraseHint =>
      'Your partner joins with this passphrase — share it via QR code on the next step.';

  @override
  String get wizardJoinPassphraseHint =>
      'Verify the entry passphrase: enter the exact passphrase the first device created to join';

  @override
  String get wizardJoinPassphraseWrong =>
      'Wrong passphrase: check the exact one the first device created';

  @override
  String get wizardSwitchToEnvelope =>
      'Import sealed key envelope instead (offline)';

  @override
  String get wizardSwitchToPassphrase => 'Use passphrase instead';

  @override
  String get wizardPinHint =>
      'You\'ll enter this PIN at every startup to unlock.';

  @override
  String get wizardDoneText => '✅ Setup complete!';

  @override
  String get welcomeDialogTitleCreate => '🎉 Welcome to your private space';

  @override
  String get welcomeDialogTitleJoin => '🎉 Welcome to the space';

  @override
  String get welcomeDialogMessage =>
      'All set! Messages are end-to-end encrypted and visible only to you two. Start chatting!';

  @override
  String get welcomeDialogStart => 'Start chatting';

  @override
  String get wizardJoinHint =>
      'Scan your partner\'s QR code (it carries the invite code & passphrase) to join in one tap; you can also paste the text or fill in the fields below.';

  @override
  String setupPageKeyGenFailed(String error) {
    return '❌ Key generation failed: $error';
  }

  @override
  String get setupPageGenKeyFirst => '⚠️ Generate the device key first';

  @override
  String get setupPagePasteEnvelope => '⚠️ Paste the key envelope (base64)';

  @override
  String get wizardEnvelopeWrong =>
      'Invalid key envelope: make sure the full sealed key copy from the other device is pasted';

  @override
  String setupPageImportFailed(String error) {
    return '❌ Import/authentication failed: $error';
  }

  @override
  String get setupPageEscrowGenKeyFirst =>
      '⚠️ Generate the device key first (①) and add its public key to the server whitelist';

  @override
  String get setupPageEscrowFillAll =>
      '⚠️ Fill in the Space ID, access passphrase and invite code';

  @override
  String get setupPageInviteLabel => 'Invite code (one-time)';

  @override
  String get setupPageInviteHint =>
      'Filled in automatically after scanning; paste the invite code when joining manually';

  @override
  String get setupPageNeedInvite =>
      '⚠️ Enter the one-time invite code (generated by an authenticated device)';

  @override
  String get wizardInviteWrong =>
      'Invalid invite code: check the code from the first device\'s invite, or ask them to generate a new one';

  @override
  String get setupPageNoEscrow =>
      '❌ No escrow package on the server (set an access passphrase on the other device first)';

  @override
  String setupPageEscrowFailed(String error) {
    return '❌ Passphrase join failed: $error';
  }

  @override
  String get setPinDialogPinLabel => 'PIN (at least 4 characters)';

  @override
  String get setPinDialogConfirmLabel => 'Confirm PIN';

  @override
  String get setPinDialogSetPin => 'Set PIN';

  @override
  String get setupPageSkipPinTitle => 'Skip app lock?';

  @override
  String get setupPageSkipPinMessage =>
      'Without the app lock the Space Key package won\'t be encrypted on this device; you\'ll need to set it up again after restart. Skip anyway?';

  @override
  String get setPinDialogPinTooShort => 'PIN must be at least 4 characters';

  @override
  String get setPinDialogPinMismatch => 'The two PINs do not match';

  @override
  String setPinDialogSetupFailed(String error) {
    return 'Setup failed: $error';
  }

  @override
  String chatPageLocaleSwitched(String label) {
    return 'Switched to $label';
  }

  @override
  String get chatPageSetLockTitle => 'Set app lock';

  @override
  String get chatPageSetLockClearHint => 'Leave blank and submit to clear PIN';

  @override
  String get chatPageSetLockTooltip => 'Set app lock';

  @override
  String get chatPageSetLockDone =>
      'App lock set — PIN required at next launch';

  @override
  String get chatPageSetLockConfirmTitle => 'Set app lock?';

  @override
  String get chatPageSetLockConfirmMessage =>
      'Set the app lock? You\'ll need to enter the PIN at every launch.';

  @override
  String get chatPageSetLockCleared =>
      'App lock cleared (enter directly at next launch)';

  @override
  String get chatPageClearLockTitle => 'Clear app lock?';

  @override
  String get chatPageClearLockMessage =>
      'Both PIN fields are empty — clear the app lock? You\'ll enter directly at next launch.';

  @override
  String chatPageMenuLocale(String value) {
    return 'Language: $value';
  }

  @override
  String chatPageMenuBurn(String value) {
    return 'Burn-after-read: $value';
  }

  @override
  String get chatPageMenuInvite => 'Invite code';

  @override
  String get chatPageMenuExport => 'Export full backup';

  @override
  String get chatPageTitleBrand => 'EINZ Private Space';

  @override
  String get chatPageStatusOnline => 'Online';

  @override
  String get chatPageStatusOffline => 'Offline';

  @override
  String get chatPageMenuChangePassphrase => 'Change passphrase';

  @override
  String chatPageMenuMyName(String value) {
    return 'My name: $value';
  }

  @override
  String get chatPageMenuAvatar => 'Avatar';

  @override
  String get chatPageAvatarUploaded => '✅ Avatar updated';

  @override
  String get chatPageAvatarTooLarge => 'Image too large (max 2MB)';

  @override
  String chatPageAvatarFailed(String error) {
    return 'Avatar upload failed: $error';
  }

  @override
  String chatPageMenuDeviceName(String value) {
    return 'Device name: $value';
  }

  @override
  String get chatPageNameUnset => 'Unset';

  @override
  String get chatPageMenuExit => 'Exit app';

  @override
  String get chatPageRenameNameTitle => 'Change my name';

  @override
  String get chatPageRenameNameLabel => 'New name';

  @override
  String get chatPageRenameDeviceTitle => 'Change device name';

  @override
  String get chatPageRenameDeviceLabel => 'New device name';

  @override
  String chatPageRenameFailed(String error) {
    return 'Rename failed: $error';
  }

  @override
  String get chatPageExitTitle => 'Exit app?';

  @override
  String get chatPageExitMessage =>
      'The app will close completely; you\'ll need your PIN to unlock next time.';

  @override
  String get save => 'Save';

  @override
  String get chatPageChangePassphraseTitle => 'Change passphrase';

  @override
  String get chatPageChangePassphraseOldLabel => 'Current passphrase';

  @override
  String get chatPageChangePassphraseNewLabel => 'New passphrase';

  @override
  String get chatPageChangePassphraseConfirmLabel => 'Confirm new passphrase';

  @override
  String get chatPageChangePassphraseMismatch => 'New passphrases do not match';

  @override
  String get chatPageChangePassphraseConfirmTitle =>
      'Change escrow passphrase?';

  @override
  String get chatPageChangePassphraseConfirmMessage =>
      'Change the escrow passphrase? You\'ll need the new passphrase to decrypt content.';

  @override
  String get chatPageChangePassphraseOldWrong => 'Wrong current passphrase';

  @override
  String get chatPageChangePassphraseNoEscrow =>
      'No passphrase set (nothing to change)';

  @override
  String get chatPageChangePassphraseDone =>
      '✅ Passphrase updated (new devices must use it)';

  @override
  String chatPageChangePassphraseFailed(String error) {
    return 'Failed to change passphrase: $error';
  }

  @override
  String get chatPageExportTitle => 'Export full backup (archive)';

  @override
  String get chatPageExportPassphraseLabel =>
      'Archive passphrase (encrypts the archive; keep it separate from the text)';

  @override
  String get chatPageExportGenerate => 'Generate archive';

  @override
  String get chatPageExportGenerated =>
      'Encrypted archive text (keep offline, separate from the passphrase):';

  @override
  String get chatPageExportCopy => 'Copy';

  @override
  String get chatPageExportCopied => 'Archive text copied';

  @override
  String get chatPageExportHint =>
      'Encrypted archive of the space key and all chat history (incl. attachment info); restore everything if devices are lost or when switching to a new device';

  @override
  String get chatPagePinSet => 'PIN: set';

  @override
  String get chatPagePinUnset => 'PIN: not set';

  @override
  String get chatPageEscrowRotatedTitle => 'Passphrase updated';

  @override
  String get chatPageEscrowRotatedNotice =>
      'Your partner reset the passphrase — you will be asked for the new one when creating invites or changing it';

  @override
  String get chatPageEscrowRotatedMessage =>
      'Your partner reset the passphrase. Enter the new one to sync this device';

  @override
  String get chatPageEscrowRotatedLabel => 'New passphrase';

  @override
  String get chatPageEscrowRotatedVerify => 'Verify & sync';

  @override
  String get chatPageEscrowRotatedNoEscrow => 'No passphrase escrow on server';

  @override
  String get chatPageEscrowRotatedInvalid => 'Incorrect passphrase, try again';

  @override
  String get chatPageEscrowResynced => '✅ New passphrase synced';

  @override
  String get chatPageMenuLocaleLabel => 'Language';

  @override
  String get chatPageMenuBurnLabel => 'Burn-after-read';

  @override
  String get chatPageMenuMyNameLabel => 'My name';

  @override
  String get chatPageMenuDeviceNameLabel => 'Device name';

  @override
  String get chatPagePinLabel => 'PIN';

  @override
  String get chatPagePinSetValue => 'Set';

  @override
  String get chatPagePinUnsetValue => 'Not set';

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
  String get lockPageTitle => 'Einz Locked';

  @override
  String get lockPagePinPrompt => 'Enter PIN to unlock';

  @override
  String lockPageLockedSeconds(int seconds) {
    return 'Locked for $seconds seconds';
  }

  @override
  String get lockPagePinLabel => 'PIN';

  @override
  String get lockPageNoPinSet =>
      'No app lock set (the lock screen only activates when a PIN is set)';

  @override
  String get lockPageUnlock => 'Unlock';

  @override
  String lockPageTooManyAttempts(int seconds) {
    return 'Too many attempts, try again in ${seconds}s';
  }

  @override
  String lockPageUnlockFailed(String error) {
    return 'Unlock failed: $error';
  }
}
