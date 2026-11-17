import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/happ/happ_sub_update.dart';
import 'package:hiddify/features/profile/add/model/free_profiles_model.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/utils/riverpod_utils.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'profile_notifier.g.dart';

@riverpod
class AddProfileNotifier extends _$AddProfileNotifier with AppLogger {
  @override
  AsyncValue<Unit?> build() {
    ref.disposeDelay(const Duration(minutes: 1));
    ref.onDispose(() {
      loggy.debug("disposing");
      _cancelToken?.cancel();
    });
    listenSelf((previous, next) {
      final t = ref.read(translationsProvider).requireValue;
      final notification = ref.read(inAppNotificationControllerProvider);
      switch (next) {
        case AsyncData(value: final _?):
          notification.showSuccessToast(t.pages.profiles.msg.save.success);
        case AsyncError(:final error):
          if (error case ProfileInvalidUrlFailure()) {
            notification.showErrorToast(t.pages.profiles.msg.invalidUrl);
          } else if (error case ProfileCancelByUserFailure()) {
            return;
          } else {
            ref
                .read(dialogNotifierProvider.notifier)
                .showCustomAlertFromErr(t.presentError(error, action: t.pages.profiles.msg.add.failure));
          }
      }
    });
    ref.onDispose(() {
      if (!(_cancelToken?.isCancelled ?? true)) _cancelToken?.cancel();
    });
    return const AsyncData(null);
  }

  ProfileRepository get _profilesRepo => ref.read(profileRepositoryProvider).requireValue;
  CancelToken? _cancelToken;

  Future<void> addClipboard(String rawInput) async {
    if (state.isLoading) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      // final activeProfile = await ref.read(activeProfileProvider.future);
      // final markAsActive = activeProfile == null || ref.read(Preferences.markNewProfileActive);
      final TaskEither<ProfileFailure, Unit> task;
      if (LinkParser.parse(rawInput) case (final rs)?) {
        loggy.debug("adding profile, url: [${rs.url}]");
        task = _profilesRepo.upsertRemote(
          rs.url,
          userOverride: rs.name.isNotEmpty ? UserOverride(name: rs.name) : null,
          cancelToken: _cancelToken = CancelToken(),
        );
      } else {
        loggy.debug("adding profile, content");
        task = _profilesRepo.addLocal(safeDecodeBase64(rawInput));
      }
      return await task
          .match(
            (err) {
              loggy.warning("failed to add profile", err);
              throw err;
            },
            (_) {
              loggy.info("successfully added profile");
              return unit;
            },
          )
          .run();
    });
  }

  /// Adds all the files of a zip as one profile named [name]. The files are merged into one text that goes straight to
  /// the core, which decides which of them are valid configs.
  Future<void> addArchive(Uint8List zipBytes, {required String name}) async {
    if (state.isLoading) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final text = readZipText(zipBytes);
      if (text.isEmpty) throw const ProfileFailure.invalidConfig();
      return await _profilesRepo
          .addLocal(text, userOverride: UserOverride(name: name))
          .match(
            (err) {
              loggy.warning("failed to add profile from zip", err);
              throw err;
            },
            (_) {
              loggy.info("successfully added profile from zip");
              return unit;
            },
          )
          .run();
    });
  }

  Future<void> addManual({required String url, required UserOverride userOverride}) async {
    if (state.isLoading) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final task = _profilesRepo.upsertRemote(url, userOverride: userOverride);
      return await task
          .match(
            (err) {
              loggy.warning("failed to add profile", err);
              throw err;
            },
            (r) {
              loggy.info("successfully added profile, mark as active? [true]");
              return r;
            },
          )
          .run();
    });
  }
}

@riverpod
class UpdateProfileNotifier extends _$UpdateProfileNotifier with AppLogger {
  Timer? _resetTimer;

  @override
  AsyncValue<Unit?> build(String id) {
    ref.disposeDelay(const Duration(minutes: 1));
    ref.onDispose(() {
      _resetTimer?.cancel();
      _cancelToken?.cancel();
    });
    return const AsyncData(null);
  }

  ProfileRepository get _profilesRepo => ref.read(profileRepositoryProvider).requireValue;

  /// The saved config of profile [id]; null when there is none or it can not be read.
  Future<List<int>?> _readConfig(String id) async {
    try {
      final file = ref.read(profilePathResolverProvider).file(id);
      return await file.exists() ? await file.readAsBytes() : null;
    } catch (_) {
      return null;
    }
  }

  /// Happify: the download under way, stopped when a new update replaces it.
  CancelToken? _cancelToken;

  /// Happify: the number of the latest update; only that one sets the state, so an update that a
  /// newer one replaced can never leave the spinner on or turn it off too early.
  int _run = 0;
  DateTime? _startedAt;

