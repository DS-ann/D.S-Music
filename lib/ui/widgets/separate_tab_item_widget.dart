import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:harmonymusic/ui/widgets/modification_list.dart';

import '../screens/Artists/artist_screen_controller.dart';
import '../screens/Search/search_result_screen_controller.dart';
import 'list_widget.dart';
import 'loader.dart';
import 'sort_widget.dart';

class SeparateTabItemWidget extends StatelessWidget {
  const SeparateTabItemWidget({
    super.key,
    required this.items,
    required this.title,
    this.isCompleteList = true,
    this.isResultWidget = true,
    this.hideTitle = false,
    this.topPadding = 0,
    this.scrollController,
    this.artistControllerTag,
  });

  final String? artistControllerTag;
  final List<dynamic> items;
  final String title;
  final bool isCompleteList;
  final double topPadding;
  final bool isResultWidget;
  final bool hideTitle;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final artistController =
        Get.isRegistered<ArtistScreenController>(tag: artistControllerTag)
            ? Get.find<ArtistScreenController>(tag: artistControllerTag)
            : null;

    final searchResController =
        Get.isRegistered<SearchResultScreenController>()
            ? Get.find<SearchResultScreenController>()
            : null;

    final normalizedTitle = title.trim().toLowerCase();

    return Padding(
      padding: EdgeInsets.only(top: topPadding, left: 5),
      child: Column(
        children: [
          if (!hideTitle)
            SizedBox(
              height: 30,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    title.toLowerCase().removeAllWhitespace.tr,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  isCompleteList
                      ? const SizedBox.shrink()
                      : TextButton(
                          onPressed: () {
                            searchResController?.viewAllCallback(title);
                          },
                          child: Text(
                            "viewAll".tr,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                ],
              ),
            ),

          if (isCompleteList)
            Obx(() {
              final controller = searchResController;

              if (isResultWidget && controller != null) {
                final loading = controller.isTabLoading(title);
                final error = controller.tabError(title);
                final result = controller.separatedResultContent[title];
                final list = result is List
                    ? List<dynamic>.from(result)
                    : <dynamic>[];

                if (loading) {
                  return const Expanded(
                    child: Center(child: LoadingIndicator()),
                  );
                }

                if (error != null && !controller.hasTabResult(title)) {
                  return Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              "Couldn't load ${title.toLowerCase()}",
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 10),
                            TextButton(
                              onPressed: () {
                                final index = controller.railItems
                                    .indexOf(title);
                                if (index >= 0) {
                                  controller.onDestinationSelected(index + 1);
                                }
                              },
                              child: Text("retry".tr),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }

                // An empty loaded result is a real empty state. Do not leave
                // a full gray/loading area behind.
                if (list.isEmpty) {
                  return Expanded(
                    child: Center(
                      child: Text(
                        "No ${title.toLowerCase().tr}!",
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  );
                }

                return ListWidget(
                  list,
                  title,
                  isCompleteList,
                  scrollController: scrollController,
                );
              }

              if (!isResultWidget && artistController != null) {
                if (!artistController.isArtistContentFetced.isTrue) {
                  return const Expanded(
                    child: Center(child: LoadingIndicator()),
                  );
                }

                return Obx(
                  () => artistController.additionalOperationMode.value ==
                          OperationMode.none
                      ? ListWidget(
                          items,
                          title,
                          isCompleteList,
                          isArtistSongs: true,
                          artist: artistController.artist_,
                          scrollController: scrollController,
                        )
                      : ModificationList(
                          mode: artistController.additionalOperationMode.value,
                          screenController: artistController,
                        ),
                );
              }

              return const SizedBox.shrink();
            })
          else
            ListWidget(
              items,
              title,
              isCompleteList,
              scrollController: scrollController,
            ),

          // Keep this variable used so the widget remains compatible with
          // callers that depend on the title normalization.
          if (normalizedTitle.isEmpty) const SizedBox.shrink(),
        ],
      ),
    );
  }
}
