#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/.env"

: "${LIDARR_URL:?}"
: "${LIDARR_API_KEY:?}"
INCOMING="${INCOMING:-/tdas/media/media-stack/downloads/music/Singles}"
DRY_RUN=false
DEBUG_LEVEL=0
PRESERVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --debug) DEBUG_LEVEL=1; shift ;;
    --debug=*) DEBUG_LEVEL="${1#--debug=}"; shift ;;
    -v) DEBUG_LEVEL=1; shift ;;
    -vv) DEBUG_LEVEL=2; shift ;;
    -vvv) DEBUG_LEVEL=3; shift ;;
    --preserve) PRESERVE=true; shift ;;
    *) shift ;;
  esac
done

debug_if_level() {
  local level=$1
  shift
  if [[ $DEBUG_LEVEL -ge $level ]]; then
    echo "$@" >&2
  fi
}

# Convenience wrappers
debug() { debug_if_level 1 "$@"; }
debug2() { debug_if_level 2 "$@"; }
debug3() { debug_if_level 3 "$@"; }

api() {
  local method="GET"
  local arg
  local url=""

  for arg in "$@"; do
    if [[ "$arg" =~ ^https?:// ]]; then
      url="$arg"
    fi
  done

  if [[ " ${*} " =~ [[:space:]]-X[[:space:]]+([^[:space:]]+) ]]; then
    method="${BASH_REMATCH[1]}"
  fi

  debug "API $method $url"
  curl -fsS \
    --retry 3 \
    --retry-delay 1 \
    --retry-all-errors \
    -H "X-Api-Key: $LIDARR_API_KEY" \
    "$@"
}

canonicalize_path() {
  readlink -f -- "$1" 2>/dev/null || printf '%s\n' "$1"
}

trackfile_path_for_track_entry() {
  local track_entry_json="$1"
  local track_file_id track_file_json

  track_file_id=$(jq -r '.trackFileId // empty' <<<"$track_entry_json")
  [[ -z "$track_file_id" || "$track_file_id" == "null" ]] && return 1

  track_file_json=$(api "$LIDARR_URL/api/v1/trackfile/$track_file_id" || true)
  [[ -z "$track_file_json" ]] && return 1

  jq -r '.path // empty' <<<"$track_file_json"
}

trigger_rename_for_artist() {
  local artist_id="$1"
  local artist_name="$2"
  local file_path="$3"

  if $DRY_RUN; then
    echo "[DRY RUN] POST /command RenameFiles artistId=$artist_id source_file='$file_path'"
    return 0
  fi

  if api -X POST \
    "$LIDARR_URL/api/v1/command" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --argjson artist_id "$artist_id" '{name:"RenameFiles", artistId:$artist_id}')" >/dev/null; then
    echo "Triggered Lidarr rename for artist='$artist_name' source_file='$file_path'"
    return 0
  fi

  echo "SKIP: failed to trigger Lidarr rename artist='$artist_name' source_file='$file_path'" >&2
  return 1
}

track_entry_has_library_file() {
  local track_entry_json="$1"

  jq -e '(.hasFile // false) == true and ((.trackFileId // 0) > 0)' <<<"$track_entry_json" >/dev/null 2>&1
}

trigger_rescan_for_file_dir() {
  local file_path="$1"
  local folder_path
  folder_path=$(dirname -- "$file_path")

  if $DRY_RUN; then
    echo "[DRY RUN] POST /command RescanFolders folder='$folder_path'"
    return 0
  fi

  if api -X POST \
    "$LIDARR_URL/api/v1/command" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg folder "$folder_path" '{name:"RescanFolders", folders:[$folder]}')" >/dev/null; then
    echo "Triggered Lidarr rescan for folder='$folder_path'"
    return 0
  fi

  echo "SKIP: failed to trigger Lidarr rescan folder='$folder_path'" >&2
  return 1
}

