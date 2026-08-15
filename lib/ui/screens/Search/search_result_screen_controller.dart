import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:harmonymusic/ui/screens/Settings/settings_screen_controller.dart';

import '../../../utils/debug_logger.dart';
import '../../../utils/helper.dart';
import '../Home/home_screen_controller.dart';
import '/services/music_service.dart';
import '/ui/widgets/sort_widget.dart';

const _ctrlLogTag = 'SearchCtrl';

class SearchResultScreenController extends GetxController
    with GetTickerProviderStateMixin {
  final navigationRailCurrentIndex = 0.obs;
  final isResultContentFetced = false.obs;
  final isSeparatedResultContentFetced = false.obs;
  final resultContent = <String, dynamic>{}.obs;
  final separatedResultContent = <String, dynamic>{}.obs;
  final musicServices = Get.find<MusicServices>();
  final queryString = ''.obs;
  final railItems = <String>[].obs;
  final railitemHeight = Get.size.height.obs;
  /// Continuation data for each result tab.
  final Map<String, dynamic> additionalParamNext = {};

  /// Loading state for each tab. An empty list is NOT the same thing as
  /// "not loaded" — a request can legitimately return zero results.
  final Map<String, bool> tabLoading = <String, bool>{};
  final Map<String, String?> tabErrors = <String, String?>{};

  /// Prevents duplicate requests when the navigation/tab animation reports
  /// the same destination more than once.
  final Set<String> tabRequestInProgress = <String>{};

  bool continuationInProgress = false;
  TabController? tabController;
  bool isTabTransitionReversed = false;
  //ScrollContollers List
  final Map<String, ScrollController> scrollControllers = {};

  @override
  void onReady() {
    _getInitSearchResult();
    Get.find<HomeScreenController>().whenHomeScreenOnTop();
    super.onReady();
  }

  Future<void> onDestinationSelected(int value,
      {bool ignoreTabCommand = false}) async {
    if (railItems.isEmpty) {
      return;
    }

    if (value < 0 || value > railItems.length) {
      return;
    }

    isTabTransitionReversed = value > navigationRailCurrentIndex.value;
    navigationRailCurrentIndex.value = value;

    if (tabController != null && !ignoreTabCommand) {
      if (tabController!.index != value) {
        tabController?.animateTo(value);
      }
    }

    // Main "All" tab.
    if (value == 0) {
      isSeparatedResultContentFetced.value = true;
      return;
    }

    final tabName = railItems[value - 1];

    // Do not start the same request twice. This is important because the
    // TabController animation listener can call this method again.
    if (tabRequestInProgress.contains(tabName)) {
      isSeparatedResultContentFetced.value = false;
      return;
    }

    // If this tab has already been loaded successfully, display it directly.
    // An empty list is considered a valid loaded response, so use the explicit
    // loading state rather than list.isEmpty().
    if (separatedResultContent.containsKey(tabName) &&
        tabLoading[tabName] != true &&
        additionalParamNext.containsKey(tabName)) {
      isSeparatedResultContentFetced.value = true;
      _attachContinuationListener(tabName);
      return;
    }

    tabRequestInProgress.add(tabName);
    tabLoading[tabName] = true;
    tabErrors[tabName] = null;
    isSeparatedResultContentFetced.value = false;

    try {
      final itemCount =
          (tabName == 'Songs' || tabName == 'Videos') ? 25 : 30;

      final endpointMap = resultContent['searchEndpoint'];
      final filterParams = endpointMap is Map
          ? endpointMap[tabName]
          : null;

      final x = await musicServices.search(
        queryString.value,
        filter: tabName.replaceAll(" ", "_").toLowerCase(),
        limit: itemCount,
        filterParams: filterParams?.toString(),
      );

      final rawResults = x[tabName];
      final List<dynamic> parsedResults =
          rawResults is List ? List<dynamic>.from(rawResults) : <dynamic>[];

      separatedResultContent[tabName] = parsedResults;
      separatedResultContent.refresh();

      // Always store the continuation map. If no continuation exists, use an
      // empty map rather than indexing a null value later.
      final nextParams = x['params'];
      additionalParamNext[tabName] =
          nextParams is Map ? Map<String, dynamic>.from(nextParams) : <String, dynamic>{};

      DebugLogger.info(
        _ctrlLogTag,
        'Loaded tab "$tabName": ${parsedResults.length} results',
      );

      tabLoading[tabName] = false;
      tabErrors[tabName] = null;
      isSeparatedResultContentFetced.value = true;
      _attachContinuationListener(tabName);
    } catch (e, stack) {
      tabLoading[tabName] = false;
      tabErrors[tabName] = e.toString();
      isSeparatedResultContentFetced.value = true;

      DebugLogger.warn(
        _ctrlLogTag,
        'Failed loading tab "$tabName": $e\\n$stack',
      );
    } finally {
      tabRequestInProgress.remove(tabName);
    }
  }

  bool isTabLoading(String tabName) => tabLoading[tabName] == true;

  String? tabError(String tabName) => tabErrors[tabName];

  bool hasTabResult(String tabName) =>
      separatedResultContent.containsKey(tabName);

  void _attachContinuationListener(String tabName) {
    final controller = scrollControllers[tabName];
    if (controller == null) {
      return;
    }

    // addListener is called only after the tab has loaded. Existing listener
    // count is tracked by a small flag map to avoid attaching multiple
    // identical listeners on repeated taps.
    if (_continuationListenerAttached.contains(tabName)) {
      return;
    }

    _continuationListenerAttached.add(tabName);

    controller.addListener(() {
      if (!controller.hasClients || controller.position.maxScrollExtent <= 0) {
        return;
      }

      final maxScroll = controller.position.maxScrollExtent;
      final currentScroll = controller.position.pixels;

      if (currentScroll < maxScroll / 2) {
        return;
      }

      final params = additionalParamNext[tabName];
      if (params is! Map || params.isEmpty) {
        return;
      }

      final additional = params['additionalParams']?.toString() ?? '';
      if (additional.isEmpty ||
          additional == '&ctoken=null&continuation=null') {
        return;
      }

      if (!continuationInProgress) {
        continuationInProgress = true;
        getContinuationContents(tabName: tabName);
      }
    });
  }

  final Set<String> _continuationListenerAttached = <String>{};

  Future<void> getContinuationContents({String? tabName}) async {
    final resolvedTabName = tabName ??
        (navigationRailCurrentIndex.value > 0
            ? railItems[navigationRailCurrentIndex.value - 1]
            : null);

    if (resolvedTabName == null) {
      continuationInProgress = false;
      return;
    }

    final params = additionalParamNext[resolvedTabName];
    if (params is! Map || params.isEmpty) {
      continuationInProgress = false;
      return;
    }

    try {
      final x = await musicServices.getSearchContinuation(params);

      final newRaw = x[resolvedTabName];
      final newItems =
          newRaw is List ? List<dynamic>.from(newRaw) : <dynamic>[];

      final currentRaw = separatedResultContent[resolvedTabName];
      final currentItems =
          currentRaw is List ? List<dynamic>.from(currentRaw) : <dynamic>[];

      if (newItems.isNotEmpty) {
        // Deduplicate continuation results where possible.
        final seen = <String>{
          for (final item in currentItems) _resultIdentity(item),
        };

        for (final item in newItems) {
          final id = _resultIdentity(item);
          if (seen.add(id)) {
            currentItems.add(item);
          }
        }

        separatedResultContent[resolvedTabName] = currentItems;
        separatedResultContent.refresh();
      }

      final nextParams = x['params'];
      additionalParamNext[resolvedTabName] =
          nextParams is Map ? Map<String, dynamic>.from(nextParams) : <String, dynamic>{};

      DebugLogger.info(
        _ctrlLogTag,
        'Continuation for "$resolvedTabName": '
        'received=${newItems.length}, total=${currentItems.length}',
      );
    } catch (e, stack) {
      DebugLogger.warn(
        _ctrlLogTag,
        'Continuation failed for "$resolvedTabName": $e\\n$stack',
      );
    } finally {
      continuationInProgress = false;
    }
  }

  String _resultIdentity(dynamic item) {
    try {
      final id = item.id;
      if (id != null) return 'id:$id';
    } catch (_) {}

    try {
      final browseId = item.browseId;
      if (browseId != null) return 'browse:$browseId';
    } catch (_) {}

    try {
      final playlistId = item.playlistId;
      if (playlistId != null) return 'playlist:$playlistId';
    } catch (_) {}

    try {
      final title = item.title;
      if (title != null) return 'title:$title';
    } catch (_) {}

    return item.toString();
  }

  void viewAllCallback(String text) {
    onDestinationSelected(railItems.indexOf(text) + 1);
  }

  Future<void> _getInitSearchResult() async {
    isResultContentFetced.value = false;
    final args = Get.arguments;
    if (args != null) {
      queryString.value = args;
      DebugLogger.info(_ctrlLogTag, '_getInitSearchResult: query="$args"');
      try {
        resultContent.value = await musicServices.search(args);
      } catch (e, stack) {
        DebugLogger.warn(
          _ctrlLogTag,
          '_getInitSearchResult failed: $e\\n$stack',
        );
        resultContent.clear();
        railItems.clear();
        isResultContentFetced.value = true;
        return;
      }

      // Diagnostic: full key/count breakdown of the resultContent map.
      final breakdown = <String, int>{};
      resultContent.forEach((k, v) {
        if (k == 'searchEndpoint' || k == 'params') {
          breakdown[k] = v is Map ? v.length : 0;
        } else {
          breakdown[k] = v is List ? v.length : 0;
        }
      });
      DebugLogger.info(
        _ctrlLogTag,
        'resultContent received: keys=${resultContent.keys.toList()} '
        'breakdown=$breakdown',
      );

      final allKeys = resultContent.keys.where((element) => ([
            "Songs",
            "Videos",
            "Albums",
            "Featured playlists",
            "Community playlists",
            "Artists"
          ]).contains(element));
      railItems.value = List<String>.from(allKeys);
      DebugLogger.info(
        _ctrlLogTag,
        'railItems (after filter) = $railItems',
      );
      final playlistTabCount =
          railItems.where((element) => element.contains("playlists")).length;

      // This is only an approximate desktop/rail layout height. It should
      // never be based on a hard-coded result count such as 30.
      final calH =
          30 + (railItems.length + 1 - playlistTabCount) * 123 +
          playlistTabCount * 150.0;

      railitemHeight.value = calH;

      // Scroll controllers for continuation.
      for (final controller in scrollControllers.values) {
        controller.dispose();
      }
      scrollControllers.clear();
      additionalParamNext.clear();
      tabLoading.clear();
      tabErrors.clear();
      tabRequestInProgress.clear();
      _continuationListenerAttached.clear();

      for (String item in railItems) {
        scrollControllers[item] = ScrollController();
        tabLoading[item] = false;
      }

      //Case if bottom nav used
      if (GetPlatform.isDesktop ||
          Get.find<SettingsScreenController>().isBottomNavBarEnabled.isTrue) {
        // assiging init val
        for (var element in railItems) {
          separatedResultContent[element] = [];
        }

        //tab controller for v2
        tabController =
            TabController(length: railItems.length + 1, vsync: this);

        tabController?.animation?.addListener(() {
          int indexChange = tabController!.offset.round();
          int index = tabController!.index + indexChange;

          if (index != navigationRailCurrentIndex.value) {
            onDestinationSelected(index, ignoreTabCommand: true);
          }
        });
      }
      isResultContentFetced.value = true;
    }
  }

  void onSort(SortType sortType, bool isAscending, String title) {
    if (title == "Songs" || title == "Videos") {
      final songList = separatedResultContent[title].toList();
      sortSongsNVideos(songList, sortType, isAscending);
      separatedResultContent[title] = songList;
    } else if (title.contains('playlists')) {
      final playlists = separatedResultContent[title].toList();
      sortPlayLists(playlists, sortType, isAscending);
      separatedResultContent[title] = playlists;
    } else if (title == "Artists") {
      final artistList = separatedResultContent[title].toList();
      sortArtist(artistList, sortType, isAscending);
      separatedResultContent[title] = artistList;
    } else if (title == "Albums") {
      final albumList = separatedResultContent[title].toList();
      sortAlbumNSingles(albumList, sortType, isAscending);
      separatedResultContent[title] = albumList;
    }
  }

  @override
  void onClose() {
    for (String item in railItems) {
      (scrollControllers[item])!.dispose();
    }
    Get.find<HomeScreenController>().whenHomeScreenOnTop();
    tabController?.dispose();
    super.onClose();
  }
}