// ignore_for_file: constant_identifier_names

import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:get/get.dart' as getx;
import 'package:hive/hive.dart';

import '/models/album.dart';
import '/services/utils.dart';
import '../utils/debug_logger.dart';
import '../utils/helper.dart';
import 'constant.dart';
import 'continuations.dart';
import 'http_logger.dart';
import 'nav_parser.dart';

const _logTag = 'Search';

enum AudioQuality {
  Low,
  High,
}

class MusicServices extends getx.GetxService {
  final Map<String, String> _headers = {
    'user-agent': userAgent,
    'accept': '*/*',
    'accept-encoding': 'gzip, deflate',
    'content-type': 'application/json',
    'content-encoding': 'gzip',
    'origin': domain,
    'cookie': 'CONSENT=YES+1',
  };

  final Map<String, dynamic> _context = {
    'context': {
      'client': {
        "clientName": "WEB_REMIX",
        "clientVersion": "1.20230213.01.00",
      },
      'user': {}
    }
  };

  @override
  void onInit() {
    init();
    super.onInit();
  }

  final dio = Dio();

  MusicServices() {
    // HTTP request/response logging is wired at construction so every call
    // made by this service (search, browse, player, etc.) is captured.
    dio.interceptors.add(HttpLoggingInterceptor());
    DebugLogger.info('MusicServices', 'instance created, HTTP interceptor attached');
  }

  Future<void> init() async {
    //check visitor id in data base, if not generate one , set lang code
    final date = DateTime.now();
    _context['context']['client']['clientVersion'] =
        "1.${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}.01.00";
    final signatureTimestamp = getDatestamp() - 1;
    _context['playbackContext'] = {
      'contentPlaybackContext': {'signatureTimestamp': signatureTimestamp},
    };

    final appPrefsBox = Hive.box('AppPrefs');
    hlCode = appPrefsBox.get('contentLanguage') ?? "en";
    if (appPrefsBox.containsKey('visitorId')) {
      final visitorData = appPrefsBox.get("visitorId");
      if (visitorData != null && !isExpired(epoch: visitorData['exp'])) {
        _headers['X-Goog-Visitor-Id'] = visitorData['id'];
        appPrefsBox.put("visitorId", {
          'id': visitorData['id'],
          'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 2590200
        });
        printINFO("Got Visitor id ($visitorData['id']) from Box");
        return;
      }
    }

    final visitorId = await genrateVisitorId();
    if (visitorId != null) {
      _headers['X-Goog-Visitor-Id'] = visitorId;
      printINFO("New Visitor id generated ($visitorId)");
      appPrefsBox.put("visitorId", {
        'id': visitorId,
        'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 2592000
      });
      return;
    }
    // not able to generate in that case
    _headers['X-Goog-Visitor-Id'] =
        visitorId ?? "CgttN24wcmd5UzNSWSi2lvq2BjIKCgJKUBIEGgAgYQ%3D%3D";
  }

  set hlCode(String code) {
    _context['context']['client']['hl'] = code;
  }

  Future<String?> genrateVisitorId() async {
    try {
      final response =
          await dio.get(domain, options: Options(headers: _headers));
      final reg = RegExp(r'ytcfg\.set\s*\(\s*({.+?})\s*\)\s*;');
      final matches = reg.firstMatch(response.data.toString());
      String? visitorId;
      if (matches != null) {
        final ytcfg = json.decode(matches.group(1).toString());
        visitorId = ytcfg['VISITOR_DATA']?.toString();
      }
      return visitorId;
    } catch (e) {
      return null;
    }
  }

  Future<Response> _sendRequest(String action, Map<dynamic, dynamic> data,
      {additionalParams = ""}) async {
    //print("$baseUrl$action$fixedParms$additionalParams          data:$data");
    try {
      final response =
          await dio.post("$baseUrl$action$fixedParms$additionalParams",
              options: Options(
                headers: _headers,
              ),
              data: data);

      if (response.statusCode == 200) {
        return response;
      } else {
        return _sendRequest(action, data, additionalParams: additionalParams);
      }
    } on DioException catch (e) {
      printINFO("Error $e");
      throw NetworkError();
    }
  }

  // Future<List<Map<String, dynamic>>>
  Future<dynamic> getHome({int limit = 4}) async {
    final data = Map.from(_context);
    data["browseId"] = "FEmusic_home";
    final response = await _sendRequest("browse", data);
    final results = nav(response.data, single_column_tab + section_list);
    final home = [...parseMixedContent(results)];

    final sectionList =
        nav(response.data, single_column_tab + ['sectionListRenderer']);
    //inspect(sectionList);
    //print(sectionList.containsKey('continuations'));
    if (sectionList.containsKey('continuations')) {
      requestFunc(additionalParams) async {
        return (await _sendRequest("browse", data,
                additionalParams: additionalParams))
            .data;
      }

      parseFunc(contents) => parseMixedContent(contents);
      final x = (await getContinuations(sectionList, 'sectionListContinuation',
          limit - home.length, requestFunc, parseFunc));
      // inspect(x);
      home.addAll([...x]);
    }

    return home;
  }

