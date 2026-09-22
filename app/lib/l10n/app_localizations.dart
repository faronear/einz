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

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

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

  /// No description provided for @wizardProbeConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to {server}…'**
  String wizardProbeConnecting(String server);

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

  /// No description provided for @wizardNameInvalidError.
  ///
  /// In en, this message translates to:
  /// **'Only Chinese/English letters, digits, _ , - and emoji are allowed'**
  String get wizardNameInvalidError;

  /// No description provided for @wizardNameTooLongError.
  ///
  /// In en, this message translates to:
  /// **'At most {max} characters'**
  String wizardNameTooLongError(int max);

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
  /// **'The passphrase encrypts every message. Memorize it and never leak it — share it only with your partner.'**
  String get wizardPassphraseHint;

  /// No description provided for @wizardPassphraseMinLengthHint.
  ///
  /// In en, this message translates to:
  /// **'At least 8 characters'**
  String get wizardPassphraseMinLengthHint;

  /// No description provided for @wizardPassphraseTooShort.
  ///
  /// In en, this message translates to:
  /// **'Passphrase must be at least 8 characters'**
  String get wizardPassphraseTooShort;

  /// No description provided for @wizardPassphraseConfirmHint.
  ///
  /// In en, this message translates to:
  /// **'Re-enter passphrase'**
  String get wizardPassphraseConfirmHint;

  /// No description provided for @wizardPassphraseMismatch.
  ///
  /// In en, this message translates to:
  /// **'Passphrases do not match'**
  String get wizardPassphraseMismatch;

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
  /// **'All set!'**
  String get welcomeDialogTitleCreate;

  /// No description provided for @welcomeDialogTitleJoin.
  ///
  /// In en, this message translates to:
  /// **'All set!'**
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
  /// **'Submit'**
  String get setPinDialogSetPin;

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

  /// No description provided for @setPinDialogOldWrong.
  ///
  /// In en, this message translates to:
  /// **'Wrong current PIN'**
  String get setPinDialogOldWrong;

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
  /// **'Once set, you\'ll unlock every time you enter the space — safer. You can also leave the new PIN blank to clear it.'**
  String get chatPageSetLockClearHint;

  /// No description provided for @chatPageSetLockHintNoPin.
  ///
  /// In en, this message translates to:
  /// **'Once set, you\'ll unlock every time you enter the space — safer.'**
  String get chatPageSetLockHintNoPin;

  /// No description provided for @chatPageSetLockOldLabel.
  ///
  /// In en, this message translates to:
  /// **'Current PIN'**
  String get chatPageSetLockOldLabel;

  /// No description provided for @chatPageSetLockOldRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter your current PIN first'**
  String get chatPageSetLockOldRequired;

  /// No description provided for @chatPageSetLockSameAsOld.
  ///
  /// In en, this message translates to:
  /// **'New PIN is the same as the current one — nothing changed'**
  String get chatPageSetLockSameAsOld;

  /// No description provided for @chatPageSetLockNoPinNotice.
  ///
  /// In en, this message translates to:
  /// **'No PIN set — next launch goes straight into the space'**
  String get chatPageSetLockNoPinNotice;

  /// No description provided for @chatPageSetLockDone.
  ///
  /// In en, this message translates to:
  /// **'App lock set — PIN required at next launch'**
  String get chatPageSetLockDone;

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
  /// **'A blank new PIN clears the app lock — clear it? Next launch will go straight into chat.'**
  String get chatPageClearLockMessage;

  /// No description provided for @chatPageMenuInvite.
  ///
  /// In en, this message translates to:
  /// **'Invite code'**
  String get chatPageMenuInvite;

  /// No description provided for @chatPageInviteDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Invite code generated'**
  String get chatPageInviteDialogTitle;

  /// No description provided for @chatPageInviteDialogHint.
  ///
  /// In en, this message translates to:
  /// **'Invite a new device to this space. One-time use, valid for 24 hours.'**
  String get chatPageInviteDialogHint;

  /// No description provided for @chatPageInviteCopyLinkTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy invite link'**
  String get chatPageInviteCopyLinkTooltip;

  /// No description provided for @chatPageInviteCopyCodeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy invite code'**
  String get chatPageInviteCopyCodeTooltip;

  /// No description provided for @chatPageInviteLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Invite link copied'**
  String get chatPageInviteLinkCopied;

  /// No description provided for @chatPageInviteCodeCopied.
  ///
  /// In en, this message translates to:
  /// **'Invite code copied'**
  String get chatPageInviteCodeCopied;

  /// No description provided for @chatPageInviteFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to generate invite code: {error}'**
  String chatPageInviteFailed(String error);

  /// No description provided for @chatPageTitleBrand.
  ///
  /// In en, this message translates to:
  /// **'My Einz'**
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

  /// No description provided for @chatPageMenuMore.
  ///
  /// In en, this message translates to:
  /// **'Menu'**
  String get chatPageMenuMore;

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
  /// **'This device in this space'**
  String get chatPageRenameDeviceTitle;

  /// No description provided for @chatPageRenameDeviceLabel.
  ///
  /// In en, this message translates to:
  /// **'Name in this space'**
  String get chatPageRenameDeviceLabel;

  /// No description provided for @chatPageDeviceScopeHint.
  ///
  /// In en, this message translates to:
  /// **'The name and public key belong to this space only — the same device has its own set in every space.'**
  String get chatPageDeviceScopeHint;

  /// No description provided for @chatPageRenameDeviceEmptyError.
  ///
  /// In en, this message translates to:
  /// **'Name cannot be empty'**
  String get chatPageRenameDeviceEmptyError;

  /// No description provided for @chatPageRenameDeviceInvalidError.
  ///
  /// In en, this message translates to:
  /// **'Only Chinese/English letters, digits, _ and - are allowed'**
  String get chatPageRenameDeviceInvalidError;

  /// No description provided for @chatPageRenameDeviceTooLongError.
  ///
  /// In en, this message translates to:
  /// **'At most {max} characters'**
  String chatPageRenameDeviceTooLongError(int max);

  /// No description provided for @chatPageRenameMyselfEmptyError.
  ///
  /// In en, this message translates to:
  /// **'Name cannot be empty'**
  String get chatPageRenameMyselfEmptyError;

  /// No description provided for @chatPageRenameNameInvalidError.
  ///
  /// In en, this message translates to:
  /// **'Only Chinese/English letters, digits, _ , - and emoji are allowed'**
  String get chatPageRenameNameInvalidError;

  /// No description provided for @chatPageRenameNameTooLongError.
  ///
  /// In en, this message translates to:
  /// **'At most {max} characters'**
  String chatPageRenameNameTooLongError(int max);

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

  /// No description provided for @chatPagePublicKeyCopied.
  ///
  /// In en, this message translates to:
  /// **'Public key copied'**
  String get chatPagePublicKeyCopied;

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
  /// **'Exits Einz on this device.'**
  String get chatPageExitMessage;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @chatPageChangePassphraseTitle.
  ///
  /// In en, this message translates to:
  /// **'Change secret passphrase'**
  String get chatPageChangePassphraseTitle;

  /// No description provided for @chatPageChangePassphraseSubmit.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get chatPageChangePassphraseSubmit;

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

  /// No description provided for @chatPagePassphraseRevealTip.
  ///
  /// In en, this message translates to:
  /// **'Show plain text (auto-hides after 3s)'**
  String get chatPagePassphraseRevealTip;

  /// No description provided for @chatPageChangePassphraseMismatch.
  ///
  /// In en, this message translates to:
  /// **'New passphrases do not match'**
  String get chatPageChangePassphraseMismatch;

  /// No description provided for @chatPageChangePassphraseSame.
  ///
  /// In en, this message translates to:
  /// **'New passphrase is the same as the current one — nothing changed'**
  String get chatPageChangePassphraseSame;

  /// No description provided for @chatPageChangePassphraseOldWrong.
  ///
  /// In en, this message translates to:
  /// **'Wrong current passphrase'**
  String get chatPageChangePassphraseOldWrong;

  /// No description provided for @chatPageChangePassphraseDone.
  ///
  /// In en, this message translates to:
  /// **'✅ Passphrase updated — tell your partner; new devices must use the new one'**
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

  /// No description provided for @chatPageMenuAttachmentStorage.
  ///
  /// In en, this message translates to:
  /// **'Attachment storage'**
  String get chatPageMenuAttachmentStorage;

  /// No description provided for @chatPageAttachmentStorageSecured.
  ///
  /// In en, this message translates to:
  /// **'Remote only'**
  String get chatPageAttachmentStorageSecured;

  /// No description provided for @chatPageAttachmentStorageSecuredDesc.
  ///
  /// In en, this message translates to:
  /// **'Downloads and decrypts the attachment every time it is opened; no plaintext copy is kept'**
  String get chatPageAttachmentStorageSecuredDesc;

  /// No description provided for @chatPageAttachmentStorageStored.
  ///
  /// In en, this message translates to:
  /// **'Keep locally'**
  String get chatPageAttachmentStorageStored;

  /// No description provided for @chatPageAttachmentStorageStoredDesc.
  ///
  /// In en, this message translates to:
  /// **'Keeps a decrypted copy after the first download, so opening it again is instant'**
  String get chatPageAttachmentStorageStoredDesc;

  /// No description provided for @chatPageAttachmentStorageSubmit.
  ///
  /// In en, this message translates to:
  /// **'Submit'**
  String get chatPageAttachmentStorageSubmit;

  /// No description provided for @chatPageAttachmentStorageWarnClear.
  ///
  /// In en, this message translates to:
  /// **'Switching to \"Remote only\" immediately deletes locally stored attachments'**
  String get chatPageAttachmentStorageWarnClear;

  /// No description provided for @chatPageMenuStyleLabel.
  ///
  /// In en, this message translates to:
  /// **'Interface style'**
  String get chatPageMenuStyleLabel;

  /// No description provided for @chatPageUiStylePlain.
  ///
  /// In en, this message translates to:
  /// **'Plain'**
  String get chatPageUiStylePlain;

  /// No description provided for @chatPageUiStylePlainDesc.
  ///
  /// In en, this message translates to:
  /// **'Light pink solid background, clean and calm'**
  String get chatPageUiStylePlainDesc;

  /// No description provided for @chatPageUiStyleGradient.
  ///
  /// In en, this message translates to:
  /// **'Gradient'**
  String get chatPageUiStyleGradient;

  /// No description provided for @chatPageUiStyleGradientDesc.
  ///
  /// In en, this message translates to:
  /// **'Pink-blue gradient in the brand colors'**
  String get chatPageUiStyleGradientDesc;

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
  /// **'Device name'**
  String get chatPageMenuDeviceNameLabel;

  /// No description provided for @chatPagePinLabel.
  ///
  /// In en, this message translates to:
  /// **'PIN'**
  String get chatPagePinLabel;

  /// No description provided for @chatPageLockNow.
  ///
  /// In en, this message translates to:
  /// **'Lock now'**
  String get chatPageLockNow;

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
  /// **'Delete now'**
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

  /// No description provided for @chatPageMsgSendingTap.
  ///
  /// In en, this message translates to:
  /// **'Sending… tap to verify and resend'**
  String get chatPageMsgSendingTap;

  /// No description provided for @chatPageMsgDelivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get chatPageMsgDelivered;

  /// No description provided for @chatPageMsgFailed.
  ///
  /// In en, this message translates to:
  /// **'Send failed, tap to retry'**
  String get chatPageMsgFailed;

  /// No description provided for @chatPageMsgFailedTap.
  ///
  /// In en, this message translates to:
  /// **'Tap to resend'**
  String get chatPageMsgFailedTap;

  /// No description provided for @chatPageOfflineUnsent.
  ///
  /// In en, this message translates to:
  /// **'Offline · {count} unsent'**
  String chatPageOfflineUnsent(int count);

  /// No description provided for @chatPageDeviceUnrecognized.
  ///
  /// In en, this message translates to:
  /// **'This device is not recognized by the server (its data may have been reset) · local messages only, no sync; your local data is NOT cleared'**
  String get chatPageDeviceUnrecognized;

  /// No description provided for @chatPageOfflineLocalOnly.
  ///
  /// In en, this message translates to:
  /// **'Offline · local messages only, cannot send or receive'**
  String get chatPageOfflineLocalOnly;

  /// No description provided for @chatPageMsgResending.
  ///
  /// In en, this message translates to:
  /// **'Resending…'**
  String get chatPageMsgResending;

  /// No description provided for @chatPageMsgSpeedingUp.
  ///
  /// In en, this message translates to:
  /// **'Speeding up…'**
  String get chatPageMsgSpeedingUp;

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

  /// No description provided for @chatPageVoicePermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Microphone permission denied. Please enable it in system settings.'**
  String get chatPageVoicePermissionDenied;

  /// No description provided for @chatPageVoiceEmpty.
  ///
  /// In en, this message translates to:
  /// **'Recording was empty and was discarded.'**
  String get chatPageVoiceEmpty;

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

  /// No description provided for @chatPageAttachEmoji.
  ///
  /// In en, this message translates to:
  /// **'Emoji'**
  String get chatPageAttachEmoji;

  /// No description provided for @chatPageEmojiKeyboard.
  ///
  /// In en, this message translates to:
  /// **'Keyboard'**
  String get chatPageEmojiKeyboard;

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

  /// No description provided for @chatPageAttachmentTapToDownload.
  ///
  /// In en, this message translates to:
  /// **'Not on this device — tap to download again'**
  String get chatPageAttachmentTapToDownload;

  /// No description provided for @chatPageVideoLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Video failed to load — tap to retry'**
  String get chatPageVideoLoadFailed;

  /// No description provided for @chatPageFileOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open file: {error}'**
  String chatPageFileOpenFailed(String error);

  /// No description provided for @chatPageDeviceRevoked.
  ///
  /// In en, this message translates to:
  /// **'Device revoked — local data cleared, please set up again'**
  String get chatPageDeviceRevoked;

  /// No description provided for @chatPageDevicePublicKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Public key in this space'**
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
  /// **'My Einz'**
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

  /// No description provided for @chatPageMenuAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get chatPageMenuAbout;

  /// No description provided for @aboutPageTitle.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get aboutPageTitle;

  /// No description provided for @aboutIntro.
  ///
  /// In en, this message translates to:
  /// **'Einz is a private chat and shared space for two: all messages and attachments are end-to-end encrypted, and no third party — including Einz itself — can read them, strictly safeguarding your privacy.'**
  String get aboutIntro;

  /// No description provided for @aboutVersionLabel.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get aboutVersionLabel;

  /// No description provided for @aboutServerLabel.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get aboutServerLabel;

  /// No description provided for @aboutServerDevNote.
  ///
  /// In en, this message translates to:
  /// **'Development address (not production), for debugging only'**
  String get aboutServerDevNote;

  /// No description provided for @advancedMenuTitle.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get advancedMenuTitle;

  /// No description provided for @advancedLeaveSpace.
  ///
  /// In en, this message translates to:
  /// **'Leave and clear this space'**
  String get advancedLeaveSpace;

  /// No description provided for @leaveSpaceTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave and clear this space?'**
  String get leaveSpaceTitle;

  /// No description provided for @leaveSpaceMessage.
  ///
  /// In en, this message translates to:
  /// **'This leaves this space and erases its messages and keys from this device.\n\nYour other spaces are untouched, and the space itself with its server-side data is kept.\n\nThis cannot be undone!'**
  String get leaveSpaceMessage;

  /// No description provided for @resetDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'Erase everything on this device?'**
  String get resetDeviceTitle;

  /// No description provided for @resetDeviceMessage.
  ///
  /// In en, this message translates to:
  /// **'This erases **every space** on this device together with its messages, attachments and keys, and returns to the new-device setup.\n\nThe spaces themselves stay on the server, and neither your other devices nor your partner\'s are affected.\n\nThis cannot be undone!'**
  String get resetDeviceMessage;

  /// No description provided for @resetDeviceConfirm.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get resetDeviceConfirm;

  /// No description provided for @resetDeviceNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Type \"{name}\" to confirm'**
  String resetDeviceNameLabel(String name);

  /// No description provided for @resetDeviceNameMismatch.
  ///
  /// In en, this message translates to:
  /// **'That does not match — try again'**
  String get resetDeviceNameMismatch;

  /// No description provided for @resetDeviceConfirmWord.
  ///
  /// In en, this message translates to:
  /// **'RESET'**
  String get resetDeviceConfirmWord;

  /// No description provided for @resetDevicePinLabel.
  ///
  /// In en, this message translates to:
  /// **'This device\'s PIN'**
  String get resetDevicePinLabel;

  /// No description provided for @resetDeviceServerResidualHint.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Local data erased, but retiring it on the server failed — this device may still show up in your partner\'s device list'**
  String get resetDeviceServerResidualHint;

  /// No description provided for @spaceListTitle.
  ///
  /// In en, this message translates to:
  /// **'My spaces'**
  String get spaceListTitle;

  /// No description provided for @spaceListAdd.
  ///
  /// In en, this message translates to:
  /// **'Create or join a space'**
  String get spaceListAdd;

  /// No description provided for @spaceListSwitch.
  ///
  /// In en, this message translates to:
  /// **'Switch space'**
  String get spaceListSwitch;

  /// No description provided for @spaceListManage.
  ///
  /// In en, this message translates to:
  /// **'Manage spaces'**
  String get spaceListManage;

  /// No description provided for @spaceListDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove this space?'**
  String get spaceListDeleteTitle;

  /// No description provided for @spaceListDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'This removes the space from this device only. Your other spaces are untouched, and the chat data on the server is kept. Removing it also unregisters this device from that space on the server (your partner\'s device list will show it as retired).'**
  String get spaceListDeleteMessage;

  /// No description provided for @spaceListDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get spaceListDeleteConfirm;

  /// No description provided for @spaceListResetDevice.
  ///
  /// In en, this message translates to:
  /// **'Erase everything on this device…'**
  String get spaceListResetDevice;

  /// No description provided for @spaceListMe.
  ///
  /// In en, this message translates to:
  /// **'Me: {name}'**
  String spaceListMe(String name);

  /// No description provided for @setupPinReuseNotice.
  ///
  /// In en, this message translates to:
  /// **'This space will use your current lock screen code.'**
  String get setupPinReuseNotice;
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
