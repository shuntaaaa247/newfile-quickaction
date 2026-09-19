#!/bin/bash
set -euo pipefail

REP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$REP_DIR/scripts/config.sh"

# LaunchAgent を削除する
if [ -f "$LAUNCH_AGENT_PLIST" ]; then
  launchctl bootout "gui/$UID/${LAUNCH_AGENT_LABEL:?LAUNCH_AGENT_LABEL is not set}" 2>/dev/null || true
  rm -f "$LAUNCH_AGENT_PLIST"
fi

# pbs のバックアップ
if [ -d "$PBS_BACKUP_DIR" ]; then
  # 直近のバックアップ（比較用）。1つも無ければ空
  # 日時ディレクトリはゼロ埋め固定長なので、名前順=新しい順になる
  PREV="$(ls -1 "$PBS_BACKUP_DIR" | tail -1)"
else
  PREV=""
fi

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

# 本ツールが作成した .workflow および pbs のキーを削除する
removed_workflow=()
for w in "$SERVICES_DIR"/*.workflow; do
  [ -d "$w" ] || continue
  id="$(plutil -extract CFBundleIdentifier raw "$w/Contents/Info.plist" 2>/dev/null || true)"
  case "$id" in
    "$BUNDLE_PREFIX".*) ;;  # 自分の物
    *) continue ;;          # 他人の物・IDなし → 触らない
  esac

  name="$(plutil -extract NSServices.0.NSMenuItem.default raw "$w/Contents/Info.plist" 2>/dev/null || true)"
  /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:\"$id - $name - runWorkflowAsService\"" "$TMP_PBS" 2>/dev/null || true
  rm -rf "$w"
  removed_workflow+=("$(basename "$w")")
done

# pbs への反映
if ! plutil -lint -s "$TMP_PBS"; then
  echo "エラー: 書き換えた pbs が壊れています。反映を中止しました（変更なし）。" >&2
  exit 1
fi
defaults import pbs "$TMP_PBS"
/System/Library/CoreServices/pbs -flush

# インストール時に展開した bin/ を削除する
# Templates/ と PBS_BACKUP/ には触れない
rm -rf "$BIN_DIR"

# アンインストールが実行されたことを伝えるメモファイルを置く
if [ -d "$TEMPLATES_DIR" ] || [ -d "$PBS_BACKUP_DIR" ]; then
  cat > "$APP_SUPPORT/$UNINSTALL_NOTE" << EOS
newfile-quickaction はアンインストール済みです。

削除したもの：
  - クイックアクションの .workflow（このツールが作成したものだけ）
  - クイックアクションのpbs（有効/無効の設定、このツールの項目だけ）
  - 生成スクリプト（bin/）
  - ファイル監視の設定（LaunchAgent、このツールが作成したものだけ）

残したもの:
  - Templates/ … あなたが編集・追加したテンプレートのため残しました
  - PBS_BACKUP/  … 設定を書き換える前のバックアップです（戻し方は README を参照）

残りも消す場合：
  rm -rf "$APP_SUPPORT"
EOS
fi

# 報告と終了コード
DONE=1
if [ ${#removed_workflow[@]} -gt 0 ]; then
  echo "次の項目を削除しました:"
  printf '  - %s\n' "${removed_workflow[@]}"
else
  echo "このツールがインストールした項目は見つかりませんでした。"
fi