retag_source_file_for_rescan() {
  local file_path="$1"
  local target_artist="$2"
  local target_album="$3"
  local target_track="$4"
  local source_album_artist="$5"
  local current_album="$6"
  local current_track_artist="${7:-}"
  local current_track_title="${8:-}"

  local normalized_current_album normalized_target_album
  local normalized_source_album_artist normalized_target_artist normalized_current_track_artist
  local normalized_current_track_title normalized_target_track
  local should_retag=false tmp_file extension ffmpeg_args=()

  [[ -z "$target_artist" || -z "$target_album" || -z "$target_track" ]] && return 0

  normalized_current_album=$(normalize "$current_album")
  normalized_target_album=$(normalize "$target_album")
  normalized_source_album_artist=$(normalize "$source_album_artist")
  normalized_target_artist=$(normalize "$target_artist")
  normalized_current_track_artist=$(normalize "$current_track_artist")
  normalized_current_track_title=$(normalize "$current_track_title")
  normalized_target_track=$(normalize "$target_track")

  if is_various_artist "$source_album_artist"; then
    should_retag=true
  fi

  if [[ -z "$normalized_current_album" || "$normalized_current_album" != "$normalized_target_album" ]]; then
    should_retag=true
  fi

  if [[ -z "$normalized_source_album_artist" || "$normalized_source_album_artist" != "$normalized_target_artist" ]]; then
    should_retag=true
  fi

  if [[ -n "$normalized_current_track_artist" && "$normalized_current_track_artist" != "$normalized_target_artist" ]]; then
    should_retag=true
  fi

  if [[ -n "$normalized_current_track_title" && "$normalized_current_track_title" != "$normalized_target_track" ]]; then
    should_retag=true
  fi

  if ! $should_retag; then
    return 0
  fi

  if $DRY_RUN; then
    echo "[DRY RUN] RETAG source file='$file_path' artist='$target_artist' album='$target_album' title='$target_track'"
    return 0
  fi

  extension=${file_path##*.}
  tmp_file=$(mktemp "$(dirname -- "$file_path")/.retag.$$.XXXXXX.${extension}")

  if [[ "${extension,,}" == "mp3" ]]; then
    ffmpeg_args=(-id3v2_version 3 -write_id3v1 1)
  fi

  if ffmpeg -v error -y -i "$file_path" -map 0 -c copy \
    "${ffmpeg_args[@]}" \
    -metadata artist="$target_artist" \
    -metadata album_artist="$target_artist" \
    -metadata albumartist="$target_artist" \
    -metadata album="$target_album" \
    -metadata title="$target_track" \
    "$tmp_file" >/dev/null 2>&1; then
    mv -f -- "$tmp_file" "$file_path"
    echo "Retagged source file='$file_path' artist='$target_artist' album='$target_album'"
    return 0
  fi

  rm -f -- "$tmp_file"
  echo "SKIP: failed to retag source file='$file_path' artist='$target_artist' album='$target_album'" >&2
  return 1
}

library_track_points_at_source_file() {
  local track_entry_json="$1"
  local source_file="$2"

  local source_path library_path
  source_path=$(canonicalize_path "$source_file")
  library_path=$(trackfile_path_for_track_entry "$track_entry_json" || true)

  if [[ -n "$library_path" ]]; then
    library_path=$(canonicalize_path "$library_path")
    debug2 "Matched library file path='$library_path' source_path='$source_path'"

    if [[ "$library_path" == "$source_path" ]]; then
      return 0
    fi
  fi

  return 1
}

is_various_artist() {
  local value
  value=$(normalize "$1" | tr '[:upper:]' '[:lower:]')
  value=${value//./}
  value=${value//,/}

  [[ "$value" == "various" \
    || "$value" == "various artists" \
    || "$value" == "various artist" \
    || "$value" == "va" \
    || "$value" == "v/a" \
    || "$value" == "v a" ]]
}

artist_from_filename() {
  local file_name stem parsed_artist

  file_name=$(basename -- "$1")
  stem=${file_name%.*}
  stem=$(printf '%s' "$stem" | sed -E 's/^[0-9]+[[:space:]]*[-._][[:space:]]*//; s/^[0-9]+[[:space:]]+//')

  if [[ "$stem" =~ ^(.+)[[:space:]]-[[:space:]](.+)$ ]]; then
    parsed_artist=$(normalize "${BASH_REMATCH[1]}")
    printf '%s\n' "$parsed_artist"
    return 0
  fi

  return 1
}

lookup_album_candidate_musicbrainz() {
  local artist_name="$1"
  local album_name="$2"
  local artist_fid="$3"
  local track_name="$4"

  [[ -z "$album_name" || -z "$artist_name" || -z "$artist_fid" ]] && return 1

  curl -fsS \
    --retry 3 \
    --retry-delay 1 \
    --retry-all-errors \
    -H "User-Agent: import-single-tracks/1.0 (github-copilot)" \
    "https://musicbrainz.org/ws/2/release-group?query=$(jq -rn --arg album "$album_name" --arg artist "$artist_name" '"releasegroup:\"" + $album + "\" AND artist:\"" + $artist + "\"" | @uri')&fmt=json&limit=10" \
    | jq -c --arg artist_fid "$artist_fid" --arg album_name "$album_name" --arg track_name "$track_name" '
        def is_live_requested:
          (($album_name + " " + $track_name) | ascii_downcase | contains("live"));

        def not_live_unless_requested:
          if is_live_requested then true
          else (((.title // "") | ascii_downcase | contains("live")) | not)
          end;

        [ .["release-groups"][]
          | select(any(.["artist-credit"][]?; (.artist.id // empty) == $artist_fid))
          | {
              title: .title,
              foreignAlbumId: .id,
              primaryType: (.["primary-type"] // "")
            }
        ] as $matches
        | (
            ($matches | map(select(((.title // "") | ascii_downcase) == ($album_name | ascii_downcase) and not_live_unless_requested and .primaryType == "Album")) | .[0])
            // ($matches | map(select(((.title // "") | ascii_downcase) == ($album_name | ascii_downcase) and not_live_unless_requested)) | .[0])
            // ($matches | map(select(not_live_unless_requested and .primaryType == "Album")) | .[0])
            // ($matches | map(select(not_live_unless_requested)) | .[0])
            // ($matches | .[0])
          ) // empty
        | del(.primaryType)
      ' \
    || true
}

lookup_album_candidate_musicbrainz_recording() {
  local artist_name="$1"
  local track_name="$2"
  local artist_fid="$3"

  [[ -z "$track_name" || -z "$artist_name" || -z "$artist_fid" ]] && return 1

  curl -fsS \
    --retry 3 \
    --retry-delay 1 \
    --retry-all-errors \
    -H "User-Agent: import-single-tracks/1.0 (github-copilot)" \
    "https://musicbrainz.org/ws/2/recording?query=$(jq -rn --arg track "$track_name" --arg artist "$artist_name" '"recording:\"" + $track + "\" AND artist:\"" + $artist + "\"" | @uri')&fmt=json&limit=25&inc=releases+release-groups" \
    | jq -c --arg artist_fid "$artist_fid" '
        [ .recordings[]
          | select(any(.["artist-credit"][]?; (.artist.id // empty) == $artist_fid))
          | .releases[]?
          | .["release-group"]?
          | {
              title: .title,
              foreignAlbumId: .id,
              primaryType: (.["primary-type"] // ""),
              secondaryTypes: (.["secondary-types"] // [])
            }
        ]
        | unique_by(.foreignAlbumId) as $matches
        | (
            ($matches | map(select(.primaryType == "Album" and (.secondaryTypes | index("Compilation") | not) and (.secondaryTypes | index("Live") | not))) | .[0])
            // ($matches | map(select((.secondaryTypes | index("Compilation") | not) and (.secondaryTypes | index("Live") | not))) | .[0])
            // ($matches | map(select(.primaryType == "Single")) | .[0])
            // ($matches | .[0])
          ) // empty
        | del(.primaryType, .secondaryTypes)
      ' \
    || true
}

lookup_album_candidate() {
  local artist_name="$1"
  local track_name="$2"
  local album_name="$3"
  local artist_fid="$4"
  local source_album_artist="${5:-}"
  local lookup_results=""
  local lookup_entry=""
  local album_lookup_results=""
  local album_title_only_results=""

  choose_lookup_entry() {
    jq --arg fid "$artist_fid" --arg album_name "$album_name" --arg track_name "$track_name" '
      # Determine if we should exclude Live albums
      def is_live_requested: ($album_name | ascii_downcase) | contains("live");
      def not_live_unless_requested: 
        if is_live_requested then true else (((.title // "") | ascii_downcase | contains("live")) | not) end;
      def normalize_track_title($value):
        ($value // "")
        | ascii_downcase
        | gsub("[’‘`´′]"; "\u0027")
        | gsub("\\[[^][]*\\]"; "")
        | gsub("\\([^()]*\\)"; "")
        | gsub(" - (album|single|radio|explicit|clean|mono|stereo|edit|version|mix|remaster(ed)?|acoustic|bonus)([^-]*)$"; "")
        | gsub("[[:space:]]+"; " ")
        | sub("^ "; "")
        | sub(" $"; "");
      def exact_track_title_album_match:
        (normalize_track_title($track_name) != "")
        and (normalize_track_title(.title) == normalize_track_title($track_name));
      
      [ (if type == "array" then . else [] end)[]
        | objects
        | select((.artist.foreignArtistId // empty) == $fid)
      ] as $matches
      | (
          ($matches | map(select(exact_track_title_album_match and not_live_unless_requested)) | .[0])
          //
          ($matches | map(select((.albumType // empty) == "Album" and not_live_unless_requested)) | .[0])
          // ($matches | map(select((.albumType // empty) != "Single" and not_live_unless_requested)) | .[0])
          // ($matches | map(select(not_live_unless_requested)) | .[0])
          // ($matches | .[0])
        ) // empty
    '
  }

  choose_exact_album_entry() {
    jq --arg fid "$artist_fid" --arg album_name "$album_name" '
      def is_live_requested: ($album_name | ascii_downcase) | contains("live");
      def not_live_unless_requested: 
        if is_live_requested then true else (((.title // "") | ascii_downcase | contains("live")) | not) end;
      
      [ (if type == "array" then . else [] end)[]
        | objects
        | select((.artist.foreignArtistId // empty) == $fid)
      ] as $matches
      | (
          $matches
          | map(select((((.title // "") | ascii_downcase) == ($album_name | ascii_downcase)) and not_live_unless_requested))
          | .[0]
        ) // empty
    '
  }

  if is_various_artist "$source_album_artist" && [[ -n "$track_name" ]]; then
    lookup_entry=$(lookup_album_candidate_musicbrainz_recording "$artist_name" "$track_name" "$artist_fid" || true)

    if [[ -n "$lookup_entry" && "$lookup_entry" != "null" ]]; then
      debug2 "Compilation-style source detected; using recording-based studio album fallback before track lookup"
      printf '%s\n' "$lookup_entry"
      return 0
    fi
  fi

  if [[ -n "$album_name" ]]; then
    album_lookup_results=$(api \
      "$LIDARR_URL/api/v1/album/lookup?term=$(jq -rn --arg q "$artist_name $album_name" '$q|@uri')" \
      || true)

    if [[ -n "$album_lookup_results" ]]; then
      lookup_entry=$(choose_exact_album_entry <<<"$album_lookup_results")

      if [[ -n "$lookup_entry" && "$lookup_entry" != "null" ]]; then
        printf '%s\n' "$lookup_entry"
        return 0
      fi

    fi
  fi

  if [[ -n "$track_name" ]]; then
    lookup_results=$(api \
      "$LIDARR_URL/api/v1/album/lookup?term=$(jq -rn --arg q "$artist_name $track_name" '$q|@uri')" \
      || true)

    if [[ -n "$lookup_results" ]]; then
      lookup_entry=$(choose_lookup_entry <<<"$lookup_results")

      if [[ -n "$lookup_entry" && "$lookup_entry" != "null" ]]; then
        lookup_album_type=$(jq -r '.albumType // empty' <<<"$lookup_entry")

        if [[ "$lookup_album_type" == "Single" ]]; then
          lookup_entry=$(lookup_album_candidate_musicbrainz_recording "$artist_name" "$track_name" "$artist_fid" || true)
        fi

        printf '%s\n' "$lookup_entry"
        return 0
      fi
    fi
  fi

  if [[ -n "$album_name" ]]; then
    album_title_only_results=$(api \
      "$LIDARR_URL/api/v1/album/lookup?term=$(jq -rn --arg q "$album_name" '$q|@uri')" \
      || true)

    if [[ -n "$album_title_only_results" ]]; then
      lookup_entry=$(choose_exact_album_entry <<<"$album_title_only_results")

      if [[ -n "$lookup_entry" && "$lookup_entry" != "null" ]]; then
        printf '%s\n' "$lookup_entry"
        return 0
      fi

      lookup_entry=$(choose_lookup_entry <<<"$album_title_only_results")

      if [[ -n "$lookup_entry" && "$lookup_entry" != "null" ]]; then
        printf '%s\n' "$lookup_entry"
        return 0
      fi
    fi

    if [[ -n "$album_lookup_results" ]]; then
      lookup_entry=$(choose_lookup_entry <<<"$album_lookup_results")

      if [[ -n "$lookup_entry" && "$lookup_entry" != "null" ]]; then
        printf '%s\n' "$lookup_entry"
        return 0
      fi
    fi
  fi

  return 1
}

choose_library_track_entry() {
  local matching_tracks_json="$1"
  local artist_albums_json="$2"
  local album_name="$3"
  local track_name="$4"

  jq -n \
    --argjson tracks "$matching_tracks_json" \
    --argjson albums "$artist_albums_json" \
    --arg album_name "$album_name" \
    --arg track_name "$track_name" '
      def is_live_requested:
        (($album_name + " " + $track_name) | ascii_downcase | contains("live"));

      def normalize_track_title($value):
        ($value // "")
        | ascii_downcase
        | gsub("[’‘`´′]"; "\u0027")
        | gsub("\\[[^][]*\\]"; "")
        | gsub("\\([^()]*\\)"; "")
        | gsub(" - (album|single|radio|explicit|clean|mono|stereo|edit|version|mix|remaster(ed)?|acoustic|bonus)([^-]*)$"; "")
        | gsub("[[:space:]]+"; " ")
        | sub("^ "; "")
        | sub(" $"; "");

      def album_for($track):
        ($albums | map(select((.id // 0) == ($track.albumId // -1))) | .[0]);

      def normalized_title($album_entry):
        (($album_entry.title // "") | ascii_downcase);

      def live_candidate($track; $album_entry):
        ((normalized_title($album_entry) | contains("live"))
          or (((($track.title // "") | ascii_downcase) | contains("live"))));

      def exact_album_match($album_entry):
        normalized_title($album_entry) == ($album_name | ascii_downcase);

      def non_live_album($album_entry):
        (normalized_title($album_entry) | contains("live") | not);

      $tracks
      | map(select(normalize_track_title(.title) == normalize_track_title($track_name)))
      | map(. + {matchedAlbum: album_for(.)})
      | map(. + {
          exactAlbumMatch: exact_album_match(.matchedAlbum),
          nonLiveAlbum: non_live_album(.matchedAlbum),
          liveCandidate: live_candidate(.; .matchedAlbum),
          preferredAlbumType: (((.matchedAlbum.albumType // "") == "Album") or ((.matchedAlbum.albumType // "") == "Studio"))
        })
      | if is_live_requested then map(select(.liveCandidate)) else . end
      | sort_by(
          if .exactAlbumMatch then 0 else 1 end,
          if is_live_requested then 0 else (if .nonLiveAlbum then 0 else 1 end) end,
          if .preferredAlbumType then 0 else 1 end,
          (.matchedAlbum.releaseDate // "9999-12-31")
        )
      | map(del(.matchedAlbum, .exactAlbumMatch, .nonLiveAlbum, .liveCandidate, .preferredAlbumType))
      | .[0] // empty
    '
}

normalize() {
  echo "$1" \
    | iconv -f utf-8 -t utf-8//IGNORE \
    | sed \
      -e "s/[‐-‒–—―]/-/g" \
      -e "s/[’]/'/g" \
      -e 's/[[:space:]]\+/ /g' \
      -e 's/^ *//; s/ *$//'
}

debug "DRY_RUN=$DRY_RUN"

find "$INCOMING" -type f \( -iname "*.flac" -o -iname "*.mp3" \) | while read -r file; do

  debug "----"
  debug "File: $file"

meta=$(ffprobe -v error -print_format json -show_format -show_streams "$file" 2>/dev/null || true)

if [[ -z "$meta" ]]; then
  echo "SKIP: failed to read media metadata file='$file'" >&2
  continue
fi

tags=$(jq -r '.format.tags // {}' <<<"$meta" 2>/dev/null || true)

if [[ -z "$tags" ]]; then
  echo "SKIP: invalid metadata tags file='$file'" >&2
  continue
fi

album_artist=$(jq -r '
  .album_artist // .ALBUMARTIST // .ALBUM_ARTIST // .["Album Artist"] // .["ALBUM ARTIST"] // empty
' <<<"$tags")

track_artist=$(jq -r '
  .ARTIST // .Artist // .artist // .["Artist"] // .["ARTIST"] // empty
' <<<"$tags")

source_album_artist="$album_artist"

album=$(jq -r '
  .ALBUM // .Album // .album // .["Album"] // .["ALBUM"] // empty
' <<<"$tags")

track=$(jq -r '
  .TITLE // .Title // .title // .["Title"] // .["TITLE"] // empty
' <<<"$tags")

# cleanup common bad artist cases
album_artist=$(echo "$album_artist" | sed -E \
  's/\s*\(.*Edition.*\)//I; s/\s*\[.*\]//; s/^\s+|\s+$//g')

track_artist=$(echo "$track_artist" | sed -E \
  's/\s*\(.*Edition.*\)//I; s/\s*\[.*\]//; s/^\s+|\s+$//g')

artist="$album_artist"

if [[ -z "$artist" ]] || is_various_artist "$artist"; then
  if [[ -n "$track_artist" ]] && ! is_various_artist "$track_artist"; then
    artist="$track_artist"
    debug2 "Using track artist '$artist' because album artist '$album_artist' is compilation-style"
  else
    filename_artist=$(artist_from_filename "$file" || true)
    if [[ -n "$filename_artist" ]] && ! is_various_artist "$filename_artist"; then
      artist="$filename_artist"
      debug2 "Using filename artist '$artist' because metadata artist is compilation-style"
    fi
  fi
fi

if [[ -z "$artist" ]]; then
  artist="$track_artist"
fi

album=$(echo "$album" | sed -E 's/^\s+|\s+$//g')
track_album="$album"

debug "Parsed: artist='$artist' album='$album' track='$track'"

# hard validation
if [[ -z "$artist" ]]; then
  debug2 "Raw tags:"
  debug3 "$(jq -r '.format.tags' <<<"$meta")"
  echo "SKIP: missing artist file='$file'"
  continue
fi


# must have artist at minimum
[[ -z "$artist" ]] && {
  echo "SKIP: missing artist file='$file'"
  continue
}

# if album missing → Lidarr lookup fallback
if [[ -z "$album" ]]; then
  query="${artist} ${track}"

  album_lookup=$(api \
    "$LIDARR_URL/api/v1/album/lookup?term=$(jq -rn --arg q "$query" '$q|@uri')" \
    || true)

  if [[ -z "$album_lookup" ]]; then
    echo "SKIP: album lookup failed artist='$artist' track='$track' file='$file'" >&2
    continue
  fi

  album_entry=$(jq '
    # Determine if we should exclude Live albums from fallback
    def not_live: (((.title // "") | ascii_downcase | contains("live")) | not);
    [ (if type == "array" then . else [] end)[] | objects | select(not_live) ] as $non_live
    | if ($non_live | length) > 0 then ($non_live | .[0]) else (.[0] // empty) end
  ' <<<"$album_lookup")

  foreign_album_id=$(jq -r '.foreignAlbumId // empty' <<<"$album_entry")
  album=$(jq -r '.title // empty' <<<"$album_entry")

  if [[ -z "$foreign_album_id" ]]; then
    echo "SKIP: cannot resolve album via Lidarr artist='$artist' track='$track' file='$file'"
    continue
  fi
fi

  debug "Detected: $artist - $album"

artist_norm=$(echo "$artist" | sed 's/[[:space:]]\+/ /g; s/^ *//; s/ *$//')

artist_lookup=$(api \
  "$LIDARR_URL/api/v1/artist/lookup?term=$(jq -rn --arg a "$artist_norm" '$a|@uri')" \
  || true)

if [[ -z "$artist_lookup" ]]; then
  echo "SKIP: artist lookup failed artist='$artist_norm' file='$file'" >&2
  continue
fi

artist_entry=$(jq '.[0] // empty' <<<"$artist_lookup")

debug2 "Artist input: $artist"
debug2 "Normalized artist: $artist_norm"
debug3 "Artist lookup top match: $(jq -c '.[0] // {}' <<<"$artist_lookup")"

foreign_artist_id=$(jq -r '.foreignArtistId // empty' <<<"$artist_entry")
resolved_name=$(jq -r '.artistName // empty' <<<"$artist_entry")

# already in library?
artist_list=$(api "$LIDARR_URL/api/v1/artist" || true)

if [[ -z "$artist_list" ]]; then
  echo "SKIP: failed to fetch artist library list artist='$artist' file='$file'" >&2
  continue
fi

artist_id=$(jq -r --arg fid "$foreign_artist_id" '
    map(select((.foreignArtistId // empty) == $fid))[0].id // empty
  ' <<<"$artist_list")

# not in library → create it
if [[ -z "$artist_id" ]]; then
  if [[ -z "$foreign_artist_id" ]]; then
    echo "SKIP: no metadata provider match artist='$artist' album='$album' file='$file'"
    continue
  fi

  if $DRY_RUN; then
    echo "WOULD CREATE ARTIST:"
    echo "  name=$resolved_name"
    echo "  foreignArtistId=$foreign_artist_id"
    echo "  source_track_artist=$artist"
    echo "  source_track_album=$album"
    echo "[DRY RUN] POST /artist artist='$resolved_name' source='$artist - $album' {foreignArtistId=$foreign_artist_id}"

    album_lookup=$(lookup_album_candidate "$artist" "$track" "$album" "$foreign_artist_id" || true)

    lookup_album_title=$(jq -r '.title // empty' <<<"$album_lookup")
    foreign_album_id=$(jq -r '.foreignAlbumId // empty' <<<"$album_lookup")

    if [[ -n "$foreign_album_id" ]]; then
      echo "WOULD CREATE ALBUM:"
      echo "  title=$lookup_album_title"
      echo "  foreignAlbumId=$foreign_album_id"
      echo "  artist=$resolved_name"
      echo "  track=$track"
      echo "[DRY RUN] POST /album foreignAlbumId=$foreign_album_id artist=\"$resolved_name\" track=\"$track\" album=\"$lookup_album_title\""
    else
      echo "SKIP: album not found in provider artist=\"$artist\" track=\"$track\" track_album=\"$track_album\" file=\"$file\""
    fi
    continue
  fi

  artist_create_response=$(api -X POST \
    "$LIDARR_URL/api/v1/artist" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc \
      --arg artist_name "$resolved_name" \
      --arg fid "$foreign_artist_id" \
      '{
        artistName:$artist_name,
        foreignArtistId:$fid,
        monitored:true,
        monitorNewItems:"none",
        qualityProfileId:6,
        metadataProfileId:2,
        rootFolderPath:"/downloads/music"
      }')" \
    || true)

  if [[ -z "$artist_create_response" ]]; then
    echo "SKIP: failed to create artist artist='$resolved_name' source='$artist - $album' file='$file'" >&2
    continue
  fi

  artist_id=$(jq -r '.id // empty' <<<"$artist_create_response")

  if [[ -z "$artist_id" ]]; then
    echo "SKIP: artist create returned no id artist='$resolved_name' source='$artist - $album' file='$file'" >&2
    continue
  fi

  echo "Created artist id=$artist_id artist='$resolved_name' source='$artist - $album'"
fi

# First, try to find the track in the library by artist + track name
debug "Searching library for track: artist_id=$artist_id track='$track'"

all_artist_tracks=$(api "$LIDARR_URL/api/v1/track?artistId=$artist_id" || true)

if [[ -z "$all_artist_tracks" ]]; then
  echo "SKIP: failed to fetch tracks for artist_id='$artist_id' artist='$artist' file='$file'" >&2
  continue
fi

matching_track_entries=$(jq --arg tname "$track" '
  def normalize_track_title($value):
    ($value // "")
    | ascii_downcase
    | gsub("[’‘`´′]"; "\u0027")
    | gsub("\\[[^][]*\\]"; "")
    | gsub("\\([^()]*\\)"; "")
    | gsub(" - (album|single|radio|explicit|clean|mono|stereo|edit|version|mix|remaster(ed)?|acoustic|bonus)([^-]*)$"; "")
    | gsub("[[:space:]]+"; " ")
    | sub("^ "; "")
    | sub(" $"; "");
  [ (if type == "array" then . else [] end)[]
    | objects
    | select(normalize_track_title(.title) == normalize_track_title($tname))
  ]
' <<<"$all_artist_tracks")

if [[ "$(jq 'length' <<<"$matching_track_entries")" -gt 0 ]]; then
  # Fetch the album entries so the track match can be ranked against metadata album/live status.
  artist_albums=$(api "$LIDARR_URL/api/v1/album?artistId=$artist_id" || true)

  if [[ -z "$artist_albums" ]]; then
    echo "SKIP: failed to fetch albums for artist_id='$artist_id' artist='$artist' file='$file'" >&2
    continue
  fi

  track_entry=$(choose_library_track_entry "$matching_track_entries" "$artist_albums" "$track_album" "$track")

  if [[ -z "$track_entry" || "$track_entry" == "null" ]]; then
    echo "SKIP: failed to select track match artist='$artist' track='$track' file='$file'" >&2
    continue
  fi

  debug "Found track in library"
  debug2 "Selected library track albumId=$(jq -r '.albumId // empty' <<<"$track_entry") from $(jq 'length' <<<"$matching_track_entries") title match(es)"
  
  # Track exists in library—use its album
  library_album_id=$(jq -r '.albumId' <<<"$track_entry")
  
  album_entry=$(jq --arg aid "$library_album_id" '.[] | select((.id // empty) == ($aid | tonumber))' <<<"$artist_albums")
  
  lidarr_album=$(jq -r '.title // empty' <<<"$album_entry")
  monitored=$(jq -r '.monitored' <<<"$album_entry")
  album_fully_available=$(jq -r '
    ((.statistics.percentOfTracks // 0) == 100)
    or (
      (.statistics.trackFileCount // 0) > 0
      and (.statistics.trackFileCount // 0) == (.statistics.totalTrackCount // 0)
    )
  ' <<<"$album_entry")

  track_has_library_file=false
  if track_entry_has_library_file "$track_entry"; then
    track_has_library_file=true
  fi

  source_file_is_library_file=false
  if $track_has_library_file && library_track_points_at_source_file "$track_entry" "$file"; then
    source_file_is_library_file=true
  fi

  if ! $track_has_library_file; then
    echo "Track exists in library metadata but no track file is attached artist=\"$artist\" track=\"$track\" lidarr_album=\"$lidarr_album\""

    if [[ "$monitored" != "true" ]]; then
      echo "Track metadata found but album NOT monitored → enabling monitoring artist=\"$artist\" track=\"$track\" lidarr_album=\"$lidarr_album\""

      if ! $DRY_RUN; then
        album_id=$(jq -r '.id' <<<"$album_entry")
        updated=$(jq '.monitored=true' <<<"$album_entry")

        api -X PUT \
          "$LIDARR_URL/api/v1/album/$album_id" \
          -H "Content-Type: application/json" \
          -d "$updated" >/dev/null

        echo "Album monitoring enabled artist=\"$artist\" track=\"$track\" lidarr_album=\"$lidarr_album\""
      else
        echo "[DRY RUN] PUT /album monitored=true artist=\"$artist\" track=\"$track\" lidarr_album=\"$lidarr_album\""
      fi
    fi

    resolved_track_title=$(jq -r '.title // empty' <<<"$track_entry")
    [[ -z "$resolved_track_title" ]] && resolved_track_title="$track"
    retag_source_file_for_rescan "$file" "$artist" "$lidarr_album" "$resolved_track_title" "$source_album_artist" "$track_album" "$track_artist" "$track"
    trigger_rescan_for_file_dir "$file"
    continue
  fi
  
  if [[ "$monitored" == "true" ]]; then
    echo "OK: track found in library, album already monitored artist=\"$artist\" track=\"$track\" lidarr_album=\"$lidarr_album\""

    if $source_file_is_library_file; then
      trigger_rename_for_artist "$artist_id" "$artist" "$file"
    elif [[ "$album_fully_available" == "true" && "$PRESERVE" != "true" ]]; then
        if $DRY_RUN; then
          echo "[DRY RUN] REMOVE source file='$file'"
        else
          if rm -f -- "$file"; then
            echo "Removed source file='$file'"
          else
            echo "SKIP: failed to remove source file='$file'" >&2
          fi
        fi
    else
      if [[ "$PRESERVE" == "true" ]]; then
        debug "Preserving source file due to --preserve flag"
      elif $source_file_is_library_file; then
        debug "Source file is the current Lidarr library file; rename was triggered instead of deletion"
      else
        debug "Album is monitored but not fully available yet; keeping source file '$file'"
      fi
    fi

    continue
  fi

  echo "Track found in library but album NOT monitored → enabling monitoring artist=\"$artist\" track=\"$track\" lidarr_album=\"$lidarr_album\""

  if $DRY_RUN; then
    echo "[DRY RUN] PUT /album monitored=true artist=\"$artist\" track=\"$track\" lidarr_album=\"$lidarr_album\""
    continue
  fi

  album_id=$(jq -r '.id' <<<"$album_entry")
  updated=$(jq '.monitored=true' <<<"$album_entry")
  
  api -X PUT \
    "$LIDARR_URL/api/v1/album/$album_id" \
    -H "Content-Type: application/json" \
    -d "$updated" >/dev/null

  echo "Album monitoring enabled artist=\"$artist\" track=\"$track\" lidarr_album=\"$lidarr_album\""

  if $source_file_is_library_file; then
    trigger_rename_for_artist "$artist_id" "$artist" "$file"
  fi

  continue
fi

debug "Track not found in library, falling back to metadata album lookup"

# Before album lookup, try a library-wide search for the track title
# This handles cases where metadata artist is wrong (e.g., compilation name instead of real artist)
debug2 "Attempting library-wide track search for title='$track'"
all_library_tracks=$(api "$LIDARR_URL/api/v1/track?includeAllArtistTracks=true" 2>/dev/null || true)

if [[ -n "$all_library_tracks" ]]; then
  matching_track_entries=$(jq --arg tname "$track" '
    def normalize_track_title($value):
      ($value // "")
      | ascii_downcase
      | gsub("[’‘`´′]"; "\u0027")
      | gsub("\\[[^][]*\\]"; "")
      | gsub("\\([^()]*\\)"; "")
      | gsub(" - (album|single|radio|explicit|clean|mono|stereo|edit|version|mix|remaster(ed)?|acoustic|bonus)([^-]*)$"; "")
      | gsub("[[:space:]]+"; " ")
      | sub("^ "; "")
      | sub(" $"; "");
    [ (if type == "array" then . else [] end)[]
      | objects
      | select(normalize_track_title(.title) == normalize_track_title($tname))
    ]
  ' <<<"$all_library_tracks")
  
  if [[ "$(jq 'length' <<<"$matching_track_entries")" -gt 0 ]]; then
    found_artist_ids=$(jq -r '.[].artistId // empty' <<<"$matching_track_entries" | sort -u)

    while read -r found_artist_id; do
      [[ -z "$found_artist_id" ]] && continue

      # Fetch the album entry from each candidate artist until one ranks as the best match.
      artist_albums=$(api "$LIDARR_URL/api/v1/album?artistId=$found_artist_id" || true)

      if [[ -z "$artist_albums" ]]; then
        debug2 "Could not fetch albums for artist_id=$found_artist_id during library-wide search"
        continue
      fi

      track_entry=$(choose_library_track_entry "$matching_track_entries" "$artist_albums" "$track_album" "$track")
      [[ -z "$track_entry" || "$track_entry" == "null" ]] && continue

      debug "Found track in library-wide search (metadata artist was incorrect)"
      debug2 "Selected library-wide track albumId=$(jq -r '.albumId // empty' <<<"$track_entry") from $(jq 'length' <<<"$matching_track_entries") title match(es)"

      matched_artist_name=$(jq -r '.artist.artistName // empty' <<<"$track_entry")
      [[ -z "$matched_artist_name" ]] && matched_artist_name="$artist"

      library_album_id=$(jq -r '.albumId // empty' <<<"$track_entry")
      album_entry=$(jq --arg aid "$library_album_id" '.[] | select((.id // empty) == ($aid | tonumber))' <<<"$artist_albums")
      
      if [[ -n "$album_entry" && "$album_entry" != "null" ]]; then
        lidarr_album=$(jq -r '.title // empty' <<<"$album_entry")
        monitored=$(jq -r '.monitored' <<<"$album_entry")
        album_fully_available=$(jq -r '
          ((.statistics.percentOfTracks // 0) == 100)
          or (
            (.statistics.trackFileCount // 0) > 0
            and (.statistics.trackFileCount // 0) == (.statistics.totalTrackCount // 0)
          )
        ' <<<"$album_entry")

        track_has_library_file=false
        if track_entry_has_library_file "$track_entry"; then
          track_has_library_file=true
        fi

        source_file_is_library_file=false
        if $track_has_library_file && library_track_points_at_source_file "$track_entry" "$file"; then
          source_file_is_library_file=true
        fi

        if ! $track_has_library_file; then
          echo "Track exists in library metadata but no track file is attached artist=\"$matched_artist_name\" track=\"$track\" lidarr_album=\"$lidarr_album\""
          resolved_track_title=$(jq -r '.title // empty' <<<"$track_entry")
          [[ -z "$resolved_track_title" ]] && resolved_track_title="$track"
          retag_source_file_for_rescan "$file" "$matched_artist_name" "$lidarr_album" "$resolved_track_title" "$source_album_artist" "$track_album" "$track_artist" "$track"
          trigger_rescan_for_file_dir "$file"
          continue
        fi
        
        if [[ "$monitored" == "true" ]]; then
          echo "OK: track found in library (different artist), album already monitored artist=\"$artist\" track=\"$track\" lidarr_album=\"$lidarr_album\""

          if $source_file_is_library_file; then
            trigger_rename_for_artist "$found_artist_id" "$matched_artist_name" "$file"
          elif [[ "$album_fully_available" == "true" && "$PRESERVE" != "true" ]]; then
              if $DRY_RUN; then
                echo "[DRY RUN] REMOVE source file='$file'"
              else
                if rm -f -- "$file"; then
                  echo "Removed source file='$file'"
                else
                  echo "SKIP: failed to remove source file='$file'" >&2
                fi
              fi
          else
            if [[ "$PRESERVE" == "true" ]]; then
              debug "Preserving source file due to --preserve flag"
            elif $source_file_is_library_file; then
              debug "Source file is the current Lidarr library file; rename was triggered instead of deletion"
            else
              debug "Album is monitored but not fully available yet; keeping source file '$file'"
            fi
          fi

          continue
        fi
      fi
    done <<<"$found_artist_ids"
  fi
fi

  # Track not in library—proceed with album lookup based on metadata
album_lookup=$(lookup_album_candidate "$artist" "$track" "$album" "$foreign_artist_id" "$source_album_artist" || true)

if [[ -z "$(jq -r '.foreignAlbumId // empty' <<<"$album_lookup")" ]]; then
  debug2 "Lidarr album lookup failed to resolve '$album' for '$artist'; trying MusicBrainz fallback"
  album_lookup=$(lookup_album_candidate_musicbrainz "$artist" "$album" "$foreign_artist_id" "$track" || true)
fi

if [[ -z "$(jq -r '.foreignAlbumId // empty' <<<"$album_lookup")" ]] && is_various_artist "$source_album_artist"; then
  debug2 "Compilation-style album artist '$source_album_artist' detected; trying MusicBrainz recording fallback for studio album"
  album_lookup=$(lookup_album_candidate_musicbrainz_recording "$artist" "$track" "$foreign_artist_id" || true)
fi

lookup_album_title=$(jq -r '.title // empty' <<<"$album_lookup")
foreign_album_id=$(jq -r '.foreignAlbumId // empty' <<<"$album_lookup")

if [[ -z "$foreign_album_id" ]]; then
  echo "SKIP: album not found in provider artist=\"$artist\" track=\"$track\" track_album=\"$track_album\" file=\"$file\""
  continue
fi

# fetch albums for artist to see if this album is already in library
artist_albums=$(api \
  "$LIDARR_URL/api/v1/album?artistId=$artist_id" \
  || true)

if [[ -z "$artist_albums" ]]; then
  echo "SKIP: failed to fetch albums for artist_id='$artist_id' artist='$artist' file='$file'" >&2
  continue
fi

album_entry=$(jq --arg fid "$foreign_album_id" '
  .[] | select((.foreignAlbumId // empty) == $fid)
' <<<"$artist_albums")

if [[ -n "$album_entry" && -n "$(jq -r '.id // empty' <<<"$album_entry")" ]]; then
  selected_album_id=$(jq -r '.id // empty' <<<"$album_entry")
  selected_album_has_track=$(jq --arg aid "$selected_album_id" --arg tname "$track" '
    def normalize_track_title($value):
      ($value // "")
      | ascii_downcase
      | gsub("[’‘`´′]"; "\u0027")
      | gsub("\\[[^][]*\\]"; "")
      | gsub("\\([^()]*\\)"; "")
      | gsub(" - (album|single|radio|explicit|clean|mono|stereo|edit|version|mix|remaster(ed)?|acoustic|bonus)([^-]*)$"; "")
      | gsub("[[:space:]]+"; " ")
      | sub("^ "; "")
      | sub(" $"; "");
    [ (if type == "array" then . else [] end)[]
      | objects
      | select((.albumId // -1) == ($aid | tonumber))
      | select(normalize_track_title(.title) == normalize_track_title($tname))
    ]
    | if length > 0 then "true" else "false" end
  ' <<<"$all_artist_tracks")

  if [[ "$selected_album_has_track" != "true" ]]; then
    debug2 "Resolved album does not contain track in library metadata (artist='$artist' album='$(jq -r '.title // empty' <<<"$album_entry")' track='$track'); retrying track-only lookup"

    track_only_lookup=$(lookup_album_candidate "$artist" "$track" "" "$foreign_artist_id" "$source_album_artist" || true)
    track_only_fid=$(jq -r '.foreignAlbumId // empty' <<<"$track_only_lookup")

    if [[ -n "$track_only_fid" && "$track_only_fid" != "$foreign_album_id" ]]; then
      foreign_album_id="$track_only_fid"
      lookup_album_title=$(jq -r '.title // empty' <<<"$track_only_lookup")
      album_entry=$(jq --arg fid "$foreign_album_id" '
        .[] | select((.foreignAlbumId // empty) == $fid)
      ' <<<"$artist_albums")
      debug2 "Switched to track-only album candidate title='$lookup_album_title' foreignAlbumId='$foreign_album_id'"
    fi
  fi
fi

debug2 "Album foreign ID: $foreign_album_id"
debug2 "Found $(jq 'length' <<<"$artist_albums") albums for artist"

if [[ $DEBUG_LEVEL -ge 3 ]]; then
  jq -c '.[] | {id, title, foreignAlbumId, monitored}' <<<"$artist_albums" >&2
fi

debug2 "Matched album ID: $(jq -r '.id // empty' <<<"$album_entry")"
debug2 "Matched album title: $(jq -r '.title // empty' <<<"$album_entry")"

lidarr_album=$(jq -r '.title // empty' <<<"$album_entry")
[[ -z "$lidarr_album" ]] && lidarr_album="$lookup_album_title"

if [[ -z "$album_entry" ]] || [[ -z "$(jq -r '.id // empty' <<<"$album_entry")" ]]; then
  # Album not in library—create and monitor it
  if $DRY_RUN; then
    echo "WOULD CREATE ALBUM:"
    echo "  title=$lookup_album_title"
    echo "  foreignAlbumId=$foreign_album_id"
    echo "  artist=$artist"
    echo "  track=$track"
    echo "[DRY RUN] POST /album foreignAlbumId=$foreign_album_id artist=\"$artist\" track=\"$track\" album=\"$lookup_album_title\""
    continue
  fi

  album_create_payload=$(jq -nc \
    --arg artist_name "$resolved_name" \
    --arg artist_fid "$foreign_artist_id" \
    --arg fid "$foreign_album_id" \
    '{
      foreignAlbumId:$fid,
      monitored:true,
      artist:{
        artistName:$artist_name,
        foreignArtistId:$artist_fid,
        qualityProfileId:6,
        metadataProfileId:1,
        rootFolderPath:"/downloads/music"
      }
    }')

  album_create_response=$(curl -sS \
    -H "X-Api-Key: $LIDARR_API_KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    "$LIDARR_URL/api/v1/album" \
    -d "$album_create_payload" \
    -w $'\n%{http_code}')

  album_create_status=$(tail -n1 <<<"$album_create_response")
  album_create_body=$(sed '$d' <<<"$album_create_response")

  if [[ "$album_create_status" == "200" || "$album_create_status" == "201" ]]; then
    album_id=$(jq -r '.id // empty' <<<"$album_create_body")
    echo "Created album id=$album_id artist=\"$artist\" track=\"$track\" album=\"$lookup_album_title\""
    continue
  fi

  if [[ "$album_create_status" == "409" || ( "$album_create_status" == "400" && "$album_create_body" == *"AlbumExistsValidator"* ) ]]; then
    debug "Album create conflicted; re-querying existing artist albums for foreignAlbumId=$foreign_album_id"

    artist_albums=$(api \
      "$LIDARR_URL/api/v1/album?artistId=$artist_id" \
      || true)

    if [[ -z "$artist_albums" ]]; then
      echo "SKIP: failed to re-fetch albums after create conflict artist='$artist' track='$track' file='$file'" >&2
      continue
    fi

    album_entry=$(jq --arg fid "$foreign_album_id" '
      .[] | select((.foreignAlbumId // empty) == $fid)
    ' <<<"$artist_albums")

    lidarr_album=$(jq -r '.title // empty' <<<"$album_entry")

    if [[ -n "$(jq -r '.id // empty' <<<"$album_entry")" ]]; then
      debug "Resolved 409 conflict to existing album id=$(jq -r '.id' <<<"$album_entry")"
    else
      echo "SKIP: album create conflicted but album not found after requery artist=\"$artist\" track=\"$track\" album=\"$lookup_album_title\""
      continue
    fi
  else
    echo "SKIP: failed to create album artist=\"$artist\" track=\"$track\" album=\"$lookup_album_title\" status=$album_create_status" >&2
    [[ -n "$album_create_body" ]] && echo "$album_create_body" >&2
    continue
  fi
fi

  # -------------------------
  # album exists in library → ensure monitored
  # -------------------------
  monitored=$(jq -r '.monitored' <<<"$album_entry")

  if [[ "$monitored" == "true" ]]; then
    echo "OK: album already monitored artist=\"$artist\" track=\"$track\" lidarr_album=\"$lidarr_album\""
    retag_source_file_for_rescan "$file" "$artist" "$lidarr_album" "$track" "$source_album_artist" "$track_album" "$track_artist" "$track"
    trigger_rescan_for_file_dir "$file"
    continue
  fi

  echo "Album exists but NOT monitored → enabling monitoring artist=\"$artist\" track=\"$track\" lidarr_album=\"$lidarr_album\""

  if $DRY_RUN; then
    echo "[DRY RUN] PUT /album monitored=true artist=\"$artist\" track=\"$track\" lidarr_album=\"$lidarr_album\""
    continue
  fi

  album_id=$(jq -r '.id' <<<"$album_entry")

  updated=$(jq '.monitored=true' <<<"$album_entry")

  monitor_update_response=$(api -X PUT \
    "$LIDARR_URL/api/v1/album/$album_id" \
    -H "Content-Type: application/json" \
    -d "$updated" \
    || true)

  if [[ -z "$monitor_update_response" ]]; then
    echo "SKIP: failed to enable monitoring artist=\"$artist\" track=\"$track\" lidarr_album=\"$lidarr_album\"" >&2
    continue
  fi

  echo "Album monitoring enabled artist=\"$artist\" track=\"$track\" lidarr_album=\"$lidarr_album\""
  retag_source_file_for_rescan "$file" "$artist" "$lidarr_album" "$track" "$source_album_artist" "$track_album" "$track_artist" "$track"
  trigger_rescan_for_file_dir "$file"
done