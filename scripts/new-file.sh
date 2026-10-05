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
/bin/cp -p "$TEMPLATES_DIR/$TEMPLATE_NAME" "$dest/$TEMPLATE_NAME"

# cp -p はモード以外も継承するので、コピー先では打ち消す。
# どちらも失敗してもファイル自体は正しく作れているので、エラーにはしない。
# ロック(uchg): 継承するとリネームも編集もできなくなる。テンプレートをロックする動機は
# テンプレート自身を誤編集から守ることなので、コピー側では外す。
/usr/bin/chflags nouchg "$dest/$TEMPLATE_NAME" 2>/dev/null || true
# 日時: 継承するとテンプレートの日付になり、日付順のフォルダで新規ファイルが先頭に来ない。
/usr/bin/touch "$dest/$TEMPLATE_NAME" 2>/dev/null || true
