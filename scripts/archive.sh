#!/usr/bin/env bash
# archive.sh: скачивает с YouTube (1080p или макс.) и заливает на archive.org (айтем: arthas-archive-<id>)
set -eo pipefail

touch skip.txt verified.txt
: > done.txt; : > ok.txt; : > ids.txt
[ -f prev.json ] || : > prev.json

SKIP_TTL=2592000   # 30 дней
HARD=20400         # 340 мин от старта джоба
SOFT=19000         # после этого новые видео не начинаем
JOB_START="${JOB_START:-$(date +%s)}"
left() { echo $(( JOB_START + HARD - $(date +%s) )); }

# ---------- статус: status.json, skip.txt, verified.txt уходят в ветку status ----------
fail_run=0
cur_id=""; cur_title=""; cur_item=""; cur_stage="подготовка"

skip_add() {  # $1=id $2=через сколько дней повторить $3=причина
  echo "$1 $(( $(date +%s) - SKIP_TTL + $2 * 86400 )) $3" >> skip.txt
}

write_status() {  # $1 = running|ended|failed
  : >> skip.txt; : >> verified.txt; : >> ok.txt; : >> done.txt
  sort -k1,1 -k2,2nr skip.txt | awk '!s[$1]++' > skip.tmp && mv skip.tmp skip.txt
  sort -k1,1 -k3,3nr verified.txt | awk '!s[$1]++' > verified.tmp && mv verified.tmp verified.txt
  cat done.txt ok.txt | sort -u > all_done.txt
  if [ -s ids.txt ]; then
    nums=$(awk -F'\t' 'FILENAME==ARGV[1]{d[$1]=1;next} {t++; if($1 in d) a++} END{print t+0, a+0}' all_done.txt ids.txt) || nums=""
  else
    nums=$(jq -r '[(.total // ((.streams.total//0)+(.videos.total//0))),
                   (.archived // ((.streams.archived//0)+(.videos.archived//0)))]|@tsv' prev.json 2>/dev/null) || nums=""
  fi
  read -r tot arch <<< "${nums:-0 0}" || true
  sk=$(awk -v lim=$(( $(date +%s) - SKIP_TTL )) '$2>lim' skip.txt | wc -l)
  jq -n --arg u "$(date -u +%FT%TZ)" --arg s "$1" --arg cid "$cur_id" --arg cti "$cur_title" --arg cst "$cur_stage" --arg citem "$cur_item" \
    --argjson tot "$tot" --argjson arch "$arch" \
    --argjson ok "$(wc -l < ok.txt)" --argjson fl "$fail_run" --argjson sk "$sk" \
    '{updated:$u,state:$s,current:{id:$cid,item:$citem,title:$cti,stage:$cst},total:$tot,archived:$arch,run:{ok:$ok,failed:$fl},skipped:$sk}' > status.json
  rm -rf _st && mkdir _st && cp status.json skip.txt verified.txt _st/
  ( cd _st && git init -q -b status && git config user.name archive-bot \
    && git config user.email bot@users.noreply.github.com \
    && git add status.json skip.txt verified.txt && git commit -qm status \
    && git push -f -q "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" status ) || echo "WARN: статус не отправлен"
}
trap 'rc=$?; trap - EXIT; if [ "$rc" -eq 0 ]; then cur_stage="завершено"; write_status ended; else cur_stage="остановлено с ошибкой"; write_status failed || echo "::warning::статус не записан"; fi; exit "$rc"' EXIT

# ---------- имена айтемов на archive.org ----------
existing_item() {
  local id="$1" n
  # Проверяем новый формат, а затем старые поколения имен
  for n in "arthas-archive-$id" "arthas-$id" "arthas-stream-$id" "arthas-video-$id"; do
    if ia metadata "$n" --exists </dev/null >/dev/null 2>&1; then printf '%s' "$n"; return 0; fi
  done
  return 1
}
item_of() { existing_item "$1" || printf 'arthas-archive-%s' "$1"; }

# ---------- 0. проверки и cookies ----------
[ -n "${YT_COOKIES_B64:-}" ] || { echo "::error::Секрет YT_COOKIES_B64 не задан"; exit 1; }
[ -n "${IA_EMAIL:-}" ] || { echo "::error::Секрет IA_EMAIL не задан, список загруженного был бы пустым"; exit 1; }
echo "$YT_COOKIES_B64" | base64 -d > cookies.txt
chmod 600 cookies.txt
YT=(yt-dlp --cookies cookies.txt)

# ---------- 1. канал одним списком ----------
: > ids_raw.txt
list_tab() {
  "${YT[@]}" --no-match-filter --flat-playlist --extractor-args "youtubetab:approximate_date" \
    --print $'%(timestamp)s\t%(id)s\t%(title)s' "https://www.youtube.com/$CHANNEL/$1" >> ids_raw.txt \
    || echo "::warning::Не удалось получить список: $1"
}
list_tab streams
list_tab videos

awk -F'\t' 'BEGIN{OFS="\t"} {
  ts = ($1 ~ /^[0-9]+$/) ? $1 : 0
  if (!seen[$2]++) print $2, ts, $3, ++n
}' ids_raw.txt | sort -t$'\t' -k2,2n -k4,4nr | cut -f1-3 > ids.txt
[ -s ids.txt ] || { echo "::error::Список пуст: блокировка, протухшие куки или неверный CHANNEL"; exit 1; }

# ---------- 2. что уже загружено ----------
ia search "uploader:$IA_EMAIL AND NOT subject:$TAG-incomplete" --itemlist > ia_all.txt
ia search "uploader:$IA_EMAIL AND subject:$TAG AND NOT subject:$TAG-incomplete" --itemlist > ia_tag.txt

# Учитываем как arthas-archive-<id>, так и старые arthas-<id>, arthas-stream-<id> и youtube-<id>
{ grep -E '^arthas-' ia_all.txt || true; cat ia_tag.txt; } \
  | sed -E 's/^(youtube|arthas-archive|arthas-stream|arthas-video|arthas)-//' | sort -u > done.txt

# ---------- 2.5 активные пропуски ----------
awk -v lim=$(( $(date +%s) - SKIP_TTL )) '$2>lim{print $1}' skip.txt > skip_ids.txt
cat done.txt skip_ids.txt > excl.txt

# ---------- 3. очередь ----------
awk -F'\t' 'FILENAME==ARGV[1]{d[$1]=1; next} !($1 in d)' excl.txt ids.txt > todo.txt
echo "Всего на канале: $(wc -l < ids.txt)"
echo "Уже в архиве:    $(wc -l < done.txt)"
echo "В пропусках:     $(wc -l < skip_ids.txt)"
echo "К загрузке:      $(wc -l < todo.txt)"

write_status running || echo "::warning::не удалось обновить статус"

# Быстрая проверка куки
first=$(head -n 1 todo.txt | cut -f1)
if [ -n "$first" ]; then
  if ! out=$("${YT[@]}" --no-match-filter --skip-download --print id "https://youtu.be/$first" 2>&1 </dev/null); then
    echo "$out" | tail -n 5
    if grep -qiE 'cookies are no longer valid|not a bot' <<< "$out"; then
      echo "::error::Куки не работают, обнови секрет YT_COOKIES_B64"; exit 1
    fi
  fi
fi

# ---------- 4. скачиваем и заливаем ----------
PERM='Private video|members-only|Join this channel|has been removed|Video unavailable|has been terminated|not available in your country|copyright'
LIVE='live event will begin|Premieres in|live stream recording is not available'
bot_fails=0
fmt_fails=0

while IFS=$'\t' read -r id _ts title <&3; do
  rem=$(left)
  if [ $(( $(date +%s) - JOB_START )) -gt "$SOFT" ] || [ "$rem" -lt 900 ]; then
    echo "Лимит времени, продолжим в следующем запуске"
    break
  fi

  item=$(item_of "$id")
  echo "=== $item ==="
  cur_id="$id"; cur_item="$item"; cur_title="$title"; cur_stage="скачивание с YouTube"
  write_status running || echo "::warning::не удалось обновить статус"
  rm -rf dl; mkdir dl

  # Скачивает 1080p, если нет — максимально доступное (720p, 480p и т.д.)
  if ! timeout "$rem" "${YT[@]}" \
       -f "bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b/b" -S "ext:mp4:m4a" --merge-output-format mp4 \
       --max-filesize 12G --no-progress \
       --sleep-requests 1 --sleep-interval 5 --max-sleep-interval 15 --retries 5 \
       --write-info-json --write-thumbnail \
       -o "dl/$id.%(ext)s" "https://youtu.be/$id" </dev/null 2>&1 | tee dl.log; then
    echo "FAIL download $id"
    fail_run=$((fail_run+1))
    if grep -qiE 'cookies are no longer valid' dl.log; then
      echo "::error::Куки протухли, обнови секрет YT_COOKIES_B64"; exit 1
    elif grep -qiE 'not a bot' dl.log; then
      bot_fails=$((bot_fails+1))
      if [ "$bot_fails" -ge 3 ]; then
        echo "::error::YouTube блокирует запросы (бот-проверка), вероятно протухли куки"; exit 1
      fi
    elif grep -qiE 'Requested format is not available' dl.log; then
      fmt_fails=$((fmt_fails+1))
      if [ "$fmt_fails" -ge 5 ]; then
        echo "::error::5 видео подряд без доступных видеоформатов: проверь куки и версию yt-dlp/deno"; exit 1
      fi
      skip_add "$id" 3 no_format
    elif grep -qiE 'larger than max-filesize' dl.log; then
      skip_add "$id" 30 too_large
    elif grep -qiE 'confirm your age' dl.log; then
      skip_add "$id" 7 age
    elif grep -qiE "$LIVE" dl.log; then
      skip_add "$id" 1 live
    elif grep -qiE "$PERM" dl.log; then
      reason=$( (grep -oiE "$PERM" dl.log || true) | head -n1 | tr ' ' '_') || true
      skip_add "$id" 30 "${reason:-unavailable}"
    fi
    continue
  fi
  bot_fails=0; fmt_fails=0

  # Проверяем фильтр стримов
  if [ ! -f "dl/$id.info.json" ]; then
    if grep -qi 'does not pass filter' dl.log; then
      echo "SKIP $id: трансляция ещё идёт или завершилась менее 2 дней назад"
      skip_add "$id" 2 recent_or_live
    else
      echo "FAIL $id: info.json не создан"
      fail_run=$((fail_run+1))
    fi
    rm -rf dl
    continue
  fi

  jt=$(jq -r '.title // empty' "dl/$id.info.json")
  [ -n "$jt" ] && title="$jt"
  [ -n "$title" ] || title="$id"
  cur_title="$title"; cur_stage="заливка на archive.org"
  write_status running || echo "::warning::не удалось обновить статус"

  vdate=$(jq -r '.upload_date // empty' "dl/$id.info.json" \
          | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})$/\1-\2-\3/')
  desc=$(jq -r '(.description // "")[0:2000] | @html | gsub("\n";"<br>")' "dl/$id.info.json")

  vh=$(jq -r '.height // empty' "dl/$id.info.json")
  [ -n "$vh" ] || vh=1080
  max_yt_h=$(jq '[.formats[]?.height // 0] | max' "dl/$id.info.json")

  meta=(--metadata="mediatype:movies" --metadata="title:$title" --metadata="creator:$CREATOR"
        --metadata="source:https://youtu.be/$id" --metadata="subject:$TAG-incomplete")
  if [ -n "$vdate" ]; then meta+=(--metadata="date:$vdate"); fi
  if [ -n "$desc" ];  then meta+=(--metadata="description:$desc"); fi

  rem=$(left)
  if timeout "$rem" ia upload "$item" dl/"$id".* "${meta[@]}" --checksum --retries 5 </dev/null; then
    tagged=0
    for t in 1 2 3; do
      if ia metadata "$item" --modify="subject:$TAG" </dev/null; then tagged=1; break; fi
      sleep 10
    done
    if [ "$tagged" -eq 1 ]; then
      echo "OK $item (${vh}p)"
      echo "$id" >> ok.txt
      record_h="$vh"
      if [ -n "$max_yt_h" ] && [ "$max_yt_h" -lt 1080 ]; then
        record_h=1080
      fi
      echo "$id $record_h $(date +%s)" >> verified.txt
    else
      echo "FAIL tag $item (останется -incomplete)"
      fail_run=$((fail_run+1))
    fi
  else
    echo "FAIL upload $item"
    fail_run=$((fail_run+1))
  fi

  rm -rf dl
done 3< todo.txt