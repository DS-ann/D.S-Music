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
  final additionalParamNext = <String, dynamic>{};
  bool continuationInProgress = false;
  TabController? tabController;
  bool isTabTransitionReversed = false;

  // ScrollControllers Map
  final Map<String, ScrollController> scrollControllers = {};

  @override
  void onReady() {
    _getInitSearchResult();
    Get.find<HomeScreenController>().whenHomeScreenOnTop();
    super.onReady();
  }

  Future<void> onDestinationSelected(
    int value, {
    bool ignoreTabCommand = false,
  }) async {
    if (railItems.isEmpty || value < 0 || value > railItems.length) {
      return;
    }

    isTabTransitionReversed = value > navigationRailCurrentIndex.value;
    isSeparatedResultContentFetced.value = false;
    navigationRailCurrentIndex.value = value;

    if (tabController != null && !ignoreTabCommand) {
      tabController?.animateTo(value);
    }

    if (value > 0) {
      final tabName = railItems[value - 1];
      if (!separatedResultContent.containsKey(tabName) ||
          (separatedResultContent[tabName] as List).isEmpty) {
        final itemCount = (tabName == 'Songs' || tabName == 'Videos') ? 25 : 10;
        final x = await musicServices.search(
          queryString.value,
          filter: tabName.replaceAll(" ", "_").toLowerCase(),
          limit: itemCount,
          filterParams: resultContent['searchEndpoint']?[tabName],
        );

        separatedResultContent[tabName] = x[tabName] ?? [];
        additionalParamNext[tabName] = x['params'] ?? {};
        separatedResultContent.refresh();
      }
    }
    isSeparatedResultContentFetced.value = true;
  }

  Future<void> getContinuationContents() async {
    if (navigationRailCurrentIndex.value <= 0) return;
    final tabName = railItems[navigationRailCurrentIndex.value - 1];

    if (additionalParamNext[tabName] == null) return;

    try {
      final x = await musicServices
          .getSearchContinuation(additionalParamNext[tabName]);
      if (x[tabName] != null && x[tabName] is List) {
        (separatedResultContent[tabName] as List).addAll(x[tabName]);
        additionalParamNext[tabName] = x['params'];
        separatedResultContent.refresh();
      }
    } catch (e) {
      DebugLogger.info(_ctrlLogTag, "Continuation error: $e");
    } finally {
      continuationInProgress = false;
    }
  }

  void viewAllCallback(String text) {
    final index = railItems.indexOf(text);
    if (index != -1) {
      onDestinationSelected(index + 1);
    }
  }

  Future<void> _getInitSearchResult() async {
    isResultContentFetced.value = false;
    final args = Get.arguments;
    if (args != null) {
      queryString.value = args;
      DebugLogger.info(_ctrlLogTag, '_getInitSearchResult: query="$args"');
      resultContent.value = await musicServices.search(args);

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
      DebugLogger.info(_ctrlLogTag, 'railItems (after filter) = $railItems');

      final len =
          railItems.where((element) => element.contains("playlists")).length;
      final calH = 30 + (railItems.length + 1 - len) * 123 + len * 150.0;
      railitemHeight.value =
          calH >= railitemHeight.value ? calH : railitemHeight.value;

      // Attach ScrollController listeners ONLY ONCE during initialization
      for (String item in railItems) {
        final controller = ScrollController();
        controller.addListener(() {
          if (!controller.hasClients) return;

          final maxScroll = controller.position.maxScrollExtent;
          final currentScroll = controller.position.pixels;

          final params = additionalParamNext[item];
          final additionalParamsStr = params?['additionalParams'] ?? '';

          if (currentScroll >= maxScroll / 2 &&
              additionalParamsStr != '&ctoken=null&continuation=null') {
            if (!continuationInProgress) {
              continuationInProgress = true;
              getContinuationContents();
            }
          }
        });
        scrollControllers[item] = controller;
      }

      if (GetPlatform.isDesktop ||
          Get.find<SettingsScreenController>()
              .isBottomNavBarEnabled
              .isTrue) {
        for (var element in railItems) {
          separatedResultContent[element] = [];
        }

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
    if (!separatedResultContent.containsKey(title) ||
        separatedResultContent[title] == null) return;

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
      scrollControllers[item]?.dispose();
    }
    scrollControllers.clear();
    Get.find<HomeScreenController>().whenHomeScreenOnTop();
    tabController?.dispose();
    super.onClose();
  }
}