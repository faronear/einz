// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

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
  String get skip => 'Skip';

  @override
  String get setupPageEnvelopeKeyHint =>
      'Offline handover text (asymmetric encryption). Get it from your partner.';

  @override
  String get setupPageNeedPassphrase => '❗️ Set a passphrase first';

  @override
  String get wizardJoinPassphraseRequired =>
      '❗️ Enter the passphrase to verify';

  @override
  String get setupEnrollBoundNotice => '🎉 New device bound';

  @override
  String get wizardStartTitle => 'Enter Einz';

  @override
  String get wizardDetectTitle => 'Checking server status…';

  @override
  String get wizardDetectHint => 'Auto-detects if you\'re the first device';

  @override
  String get wizardDetectFailed => 'Cannot reach server — retrying…';

  @override
  String get wizardNameHint => 'Your name (you can change it later)';

  @override
  String get wizardPeerNameHint =>
      'Your partner\'s name (you can change it later)';

  @override
  String get wizardPeerNameHintInput => 'Partner\'s name';

  @override
  String get wizardNameRequired => 'Enter your name';

  @override
  String get wizardPeerNameRequired => 'Enter your partner\'s name';

  @override
  String get wizardNameHintInput => 'Your name';

  @override
  String get wizardMyGenderLabel => 'Your gender';

  @override
  String get wizardPeerGenderLabel => 'Partner\'s gender';

  @override
  String get wizardGenderMale => 'Male';

  @override
  String get wizardGenderFemale => 'Female';

  @override
  String get wizardGenderRequired => 'Select a gender';

  @override
  String get wizardIdentityHint => 'Limited to two people — choose your role';

  @override
  String get wizardIdentityCreator => 'Creator';

  @override
  String get wizardIdentityPartner => 'Partner';

  @override
  String get wizardIdentityFirst => '⚠️ Pick your role first';

  @override
  String get wizardInviteHint =>
      'Any bound device can generate an invite code (one-time, valid 24h).';

  @override
  String get wizardRoleOffline => 'Import key envelope (offline)';

  @override
  String get wizardAppBarCreate => 'Create a space';

  @override
  String get wizardAppBarJoin => 'Join a space';

  @override
  String get wizardAppBarOffline => 'Import key envelope';

  @override
  String get wizardNext => 'Next';

  @override
  String get wizardBack => 'Back';

  @override
  String get wizardDone => 'Done';

  @override
  String get wizardTitleName => 'About me';

  @override
  String get wizardTitlePeerName => 'About partner';

  @override
  String get wizardTitleJoinIdentity => 'Choose your role';

  @override
  String get wizardJoinIdentityHint =>
      'Limited to two people — pick your identity.';

  @override
  String get wizardJoinNoSlots => 'No preset members — cannot join';

  @override
  String get wizardSlotOnline => 'online';

  @override
  String get wizardSlotRequired => 'Pick an identity';

  @override
  String get wizardSpaceLimit =>
      'Space limit reached (server maxSpaces) — cannot create';

  @override
  String get wizardTitleInvite => 'Verify invite code';

  @override
  String get wizardTitlePassphrase => 'Set passphrase';

  @override
  String get wizardJoinPassphraseTitle => 'Verify passphrase';

  @override
  String get wizardTitlePin => 'Set PIN';

  @override
  String get wizardTitleEnvelope => 'Key envelope';

  @override
  String get wizardTitleIdentity => 'I am';

  @override
  String get wizardEnrollExists =>
      'This server already has a space (created by another device). Use the Join flow with your partner\'s one-time invite code.';

  @override
  String get wizardEnrollGoJoin => 'Use Join flow';

  @override
  String wizardEnrollFailed(String error) {
    return '❌ Enrollment failed: $error';
  }

  @override
  String get wizardPassphraseHint =>
      'Encrypts & decrypts all messages. Remember it — never leak! Share only with your partner.';

  @override
  String get wizardPassphraseMinLengthHint => 'At least 8 characters';

  @override
  String get wizardPassphraseTooShort =>
      'Passphrase must be at least 8 characters';

  @override
  String get wizardPassphraseConfirmHint => 'Re-enter passphrase';

  @override
  String get wizardPassphraseMismatch => 'Passphrases do not match';

  @override
  String get wizardJoinPassphraseHint =>
      'A password shared with your partner to protect messages. Don\'t know it? Ask your partner.';

  @override
  String get wizardJoinPassphraseWrong =>
      'Wrong passphrase: use the one set on the first device';

  @override
  String get wizardSwitchToEnvelope => 'Use key envelope instead (offline)';

  @override
  String get wizardSwitchToPassphrase => 'Use passphrase instead';

  @override
  String get wizardPinHint =>
      'Device-specific lock PIN. Enter it each time you launch.';

  @override
  String get welcomeDialogTitleCreate => '🎉 All set!';

  @override
  String get welcomeDialogTitleJoin => '🎉 All set!';

  @override
  String get welcomeDialogMessage =>
      'Just the two of you, end-to-end encrypted for total privacy. Enter Einz and start chatting.';

  @override
  String get welcomeDialogStart => 'Enter Einz';

  @override
  String setupPageKeyGenFailed(String error) {
    return '❌ Key generation failed: $error';
  }

  @override
  String get setupEntryTitle => 'Get started with Einz';

  @override
  String get setupEntryHint =>
      'Create a private space for two, or join via an invite link';

  @override
  String get setupEntryCreate => 'Create';

  @override
  String get setupEntryJoin => 'Join';

  @override
  String get setupEntryLegacyServer =>
      'Server version too old — please upgrade';

  @override
  String get setupTokenTitle => 'Verify invite link';

  @override
  String get setupTokenHint =>
      'Ask the creator for a one-time invite link or code';

  @override
  String get setupTokenInputHint => 'Paste the invite link or code';

  @override
  String get setupTokenNeedInput => 'Enter the invite link or code';

  @override
  String get setupTokenInvalid => 'Invalid invite link';

  @override
  String get setupTokenExpired => 'Invite link expired';

  @override
  String get setupTokenUsed => 'Invite link already used';

  @override
  String get setupTokenSpaceFull => 'Space is full';

  @override
  String setupTokenSpaceInfo(String name) {
    return 'Join $name\'s space';
  }

  @override
  String get setupTokenSpacePrivate =>
      'Join a private space (waiting for the second member)';

  @override
  String get setupCreateShareTitle =>
      'Share invite link with partner (valid 24h)';

  @override
  String get setupCreateCopy => 'Copy invite link';

  @override
  String get setupCreateCopied => 'Copied';

  @override
  String get setupPageInitFailed => 'Initialization failed, retrying…';

  @override
  String get startupInitFailed =>
      'Startup failed — your data is safe, please retry';

  @override
  String get startupInitRetry => 'Retry';

  @override
  String get setupPagePasteEnvelope => '⚠️ Paste the key envelope (base64)';

  @override
  String get wizardEnvelopeWrong =>
      'Invalid key envelope: paste the full sealed copy from the other device';

  @override
  String get setupPageInviteHint => 'Paste or type the invite code';

  @override
  String get setupPageNeedInvite => '⚠️ Enter the one-time invite code';

  @override
  String get setupPageScanInvite => 'Scan invite QR';

  @override
  String get setupPageScannerHint => 'Point the camera at the invite QR code';

  @override
  String get wizardInviteWrong =>
      'Invalid invite code: use a one-time code from a bound device';

  @override
  String get setupPageNoEscrow =>
      '❌ No escrow package on the server — set a passphrase on the other device first';

  @override
  String setupPageEscrowFailed(String error) {
    return '❌ Passphrase join failed: $error';
  }

  @override
  String get setPinDialogPinLabel => 'PIN (at least 6 digits)';

  @override
  String get setPinDialogPinHint => 'At least 6 digits';

  @override
  String get setPinDialogConfirmLabel => 'Confirm PIN';

  @override
  String get setPinDialogConfirmHint => 'Type it again to confirm';

  @override
  String get setPinDialogSetPin => 'Set PIN';

  @override
  String get setupPageSkipPinTitle => 'Skip app lock?';

  @override
  String get setupPageSkipPinMessage =>
      'Without the app lock the Space Key isn\'t encrypted on this device. Skip anyway?';

  @override
  String get setPinDialogPinTooShort => 'PIN must be at least 6 digits';

  @override
  String get setPinDialogPinDigitsOnly => 'Digits only';

  @override
  String get setPinDialogPinMismatch => 'PINs do not match';

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
  String get chatPageSetLockClearHint => 'Leave blank to clear PIN';

  @override
  String get chatPageSetLockDone =>
      'App lock set — PIN required at next launch';

  @override
  String get chatPageSetLockConfirmTitle => 'Set app lock?';

  @override
  String get chatPageSetLockConfirmMessage =>
      'Set the app lock? You\'ll need the PIN at every launch.';

  @override
  String get chatPageSetLockCleared =>
      'App lock cleared (enter directly next time)';

  @override
  String get chatPageClearLockTitle => 'Clear app lock?';

  @override
  String get chatPageClearLockMessage =>
      'Both PIN fields empty — clear the app lock? You\'ll enter directly next time.';

  @override
  String get chatPageMenuInvite => 'Invite code';

  @override
  String get chatPageTitleBrand => 'EINZ Private Space';

  @override
  String get chatPageMenuChangePassphrase => 'Passphrase';

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
  String get chatPageNameUnset => 'Unset';

  @override
  String get chatPageMenuExit => 'Exit';

  @override
  String get chatPageRenameNameTitle => 'My profile';

  @override
  String get chatPageRenameNameLabel => 'My name';

  @override
  String get chatPageGenderLabel => 'Gender';

  @override
  String get chatPageRenameDeviceTitle => 'Device info';

  @override
  String get chatPageRenameDeviceLabel => 'Device name';

  @override
  String get chatPageRenameDeviceEmptyError => 'Name cannot be empty';

  @override
  String get chatPageRenameMyselfEmptyError => 'Name cannot be empty';

  @override
  String get chatPageRenameSameAsPeerError =>
      'Can\'t match your partner\'s name — pick another';

  @override
  String get chatPageCopy => 'Copy';

  @override
  String get chatPageCopied => 'Copied';

  @override
  String get chatPageEdit => 'Edit';

  @override
  String chatPageRenameFailed(String error) {
    return 'Rename failed: $error';
  }

  @override
  String get chatPageExitTitle => 'Exit?';

  @override
  String get chatPageExitMessage =>
      'Exits Einz on this device. You\'ll need your PIN to re-enter.';

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
  String get chatPageChangePassphraseConfirmTitle => 'Change passphrase?';

  @override
  String get chatPageChangePassphraseConfirmMessage =>
      'Change the passphrase? You\'ll need the new one to decrypt content.';

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
  String get chatPageEscrowRotatedNotice =>
      'Your partner reset the passphrase — use the new one to create invites or change it';

  @override
  String get chatPageMenuLocaleLabel => 'Language';

  @override
  String get chatPageMenuStyleLabel => 'Interface style';

  @override
  String get chatPageStyleSheetClose => 'Close';

  @override
  String get chatPageMenuBurnLabel => 'Burn-after-read';

  @override
  String get chatPageMenuMyNameLabel => 'My name';

  @override
  String get chatPageMenuDeviceNameLabel => 'Device';

  @override
  String get chatPagePinLabel => 'PIN';

  @override
  String get chatPagePinSetValue => 'Set';

  @override
  String get chatPagePinUnsetValue => 'Not set';

  @override
  String get chatPageBurnHeading => 'Burn-after-read (this device only)';

  @override
  String get chatPageBurnOff => 'Burn-after-read off (messages kept forever)';

  @override
  String get chatPageBurnFailed => 'Failed to set burn-after-read';

  @override
  String chatPageBurnWillDelete(String duration) {
    return 'New messages auto-delete after $duration';
  }

  @override
  String get chatPageActionDelete => 'Delete';

  @override
  String get chatPageActionQuote => 'Quote';

  @override
  String get chatPageActionBurn => 'Burn after reading';

  @override
  String get chatPageDeleteConfirmTitle => 'Delete message';

  @override
  String get chatPageDeleteConfirmMessage =>
      'Removed only on this device; the other side is unaffected and it can\'t be undone. Delete?';

  @override
  String get chatPageDeleteCancel => 'Cancel';

  @override
  String get chatPageDeleteConfirmOk => 'Delete';

  @override
  String chatPageSendFailed(String error) {
    return 'Send failed: $error';
  }

  @override
  String get chatPageMsgSending => 'Sending…';

  @override
  String get chatPageMsgSent => 'Sent';

  @override
  String get chatPageMsgDelivered => 'Delivered';

  @override
  String get chatPageMsgFailed => 'Send failed, tap to retry';

  @override
  String chatPageVoiceStartFailed(String error) {
    return 'Recording start failed: $error';
  }

  @override
  String chatPageVoiceFailed(String error) {
    return 'Recording failed: $error';
  }

  @override
  String get chatPageLongPressToRecord => 'Long press to record';

  @override
  String get chatPageInputHint => 'Type a message…';

  @override
  String get chatPageAudioMetaMissing => 'Audio metadata missing';

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
  String get chatPageAttachAudioFile => 'Audio file';

  @override
  String get chatPageAttachAnyFile => 'Any file';

  @override
  String get chatPageVideoMetaMissing => 'Video metadata missing';

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
  String get chatPageDevicePublicKeyLabel => 'Public key';

  @override
  String get chatPageDevicePublicKeyFailed => 'Not recorded';

  @override
  String get burnOptionKeepIndefinitely => 'Keep indefinitely';

  @override
  String get burnOption1Minute => '1 minute';

  @override
  String get burnOption5Minutes => '5 minutes';

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
    return 'Locked for ${seconds}s';
  }

  @override
  String get lockPagePinLabel => 'PIN';

  @override
  String get lockPageNoPinSet =>
      'No app lock set (lock screen activates only with a PIN)';

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