  Future<List<Map<String, dynamic>>> getCharts(String catogory,
      {String? countryCode}) async {
    final List<Map<String, dynamic>> charts = [];
    final data = Map.from(_context);

    data['browseId'] = 'FEmusic_charts';
    data['context']['client']["hl"] = 'en';
    if (countryCode != null) {
      data['formData'] = {
        'selectedValues': [countryCode]
      };
    }
    final response = (await _sendRequest('browse', data)).data;
    final results = nav(response, single_column_tab + section_list);
    results.removeAt(0);
    for (dynamic result in results) {
      if (nav(result, [
            "musicCarouselShelfRenderer",
            "header",
            "musicCarouselShelfBasicHeaderRenderer",
            ...title_text
          ]) ==
          "Video charts") {
        for (dynamic item in result['musicCarouselShelfRenderer']['contents']) {
          final chartItem =
              await getChartItems(parseChartsItemBrowseId(item), catogory);
          charts.add(chartItem);
        }
      } else {
        continue;
      }
    }

    return charts;
  }

  Future<Map<String, dynamic>> getChartItems(
      Map<String, dynamic> item, String catogory) async {
    final catString = catogory == "TMV" ? "Top Music Videos" : "Trending";
    if ((item['title'])!.contains(catString)) {
      final songs = (await getPlaylistOrAlbumSongs(
          playlistId: item['browseId']))['tracks'];
      final limitedSongs = songs.length > 24 ? songs.sublist(0, 24) : songs;
      return {'title': item['title'], 'contents': limitedSongs};
    }
    return {'title': item['title'], 'contents': []};
  }

  Future<Map<String, dynamic>> getWatchPlaylist(
      {String videoId = "",
      String? playlistId,
      int limit = 25,
      bool radio = false,
      bool shuffle = false,
      String? additionalParamsNext,
      bool onlyRelated = false}) async {
    if (videoId.isNotEmpty && videoId.substring(0, 4) == "MPED") {
      videoId = videoId.substring(4);
    }
    final data = Map.from(_context);
    data['enablePersistentPlaylistPanel'] = true;
    data['isAudioOnly'] = true;
    data['tunerSettingValue'] = 'AUTOMIX_SETTING_NORMAL';
    if (videoId == "" && playlistId == null) {
      throw Exception(
          "You must provide either a video id, a playlist id, or both");
    }
    if (videoId != "") {
      data['videoId'] = videoId;
      playlistId ??= "RDAMVM$videoId";

      if (!(radio || shuffle)) {
        data['watchEndpointMusicSupportedConfigs'] = {
          'watchEndpointMusicConfig': {
            'hasPersistentPlaylistPanel': true,
            'musicVideoType': "MUSIC_VIDEO_TYPE_ATV",
          }
        };
      }
    }

    playlistId = validatePlaylistId(playlistId!);
    data['playlistId'] = playlistId;
    final isPlaylist =
        playlistId.startsWith('PL') || playlistId.startsWith('OLA');
    if (shuffle) {
      data['params'] = "wAEB8gECKAE%3D";
    }
    if (radio) {
      data['params'] = "wAEB";
    }

    final List<dynamic> tracks = [];
    dynamic lyricsBrowseId, relatedBrowseId, playlist;
    final results = {};

    if (additionalParamsNext == null) {
      final response = (await _sendRequest("next", data)).data;
      final watchNextRenderer = nav(response, [
        'contents',
        'singleColumnMusicWatchNextResultsRenderer',
        'tabbedRenderer',
        'watchNextTabbedResultsRenderer'
      ]);

      lyricsBrowseId = getTabBrowseId(watchNextRenderer, 1);
      relatedBrowseId = getTabBrowseId(watchNextRenderer, 2);
      if (onlyRelated) {
        return {
          'lyrics': lyricsBrowseId,
          'related': relatedBrowseId,
        };
      }

      results.addAll(nav(watchNextRenderer, [
        ...tab_content,
        'musicQueueRenderer',
        'content',
        'playlistPanelRenderer'
      ]));
      playlist = results['contents']
          .map((content) => nav(content,
              ['playlistPanelVideoRenderer', ...navigation_playlist_id]))
          .where((e) => e != null)
          .toList()
          .first;
      tracks.addAll(parseWatchPlaylist(results['contents']));
    }

    dynamic additionalParamsForNext;
    if (results.containsKey('continuations') || additionalParamsNext != null) {
      requestFunc(additionalParams) async =>
          (await _sendRequest("next", data, additionalParams: additionalParams))
              .data;
      parseFunc(contents) => parseWatchPlaylist(contents);
      final x = await getContinuations(results, 'playlistPanelContinuation',
          limit - tracks.length, requestFunc, parseFunc,
          ctokenPath: isPlaylist ? '' : 'Radio',
          isAdditionparamReturnReq: true,
          additionalParams_: additionalParamsNext);
      additionalParamsForNext = x[1];
      tracks.addAll(List<dynamic>.from(x[0]));
    }

    return {
      'tracks': tracks,
      'playlistId': playlist,
      'lyrics': lyricsBrowseId,
      'related': relatedBrowseId,
      'additionalParamsForNext': additionalParamsForNext
    };
  }

