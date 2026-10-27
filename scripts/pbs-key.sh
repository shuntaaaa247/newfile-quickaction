# pbs の NSServicesStatus のキーを組み立て、パーサごとに退避する。source 専用（実行しない・何も出力しない）
#
# このファイルを作った理由: キー文字列「<バンドルID> - <メニュー名> - runWorkflowAsService」を
# install.sh / uninstall.sh が共通で組み立てられるようにするため
#
# require_commands はここに移さないこと。

# pbs の NSServicesStatus のキーを組み立てる。$1=バンドルID $2=メニュー名
pbs_key() {
  printf '%s' "$1 - $2 - runWorkflowAsService"
}

# PlistBuddy は -c に渡したコマンド文字列を再パースし、' " \ を引用符・エスケープとして食う。
# また : はキーパスの区切りとして解釈される。NSServicesStatus のキーにはメニュー名
# （＝利用者が自由に付けたテンプレートのファイル名）が入るので、これらを事前に退避する。
# \ を最初に処理しないと、後続の置換で入れた \ をさらにエスケープしてしまう。
#
# 退避はキー全体に掛けてよい。バンドルID部に含まれるのは英数字とドットだけなので、
# 名前だけに掛けた場合と結果が同一になる。
pb_escape() {
  printf '%s' "$1" | /usr/bin/sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g" -e 's/"/\\"/g' -e 's/:/\\:/g'
}

# plutil のキーパスは . だけを区切りとして扱う。バンドルIDに . が含まれるので退避する。
plutil_escape() {
  printf '%s' "$1" | /usr/bin/sed 's/\./\\./g'
}
