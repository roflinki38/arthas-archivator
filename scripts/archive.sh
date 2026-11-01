#!/usr/bin/env bash
# archive.sh: скачивает с YouTube (только 1080p) и заливает на archive.org, пишет статус в ветку status.
# Запускается из workflow (шаг Archive). Нужные переменные окружения:
#   CHANNEL, TAG, CREATOR, IA_EMAIL, GH_TOKEN, YT_COOKIES_B64, GITHUB_REPOSITORY
#   JOB_START (необязательно): unix-время старта джоба, от него считаются лимиты времени
# Рабочая папка: текущая. Файлы skip.txt и verified.txt подгружаются предыдущим шагом (Load state).
set -eo pipefail
touch skip.txt verified.txt

SKIP_TTL=2592000   # 30 дней
HARD=20400         # 340 мин от старта джоба: чуть меньше timeout-minutes, чтобы trap успел записать статус
SOFT=19000         # после этого новые видео не начинаем
JOB_START="${JOB_START:-$(date +%s)}"
left() { echo $(( JOB_START + HARD - $(date +%s) )); }

# ---------- 0. проверки и cookies ----------
[ -n "${YT_COOKIES_B64:-}" ] || { echo "::error::Секрет YT_COOKIES_B64 не задан"; exit 1; }
[ -n "${IA_EMAIL:-}" ] || { echo "::error::Секрет IA_EMAIL не задан, список загруженного был бы пустым"; exit 1; }
echo "$YT_COOKIES_B64" | base64 -d > cookies.txt
chmod 600 cookies.txt
YT=(yt-dlp --cookies cookies.txt)

# ---------- 1. все стримы и видео канала ----------
: > ids_raw.txt
list_tab() {  # $1=kind $2=вкладка
  "${YT[@]}" --flat-playlist --print "%(id)s %(title)s" "https://www.youtube.com/$CHANNEL/$2" \
    | sed "s/^/$1 /" >> ids_raw.txt || echo "::warning::Не удалось получить список: $2"
}
list_tab stream streams
list_tab video videos
awk '!seen[$2]++' ids_raw.txt > ids.txt
[ -s ids.txt ] || { echo "::error::Список пуст: блокировка, протухшие куки или неверный CHANNEL"; exit 1; }

# ---------- 2. что уже загружено ----------
ia search "uploader:$IA_EMAIL AND NOT subject:$TAG-incomplete" --itemlist > ia_all.txt
ia search "uploader:$IA_EMAIL AND subject:$TAG AND NOT subject:$TAG-incomplete" --itemlist > ia_tag.txt
{ grep -E '^arthas-[a-z]+-' ia_all.txt || true; cat ia_tag.txt; } \
  | sed -E 's/^(youtube|arthas-[a-z]+)-//' | sort -u > done.txt

# ---------- 2.5 активные пропуски (skip.txt загружен шагом Load state) ----------
awk -v lim=$(( $(date +%s) - SKIP_TTL )) '$2>lim{print $1}' skip.txt > skip_ids.txt
cat done.txt skip_ids.txt > excl.txt

# ---------- 3. очередь = разница ----------
awk 'FILENAME==ARGV[1]{d[$1]=1; next} !($2 in d)' excl.txt ids.txt > todo.txt
echo "Всего на канале: $(wc -l < ids.txt)"
echo "Уже в архиве:    $(wc -l < done.txt)"
echo "В пропусках:     $(wc -l < skip_ids.txt)"
echo "К загрузке:      $(wc -l < todo.txt)"

# ---------- статус: status.json, skip.txt, verified.txt уходят в ветку status ----------
: > ok.txt
fail_run=0
cur_id=""; cur_title=""; cur_item=""; cur_stage="подготовка"

skip_add() {  # $1=id $2=через сколько дней повторить $3=причина
  echo "$1 $(( $(date +%s) - SKIP_TTL + $2 * 86400 )) $3" >> skip.txt
}