  /// Updates [profile]. While an update runs, a call does nothing, unless [restart] (the user's
  /// own «Обновить» on the card or in its menu): then the update under way is stopped and a new one
  /// starts at once; a second tap within a moment of the first counts as the same tap.
  Future<void> updateProfile(RemoteProfileEntity profile, {bool isBulk = false, bool restart = false}) async {
    if (state.isLoading) {
      if (!restart) return;
      final started = _startedAt;
      if (started != null && DateTime.now().difference(started) < const Duration(milliseconds: 800)) return;
      _cancelToken?.cancel();
    }
    final run = ++_run;
    _startedAt = DateTime.now();
    _resetTimer?.cancel();
    state = const AsyncLoading();
    if (!isBulk) unawaited(ref.read(hapticServiceProvider.notifier).lightImpact());
    final cancelToken = _cancelToken = CancelToken();
    // Build-42: the config as it was, to tell whether the update changed it (no reload if not)
    final configBefore = await _readConfig(profile.id);
    AsyncValue<Unit?> result;
    try {
      result = await AsyncValue.guard(() async {
        return await _profilesRepo
            .upsertRemote(profile.url, cancelToken: cancelToken)
            .match(
              (err) {
                loggy.warning("failed to update profile", err);
                throw err;
              },
              (_) {
                loggy.info('successfully updated profile');
                // replaced by a newer update just as it finished: that one reconnects
                if (cancelToken.isCancelled) return unit;
                // the reconnect of the active profile goes on by itself: the spinner shows the
                // download only, and never waits on the tunnel
                unawaited(() async {
                  try {
                    final active = await ref.read(activeProfileProvider.future);
                    if (active != null && active.id == profile.id) {
                      // Build-42: a reload drops every open connection; an update that changed
                      // nothing (the usual hourly one) leaves the tunnel alone
                      final changed = happSubUpdateNeedsReload(
                        before: configBefore,
                        after: await _readConfig(profile.id),
                        overrideBefore: profile.profileOverride(),
                        overrideAfter: active.profileOverride(),
                      );
                      if (!changed) {
                        loggy.info('the update changed nothing, no reconnect');
                        return;
                      }
                      await ref.read(connectionNotifierProvider.notifier).reconnect(profile);
                    }
                  } catch (e) {
                    loggy.warning("reconnect after the update failed", e);
                  }
                }());
                return unit;
              },
            )
            .run();
      });
    } catch (e, st) {
      result = AsyncError(e, st);
    }

    // a newer update owns the state now
    if (run != _run) return;
    _cancelToken = null;
    _startedAt = null;
    // stopped (the provider went away): back to idle, without an error
    if (cancelToken.isCancelled) {
      _resetTimer?.cancel();
      state = const AsyncData(null);
      return;
    }
    state = result;

    // Single, user-initiated updates report failure via a dialog; success is
    // shown inline by the button indicator. Bulk runs stay silent here and are
    // summarized in one aggregate toast by ForegroundProfilesUpdateNotifier.
    if (result case AsyncError(:final error) when !isBulk) {
      try {
        final t = ref.read(translationsProvider).requireValue;
        ref
            .read(dialogNotifierProvider.notifier)
            .showCustomAlertFromErr(t.presentError(error, action: t.pages.profiles.msg.update.failure));
      } catch (e) {
        loggy.warning("could not show the update error", e);
      }
    }

    // Hold the success/failure result for 2s so the leading can flash an icon,
    // then reset to idle. Kept in the provider (not widget state) so it survives
    // the profile list re-sorting that happens right after an update.
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (run == _run && !state.isLoading) state = const AsyncData(null);
    });
  }
}

@riverpod
class FreeSwitchNotifier extends _$FreeSwitchNotifier {
  @override
  bool build() {
    return false;
  }

  Future<void> onChange(bool value) async => state = value;
}

@riverpod
class AddProfilePageNotifier extends _$AddProfilePageNotifier {
  @override
  AddProfilePages build() => AddProfilePages.options;

  void goOptions() => state = AddProfilePages.options;
  void goManual() => state = AddProfilePages.manual;
}

enum AddProfilePages { options, manual }

@riverpod
class FreeProfilesNotifier extends _$FreeProfilesNotifier {
  @override
  Future<List<FreeProfile>> build() async {
    final httpClient = ref.watch(httpClientProvider);
    final res = await httpClient.get(
      'https://raw.githubusercontent.com/hiddify/hiddify-app/refs/heads/main/test.configs/free_configs',
    );
    if (res.statusCode == 200) {
      return FreeProfilesModel.fromJson(jsonDecode(res.data.toString()) as Map<String, dynamic>).profiles;
    }
    return <FreeProfile>[];
  }
}

@riverpod
Future<List<FreeProfile>> freeProfilesFilteredByRegion(Ref ref) async {
  final freeProfiles = await ref.watch(freeProfilesNotifierProvider.future);
  final region = ref.watch(ConfigOptions.region);
  return freeProfiles.where((e) => e.region.contains(region.name) || e.region.isEmpty).toList();
}
