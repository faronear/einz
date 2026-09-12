import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @setupPageEnvelopeKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Offline handover text (asymmetric encryption). Get it from your partner.'**
  String get setupPageEnvelopeKeyHint;

  /// No description provided for @setupPageNeedPassphrase.
  ///
  /// In en, this message translates to:
  /// **'❗️ Set a passphrase first'**
  String get setupPageNeedPassphrase;

  /// No description provided for @wizardJoinPassphraseRequired.
  ///
  /// In en, this message translates to:
  /// **'❗️ Enter the passphrase to verify'**
  String get wizardJoinPassphraseRequired;

  /// No description provided for @setupEnrollBoundNotice.
  ///
  /// In en, this message translates to:
  /// **'🎉 New device bound'**
  String get setupEnrollBoundNotice;

  /// No description provided for @wizardStartTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter Einz'**
  String get wizardStartTitle;

  /// No description provided for @wizardDetectTitle.
  ///
  /// In en, this message translates to:
  /// **'Checking server status…'**
  String get wizardDetectTitle;

  /// No description provided for @wizardDetectHint.
  ///
  /// In en, this message translates to:
  /// **'Auto-detects if you\'re the first device'**
  String get wizardDetectHint;

  /// No description provided for @wizardDetectFailed.
  ///
  /// In en, this message translates to:
  /// **'Cannot reach server — retrying…'**
  String get wizardDetectFailed;

  /// No description provided for @wizardNameHint.
  ///
  /// In en, this message translates to:
  /// **'Your name (you can change it later)'**
  String get wizardNameHint;

  /// No description provided for @wizardPeerNameHint.
  ///
  /// In en, this message translates to:
  /// **'Your partner\'s name (you can change it later)'**
  String get wizardPeerNameHint;

  /// No description provided for @wizardPeerNameHintInput.
  ///
  /// In en, this message translates to:
  /// **'Partner\'s name'**
  String get wizardPeerNameHintInput;

  /// No description provided for @wizardNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter your name'**
  String get wizardNameRequired;

  /// No description provided for @wizardPeerNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter your partner\'s name'**
  String get wizardPeerNameRequired;

  /// No description provided for @wizardNameHintInput.
  ///
  /// In en, this message translates to:
  /// **'Your name'**
  String get wizardNameHintInput;

  /// No description provided for @wizardMyGenderLabel.
  ///
  /// In en, this message translates to:
  /// **'Your gender'**
  String get wizardMyGenderLabel;

  /// No description provided for @wizardPeerGenderLabel.
  ///
  /// In en, this message translates to:
  /// **'Partner\'s gender'**
  String get wizardPeerGenderLabel;

  /// No description provided for @wizardGenderMale.
  ///
  /// In en, this message translates to:
  /// **'Male'**
  String get wizardGenderMale;

  /// No description provided for @wizardGenderFemale.
  ///
  /// In en, this message translates to:
  /// **'Female'**
  String get wizardGenderFemale;

  /// No description provided for @wizardGenderRequired.
  ///
  /// In en, this message translates to:
  /// **'Select a gender'**
  String get wizardGenderRequired;

  /// No description provided for @wizardIdentityHint.
  ///
  /// In en, this message translates to:
  /// **'Limited to two people — choose your role'**
  String get wizardIdentityHint;

  /// No description provided for @wizardIdentityCreator.
  ///
  /// In en, this message translates to:
  /// **'Creator'**
  String get wizardIdentityCreator;

  /// No description provided for @wizardIdentityPartner.
  ///
  /// In en, this message translates to:
  /// **'Partner'**
  String get wizardIdentityPartner;

  /// No description provided for @wizardIdentityFirst.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Pick your role first'**
  String get wizardIdentityFirst;

  /// No description provided for @wizardInviteHint.
  ///
  /// In en, this message translates to:
  /// **'Any bound device can generate an invite code (one-time, valid 24h).'**
  String get wizardInviteHint;

  /// No description provided for @wizardRoleOffline.
  ///
  /// In en, this message translates to:
  /// **'Import key envelope (offline)'**
  String get wizardRoleOffline;

  /// No description provided for @wizardAppBarCreate.
  ///
  /// In en, this message translates to:
  /// **'Create a space'**
  String get wizardAppBarCreate;

  /// No description provided for @wizardAppBarJoin.
  ///
  /// In en, this message translates to:
  /// **'Join a space'**
  String get wizardAppBarJoin;

  /// No description provided for @wizardAppBarOffline.
  ///
  /// In en, this message translates to:
  /// **'Import key envelope'**
  String get wizardAppBarOffline;

  /// No description provided for @wizardNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get wizardNext;

  /// No description provided for @wizardBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get wizardBack;

  /// No description provided for @wizardDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get wizardDone;

  /// No description provided for @wizardTitleName.
  ///
  /// In en, this message translates to:
  /// **'About me'**
  String get wizardTitleName;

  /// No description provided for @wizardTitlePeerName.
  ///
  /// In en, this message translates to:
  /// **'About partner'**
  String get wizardTitlePeerName;

  /// No description provided for @wizardTitleJoinIdentity.
  ///
  /// In en, this message translates to:
  /// **'Choose your role'**
  String get wizardTitleJoinIdentity;

  /// No description provided for @wizardJoinIdentityHint.
  ///
  /// In en, this message translates to:
  /// **'Limited to two people — pick your identity.'**
  String get wizardJoinIdentityHint;

  /// No description provided for @wizardJoinNoSlots.
  ///
  /// In en, this message translates to:
  /// **'No preset members — cannot join'**
  String get wizardJoinNoSlots;

  /// No description provided for @wizardSlotOnline.
  ///
  /// In en, this message translates to:
  /// **'online'**
  String get wizardSlotOnline;

  /// No description provided for @wizardSlotRequired.
  ///
  /// In en, this message translates to:
  /// **'Pick an identity'**
  String get wizardSlotRequired;

  /// No description provided for @wizardSpaceLimit.
  ///
  /// In en, this message translates to:
  /// **'Space limit reached (server maxSpaces) — cannot create'**
  String get wizardSpaceLimit;

  /// No description provided for @wizardTitleInvite.
  ///
  /// In en, this message translates to:
  /// **'Verify invite code'**
  String get wizardTitleInvite;

  /// No description provided for @wizardTitlePassphrase.
  ///
  /// In en, this message translates to:
  /// **'Set passphrase'**
  String get wizardTitlePassphrase;

  /// No description provided for @wizardJoinPassphraseTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify passphrase'**
  String get wizardJoinPassphraseTitle;

  /// No description provided for @wizardTitlePin.
  ///
  /// In en, this message translates to:
  /// **'Set PIN'**
  String get wizardTitlePin;

  /// No description provided for @wizardTitleEnvelope.
  ///
  /// In en, this message translates to:
  /// **'Key envelope'**
  String get wizardTitleEnvelope;

  /// No description provided for @wizardTitleIdentity.
  ///
  /// In en, this message translates to:
  /// **'I am'**
  String get wizardTitleIdentity;

  /// No description provided for @wizardEnrollExists.
  ///
  /// In en, this message translates to:
  /// **'This server already has a space (created by another device). Use the Join flow with your partner\'s one-time invite code.'**
  String get wizardEnrollExists;

  /// No description provided for @wizardEnrollGoJoin.
  ///
  /// In en, this message translates to:
  /// **'Use Join flow'**
  String get wizardEnrollGoJoin;

  /// No description provided for @wizardEnrollFailed.
  ///
  /// In en, this message translates to:
  /// **'❌ Enrollment failed: {error}'**
  String wizardEnrollFailed(String error);

  /// No description provided for @wizardPassphraseHint.
  ///
  /// In en, this message translates to:
  /// **'Encrypts & decrypts all messages. Remember it — never leak! Share only with your partner.'**
  String get wizardPassphraseHint;

  /// No description provided for @wizardJoinPassphraseHint.
  ///
  /// In en, this message translates to:
  /// **'A password shared with your partner to protect messages. Don\'t know it? Ask your partner.'**
  String get wizardJoinPassphraseHint;

  /// No description provided for @wizardJoinPassphraseWrong.
  ///
  /// In en, this message translates to:
  /// **'Wrong passphrase: use the one set on the first device'**
  String get wizardJoinPassphraseWrong;

  /// No description provided for @wizardSwitchToEnvelope.
  ///
  /// In en, this message translates to:
  /// **'Use key envelope instead (offline)'**
  String get wizardSwitchToEnvelope;

  /// No description provided for @wizardSwitchToPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Use passphrase instead'**
  String get wizardSwitchToPassphrase;

  /// No description provided for @wizardPinHint.
  ///
  /// In en, this message translates to:
  /// **'Device-specific lock PIN. Enter it each time you launch.'**
  String get wizardPinHint;

  /// No description provided for @welcomeDialogTitleCreate.
  ///
  /// In en, this message translates to:
  /// **'🎉 All set!'**
  String get welcomeDialogTitleCreate;

  /// No description provided for @welcomeDialogTitleJoin.
  ///
  /// In en, this message translates to:
  /// **'🎉 All set!'**
  String get welcomeDialogTitleJoin;

  /// No description provided for @welcomeDialogMessage.
  ///
  /// In en, this message translates to:
  /// **'Just the two of you, end-to-end encrypted for total privacy. Enter Einz and start chatting.'**
  String get welcomeDialogMessage;

  /// No description provided for @welcomeDialogStart.
  ///
  /// In en, this message translates to:
  /// **'Enter Einz'**
  String get welcomeDialogStart;

  /// No description provided for @setupPageKeyGenFailed.
  ///
  /// In en, this message translates to:
  /// **'❌ Key generation failed: {error}'**
  String setupPageKeyGenFailed(String error);

  /// No description provided for @setupEntryTitle.
  ///
  /// In en, this message translates to:
  /// **'Get started with Einz'**
  String get setupEntryTitle;

  /// No description provided for @setupEntryHint.
  ///
  /// In en, this message translates to:
  /// **'Create a private space for two, or join via an invite link'**
  String get setupEntryHint;

  /// No description provided for @setupEntryCreate.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get setupEntryCreate;

  /// No description provided for @setupEntryJoin.
  ///
  /// In en, this message translates to:
  /// **'Join'**
  String get setupEntryJoin;

  /// No description provided for @setupEntryLegacyServer.
  ///
  /// In en, this message translates to:
  /// **'Server version too old — please upgrade'**
  String get setupEntryLegacyServer;

  /// No description provided for @setupTokenTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify invite link'**
  String get setupTokenTitle;

  /// No description provided for @setupTokenHint.
  ///
  /// In en, this message translates to:
  /// **'Ask the creator for a one-time invite link or code'**
  String get setupTokenHint;

  /// No description provided for @setupTokenInputHint.
  ///
  /// In en, this message translates to:
  /// **'Paste the invite link or code'**
  String get setupTokenInputHint;

  /// No description provided for @setupTokenNeedInput.
  ///
  /// In en, this message translates to:
  /// **'Enter the invite link or code'**
  String get setupTokenNeedInput;

  /// No description provided for @setupTokenInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid invite link'**
  String get setupTokenInvalid;

  /// No description provided for @setupTokenExpired.
  ///
  /// In en, this message translates to:
  /// **'Invite link expired'**
  String get setupTokenExpired;

  /// No description provided for @setupTokenUsed.
  ///
  /// In en, this message translates to:
  /// **'Invite link already used'**
  String get setupTokenUsed;

  /// No description provided for @setupTokenSpaceFull.
  ///
  /// In en, this message translates to:
  /// **'Space is full'**
  String get setupTokenSpaceFull;

  /// No description provided for @setupTokenSpaceInfo.
  ///
  /// In en, this message translates to:
  /// **'Join {name}\'s space'**
  String setupTokenSpaceInfo(String name);

  /// No description provided for @setupTokenSpacePrivate.
  ///
  /// In en, this message translates to:
  /// **'Join a private space (waiting for the second member)'**
  String get setupTokenSpacePrivate;

  /// No description provided for @setupCreateShareTitle.
  ///
  /// In en, this message translates to:
  /// **'Share invite link with partner (valid 24h)'**
  String get setupCreateShareTitle;

  /// No description provided for @setupCreateCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy invite link'**
  String get setupCreateCopy;

  /// No description provided for @setupCreateCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get setupCreateCopied;

  /// Friendly message when startup initialization (local database / server probe) fails — hides technical details (e.g. SqliteException), auto-retrying
  ///
  /// In en, this message translates to:
  /// **'Initialization failed, retrying…'**
  String get setupPageInitFailed;

  /// No description provided for @startupInitFailed.
  ///
  /// In en, this message translates to:
  /// **'Startup failed — your data is safe, please retry'**
  String get startupInitFailed;

  /// No description provided for @startupInitRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get startupInitRetry;

  /// No description provided for @setupPagePasteEnvelope.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Paste the key envelope (base64)'**
  String get setupPagePasteEnvelope;

  /// No description provided for @wizardEnvelopeWrong.
  ///
  /// In en, this message translates to:
  /// **'Invalid key envelope: paste the full sealed copy from the other device'**
  String get wizardEnvelopeWrong;

  /// No description provided for @setupPageInviteHint.
  ///
  /// In en, this message translates to:
  /// **'Paste or type the invite code'**
  String get setupPageInviteHint;

  /// No description provided for @setupPageNeedInvite.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Enter the one-time invite code'**
  String get setupPageNeedInvite;

  /// No description provided for @setupPageScanInvite.
  ///
  /// In en, this message translates to:
  /// **'Scan invite QR'**
  String get setupPageScanInvite;

  /// No description provided for @setupPageScannerHint.
  ///
  /// In en, this message translates to:
  /// **'Point the camera at the invite QR code'**
  String get setupPageScannerHint;

  /// No description provided for @wizardInviteWrong.
  ///
  /// In en, this message translates to:
  /// **'Invalid invite code: use a one-time code from a bound device'**
  String get wizardInviteWrong;

  /// No description provided for @setupPageNoEscrow.
  ///
  /// In en, this message translates to:
  /// **'❌ No escrow package on the server — set a passphrase on the other device first'**
  String get setupPageNoEscrow;

  /// No description provided for @setupPageEscrowFailed.
  ///
  /// In en, this message translates to:
  /// **'❌ Passphrase join failed: {error}'**
  String setupPageEscrowFailed(String error);

  /// No description provided for @setPinDialogPinLabel.
  ///
  /// In en, this message translates to:
  /// **'PIN (at least 6 digits)'**
  String get setPinDialogPinLabel;

  /// No description provided for @setPinDialogPinHint.
  ///
  /// In en, this message translates to:
  /// **'At least 6 digits'**
  String get setPinDialogPinHint;

  /// No description provided for @setPinDialogConfirmLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm PIN'**
  String get setPinDialogConfirmLabel;

  /// No description provided for @setPinDialogConfirmHint.
  ///
  /// In en, this message translates to:
  /// **'Type it again to confirm'**
  String get setPinDialogConfirmHint;

  /// No description provided for @setPinDialogSetPin.
  ///
  /// In en, this message translates to:
  /// **'Set PIN'**
  String get setPinDialogSetPin;

  /// No description provided for @setupPageSkipPinTitle.
  ///
  /// In en, this message translates to:
  /// **'Skip app lock?'**
  String get setupPageSkipPinTitle;

  /// No description provided for @setupPageSkipPinMessage.
  ///
  /// In en, this message translates to:
  /// **'Without the app lock the Space Key isn\'t encrypted on this device. Skip anyway?'**
  String get setupPageSkipPinMessage;

  /// No description provided for @setPinDialogPinTooShort.
  ///
  /// In en, this message translates to:
  /// **'PIN must be at least 6 digits'**
  String get setPinDialogPinTooShort;

  /// No description provided for @setPinDialogPinDigitsOnly.
  ///
  /// In en, this message translates to:
  /// **'Digits only'**
  String get setPinDialogPinDigitsOnly;

  /// No description provided for @setPinDialogPinMismatch.
  ///
  /// In en, this message translates to:
  /// **'PINs do not match'**
  String get setPinDialogPinMismatch;

  /// No description provided for @setPinDialogSetupFailed.
  ///
  /// In en, this message translates to:
  /// **'Setup failed: {error}'**
  String setPinDialogSetupFailed(String error);

  /// No description provided for @chatPageLocaleSwitched.
  ///
  /// In en, this message translates to:
  /// **'Switched to {label}'**
  String chatPageLocaleSwitched(String label);

  /// No description provided for @chatPageSetLockTitle.
  ///
  /// In en, this message translates to:
  /// **'Set app lock'**
  String get chatPageSetLockTitle;

  /// No description provided for @chatPageSetLockClearHint.
  ///
  /// In en, this message translates to:
  /// **'Leave blank to clear PIN'**
  String get chatPageSetLockClearHint;

  /// No description provided for @chatPageSetLockDone.
  ///
  /// In en, this message translates to:
  /// **'App lock set — PIN required at next launch'**
  String get chatPageSetLockDone;

  /// No description provided for @chatPageSetLockConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Set app lock?'**
  String get chatPageSetLockConfirmTitle;

  /// No description provided for @chatPageSetLockConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'Set the app lock? You\'ll need the PIN at every launch.'**
  String get chatPageSetLockConfirmMessage;

  /// No description provided for @chatPageSetLockCleared.
  ///
  /// In en, this message translates to:
  /// **'App lock cleared (enter directly next time)'**
  String get chatPageSetLockCleared;

  /// No description provided for @chatPageClearLockTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear app lock?'**
  String get chatPageClearLockTitle;

  /// No description provided for @chatPageClearLockMessage.
  ///
  /// In en, this message translates to:
  /// **'Both PIN fields empty — clear the app lock? You\'ll enter directly next time.'**
  String get chatPageClearLockMessage;

  /// No description provided for @chatPageMenuInvite.
  ///
  /// In en, this message translates to:
  /// **'Invite code'**
  String get chatPageMenuInvite;

  /// No description provided for @chatPageTitleBrand.
  ///
  /// In en, this message translates to:
  /// **'EINZ Private Space'**
  String get chatPageTitleBrand;

  /// No description provided for @chatPageMenuChangePassphrase.
  ///
  /// In en, this message translates to:
  /// **'Change passphrase'**
  String get chatPageMenuChangePassphrase;

  /// No description provided for @chatPageMenuAvatar.
  ///
  /// In en, this message translates to:
  /// **'Avatar'**
  String get chatPageMenuAvatar;

  /// No description provided for @chatPageAvatarUploaded.
  ///
  /// In en, this message translates to:
  /// **'✅ Avatar updated'**
  String get chatPageAvatarUploaded;

  /// No description provided for @chatPageAvatarTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Image too large (max 2MB)'**
  String get chatPageAvatarTooLarge;

  /// No description provided for @chatPageAvatarFailed.
  ///
  /// In en, this message translates to:
  /// **'Avatar upload failed: {error}'**
  String chatPageAvatarFailed(String error);

  /// No description provided for @chatPageNameUnset.
  ///
  /// In en, this message translates to:
  /// **'Unset'**
  String get chatPageNameUnset;

  /// No description provided for @chatPageMenuExit.
  ///
  /// In en, this message translates to:
  /// **'Exit'**
  String get chatPageMenuExit;

  /// No description provided for @chatPageRenameNameTitle.
  ///
  /// In en, this message translates to:
  /// **'My profile'**
  String get chatPageRenameNameTitle;

  /// No description provided for @chatPageRenameNameLabel.
  ///
  /// In en, this message translates to:
  /// **'My name'**
  String get chatPageRenameNameLabel;

  /// No description provided for @chatPageGenderLabel.
  ///
  /// In en, this message translates to:
  /// **'Gender'**
  String get chatPageGenderLabel;

  /// No description provided for @chatPageRenameDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'Device info'**
  String get chatPageRenameDeviceTitle;

  /// No description provided for @chatPageRenameDeviceLabel.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get chatPageRenameDeviceLabel;

  /// No description provided for @chatPageRenameDeviceEmptyError.
  ///
  /// In en, this message translates to:
  /// **'Name cannot be empty'**
  String get chatPageRenameDeviceEmptyError;

  /// No description provided for @chatPageRenameMyselfEmptyError.
  ///
  /// In en, this message translates to:
  /// **'Name cannot be empty'**
  String get chatPageRenameMyselfEmptyError;

  /// No description provided for @chatPageRenameSameAsPeerError.
  ///
  /// In en, this message translates to:
  /// **'Can\'t match your partner\'s name — pick another'**
  String get chatPageRenameSameAsPeerError;

  /// No description provided for @chatPageCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get chatPageCopy;

  /// No description provided for @chatPageCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get chatPageCopied;

  /// No description provided for @chatPageEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get chatPageEdit;

  /// No description provided for @chatPageRenameFailed.
  ///
  /// In en, this message translates to:
  /// **'Rename failed: {error}'**
  String chatPageRenameFailed(String error);

  /// No description provided for @chatPageExitTitle.
  ///
  /// In en, this message translates to:
  /// **'Exit?'**
  String get chatPageExitTitle;

  /// No description provided for @chatPageExitMessage.
  ///
  /// In en, this message translates to:
  /// **'Exits Einz on this device. You\'ll need your PIN to re-enter.'**
  String get chatPageExitMessage;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @chatPageChangePassphraseTitle.
  ///
  /// In en, this message translates to:
  /// **'Change passphrase'**
  String get chatPageChangePassphraseTitle;

  /// No description provided for @chatPageChangePassphraseOldLabel.
  ///
  /// In en, this message translates to:
  /// **'Current passphrase'**
  String get chatPageChangePassphraseOldLabel;

  /// No description provided for @chatPageChangePassphraseNewLabel.
  ///
  /// In en, this message translates to:
  /// **'New passphrase'**
  String get chatPageChangePassphraseNewLabel;

  /// No description provided for @chatPageChangePassphraseConfirmLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm new passphrase'**
  String get chatPageChangePassphraseConfirmLabel;

  /// No description provided for @chatPageChangePassphraseMismatch.
  ///
  /// In en, this message translates to:
  /// **'New passphrases do not match'**
  String get chatPageChangePassphraseMismatch;

  /// No description provided for @chatPageChangePassphraseConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Change passphrase?'**
  String get chatPageChangePassphraseConfirmTitle;

  /// No description provided for @chatPageChangePassphraseConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'Change the passphrase? You\'ll need the new one to decrypt content.'**
  String get chatPageChangePassphraseConfirmMessage;

  /// No description provided for @chatPageChangePassphraseOldWrong.
  ///
  /// In en, this message translates to:
  /// **'Wrong current passphrase'**
  String get chatPageChangePassphraseOldWrong;

  /// No description provided for @chatPageChangePassphraseNoEscrow.
  ///
  /// In en, this message translates to:
  /// **'No passphrase set (nothing to change)'**
  String get chatPageChangePassphraseNoEscrow;

  /// No description provided for @chatPageChangePassphraseDone.
  ///
  /// In en, this message translates to:
  /// **'✅ Passphrase updated (new devices must use it)'**
  String get chatPageChangePassphraseDone;

  /// No description provided for @chatPageChangePassphraseFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to change passphrase: {error}'**
  String chatPageChangePassphraseFailed(String error);

  /// No description provided for @chatPageEscrowRotatedNotice.
  ///
  /// In en, this message translates to:
  /// **'Your partner reset the passphrase — use the new one to create invites or change it'**
  String get chatPageEscrowRotatedNotice;

  /// No description provided for @chatPageMenuLocaleLabel.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get chatPageMenuLocaleLabel;

  /// No description provided for @chatPageMenuStyleLabel.
  ///
  /// In en, this message translates to:
  /// **'Interface style'**
  String get chatPageMenuStyleLabel;

  /// No description provided for @chatPageStyleSheetClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get chatPageStyleSheetClose;

  /// No description provided for @chatPageMenuBurnLabel.
  ///
  /// In en, this message translates to:
  /// **'Burn-after-read'**
  String get chatPageMenuBurnLabel;

  /// No description provided for @chatPageMenuMyNameLabel.
  ///
  /// In en, this message translates to:
  /// **'My name'**
  String get chatPageMenuMyNameLabel;

  /// No description provided for @chatPageMenuDeviceNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get chatPageMenuDeviceNameLabel;

  /// No description provided for @chatPagePinLabel.
  ///
  /// In en, this message translates to:
  /// **'PIN'**
  String get chatPagePinLabel;

  /// No description provided for @chatPagePinSetValue.
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get chatPagePinSetValue;

  /// No description provided for @chatPagePinUnsetValue.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get chatPagePinUnsetValue;

  /// No description provided for @chatPageBurnHeading.
  ///
  /// In en, this message translates to:
  /// **'Burn-after-read (this device only)'**
  String get chatPageBurnHeading;

  /// No description provided for @chatPageBurnOff.
  ///
  /// In en, this message translates to:
  /// **'Burn-after-read off (messages kept forever)'**
  String get chatPageBurnOff;

  /// No description provided for @chatPageBurnFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to set burn-after-read'**
  String get chatPageBurnFailed;

  /// No description provided for @chatPageBurnWillDelete.
  ///
  /// In en, this message translates to:
  /// **'New messages auto-delete after {duration}'**
  String chatPageBurnWillDelete(String duration);

  /// No description provided for @chatPageActionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get chatPageActionDelete;

  /// No description provided for @chatPageActionQuote.
  ///
  /// In en, this message translates to:
  /// **'Quote'**
  String get chatPageActionQuote;

  /// No description provided for @chatPageActionBurn.
  ///
  /// In en, this message translates to:
  /// **'Burn after reading'**
  String get chatPageActionBurn;

  /// No description provided for @chatPageDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete message'**
  String get chatPageDeleteConfirmTitle;

  /// No description provided for @chatPageDeleteConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'Removed only on this device; the other side is unaffected and it can\'t be undone. Delete?'**
  String get chatPageDeleteConfirmMessage;

  /// No description provided for @chatPageDeleteCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get chatPageDeleteCancel;

  /// No description provided for @chatPageDeleteConfirmOk.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get chatPageDeleteConfirmOk;

  /// No description provided for @chatPageSendFailed.
  ///
  /// In en, this message translates to:
  /// **'Send failed: {error}'**
  String chatPageSendFailed(String error);

  /// No description provided for @chatPageMsgSending.
  ///
  /// In en, this message translates to:
  /// **'Sending…'**
  String get chatPageMsgSending;

  /// No description provided for @chatPageMsgSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get chatPageMsgSent;

  /// No description provided for @chatPageMsgFailed.
  ///
  /// In en, this message translates to:
  /// **'Send failed, tap to retry'**
  String get chatPageMsgFailed;

  /// No description provided for @chatPageVoiceStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Recording start failed: {error}'**
  String chatPageVoiceStartFailed(String error);

  /// No description provided for @chatPageVoiceFailed.
  ///
  /// In en, this message translates to:
  /// **'Recording failed: {error}'**
  String chatPageVoiceFailed(String error);

  /// No description provided for @chatPageLongPressToRecord.
  ///
  /// In en, this message translates to:
  /// **'Long press to record'**
  String get chatPageLongPressToRecord;

  /// No description provided for @chatPageInputHint.
  ///
  /// In en, this message translates to:
  /// **'Type a message…'**
  String get chatPageInputHint;

  /// No description provided for @chatPageAudioMetaMissing.
  ///
  /// In en, this message translates to:
  /// **'Audio metadata missing'**
  String get chatPageAudioMetaMissing;

  /// No description provided for @chatPageAudioPlayFailed.
  ///
  /// In en, this message translates to:
  /// **'Audio playback failed: {error}'**
  String chatPageAudioPlayFailed(String error);

  /// No description provided for @chatPageAttachPhoto.
  ///
  /// In en, this message translates to:
  /// **'Take photo'**
  String get chatPageAttachPhoto;

  /// No description provided for @chatPageAttachGalleryImage.
  ///
  /// In en, this message translates to:
  /// **'Gallery image'**
  String get chatPageAttachGalleryImage;

  /// No description provided for @chatPageAttachVideoCamera.
  ///
  /// In en, this message translates to:
  /// **'Record video'**
  String get chatPageAttachVideoCamera;

  /// No description provided for @chatPageAttachVideoGallery.
  ///
  /// In en, this message translates to:
  /// **'Gallery video'**
  String get chatPageAttachVideoGallery;

  /// No description provided for @chatPageAttachAudioFile.
  ///
  /// In en, this message translates to:
  /// **'Audio file'**
  String get chatPageAttachAudioFile;

  /// No description provided for @chatPageAttachAnyFile.
  ///
  /// In en, this message translates to:
  /// **'Any file'**
  String get chatPageAttachAnyFile;

  /// No description provided for @chatPageVideoMetaMissing.
  ///
  /// In en, this message translates to:
  /// **'Video metadata missing'**
  String get chatPageVideoMetaMissing;

  /// No description provided for @chatPageVideoPlayFailed.
  ///
  /// In en, this message translates to:
  /// **'Video playback failed: {error}'**
  String chatPageVideoPlayFailed(String error);

  /// No description provided for @chatPageImageLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'{plaintext}\n(failed to load)'**
  String chatPageImageLoadFailed(String plaintext);

  /// No description provided for @chatPagePlaying.
  ///
  /// In en, this message translates to:
  /// **'Playing…'**
  String get chatPagePlaying;

  /// No description provided for @chatPageVoiceLabel.
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get chatPageVoiceLabel;

  /// No description provided for @chatPageAttachmentMetaMissing.
  ///
  /// In en, this message translates to:
  /// **'Attachment metadata missing'**
  String get chatPageAttachmentMetaMissing;

  /// No description provided for @chatPageSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved: {path}'**
  String chatPageSaved(String path);

  /// No description provided for @chatPageDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed: {error}'**
  String chatPageDownloadFailed(String error);

  /// No description provided for @chatPageDeviceRevoked.
  ///
  /// In en, this message translates to:
  /// **'Device revoked — local data cleared, please set up again'**
  String get chatPageDeviceRevoked;

  /// No description provided for @chatPageDevicePublicKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Public key'**
  String get chatPageDevicePublicKeyLabel;

  /// No description provided for @chatPageDevicePublicKeyFailed.
  ///
  /// In en, this message translates to:
  /// **'Not recorded'**
  String get chatPageDevicePublicKeyFailed;

  /// No description provided for @burnOptionKeepIndefinitely.
  ///
  /// In en, this message translates to:
  /// **'Keep indefinitely'**
  String get burnOptionKeepIndefinitely;

  /// No description provided for @burnOption1Minute.
  ///
  /// In en, this message translates to:
  /// **'1 minute'**
  String get burnOption1Minute;

  /// No description provided for @burnOption5Minutes.
  ///
  /// In en, this message translates to:
  /// **'5 minutes'**
  String get burnOption5Minutes;

  /// No description provided for @burnOption1Hour.
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get burnOption1Hour;

  /// No description provided for @burnOption1Day.
  ///
  /// In en, this message translates to:
  /// **'1 day'**
  String get burnOption1Day;

  /// No description provided for @burnOption7Days.
  ///
  /// In en, this message translates to:
  /// **'7 days'**
  String get burnOption7Days;

  /// No description provided for @lockPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Einz Locked'**
  String get lockPageTitle;

  /// No description provided for @lockPagePinPrompt.
  ///
  /// In en, this message translates to:
  /// **'Enter PIN to unlock'**
  String get lockPagePinPrompt;

  /// No description provided for @lockPageLockedSeconds.
  ///
  /// In en, this message translates to:
  /// **'Locked for {seconds}s'**
  String lockPageLockedSeconds(int seconds);

  /// No description provided for @lockPagePinLabel.
  ///
  /// In en, this message translates to:
  /// **'PIN'**
  String get lockPagePinLabel;

  /// No description provided for @lockPageNoPinSet.
  ///
  /// In en, this message translates to:
  /// **'No app lock set (lock screen activates only with a PIN)'**
  String get lockPageNoPinSet;

  /// No description provided for @lockPageUnlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get lockPageUnlock;

  /// No description provided for @lockPageTooManyAttempts.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts, try again in {seconds}s'**
  String lockPageTooManyAttempts(int seconds);

  /// No description provided for @lockPageUnlockFailed.
  ///
  /// In en, this message translates to:
  /// **'Unlock failed: {error}'**
  String lockPageUnlockFailed(String error);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