  Future<String> getAlbumBrowseId(String audioPlaylistId) async {
    final response = await dio.get("${domain}playlist",
        options: Options(headers: _headers),
        queryParameters: {"list": audioPlaylistId});
    final reg = RegExp(r'\"MPRE.+?\"');
    final matchs = reg.firstMatch(response.data.toString());
    if (matchs != null) {
      final x = (matchs[0])!;
      final res = (x.substring(1)).split("\\")[0];
      return res;
    }
    return audioPlaylistId;
  }

  dynamic getContentRelatedToSong(String videoId, String hlCode) async {
    final params = await getWatchPlaylist(videoId: videoId, onlyRelated: true);
    final data = Map.from(_context);
    data['browseId'] = params['related'];
    data['context']['client']['hl'] = hlCode;
    final response = (await _sendRequest('browse', data)).data;
    final sections = nav(response, ['contents'] + section_list);
    final x = parseMixedContent(sections);
    return x;
  }

  dynamic getLyrics(String browseId) async {
    final data = Map.from(_context);
    data['browseId'] = browseId;
    final response = (await _sendRequest('browse', data)).data;
    return nav(
      response,
      ['contents', ...section_list_item, ...description_shelf, ...description],
    );
  }

  Future<Map<String, dynamic>> getPlaylistOrAlbumSongs(
      {String? playlistId,
      String? albumId,
      int limit = 3000,
      bool related = false,
      int suggestionsLimit = 0}) async {
    String browseId = playlistId != null
        ? (playlistId.startsWith("VL") ? playlistId : "VL$playlistId")
        : albumId!;
    if (albumId != null && albumId.contains("OLAK5uy")) {
      browseId = await getAlbumBrowseId(browseId);
    }
    final data = Map.from(_context);
    data['browseId'] = browseId;
    final Map<String, dynamic> response =
        (await _sendRequest('browse', data)).data;
    if (playlistId != null) {
      final Map<String, dynamic> header =
          nav(response, ['header', "musicDetailHeaderRenderer"]) ??
              nav(response, [
                'contents',
                "twoColumnBrowseResultsRenderer",
                'tabs',
                0,
                "tabRenderer",
                "content",
                "sectionListRenderer",
                "contents",
                0,
                "musicResponsiveHeaderRenderer"
              ]);

      final Map<String, dynamic> results =
          nav(response, musicPlaylistShelfRenderer) ??
              nav(
                response,
                [
                  'contents',
                  "singleColumnBrowseResultsRenderer",
                  "tabs",
                  0,
                  "tabRenderer",
                  "content",
                  'sectionListRenderer',
                  'contents',
                  0,
                  "musicPlaylistShelfRenderer"
                ],
              );
      final Map<String, dynamic> playlist = {'id': results['playlistId']};

      playlist['title'] = nav(header, title_text);
      playlist['thumbnails'] = nav(header, thumnail_cropped) ??
          nav(header, [
            "thumbnail",
            "musicThumbnailRenderer",
            "thumbnail",
            "thumbnails"
          ]);
      playlist["description"] = nav(header, description);
      final int runCount = header['subtitle']['runs'].length;
      if (runCount > 1) {
        playlist['author'] = {
          'name': nav(header, subtitle2),
          'id': nav(header, ['subtitle', 'runs', 2] + navigation_browse_id)
        };
        if (runCount == 5) {
          playlist['year'] = nav(header, subtitle3);
        }
      }

      final int secondSubtitleRunCount =
          header['secondSubtitle']['runs'].length;
      final String count = (((header['secondSubtitle']['runs']
                      [secondSubtitleRunCount % 3]['text'])
                  .split(' ')[0])
              .split(',') as List)
          .join();
      final int songCount = int.parse(count);
      if (header['secondSubtitle']['runs'].length > 1) {
        playlist['duration'] = header['secondSubtitle']['runs']
            [(secondSubtitleRunCount % 3) + 2]['text'];
      }
      playlist['trackCount'] = songCount;

      // requestFunc(additionalParams) async => (await _sendRequest("browse", data,
      //         additionalParams: additionalParams))
      //     .data;

      requestFuncCountinuation(cont) async =>
          (await _sendRequest("browse", {...data, ...cont})).data;

      if (songCount > 0) {
        playlist['tracks'] = parsePlaylistItems(results['contents']);
        limit = songCount;

        List<dynamic> parseFunc(contents) => parsePlaylistItems(contents);

        playlist['tracks'] = [
          ...(playlist['tracks']),
          ...(await getContinuationsPlaylist(
              results, limit, requestFuncCountinuation, parseFunc))
        ];
      }
      playlist['duration_seconds'] = sumTotalDuration(playlist);
      return playlist;
    }

    //album content
    final album = parseAlbumHeader(response);
    dynamic results = nav(
          response,
          [
            'contents',
            "twoColumnBrowseResultsRenderer",
            "secondaryContents",
            'sectionListRenderer',
            'contents',
            0,
            'musicShelfRenderer'
          ],
        ) ??
        nav(
          response,
          [
            'contents',
            "singleColumnBrowseResultsRenderer",
            "tabs",
            0,
            "tabRenderer",
            "content",
            'sectionListRenderer',
            'contents',
            0,
            'musicShelfRenderer'
          ],
        );

    album['tracks'] = parsePlaylistItems(results['contents'],
        artistsM: album['artists'],
        thumbnailsM: album["thumbnails"],
        albumIdName: {"id": albumId, 'name': album['title']},
        albumYear: album['year'],
        isAlbum: true);
    results = nav(
      response,
      [...single_column_tab, ...section_list, 1, 'musicCarouselShelfRenderer'],
    );
    if (results != null) {
      List contents = [];
      if (results.runtimeType.toString().contains("Iterable") ||
          results.runtimeType.toString().contains("List")) {
        for (dynamic result in results) {
          contents.add(parseAlbum(result['musicTwoRowItemRenderer']));
        }
      } else {
        contents
            .add(parseAlbum(results['contents'][0]['musicTwoRowItemRenderer']));
      }
      album['other_versions'] = contents;
    }
    album['duration_seconds'] = sumTotalDuration(album);

    return album;
  }

