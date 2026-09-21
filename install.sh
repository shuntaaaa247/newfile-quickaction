#!/bin/bash
set -euo pipefail

# tarball で取得するリポジトリのパスとブランチ
REPO_ARCHIVE="https://github.com/shuntaaaa247/newfile-quickaction/archive"
NFQ_REF="${NFQ_REF:-main}"

# このスクリプトが最後まで通過したかを表す。0なら未通過、1なら通過を表す
DONE=0
# tarball をダウンロードし、展開するディレクトリ。tarball ではなくクローンで走らせる場合はこの変数(パス)は使用されない。
WORK_DIR=""
# 実際に編集を施す pbs のパス。一時ファイル上で編集を行い、最後に実際の pbs に反映する
TMP_PBS=""
# 本スクリプト終了時に、本スクリプトが作成した一時ファイル等を削除する
cleanup() {
  rc=$?
  [ -n "$TMP_PBS" ] && rm -f "$TMP_PBS"
  [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  # 最後までスクリプトが走らなかった(DONE=0)時、明示的に終了コードを1にする（bash 3.2 では set -u による終了時に trap が終了コードを 0 にするで、trap文内で直前の終了コードが握り潰されることがあるため）
  [ "$DONE" = 1 ] || rc=1
  exit $rc
}
trap cleanup EXIT

# 必要なコマンドが環境に入っているかチェックを行う関数
require_commands() {
  local missing=""
  local c
  for c in "$@"; do
    # ファイル c が存在し、かつ実行権限があるかを確認する
    [ -x "$c" ] || missing="$missing  - $c"$'\n'
  done
  if [ -n "$missing" ]; then
    echo "エラー: 必要なコマンドが見つかりません。" >&2
    printf '%s' "$missing" >&2
    echo "       macOS の標準コマンドです。パスが変わっていないか確認してください。" >&2
    exit 1
  fi
}

# 必要なスクリプトを github のリポジトリから tarball で取得する関数
fetch_source() {
  require_commands /usr/bin/curl /usr/bin/tar

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nfq-src.XXXXXX")"
  echo "配布物を取得しています ($NFQ_REF)…"
  if ! curl -fsSL "$REPO_ARCHIVE/$NFQ_REF.tar.gz" -o "$WORK_DIR/src.tar.gz"; then
    echo "エラー: 配布物をダウンロードできませんでした ($REPO_ARCHIVE/$NFQ_REF.tar.gz)" >&2
    exit 1
  fi
  mkdir "$WORK_DIR/src"
  tar -xzf "$WORK_DIR/src.tar.gz" -C "$WORK_DIR/src" --strip-components=1
  REP_DIR="$WORK_DIR/src"
}

# クローンから ./install.sh（または bash install.sh）で実行されたときだけ、すでに手元にある隣のファイルを使う
# この変数パスは、クローンから実行された場合はこの install.sh があるディレクトリ、 tarball 経由で実行された場合はダウンロードされたスクリプトが最初に展開される一時ディレクトリ(WORK_DIR)のパスとなる
REP_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  REP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi
# 手元に必要なスクリプト、ファイルがない(すなわちリポジトリのクローンではない)場合は、curl | bash で取得、展開する。
if [ -z "$REP_DIR" ] || [ ! -f "$REP_DIR/scripts/config.sh" ] || [ ! -d "$REP_DIR/templates" ]; then
  fetch_source
fi

# クローン or tarball 経由で取得した必要なスクリプトが格納されるファイルを読み込む
. "$REP_DIR/scripts/config.sh"

require_commands /usr/bin/plutil /usr/bin/defaults /usr/libexec/PlistBuddy \
                 /sbin/md5 /usr/bin/uuidgen /System/Library/CoreServices/pbs

# テンプレート（クイックアクションで作成するファイル）を格納するディレクトリをユーザーの環境に作成する
mkdir -p "$TEMPLATES_DIR"

# ユーザーの環境に本ツールのアンインストールの形跡(UNINSTALL_NOTE)があれば、インストール前にその形跡を削除する
if [ -f "$APP_SUPPORT/$UNINSTALL_NOTE" ]; then
  rm -f "$APP_SUPPORT/$UNINSTALL_NOTE"
fi

# 本ツールに標準内蔵されるテンプレートをユーザーの環境に保存する
if [ ! -f "$TEMPLATES_DIR/New Text Document.txt" ]; then
  cp -p "$REP_DIR/templates/New Text Document.txt" "$TEMPLATES_DIR"
fi
if [ ! -f "$TEMPLATES_DIR/New Markdown.md" ]; then
  cp -p "$REP_DIR/templates/New Markdown.md" "$TEMPLATES_DIR"
fi

# 本ツールの実行に必要なファイル群をユーザー環境に保存する
# 実行に必要なサブのスクリプトをユーザーの環境に保存する（テンプレート追加時にクイックアクションの設定を自動で再設定するスクリプト）
mkdir -p "$BIN_DIR"
cp -p "$REP_DIR/scripts/make-workflow.sh" "$REP_DIR/scripts/config.sh" "$BIN_DIR/"
# 本ツールの実行前の pbs 設定をバックアップとして保存する（実際の保存処理は後述）
mkdir -p "$PBS_BACKUP_DIR"
# 直近のバックアップ（比較用）。1つも無ければ空
# 日時ディレクトリはゼロ埋め固定長なので、名前順=新しい順になる
PREV="$(ls -1 "$PBS_BACKUP_DIR" | tail -1)"

# 実際に編集される pbs の設定ファイルを一時ファイルとして作成する（後に本番ファイルに反映する）
TMP_PBS="$(mktemp "${TMPDIR:-/tmp}/nfq-pbs.XXXXXX")"
defaults export pbs "$TMP_PBS"

# pbs のバックアップと現在の pbs を比較し、差分があれば新たにバックアップを作成する
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

# テンプレートごとにクイックアクションに必要な .workflow と pbs のキーを追加する
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
    "$TMP_PBS" 2>/dev/null || true

  if [ "$(/usr/libexec/PlistBuddy -c "Print :NSServicesStatus:\"$KEY\":presentation_modes:ContextMenu" "$TMP_PBS" 2>/dev/null)" != true ]; then
    failed+=("$NAME")
    continue
  fi
  created+=("$NAME")
done

# 複数回目の実行時に、不要になった本ツール製の .worlflow と pbs のキーを削除する（不要なクイックアクション項目を削除する）
for w in "$SERVICES_DIR"/*.workflow; do
  [ -d "$w" ] || continue

  if id="$(plutil -extract CFBundleIdentifier raw "$w/Contents/Info.plist" 2>/dev/null)"; then
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
  if name="$(plutil -extract NSServices.0.NSMenuItem.default raw "$w/Contents/Info.plist" 2>/dev/null)"; then
    :
  else
    name=""
  fi
  /usr/libexec/PlistBuddy -c "Delete :NSServicesStatus:\"$id - $name - runWorkflowAsService\"" "$TMP_PBS" 2>/dev/null || true
  rm -rf "$w"
  removed_workflow+=("$(basename "$w")")
done

# pbs のフォーマットをチェックし、問題がなければ本番の pbs に反映する
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

macOS $(sw_vers -productVersion) で実行しました（検証済み: 26.6.2 / 12.6.1）。
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
