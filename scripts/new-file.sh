#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/config.sh"

# 作成するファイルのテンプレート名を取得
TEMPLATE_NAME="${1:-}"
[ -n "$TEMPLATE_NAME" ] || exit 0
shift
[ "$#" -gt 0 ] || exit 0

# Finder で選択されたファイル・フォルダがパッケージ(xxx.app)か判定
is_package() {
  local tree
  tree="$(/usr/bin/mdls -raw -name kMDItemContentTypeTree "$1" 2>/dev/null)" || return 1
  case "$tree" in
    *'"com.apple.package"'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Finder で選択されたファイル・フォルダの情報から、ファイルの作成先を決定
if [ "$#" -eq 1 ]; then
  if [ -d "$1" ] && ! is_package "$1"; then
    dest="$1"               # フォルダ1つ → その中
  else
    dest="$(dirname "$1")"  # ファイル / パッケージ　→ 同じ階層
  fi
else
  dest="$(dirname "$1")"
  shift
  # 複数のファイル・フォルダが選択された時に共通の祖先のディレクトリを探す
  for item in "$@"; do
    p="$(dirname "$item")"
    while [ "$dest" != "/" ] && [ "$p" != "$dest" ] && [ "${p#"$dest"/}" = "$p" ]; do
      dest="$(dirname "$dest")" # $dest は while のループごとに /path/to/dest → /path/to → /path → / と変化する
    done
  done
fi

# ファイルを作成
[ -d "$dest" ] || exit 1
/bin/cp "$TEMPLATES_DIR/$TEMPLATE_NAME" "$dest/$TEMPLATE_NAME"
# 継承したいのはモードだけなので、cp -p ではなく自分で写す。
# -p は作成日(birthtime)まで継承し、それを現在時刻に戻す標準コマンドが存在しないため
# （SetFile は Xcode Command Line Tools が必要）。-p なしなら作成日・変更日は現在になり、
# ロック(uchg)も付かない。cp は umask の影響を受けるが、ここで上書きするので結果は変わらない。
/bin/chmod "$(/usr/bin/stat -f %Lp "$TEMPLATES_DIR/$TEMPLATE_NAME")" "$dest/$TEMPLATE_NAME"