  Future<List<String>> getSearchSuggestion(String queryStr) async {
    final data = Map.from(_context);
    data['input'] = queryStr;
    final res = nav(
            (await _sendRequest("music/get_search_suggestions", data)).data,
            ['contents', 0, 'searchSuggestionsSectionRenderer', 'contents']) ??
        [];
    return res
        .map<String?>((item) {
          return (nav(item, [
            'searchSuggestionRenderer',
            'navigationEndpoint',
            'searchEndpoint',
            'query'
          ])).toString();
        })
        .whereType<String>()
        .toList();
  }

  ///Specially created for deep-links
  Future<List> getSongWithId(String songId) async {
    final data = Map.of(_context);
    data['videoId'] = songId;
    final response = (await _sendRequest("player", data)).data;
    final category =
        nav(response, ["microformat", "microformatDataRenderer", "category"]);
    if (category == "Music" ||
        (response["videoDetails"]).containsKey("musicVideoType")) {
      final list = await getWatchPlaylist(videoId: songId);
      return [true, list['tracks']];
    }
    return [false, null];
  }

  Future<Map<String, dynamic>> search(String query,
      {String? filter,
      String? scope,
      int limit = 30,
      bool ignoreSpelling = false,
      String? filterParams}) async {
    final data = Map.of(_context);
    data['context']['client']["hl"] = 'en';
    data['query'] = query;

    DebugLogger.info(
      _logTag,
      'search() called: query="$query" filter=$filter scope=$scope limit=$limit',
    );

    final Map<String, dynamic> searchResults = {};
    final filters = [
      'albums',
      'artists',
      'playlists',
      'community_playlists',
      'featured_playlists',
      'songs',
      'videos'
    ];

    if (filter != null && !filters.contains(filter)) {
      throw Exception(
          'Invalid filter provided. Please use one of the following filters or leave out the parameter: ${filters.join(', ')}');
    }

    final scopes = ['library', 'uploads'];

    if (scope != null && !scopes.contains(scope)) {
      throw Exception(
          'Invalid scope provided. Please use one of the following scopes or leave out the parameter: ${scopes.join(', ')}');
    }

    if (scope == scopes[1] && filter != null) {
      throw Exception(
          'No filter can be set when searching uploads. Please unset the filter parameter when scope is set to uploads.');
    }

    final params = getSearchParams(filter, scope, ignoreSpelling);

    if (filterParams != null || params != null) {
      data['params'] = filterParams ?? params;
    }

    final response = (await _sendRequest("search", data)).data;

    DebugLogger.info(
      _logTag,
      'response received: top-level keys=${response.keys.toList()} '
      'hasContents=${response['contents'] != null}',
    );

    if (response['contents'] == null) {
      DebugLogger.warn(_logTag, 'response.contents is null, returning empty result');
      return searchResults;
    }

    dynamic results;

    if ((response['contents']).containsKey('tabbedSearchResultsRenderer')) {
      final tabIndex =
          scope == null || filter != null ? 0 : scopes.indexOf(scope) + 1;
      results = response['contents']['tabbedSearchResultsRenderer']['tabs']
          [tabIndex]['tabRenderer']['content'];
    } else {
      results = response['contents'];
    }

    // Search Chips
    /*
    {
      "searchEndpoint": {
        "Songs": "Eg-KAQwIARAAGAMQCRAFEAAYASgB",
        "Videos": "Eg-KAQwIARAAGAMQCRAFEAAYASgB",
        "Albums": "Eg-KAQwIARAAGAMQCRAFEAAYASgB",
        "Artists": "Eg-KAQwIARAAGAMQCRAFEAAYASgB",
        "Playlists": "Eg-KAQwIARAAGAMQCRAFEAAYASgB",
        "Community playlists": "Eg-KAQwIARAAGAMQCRAFEAAYASgB",
        "Featured playlists": "Eg-KAQwIARAAGAMQCRAFEAAYASgB"
      }
     */
    if (filter == null) {
      final searchChips = nav(results,
          ['sectionListRenderer', 'header', "chipCloudRenderer", "chips"]);

      searchResults['searchEndpoint'] = {};
      if (searchChips != null) {
        for (dynamic chipsItemRenderer in searchChips) {
          final chip = chipsItemRenderer['chipCloudChipRenderer'];
          final chipText = nav(chip, ['text', 'runs', 0, 'text']);
          searchResults['searchEndpoint'][chipText] =
              nav(chip, ['navigationEndpoint', 'searchEndpoint', 'params']);
        }
      }

      DebugLogger.info(
        _logTag,
        'searchEndpoint chips: ${searchResults['searchEndpoint'].keys.toList()}',
      );

      // Note: we used to add empty "Community playlists" and
      // "Featured playlists" buckets here so the rail tabs would always
      // show those options. The rail tabs already drive their own filtered
      // searches, so we no longer pre-create empty sections. The main view
      // now only shows categories that actually have items in them.
    }

    /// End Search Chips

    results = nav(results, ['sectionListRenderer', 'contents']);

    DebugLogger.info(
      _logTag,
      'sectionListRenderer.contents count=${results?.length}',
    );

    if (results.length == 1 && results[0]['itemSectionRenderer'] != null) {
      DebugLogger.warn(
        _logTag,
        'response is a single itemSectionRenderer (probably "no results"). '
        'Returning empty map.',
      );
      return searchResults;
    }

    // Structural summary of every element in `sectionListRenderer.contents`.
    // This makes it obvious what the API actually returns — what kind of
    // renderer each element is, and what its title (if any) is.
    final structureBuf = StringBuffer('sectionListRenderer.contents structure:\n');
    for (var i = 0; i < results.length; i++) {
      final entry = results[i];
      if (entry is Map) {
        final keys = entry.keys.map((e) => e.toString()).toList();
        // Try to find any title in this element for context.
        String? title;
        for (final k in keys) {
          final v = entry[k];
          if (v is Map) {
            final t = nav(v, title_text);
            if (t != null) {
              title = t.toString();
              break;
            }
          }
        }
        structureBuf.writeln('  [$i] keys=$keys title=${title ?? "(none)"}');
      } else {
        structureBuf.writeln('  [$i] (not a Map) type=${entry.runtimeType}');
      }
    }
    DebugLogger.info(_logTag, structureBuf.toString().trimRight());

    String? type;

    int shelfIndex = 0;
    for (var res in results) {
      String category;
      // YouTube Music's current response shape (as of 2026-06) does NOT
      // group search results by category in shelves. Instead,
      // `sectionListRenderer.contents` is a flat list where:
      //   - element 0 is a `musicCardShelfRenderer` (the "Top result")
      //   - elements 1..N are each a single `itemSectionRenderer` whose
      //     inner `contents[0]` is a `musicResponsiveListItemRenderer`
      // Each item must be classified client-side using
      // [classifySearchResultBucket] (pageType + flexColumns[1] fallback).
      //
      // We don't go through `_unwrapShelf` here because the items are
      // NOT inside a shelf renderer — the `itemSectionRenderer` directly
      // holds the `musicResponsiveListItemRenderer`. We extract the item
      // directly and fall back to `_unwrapShelf` only when the structure
      // is the legacy shelf-wrapped shape.

      final Map<String, dynamic>? rawItem;
      final String? sourceKey; // for diagnostic logging only

      if (res is Map &&
          res['itemSectionRenderer'] is Map &&
          (res['itemSectionRenderer'] as Map)['contents'] is List) {
        // New shape: itemSectionRenderer.contents[0].musicResponsiveListItemRenderer
        final isr = res['itemSectionRenderer'] as Map;
        final inner = isr['contents'] as List;
        Map<String, dynamic>? found;
        for (final c in inner) {
          if (c is Map) {
            final item = c['musicResponsiveListItemRenderer'];
            if (item is Map) {
              found = Map<String, dynamic>.from(item);
              break;
            }
          }
        }
        rawItem = found;
        sourceKey = 'itemSectionRenderer';
      } else if (res is Map && res['musicCardShelfRenderer'] is Map) {
        // Top result card. The actual item data is not in
        // `musicResponsiveListItemRenderer` — it lives in the card
        // itself. For now we skip the card (the title/subtitle are
        // already shown by the card UI). Could be extended to extract
        // the underlying item if needed.
        DebugLogger.info(
          _logTag,
          'shelf[$shelfIndex] TopResult card: '
          'title="${nav(res['musicCardShelfRenderer'], ['title', 'runs', 0, 'text'])}" '
          'subtitle="${nav(res['musicCardShelfRenderer'], ['subtitle', 'runs', 0, 'text'])}"',
        );
        rawItem = null;
        sourceKey = 'musicCardShelfRenderer';
      } else {
        // Legacy shape: a real shelf. Use _unwrapShelf as a fallback.
        final unwrapped = _unwrapShelf(res);
        final shelfBody = unwrapped?.$2;
        if (unwrapped != null && shelfBody != null) {
          rawItem = _extractSingleItem(
              Map<String, dynamic>.from(shelfBody), unwrapped.$1!);
        } else {
          rawItem = null;
        }
        sourceKey = 'legacy-shelf';
      }

      DebugLogger.debug(
        _logTag,
        'shelf[$shelfIndex] keys=${res.keys.toList()} source=$sourceKey itemFound=${rawItem != null}',
      );

      if (rawItem == null) {
        shelfIndex++;
        continue;
      }

      // Filtered path: we just use the existing logic (parse all items
      // from the shelf body and bucket by shelf title). Skip per-item
      // classification here.
      if (filter != null) {
        // For filtered, fall through to the old logic via _unwrapShelf.
        final unwrapped = _unwrapShelf(res);
        final shelfBody = unwrapped?.$2;
        if (unwrapped != null && shelfBody != null) {
          final mixedItems = parseSearchResults(
            shelfBody['contents'],
            const ['artist', 'playlist', 'song', 'video', 'station'],
            type,
            'mixed',
          );
          final types = <String, int>{};
          for (final i in mixedItems) {
            types[i.runtimeType.toString()] =
                (types[i.runtimeType.toString()] ?? 0) + 1;
          }
          DebugLogger.debug(
            _logTag,
            'shelf[$shelfIndex] (filtered) parsed: total=${mixedItems.length} byType=$types',
          );
          category = nav(shelfBody, title_text) ?? 'mixed';
          searchResults[category] = mixedItems;
        }
        shelfIndex++;
        continue;
      }

      // Unfiltered path: parse + classify + bucket.
      final typed = parseSearchResult(
        rawItem,
        const ['artist', 'playlist', 'song', 'video', 'station'],
        null,
        'mixed',
      );
      if (typed == null) {
        DebugLogger.debug(
          _logTag,
          'shelf[$shelfIndex] parseSearchResult returned null',
        );
        shelfIndex++;
        continue;
      }

      final bucket = classifySearchResultBucket(rawItem);
      if (bucket == null) {
        DebugLogger.debug(
          _logTag,
          'shelf[$shelfIndex] could not classify item, '
          'type=${typed.runtimeType}',
        );
        shelfIndex++;
        continue;
      }
      final finalBucket = bucket == 'Featured playlists'
          ? (refinePlaylistBucket(rawItem) ?? 'Featured playlists')
          : bucket;

      // Cap at 10 per bucket.
      if (searchResults.containsKey(finalBucket) &&
          (searchResults[finalBucket] as List).length >= 10) {
        shelfIndex++;
        continue;
      }
      searchResults.putIfAbsent(finalBucket, () => <dynamic>[]);
      (searchResults[finalBucket] as List).add(typed);

      DebugLogger.info(
        _logTag,
        'shelf[$shelfIndex] classified: ${typed.runtimeType} -> "$finalBucket"',
      );
      shelfIndex++;
    }

    // Final summary: keys, item counts, and any orphan buckets.
    final summary = <String, int>{};
    var orphans = 0;
    searchResults.forEach((k, v) {
      if (k == 'searchEndpoint' || k == 'params') return;
      final n = v is List ? v.length : 0;
      summary[k] = n;
      if (k.toString().startsWith('_orphan_')) orphans += n;
    });
    DebugLogger.info(
      _logTag,
      'search() returning searchResults keys=${searchResults.keys.toList()} '
      'counts=$summary orphans=$orphans',
    );

    return searchResults;
  }