write_status() {  # $1 = running|ended|failed
  sort -k1,1 -k2,2nr skip.txt | awk '!s[$1]++' > skip.tmp && mv skip.tmp skip.txt
  sort -k1,1 -k3,3nr verified.txt | awk '!s[$1]++' > verified.tmp && mv verified.tmp verified.txt
  cat done.txt ok.txt | sort -u > all_done.txt
  read -r st_t st_d vd_t vd_d < <(awk 'FILENAME==ARGV[1]{d[$1]=1;next} {t[$1]++; if($2 in d) a[$1]++} END{print t["stream"]+0, a["stream"]+0, t["video"]+0, a["video"]+0}' all_done.txt ids.txt)
  sk=$(awk -v lim=$(( $(date +%s) - SKIP_TTL )) '$2>lim' skip.txt | wc -l)
  jq -n --arg u "$(date -u +%FT%TZ)" --arg s "$1" --arg cid "$cur_id" --arg cti "$cur_title" --arg cst "$cur_stage" --arg citem "$cur_item" \
    --argjson st_t "$st_t" --argjson st_d "$st_d" --argjson vd_t "$vd_t" --argjson vd_d "$vd_d" \
    --argjson ok "$(wc -l < ok.txt)" --argjson fl "$fail_run" --argjson sk "$sk" \
    '{updated:$u,state:$s,current:{id:$cid,item:$citem,title:$cti,stage:$cst},streams:{total:$st_t,archived:$st_d},videos:{total:$vd_t,archived:$vd_d},run:{ok:$ok,failed:$fl},skipped:$sk}' > status.json
  rm -rf _st && mkdir _st && cp status.json skip.txt verified.txt _st/
  ( cd _st && git init -q -b status && git config user.name archive-bot \
    && git config user.email bot@users.noreply.github.com \
    && git add status.json skip.txt verified.txt && git commit -qm status \
    && git push -f -q "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" status ) || echo "WARN: статус не отправлен"
}
trap 'rc=$?; if [ $rc -eq 0 ]; then cur_stage="завершено"; write_status ended; else cur_stage="остановлено с ошибкой"; write_status failed; fi' EXIT
write_status running

# ---------- 3.5. быстрая проверка cookies на первом видео ----------
first=$(awk 'NR==1{print $2}' todo.txt)
if [ -n "$first" ]; then
  if ! out=$("${YT[@]}" --skip-download --print id "https://youtu.be/$first" 2>&1 </dev/null); then
    echo "$out" | tail -n 5
    if grep -qiE 'cookies are no longer valid|not a bot' <<< "$out"; then
      echo "::error::Куки не работают, обнови секрет YT_COOKIES_B64"; exit 1
    fi
  fi
fi

# ---------- 4. скачиваем и заливаем (только 1080p) ----------
PERM='Private video|members-only|Join this channel|has been removed|Video unavailable|has been terminated|not available in your country|copyright'
LIVE='live event will begin|Premieres in|live stream recording is not available'
bot_fails=0
fmt_fails=0

# stdin цикла идёт через fd 3, чтобы yt-dlp/ffmpeg/ia не съедали список
while read -r kind id title <&3; do
  rem=$(left)
  if [ $(( $(date +%s) - JOB_START )) -gt "$SOFT" ] || [ "$rem" -lt 900 ]; then
    echo "Лимит времени, продолжим в следующем запуске"
    break
  fi

  item="arthas-$kind-$id"
  echo "=== $item ==="
  cur_id="$id"; cur_item="$item"; cur_title="$title"; cur_stage="скачивание с YouTube"
  write_status running
  rm -rf dl; mkdir dl

  if ! timeout "$rem" "${YT[@]}" \
       -f "bv*[height=1080]+ba/b[height=1080]" -S "ext:mp4:m4a" --merge-output-format mp4 \
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
      # нет 1080p. Если так у многих подряд, скорее всего сломано извлечение
      fmt_fails=$((fmt_fails+1))
      if [ "$fmt_fails" -ge 5 ]; then
        echo "::error::5 видео подряд без 1080p: проверь куки и версию yt-dlp/deno"; exit 1
      fi
      if ia metadata "$item" --exists </dev/null >/dev/null 2>&1; then
        # на archive.org уже есть копия, а 1080p у YouTube нет: оставляем её как окончательную
        ia metadata "$item" --modify="subject:$TAG" </dev/null >/dev/null || true
        skip_add "$id" 30 no_1080p_kept
      else
        skip_add "$id" 3 no_1080p
      fi
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

  jt=$(jq -r '.title // empty' "dl/$id.info.json")
  [ -n "$jt" ] && title="$jt"
  [ -n "$title" ] || title="$id"
  cur_title="$title"; cur_stage="заливка на archive.org"
  write_status running

  vdate=$(jq -r '.upload_date // empty' "dl/$id.info.json" \
          | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})$/\1-\2-\3/')
  desc=$(jq -r '(.description // "")[0:2000] | @html | gsub("\n";"<br>")' "dl/$id.info.json")

  # пока заливка не завершена, айтем помечен -incomplete и считается недозалитым
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
      echo "OK $item"
      echo "$id" >> ok.txt
      echo "$id 1080 $(date +%s)" >> verified.txt   # новая заливка всегда 1080p, аудит её не перепроверяет
    else
      echo "FAIL tag $item (останется -incomplete, следующий запуск быстро доделает)"
      fail_run=$((fail_run+1))
    fi
  else
    echo "FAIL upload $item"
    fail_run=$((fail_run+1))
  fi

  rm -rf dl
done 3< todo.txt
