#!/bin/bash
set -euo pipefail

REP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$REP_DIR/scripts/config.sh"

mkdir -p "$TEMPLATES_DIR"

if [ -f "$APP_SUPPORT/$UNINSTALL_NOTE" ]; then
  rm -f "$APP_SUPPORT/$UNINSTALL_NOTE"
fi

if [ ! -f "$TEMPLATES_DIR/New Text Document.txt" ]; then
  cp -p "$REP_DIR/templates/New Text Document.txt" "$TEMPLATES_DIR"
fi

if [ ! -f "$TEMPLATES_DIR/New Markdown.md" ]; then
  cp -p "$REP_DIR/templates/New Markdown.md" "$TEMPLATES_DIR"
fi

mkdir -p "$BIN_DIR"
cp -p "$REP_DIR/scripts/make-workflow.sh" "$REP_DIR/scripts/config.sh" "$BIN_DIR/"

mkdir -p "$PBS_BACKUP_DIR"
# 直近のバックアップ（比較用）。1つも無ければ空
# 日時ディレクトリはゼロ埋め固定長なので、名前順=新しい順になる
PREV="$(ls -1 "$PBS_BACKUP_DIR" | tail -1)"

TMP_PBS="$(mktemp "${TMPDIR:-/tmp}/nfq-pbs.XXXXXX")"
# このスクリプトが最後まで通過したかを表す。0なら未通過、1なら通過を表す
DONE=0
trap 'rc=$?; rm -f "$TMP_PBS"; [ "$DONE" = 1 ] || rc=1; exit $rc' EXIT

defaults export pbs "$TMP_PBS"

if [ -n "$PREV" ]; then
  PREV_XML="$(plutil -convert xml1 -o - "$PBS_BACKUP_DIR/$PREV/pbs.plist" 2>/dev/null)" || PREV_XML=""
else
  PREV_XML=""
fi
CURR_XML="$(plutil -convert xml1 -o - "$TMP_PBS")"

if [ -n "$CURR_XML" ] && [ "$PREV_XML" = "$CURR_XML" ]; then
  echo "pbs は前回のバックアップ ($PREV) から変化していないため、pbsのバックアップ作成をスキップしました。"
else
  # フォルダの命名規則は変更しない。変更すると上のPREVが最新のバックアップフォルダである保証がなくなる。
  SNAPSHOT_DIR="$PBS_BACKUP_DIR/$(date "+%Y-%m-%d_%H%M%S")"
  mkdir -p "$SNAPSHOT_DIR"
  cp "$TMP_PBS" "$SNAPSHOT_DIR/pbs.plist"
  echo "pbs 変更前に既存pbsのバックアップを $SNAPSHOT_DIR/pbs.plist に保存しました。"
fi

failed=()
created=()
GENERATED_IDS=""
removed_workflow=()

for template in "$TEMPLATES_DIR"/*; do
  [ -f "$template" ] || continue
  NAME="$(basename "$template")"

  if ! BUNDLEID="$("$BIN_DIR/make-workflow.sh" "$NAME" "$SERVICES_DIR")" || [ -z "$BUNDLEID" ]; then
    failed+=("$NAME")
    continue
  fi

  GENERATED_IDS="$GENERATED_IDS$BUNDLEID"$'\n'

  KEY="$BUNDLEID - $NAME - runWorkflowAsService"
  /usr/libexec/PlistBuddy \
    -c "Delete :NSServicesStatus:\"$KEY\"" \
    -c "Add :NSServicesStatus:\"$KEY\":presentation_modes:ContextMenu bool true" \
    -c "Add :NSServicesStatus:\"$KEY\":presentation_modes:FinderPreview bool true" \
    -c "Add :NSServicesStatus:\"$KEY\":presentation_modes:ServicesMenu bool true" \
    -c "Add :NSServicesStatus:\"$KEY\":presentation_modes:TouchBar bool false" \
    "$TMP_PBS" || true

  if [ "$(/usr/libexec/PlistBuddy -c "Print :NSServicesStatus:\"$KEY\":presentation_modes:ContextMenu" "$TMP_PBS" 2>/dev/null)" != true ]; then
    failed+=("$NAME")
    continue
  fi
  created+=("$NAME")
done

for w in "$SERVICES_DIR"/*.workflow; do
  [ -d "$w" ] || continue
  id="$(plutil -extract CFBundleIdentifier raw "$w/Contents/Info.plist" 2>/dev/null || true)"
  case "$id" in
    "$BUNDLE_PREFIX".*) ;;  # 自分の物。続けて判定する
    *) continue ;;          # 他人の物・IDなし → 触らない
  esac

  case $'\n'"$GENERATED_IDS" in
    *$'\n'"$id"$'\n'*) continue ;;  # 今回作ったものなので残す
  esac

  # ここに来たものが孤立した.workflow
  name="$(plutil -extract NSServices.0.NSMenuItem.default raw "$w/Contents/Info.plist" 2>/dev/null || true)"
  /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:\"$id - $name - runWorkflowAsService\"" "$TMP_PBS" 2>/dev/null || true
  rm -rf "$w"
  removed_workflow+=("$(basename "$w")")
done

if ! plutil -lint -s "$TMP_PBS"; then
  echo "エラー: 書き換えた pbs が壊れています。反映を中止しました（変更なし）。" >&2
  exit 1
fi

defaults import pbs "$TMP_PBS"
/System/Library/CoreServices/pbs -flush

echo "Finder で右クリック →「クイックアクション」に、次の項目を追加しました:"
for c in ${created[@]+"${created[@]}"}; do
  echo "  - $c"
done

cat << EOS

テンプレートの置き場所: ${TEMPLATES_DIR}（ここにファイルを置いてから install.sh を再実行すると、フォルダ内でファイルを作成できます）
初めて使うとき、Finder の操作を許可するダイアログが1回だけ出ます。「許可」を選んでください。

macOS $(sw_vers -productVersion) で実行しました（検証済み: 26.6.2）。
おかしな挙動があれば、Issue にこの出力全体を貼ってください。
EOS

if [ ${#removed_workflow[@]} -gt 0 ]; then
  echo "次の古い項目を削除しました:"
  printf '  - %s\n' "${removed_workflow[@]}"
fi

DONE=1
if [ ${#failed[@]} -gt 0 ]; then
  echo >&2
  echo "次のテンプレートは追加できませんでした:" >&2
  printf '  - %s\n' "${failed[@]}" >&2
  exit 1
fi