  /// Resolves an element from `sectionListRenderer.contents` to the actual
  /// shelf body that holds `title` and `contents`. Returns a `(key, body)`
  /// pair where `key` is the renderer type (e.g. `musicShelfRenderer`) and
  /// `body` is the inner Map the caller should read `title` and `contents`
  /// from. Returns null if no shelf can be found.
  ///
  /// YouTube Music wraps many of its shelves in an `itemSectionRenderer`
  /// container, so this function also unwraps one level of that:
  ///
  /// ```json
  /// { "itemSectionRenderer": { "contents": [
  ///     { "musicShelfRenderer": { "title": {...}, "contents": [...] } }
  /// ]}}
  /// ```
  (String?, Map?)? _unwrapShelf(Map res, {int depth = 0}) {
    const knownTypes = [
      'musicShelfRenderer',
      'musicCardShelfRenderer',
      'musicCarouselShelfRenderer',
      'musicImmersiveCarouselShelfRenderer',
      'musicPlaylistShelfRenderer',
    ];
    Map? asMap(Object? v) => v is Map ? v : null;

    // Direct shelf renderers.
    for (final k in knownTypes) {
      if (res.containsKey(k)) {
        final body = asMap(res[k]);
        if (body != null) return (k, body);
      }
    }
    // Last-resort fallback: any key ending with `ShelfRenderer` whose value
    // is a Map. Covers future renderer renames.
    for (final entry in res.entries) {
      final ks = entry.key.toString();
      if (ks.endsWith('ShelfRenderer')) {
        final body = asMap(entry.value);
        if (body != null) return (ks, body);
      }
    }
    // itemSectionRenderer wrapper: look one level deeper.
    if (res.containsKey('itemSectionRenderer')) {
      final outer = asMap(res['itemSectionRenderer']);
      final inner = outer?['contents'];
      DebugLogger.debug(
        _logTag,
        '_unwrapShelf(depth=$depth): itemSectionRenderer found, '
        'innerType=${inner.runtimeType} innerLen=${inner is List ? inner.length : "n/a"}',
      );
      if (inner is List) {
        for (var i = 0; i < inner.length; i++) {
          final candidate = inner[i];
          if (candidate is Map) {
            final ckeys = candidate.keys.map((e) => e.toString()).toList();
            DebugLogger.debug(
              _logTag,
              '_unwrapShelf(depth=$depth): candidate[$i] keys=$ckeys',
            );
            final unwrapped = _unwrapShelf(candidate, depth: depth + 1);
            if (unwrapped != null) return unwrapped;
          } else {
            DebugLogger.debug(
              _logTag,
              '_unwrapShelf(depth=$depth): candidate[$i] is not a Map '
              '(${candidate.runtimeType})',
            );
          }
        }
      } else if (outer != null) {
        DebugLogger.debug(
          _logTag,
          '_unwrapShelf(depth=$depth): itemSectionRenderer.contents is not a List, '
          'outer.keys=${outer.keys.toList()}',
        );
      }
    }
    return null;
  }

