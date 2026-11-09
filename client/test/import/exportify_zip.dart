import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Exportify's track CSV header row as upstream writes it today (no add-on
/// columns), every cell quoted.
const exportifyTrackHeader =
    '"Track URI","Track Name","Artist URI(s)","Artist Name(s)","Album URI",'
    '"Album Name","Album Artist URI(s)","Album Artist Name(s)",'
    '"Album Release Date","Album Image URL","Disc Number","Track Number",'
    '"Track Duration (ms)","Track Preview URL","Explicit","Popularity","ISRC",'
    '"Added By","Added At"';

/// The saved-albums file Export All has written since upstream #240
/// (October 2026): one row per album, no track columns.
const exportifySavedAlbumsHeader =
    '"Album URI","Album Name","Album Artist URI(s)","Album Artist Name(s)",'
    '"Album Type","Album Release Date","Total Tracks","Label","UPC",'
    '"Popularity","Album Image URL","Added At"';

String exportifyTrackRow(String id, String name, String artist) =>
    '"spotify:track:$id","$name","spotify:artist:0000000000000000000001",'
    '"$artist","spotify:album:0000000000000000000002","An Album",'
    '"spotify:artist:0000000000000000000001","$artist","2020-01-01",'
    '"https://i.scdn.co/image/x","1","1","200000","","false","50",'
    '"USRC17607839","","2024-05-01T10:00:00Z"';

const savedAlbumsCsv =
    '$exportifySavedAlbumsHeader\n'
    '"spotify:album:1ATL5GLyefJaxhQzSPVrLX","Arrival",'
    '"spotify:artist:0LcJLqbBmaGUft1e9Mm8HV","ABBA","album","1976-10-11",'
    '"10","Polar Music","731454993620","70","https://i.scdn.co/image/a",'
    '"2025-01-02T03:04:05Z"\n'
    '"spotify:album:6PWXKiakqhI17mTYM4y6oY","Duets, Live",'
    '"spotify:artist:1, spotify:artist:2","Simon\\, Garfunkel, Friends",'
    '"compilation","2001","2","Label, Inc.","","12",'
    '"https://i.scdn.co/image/b","2025-02-03T04:05:06Z"\n';

const _a = '4uLU6hMCjMI75M1A2tKUQC', _b = '7ouMYWpwJ422jRcDASZB7P';

/// A ZIP shaped like Exportify's current Export All: lowercased names,
/// punctuation and emoji kept, `liked.csv`, and `saved_albums.csv`.
Uint8List exportifyExportAllZip() {
  final built = Archive()
    ..add(
      ArchiveFile.string(
        '#23.csv',
        '$exportifyTrackHeader\n${exportifyTrackRow(_a, 'One', 'Ana')}\n',
      ),
    )
    ..add(
      ArchiveFile.string(
        "abba's_vibe.csv",
        '$exportifyTrackHeader\n'
            '${exportifyTrackRow(_a, 'One', 'Ana')}\n'
            '${exportifyTrackRow(_b, 'Two', 'Bo')}\n',
      ),
    )
    ..add(
      ArchiveFile.string(
        'audio_hugs_🫂📝🥺💌.csv',
        '$exportifyTrackHeader\n${exportifyTrackRow(_b, 'Two', 'Bo')}\n',
      ),
    )
    ..add(
      ArchiveFile.string(
        'liked.csv',
        '$exportifyTrackHeader\n${exportifyTrackRow(_b, 'Two', 'Bo')}\n',
      ),
    )
    ..add(ArchiveFile.string('saved_albums.csv', savedAlbumsCsv))
    ..add(
      ArchiveFile.string(
        'zz_last.csv',
        '$exportifyTrackHeader\n${exportifyTrackRow(_a, 'One', 'Ana')}\n',
      ),
    );
  return ZipEncoder().encodeBytes(built);
}
