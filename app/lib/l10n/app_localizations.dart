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

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Einz'**
  String get appTitle;

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

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get loading;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @setupPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Einz · Device Setup'**
  String get setupPageTitle;

  /// No description provided for @setupPageHeading.
  ///
  /// In en, this message translates to:
  /// **'One-time setup'**
  String get setupPageHeading;

  /// No description provided for @setupPageInstructions.
  ///
  /// In en, this message translates to:
  /// **'1) Generate device key → the device registers automatically (no whitelist needed)\n2) Create or join the private space → set up the app lock'**
  String get setupPageInstructions;

  /// No description provided for @setupPageDeviceIdLabel.
  ///
  /// In en, this message translates to:
  /// **'Device ID'**
  String get setupPageDeviceIdLabel;

  /// No description provided for @setupPageDeviceIdHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. MacBook (optional, can change later)'**
  String get setupPageDeviceIdHint;

  /// No description provided for @setupPageSpaceIdLabel.
  ///
  /// In en, this message translates to:
  /// **'Space ID'**
  String get setupPageSpaceIdLabel;

  /// No description provided for @setupPageSealedKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Sealed Space Key (base64)'**
  String get setupPageSealedKeyLabel;

  /// No description provided for @setupPageSealedKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Paste the sealed copy (contents of sealed-*.txt)'**
  String get setupPageSealedKeyHint;

  /// No description provided for @setupPageKeyInfo.
  ///
  /// In en, this message translates to:
  /// **'Device ID: {deviceId}\nPublic key: {publicKey}\n(The device will register automatically on the next step — no whitelist needed)'**
  String setupPageKeyInfo(String deviceId, String publicKey);

  /// No description provided for @setupPageGenerateKey.
  ///
  /// In en, this message translates to:
  /// **'① Generate device key'**
  String get setupPageGenerateKey;

  /// No description provided for @setupPageImportAuth.
  ///
  /// In en, this message translates to:
  /// **'② Import & authenticate'**
  String get setupPageImportAuth;

  /// No description provided for @setupPageEscrowLabel.
  ///
  /// In en, this message translates to:
  /// **'Access passphrase (new devices can join with it, optional)'**
  String get setupPageEscrowLabel;

  /// No description provided for @setupPageEscrowHelper.
  ///
  /// In en, this message translates to:
  /// **'Key escrow: the server only stores ciphertext (KEY_ESCROW.md)'**
  String get setupPageEscrowHelper;

  /// No description provided for @setupPageEscrowAccess.
  ///
  /// In en, this message translates to:
  /// **'③ Join with passphrase (no sealed copy needed)'**
  String get setupPageEscrowAccess;

  /// No description provided for @setupPageGenerateSpaceKey.
  ///
  /// In en, this message translates to:
  /// **'Create space (one-tap generate key)'**
  String get setupPageGenerateSpaceKey;

  /// No description provided for @setupPageNeedPassphrase.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Set an access passphrase above first (your partner joins with it)'**
  String get setupPageNeedPassphrase;

  /// No description provided for @joinDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Invite your partner'**
  String get joinDialogTitle;

  /// No description provided for @joinDialogHint.
  ///
  /// In en, this message translates to:
  /// **'They install the app, tap ③ Join with passphrase, then scan this code or paste the info below.'**
  String get joinDialogHint;

  /// No description provided for @joinDialogSpace.
  ///
  /// In en, this message translates to:
  /// **'Space: {spaceId}'**
  String joinDialogSpace(String spaceId);

  /// No description provided for @joinDialogPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Passphrase: {passphrase}'**
  String joinDialogPassphrase(String passphrase);

  /// No description provided for @joinDialogCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy join info'**
  String get joinDialogCopy;

  /// No description provided for @joinDialogCopied.
  ///
  /// In en, this message translates to:
  /// **'Join info copied — send it to your partner'**
  String get joinDialogCopied;

  /// No description provided for @joinDialogContinue.
  ///
  /// In en, this message translates to:
  /// **'I shared it, enter chat'**
  String get joinDialogContinue;

  /// No description provided for @scanJoinTooltip.
  ///
  /// In en, this message translates to:
  /// **'Scan to join'**
  String get scanJoinTooltip;

  /// No description provided for @scanJoinTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan to join'**
  String get scanJoinTitle;

  /// No description provided for @scanJoinHint.
  ///
  /// In en, this message translates to:
  /// **'Scan your partner\'s join QR code'**
  String get scanJoinHint;

  /// No description provided for @scanJoinFound.
  ///
  /// In en, this message translates to:
  /// **'Join info recognized — space & passphrase filled in'**
  String get scanJoinFound;

  /// No description provided for @wizardRoleTitle.
  ///
  /// In en, this message translates to:
  /// **'How do you want to set up?'**
  String get wizardRoleTitle;

  /// No description provided for @wizardDetectTitle.
  ///
  /// In en, this message translates to:
  /// **'Checking server status…'**
  String get wizardDetectTitle;

  /// No description provided for @setupPageServerBar.
  ///
  /// In en, this message translates to:
  /// **'Server: {server}'**
  String setupPageServerBar(Object server);

  /// No description provided for @wizardDetectHint.
  ///
  /// In en, this message translates to:
  /// **'We\'ll detect whether you\'re the first user (first device creates the space)'**
  String get wizardDetectHint;

  /// No description provided for @wizardDetectFailed.
  ///
  /// In en, this message translates to:
  /// **'Cannot reach server — enter the address above and retry'**
  String get wizardDetectFailed;

  /// No description provided for @wizardNameHint.
  ///
  /// In en, this message translates to:
  /// **'This is your first device. Tell us what to call you (you can rename anytime).'**
  String get wizardNameHint;

  /// No description provided for @wizardNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Your name'**
  String get wizardNameLabel;

  /// No description provided for @wizardNameHintInput.
  ///
  /// In en, this message translates to:
  /// **'e.g. Lukas (optional, change later)'**
  String get wizardNameHintInput;

  /// No description provided for @wizardIdentityHint.
  ///
  /// In en, this message translates to:
  /// **'This space already has users — choose your identity:'**
  String get wizardIdentityHint;

  /// No description provided for @wizardIdentityCreator.
  ///
  /// In en, this message translates to:
  /// **'First user (creator)'**
  String get wizardIdentityCreator;

  /// No description provided for @wizardIdentityPartner.
  ///
  /// In en, this message translates to:
  /// **'Second user (partner)'**
  String get wizardIdentityPartner;

  /// No description provided for @wizardIdentityFirst.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Choose your identity first (creator or partner)'**
  String get wizardIdentityFirst;

  /// No description provided for @wizardInviteHint.
  ///
  /// In en, this message translates to:
  /// **'Enter the one-time invite code from the creator (generated by /invite, valid 24h)'**
  String get wizardInviteHint;

  /// No description provided for @wizardRoleCreate.
  ///
  /// In en, this message translates to:
  /// **'I\'m the first user — create a new space'**
  String get wizardRoleCreate;

  /// No description provided for @wizardRoleJoin.
  ///
  /// In en, this message translates to:
  /// **'I want to join an existing space'**
  String get wizardRoleJoin;

  /// No description provided for @wizardRoleAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced: import a sealed key copy'**
  String get wizardRoleAdvanced;

  /// No description provided for @wizardAppBarCreate.
  ///
  /// In en, this message translates to:
  /// **'Create a new space'**
  String get wizardAppBarCreate;

  /// No description provided for @wizardAppBarJoin.
  ///
  /// In en, this message translates to:
  /// **'Join your partner\'s space'**
  String get wizardAppBarJoin;

  /// No description provided for @wizardAppBarAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Import sealed key'**
  String get wizardAppBarAdvanced;

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

  /// No description provided for @wizardStepDevice.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get wizardStepDevice;

  /// No description provided for @wizardStepName.
  ///
  /// In en, this message translates to:
  /// **'Your name'**
  String get wizardStepName;

  /// No description provided for @wizardStepIdentity.
  ///
  /// In en, this message translates to:
  /// **'Your identity'**
  String get wizardStepIdentity;

  /// No description provided for @wizardStepInvite.
  ///
  /// In en, this message translates to:
  /// **'Enter invite code'**
  String get wizardStepInvite;

  /// No description provided for @wizardStepEnroll.
  ///
  /// In en, this message translates to:
  /// **'Register device'**
  String get wizardStepEnroll;

  /// No description provided for @wizardStepPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Access passphrase'**
  String get wizardStepPassphrase;

  /// No description provided for @wizardStepPin.
  ///
  /// In en, this message translates to:
  /// **'App lock'**
  String get wizardStepPin;

  /// No description provided for @wizardStepShare.
  ///
  /// In en, this message translates to:
  /// **'Invite your partner'**
  String get wizardStepShare;

  /// No description provided for @wizardStepJoin.
  ///
  /// In en, this message translates to:
  /// **'Join space'**
  String get wizardStepJoin;

  /// No description provided for @wizardStepSealed.
  ///
  /// In en, this message translates to:
  /// **'Import sealed key'**
  String get wizardStepSealed;

  /// No description provided for @wizardStepDone.
  ///
  /// In en, this message translates to:
  /// **'Complete'**
  String get wizardStepDone;

  /// No description provided for @setupPageKeyGenerated.
  ///
  /// In en, this message translates to:
  /// **'✅ Key generated'**
  String get setupPageKeyGenerated;

  /// No description provided for @wizardEnrollHint.
  ///
  /// In en, this message translates to:
  /// **'Registration is fully automatic now (no manual whitelist). Tap below to register this device — the first device on the server auto-creates the private space.'**
  String get wizardEnrollHint;

  /// No description provided for @wizardEnrollAction.
  ///
  /// In en, this message translates to:
  /// **'Register this device'**
  String get wizardEnrollAction;

  /// No description provided for @wizardEnrollDoneStatus.
  ///
  /// In en, this message translates to:
  /// **'✅ Registered — continue'**
  String get wizardEnrollDoneStatus;

  /// No description provided for @wizardEnrollDone.
  ///
  /// In en, this message translates to:
  /// **'✅ Registered\nDevice: {deviceId}\nSpace: {spaceId}'**
  String wizardEnrollDone(String deviceId, String spaceId);

  /// No description provided for @wizardEnrollExists.
  ///
  /// In en, this message translates to:
  /// **'This server already hosts a space (created by another device). Switch to the Join flow and use the one-time invite code from your partner.'**
  String get wizardEnrollExists;

  /// No description provided for @wizardEnrollGoJoin.
  ///
  /// In en, this message translates to:
  /// **'Switch to Join flow'**
  String get wizardEnrollGoJoin;

  /// No description provided for @wizardEnrollFailed.
  ///
  /// In en, this message translates to:
  /// **'❌ Registration failed: {error}'**
  String wizardEnrollFailed(String error);

  /// No description provided for @wizardEnrollFirst.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Register the device first (tap the button above)'**
  String get wizardEnrollFirst;

  /// No description provided for @wizardPassphraseHint.
  ///
  /// In en, this message translates to:
  /// **'Your partner joins with this passphrase — share it via QR code on the next step.'**
  String get wizardPassphraseHint;

  /// No description provided for @wizardPinHint.
  ///
  /// In en, this message translates to:
  /// **'You\'ll enter this PIN at every startup to unlock.'**
  String get wizardPinHint;

  /// No description provided for @wizardDoneText.
  ///
  /// In en, this message translates to:
  /// **'✅ Setup complete!'**
  String get wizardDoneText;

  /// No description provided for @wizardShareHint.
  ///
  /// In en, this message translates to:
  /// **'Your partner scans this code or pastes the info to join in one tap (includes the one-time invite code).'**
  String get wizardShareHint;

  /// No description provided for @wizardShareGenInvite.
  ///
  /// In en, this message translates to:
  /// **'Generate invite & show QR'**
  String get wizardShareGenInvite;

  /// No description provided for @wizardShareRegenerate.
  ///
  /// In en, this message translates to:
  /// **'Regenerate'**
  String get wizardShareRegenerate;

  /// No description provided for @wizardShareInviteNote.
  ///
  /// In en, this message translates to:
  /// **'The invite code is single-use and expires in 24h — regenerate it from the chat page if needed.'**
  String get wizardShareInviteNote;

  /// No description provided for @wizardShareInviteFailed.
  ///
  /// In en, this message translates to:
  /// **'❌ Invite generation failed: {error}'**
  String wizardShareInviteFailed(String error);

  /// No description provided for @wizardJoinHint.
  ///
  /// In en, this message translates to:
  /// **'Scan your partner\'s QR code (it carries the invite code & passphrase) to join in one tap; you can also paste the text or fill in the fields below.'**
  String get wizardJoinHint;

  /// No description provided for @setupPageKeyGenFailed.
  ///
  /// In en, this message translates to:
  /// **'❌ Key generation failed: {error}'**
  String setupPageKeyGenFailed(String error);

  /// No description provided for @setupPageGenKeyFirst.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Generate the device key first'**
  String get setupPageGenKeyFirst;

  /// No description provided for @setupPagePasteSealed.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Paste the sealed Space Key copy (base64)'**
  String get setupPagePasteSealed;

  /// No description provided for @setupPageImportFailed.
  ///
  /// In en, this message translates to:
  /// **'❌ Import/authentication failed: {error}'**
  String setupPageImportFailed(String error);

  /// No description provided for @setupPageEscrowGenKeyFirst.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Generate the device key first (①) and add its public key to the server whitelist'**
  String get setupPageEscrowGenKeyFirst;

  /// No description provided for @setupPageEscrowFillAll.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Fill in the Space ID, access passphrase and invite code'**
  String get setupPageEscrowFillAll;

  /// No description provided for @setupPageInviteLabel.
  ///
  /// In en, this message translates to:
  /// **'Invite code (one-time)'**
  String get setupPageInviteLabel;

  /// No description provided for @setupPageInviteHint.
  ///
  /// In en, this message translates to:
  /// **'Filled in automatically after scanning; paste the invite code when joining manually'**
  String get setupPageInviteHint;

  /// No description provided for @setupPageNeedInvite.
  ///
  /// In en, this message translates to:
  /// **'⚠️ Enter the one-time invite code (generated by an authenticated device)'**
  String get setupPageNeedInvite;

  /// No description provided for @setupPageNoEscrow.
  ///
  /// In en, this message translates to:
  /// **'❌ No escrow package on the server (set an access passphrase on the other device first)'**
  String get setupPageNoEscrow;

  /// No description provided for @setupPageEscrowFailed.
  ///
  /// In en, this message translates to:
  /// **'❌ Passphrase join failed: {error}'**
  String setupPageEscrowFailed(String error);

  /// No description provided for @setPinDialogPinLabel.
  ///
  /// In en, this message translates to:
  /// **'PIN (at least 4 characters)'**
  String get setPinDialogPinLabel;

  /// No description provided for @setPinDialogConfirmLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm PIN'**
  String get setPinDialogConfirmLabel;

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
  /// **'Without the app lock the Space Key package won\'t be encrypted on this device; you\'ll need to set it up again after restart. Skip anyway?'**
  String get setupPageSkipPinMessage;

  /// No description provided for @setPinDialogPinTooShort.
  ///
  /// In en, this message translates to:
  /// **'PIN must be at least 4 characters'**
  String get setPinDialogPinTooShort;

  /// No description provided for @setPinDialogPinMismatch.
  ///
  /// In en, this message translates to:
  /// **'The two PINs do not match'**
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

  /// No description provided for @chatPageBurnHeading.
  ///
  /// In en, this message translates to:
  /// **'Burn-after (only affects this device)'**
  String get chatPageBurnHeading;

  /// No description provided for @chatPageBurnOff.
  ///
  /// In en, this message translates to:
  /// **'Burn-after is off (messages are kept forever)'**
  String get chatPageBurnOff;

  /// No description provided for @chatPageBurnWillDelete.
  ///
  /// In en, this message translates to:
  /// **'Messages will be auto-deleted after {duration}'**
  String chatPageBurnWillDelete(String duration);

  /// No description provided for @chatPageBurnTooltip.
  ///
  /// In en, this message translates to:
  /// **'Burn-after: {label}'**
  String chatPageBurnTooltip(String label);

  /// No description provided for @chatPageBurnBadge.
  ///
  /// In en, this message translates to:
  /// **'⏱ Burn-after'**
  String get chatPageBurnBadge;

  /// No description provided for @chatPageSendFailed.
  ///
  /// In en, this message translates to:
  /// **'Send failed: {error}'**
  String chatPageSendFailed(String error);

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

  /// No description provided for @chatPageRecordingHint.
  ///
  /// In en, this message translates to:
  /// **'Recording… release to send'**
  String get chatPageRecordingHint;

  /// No description provided for @chatPageInputHint.
  ///
  /// In en, this message translates to:
  /// **'Type a message…'**
  String get chatPageInputHint;

  /// No description provided for @chatPageAudioMetaMissing.
  ///
  /// In en, this message translates to:
  /// **'Audio attachment metadata missing'**
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
  /// **'Audio file (mp3 etc.)'**
  String get chatPageAttachAudioFile;

  /// No description provided for @chatPageAttachAnyFile.
  ///
  /// In en, this message translates to:
  /// **'Any file'**
  String get chatPageAttachAnyFile;

  /// No description provided for @chatPageVideoMetaMissing.
  ///
  /// In en, this message translates to:
  /// **'Video attachment metadata missing'**
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

  /// No description provided for @burnOptionUnlimited.
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get burnOptionUnlimited;

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

  /// No description provided for @burnOption30Minutes.
  ///
  /// In en, this message translates to:
  /// **'30 minutes'**
  String get burnOption30Minutes;

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
  /// **'Locked for {seconds} seconds'**
  String lockPageLockedSeconds(int seconds);

  /// No description provided for @lockPagePinLabel.
  ///
  /// In en, this message translates to:
  /// **'PIN'**
  String get lockPagePinLabel;

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
