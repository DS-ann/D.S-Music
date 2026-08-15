import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../screens/Search/search_result_screen_controller.dart';
import '../../utils/debug_logger.dart';
import '/models/album.dart';
import '/models/artist.dart';
import '/models/playlist.dart';
import '/ui/widgets/content_list_widget.dart';
import 'separate_tab_item_widget.dart';

const _widgetLogTag = 'ResultWidget';

class ResultWidget extends StatelessWidget {
  const ResultWidget({super.key, this.isv2Used = false});
  final bool isv2Used;

  @override
  Widget build(BuildContext context) {
    final SearchResultScreenController searchResScrController =
        Get.find<SearchResultScreenController>();
    final topPadding = context.isLandscape ? 50.0 : 80.0;
    return Obx(
      () => Center(
        child: Padding(
          padding: const EdgeInsets.all(0.0),
          child: SingleChildScrollView(
            padding:
                EdgeInsets.only(bottom: 200, top: isv2Used ? 0 : topPadding),
            child: searchResScrController.isResultContentFetced.value
                ? Column(children: [
                    if (!isv2Used)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          "searchRes".tr,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    if (!isv2Used)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          "${"for1".tr} \"${searchResScrController.queryString.value}\"",
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    const SizedBox(
                      height: 10,
                    ),
                    ...generateWidgetList(searchResScrController),
                  ])
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  List<Widget> generateWidgetList(
      SearchResultScreenController searchResScrController) {
    List<Widget> list = [];
    final trace = StringBuffer('generateWidgetList: ');
    for (dynamic item in searchResScrController.resultContent.entries) {
      try {
        if (item.key == "Songs" || item.key == "Videos") {
          final items = _castList<MediaItem>(item.value, item.key);
          if (items == null || items.isEmpty) {
            trace.write('[skip-empty:${item.key}]');
            continue;
          }
          trace.write('[$item.key:${items.length}]');
          list.add(SeparateTabItemWidget(
            items: items,
            title: item.key,
            isCompleteList: false,
          ));
        } else if (item.key == "Albums") {
          final items = _castList<Album>(item.value, item.key);
          if (items == null || items.isEmpty) {
            trace.write('[skip-empty:${item.key}]');
            continue;
          }
          trace.write('[$item.key:${items.length}]');
          list.add(ContentListWidget(
            content:
                AlbumContent(title: item.key, albumList: items),
            isHomeContent: false,
          ));
        } else if (item.key.toString().contains("playlist")) {
          final items = _castList<Playlist>(item.value, item.key);
          if (items == null || items.isEmpty) {
            trace.write('[skip-empty:${item.key}]');
            continue;
          }
          trace.write('[$item.key:${items.length}]');
          list.add(ContentListWidget(
            content:
                PlaylistContent(title: item.key, playlistList: items),
            isHomeContent: false,
          ));
        } else if (item.key == "Artists") {
          final items = _castList<Artist>(item.value, item.key);
          if (items == null || items.isEmpty) {
            trace.write('[skip-empty:${item.key}]');
            continue;
          }
          trace.write('[$item.key:${items.length}]');
          list.add(SeparateTabItemWidget(
            items: items,
            title: item.key,
            isCompleteList: false,
          ));
        } else {
          trace.write('[skip:${item.key}]');
        }
      } catch (e, st) {
        DebugLogger.error(_widgetLogTag,
            'failed to render entry key="${item.key}"', e, st);
        trace.write('[error:${item.key}]');
      }
    }
    DebugLogger.debug(_widgetLogTag, trace.toString());
    return list;
  }

  /// Cast a List<dynamic> to a typed List<T>. If the first item is not of
  /// type T, returns null and logs a warning. This protects the widget tree
  /// from type-cast exceptions when the parser produces the wrong type for
  /// a bucket (e.g. an Album sneaking into a Playlist bucket).
  List<T>? _castList<T>(dynamic raw, String bucketKey) {
    if (raw is! List) return null;
    if (raw.isEmpty) return <T>[];
    if (raw.first is! T) {
      DebugLogger.warn(
        _widgetLogTag,
        'bucket "$bucketKey" has wrong item type: '
        'expected $T, got ${raw.first.runtimeType}. Skipping.',
      );
      return null;
    }
    return List<T>.from(raw);
  }
}