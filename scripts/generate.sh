#!/bin/bash

# テンプレートごとに .workflow を生成し、pbs の NSServicesStatus に登録する。
# 不要になった本ツール製の .workflow とキーも削除する。
#
# 外部コマンドは絶対パスで呼ぶ。launchd や Quick Action から走るときの PATH は
# /usr/bin:/bin:/usr/sbin:/sbin だけなので、PATH に依存しない形に揃える。

set -euo pipefail

# config.sh と pbs-key.sh は自分の隣から読む。リポジトリ内でも bin/ 内でも同じコードで動く
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/config.sh"
. "$SCRIPT_DIR/pbs-key.sh"

# このスクリプトが最後まで通過したかを表す。0なら未通過、1なら通過を表す
DONE=0
# 実際に編集を施す pbs のパス。一時ファイル上で編集を行い、最後に実際の pbs に反映する
TMP_PBS=""
# 本スクリプト終了時に、本スクリプトが作成した一時ファイルを削除する
cleanup() {
  rc=$?
  [ -n "$TMP_PBS" ] && /bin/rm -f "$TMP_PBS"
  # 最後までスクリプトが走らなかった(DONE=0)時、明示的に終了コードを1にする（bash 3.2 では
  # set -u による終了時に trap が終了コードを 0 にするので、直前の終了コードが握り潰されることがあるため）
  [ "$DONE" = 1 ] || rc=1
  exit $rc
}
trap cleanup EXIT

# 実際に編集される pbs の設定ファイルを一時ファイルとして作成する（後に本番ファイルに反映する）
TMP_PBS="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/nfq-pbs.XXXXXX")"
/usr/bin/defaults export pbs "$TMP_PBS"

failed=()
created=()
GENERATED_IDS=""
removed_workflow=()

# テンプレートごとにクイックアクションに必要な .workflow と pbs のキーを追加する
for template in "$TEMPLATES_DIR"/*; do
  [ -f "$template" ] || continue
  NAME="$(/usr/bin/basename "$template")"

  if ! BUNDLEID="$("$SCRIPT_DIR/make-workflow.sh" "$NAME" "$SERVICES_DIR")" || [ -z "$BUNDLEID" ]; then
    failed+=("$NAME")
    continue
  fi

  GENERATED_IDS="$GENERATED_IDS$BUNDLEID"$'\n'

  KEY="$(pbs_key "$BUNDLEID" "$NAME")"
  PB_KEY="$(pb_escape "$KEY")"
  /usr/libexec/PlistBuddy \
    -c "Delete :NSServicesStatus:\"$PB_KEY\"" \
    -c "Add :NSServicesStatus:\"$PB_KEY\":presentation_modes:ContextMenu bool true" \
    -c "Add :NSServicesStatus:\"$PB_KEY\":presentation_modes:FinderPreview bool true" \
    -c "Add :NSServicesStatus:\"$PB_KEY\":presentation_modes:ServicesMenu bool true" \
    -c "Add :NSServicesStatus:\"$PB_KEY\":presentation_modes:TouchBar bool false" \
    "$TMP_PBS" 2>/dev/null || true

  # 検証は PlistBuddy ではなく plutil で行う。同じパーサで読み戻すと、書き込み側の
  # 引用符の取りこぼしを読み戻し側も同じように間違えるため、キーが壊れていても一致してしまう。
  # それが「エラーが出ないのにメニューに出てこない」silent failure の原因だった。
  if [ "$(/usr/bin/plutil -extract "NSServicesStatus.$(plutil_escape "$KEY").presentation_modes.ContextMenu" raw -o - "$TMP_PBS" 2>/dev/null)" != true ]; then
    failed+=("$NAME")
    continue
  fi
  created+=("$NAME")
done

# 複数回目の実行時に、不要になった本ツール製の .workflow と pbs のキーを削除する（不要なクイックアクション項目を削除する）
for w in "$SERVICES_DIR"/*.workflow; do
  [ -d "$w" ] || continue

  if id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$w/Contents/Info.plist" 2>/dev/null)"; then
    :
  else
    id=""
  fi

  case "$id" in
    "$BUNDLE_PREFIX".*) ;;  # 自分の物。続けて判定する
    *) continue ;;          # 他人の物・IDなし → 触らない
  esac

  case $'\n'"$GENERATED_IDS" in
    *$'\n'"$id"$'\n'*) continue ;;  # 今回作ったものなので残す
  esac

  # ここに来たものが孤立した.workflow
  if name="$(/usr/bin/plutil -extract NSServices.0.NSMenuItem.default raw "$w/Contents/Info.plist" 2>/dev/null)"; then
    :
  else
    name=""
  fi
  /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:\"$(pb_escape "$(pbs_key "$id" "$name")")\"" "$TMP_PBS" 2>/dev/null || true
  /bin/rm -rf "$w"
  removed_workflow+=("$(/usr/bin/basename "$w")")
done

# pbs のフォーマットをチェックし、問題がなければ本番の pbs に反映する
if ! /usr/bin/plutil -lint -s "$TMP_PBS"; then
  echo "エラー: 書き換えた pbs が壊れています。反映を中止しました（変更なし）。" >&2
  exit 1
fi
/usr/bin/defaults import pbs "$TMP_PBS"
/System/Library/CoreServices/pbs -flush

echo "Finder で右クリック →「クイックアクション」に、次の項目を追加しました:"
for c in ${created[@]+"${created[@]}"}; do
  echo "  - $c"
done

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