  /// Extract the single `musicResponsiveListItemRenderer` Map from an
  /// unwrapped shelf body. Returns null if the body is empty or in an
  /// unexpected shape.
  ///
  /// For `itemSectionRenderer`: `body.contents[0].musicResponsiveListItemRenderer`.
  /// For `musicCardShelfRenderer` (Top result): the card has no `contents`
  /// in the shelf sense — the actual item data is accessed differently
  /// (see the Top-result special case in the caller). Here we return null
  /// and the caller logs a different message.
  Map<String, dynamic>? _extractSingleItem(
      Map<String, dynamic> shelfBody, String shelfKey) {
    final contents = shelfBody['contents'];
    if (contents is List) {
      for (final c in contents) {
        if (c is Map) {
          final item = c['musicResponsiveListItemRenderer'];
          if (item is Map<String, dynamic>) return item;
          if (item is Map) return Map<String, dynamic>.from(item);
        }
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> getSearchContinuation(
    Map additionalParamsNext, {
    int limit = 10,
  }) async {
    final data = additionalParamsNext['data'];
    final type = additionalParamsNext['type'];
    final category = additionalParamsNext['category'];
    final Map<String, dynamic> searchResults = {};

    requestFunc(additionalParams) async =>
        (await _sendRequest("search", data, additionalParams: additionalParams))
            .data;

    parseFunc(contents) => parseSearchResults(contents,
        ['artist', 'playlist', 'song', 'video', 'station'], type, category);

    final x = await getContinuations(
        {}, 'musicShelfContinuation', limit, requestFunc, parseFunc,
        isAdditionparamReturnReq: true,
        additionalParams_: additionalParamsNext['additionalParams']);

    searchResults["params"] = {
      "data": data,
      "type": type,
      "category": category,
      'additionalParams': x[1],
    };

    searchResults[category] = x[0];

    return searchResults;
  }

  Future<Map<String, dynamic>> getArtist(String channelId) async {
    if (channelId.startsWith("MPLA")) {
      channelId = channelId.substring(4);
    }
    final data = Map.from(_context);
    data['context']['client']["hl"] = 'en';
    data['browseId'] = channelId;
    final response = (await _sendRequest("browse", data)).data;
    final results = nav(response, [...single_column_tab, ...section_list]);

    final Map<String, dynamic> artist = {'description': null, 'views': null};
    final Map<String, dynamic> header = (response['header']
            ['musicImmersiveHeaderRenderer']) ??
        response['header']['musicVisualHeaderRenderer'];
    artist['name'] = nav(header, title_text);
    final descriptionShelf =
        findObjectByKey(results, description_shelf[0], isKey: true);
    if (descriptionShelf != null) {
      artist['description'] = nav(descriptionShelf, description);
      artist['views'] = descriptionShelf['subheader'] == null
          ? null
          : descriptionShelf['subheader']['runs'][0]['text'];
    }
    final dynamic subscriptionButton = header['subscriptionButton'] != null
        ? header['subscriptionButton']['subscribeButtonRenderer']
        : null;
    artist['channelId'] = channelId;
    artist['shuffleId'] = nav(header,
        ['playButton', 'buttonRenderer', ...navigation_watch_playlist_id]);
    artist['radioId'] = nav(
      header,
      ['startRadioButton', 'buttonRenderer'] + navigation_playlist_id,
    );
    artist['subscribers'] = subscriptionButton != null
        ? nav(
            subscriptionButton,
            ['subscriberCountText', 'runs', 0, 'text'],
          )
        : null;

    artist['thumbnails'] = nav(header, thumbnails);

    artist.addAll(parseArtistContents(results));
    return artist;
  }

  Future<Map<String, dynamic>> getArtistRealtedContent(
      Map<String, dynamic> browseEndpoint, String category,
      {String additionalParams = ""}) async {
    final Map<String, dynamic> result = {
      "results": [],
    };
    final data = Map.of(_context);
    browseEndpoint.remove("content");
    if (browseEndpoint.isEmpty) return result;
    data.addAll(browseEndpoint);
    final response =
        (await _sendRequest("browse", data, additionalParams: additionalParams))
            .data;
    final contents = nav(response, [
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
      0,
    ]);

    if (category == "Songs" || category == "Videos") {
      if (additionalParams != "") {
        final contentList = nav(response, [
          "onResponseReceivedActions",
          0,
          "appendContinuationItemsAction",
          "continuationItems"
        ]);
        final x = parsePlaylistItems(contentList);
        result['results'] = x;
        result['additionalParams'] = "&ctoken=${null}&continuation=${null}";
      } else if (contents.containsKey("gridRenderer")) {
        result['results'] = (contents['gridRenderer']['items'])
            .map((video) => parseVideo(video['musicTwoRowItemRenderer']))
            .toList();
        result['additionalParams'] = "&ctoken=${null}&continuation=${null}";
      } else {
        final collapseContent =
            nav(contents, ['musicPlaylistShelfRenderer', "collapsedItemCount"]);
        if (collapseContent != null) {
          final contentlist =
              contents['musicPlaylistShelfRenderer']['contents'];
          if (contentlist.length.toString() != collapseContent.toString()) {
            final continuationItem = contentlist.removeAt(100);
            result['results'] = parsePlaylistItems(contentlist);
            final continuationKey = nav(continuationItem, [
              "continuationItemRenderer",
              "continuationEndpoint",
              "continuationCommand",
              "token"
            ]);
            result['additionalParams'] =
                "&ctoken=$continuationKey&continuation=$continuationKey";
          } else {
            result['results'] = parsePlaylistItems(contentlist);
            result['additionalParams'] = "&ctoken=null&continuation=null";
          }
        }
        return result;
      }
    } else if (category == 'Albums' || category == 'Singles') {
      List contentlist;

      /// in continuation
      if (additionalParams != "") {
        contentlist =
            response['continuationContents']['gridContinuation']['items'];
        final continuationKey = nav(response, [
          'continuationContents',
          'gridContinuation',
          'continuations',
          0,
          'nextContinuationData',
          'continuation'
        ]);
        result['additionalParams'] =
            "&ctoken=$continuationKey&continuation=$continuationKey";
      } else {
        /// in first request
        contentlist = contents['gridRenderer']['items'];

        final continuationKey = nav(contents, [
          'gridRenderer',
          'continuations',
          0,
          'nextContinuationData',
          'continuation'
        ]);
        result['additionalParams'] =
            "&ctoken=$continuationKey&continuation=$continuationKey";
      }

      result['results'] = category == 'Albums'
          ? contentlist
              .map((item) => parseAlbum(item['musicTwoRowItemRenderer']))
              .whereType<Album>()
              .toList()
          : contentlist
              .map((item) => parseSingle(item['musicTwoRowItemRenderer']))
              .whereType<Album>()
              .toList();
    }
    return result;
  }

  Future<String?> getSongYear(String songId) async {
    final data = Map.from(_context);
    data['browseId'] = "MPTC$songId";
    try {
      final response = (await _sendRequest('browse', data)).data;
      String? year = nav(response, [
        "onResponseReceivedActions",
        0,
        "openPopupAction",
        "popup",
        "dismissableDialogRenderer",
        "metadata",
        "musicMultiRowListItemRenderer",
        "secondTitle",
        "runs",
        2,
        "text"
      ]);
      return year;
    } catch (e) {
      rethrow;
    }
  }

  @override
  void onClose() {
    dio.close();
    super.onClose();
  }
}

class NetworkError extends Error {
  final message = "Network Error !";
}
