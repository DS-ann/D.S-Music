import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:harmonymusic/utils/helper.dart';
import 'package:hive/hive.dart';

class SyncedLyricsService {
  static Future<Map<String, dynamic>?> getSyncedLyrics(
      MediaItem song, int durInSec) async {
    final lyricsBox = await Hive.openBox("lyrics");

    try {
      // Check cache first
      if (lyricsBox.containsKey(song.id)) {
        return Map<String, dynamic>.from(lyricsBox.get(song.id));
      }

      final duration = song.duration?.inSeconds ?? durInSec;

      final artist = Uri.encodeQueryComponent(song.artist ?? "");
      final title = Uri.encodeQueryComponent(song.title);
      final album = Uri.encodeQueryComponent(song.album ?? "");

      final url =
          "https://lrclib.net/api/get"
          "?artist_name=$artist"
          "&track_name=$title"
          "&album_name=$album"
          "&duration=$duration";

      printINFO("========== LRCLIB ==========");
      printINFO("Artist   : ${song.artist}");
      printINFO("Title    : ${song.title}");
      printINFO("Album    : ${song.album}");
      printINFO("Duration : $duration");
      printINFO("URL      : $url");

      final response = await Dio().get(url);

      printINFO("Status Code : ${response.statusCode}");
      printINFO("Response    : ${response.data}");

      if (response.statusCode == 200 &&
          response.data is Map<String, dynamic>) {
        final data = response.data as Map<String, dynamic>;

        if (data["syncedLyrics"] != null &&
            data["syncedLyrics"].toString().isNotEmpty) {
          final lyricsData = {
            "synced": data["syncedLyrics"],
            "plainLyrics": data["plainLyrics"],
          };

          await lyricsBox.put(song.id, lyricsData);

          printINFO("Synced lyrics downloaded successfully.");

          return lyricsData;
        }

        printINFO("No synced lyrics found in response.");
      }
    } on DioException catch (e) {
      printERROR("========== LRCLIB ERROR ==========");
      printERROR("Status : ${e.response?.statusCode}");
      printERROR("Data   : ${e.response?.data}");
      printERROR("Error  : ${e.message}");
    } catch (e) {
      printERROR(e.toString());
    } finally {
      await lyricsBox.close();
    }

    return null;
  }
}
