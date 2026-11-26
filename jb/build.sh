#!/bin/sh
# jb 工具箱构建脚本
#
# 运行位置：越狱设备的 shell（NewTerm / SSH），不要在 DSH Go 的虚拟 shell 里跑
#           —— 那里没有 clang，也没有 /var/jb。
#
# 用法：
#   ./build.sh helper            编译并安装 jbhelper 守护进程
#   ./build.sh tweak [工程目录]   用 Theos 编译 tweak（默认 tweak-template）
#   ./build.sh install <deb>     安装 deb 并重启目标 App
#   ./build.sh check             不需要 clang 的静态检查
#   ./build.sh token             打印 helper 令牌
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
JB_ROOT=${JB_ROOT:-/var/jb}
CC=${CC:-$JB_ROOT/usr/bin/clang}
THEOS=${THEOS:-$JB_ROOT/opt/theos}

die() { echo "错误: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "找不到 $1（先 apt install）"; }

cmd_helper() {
    need "$CC"
    [ -f "$ROOT/helper/jbhelper.m" ] || die "缺少 helper/jbhelper.m"
    echo "==> 编译 jbhelper"
    "$CC" -fobjc-arc -O2 -Wall -framework Foundation \
        -o "$ROOT/helper/jbhelper" "$ROOT/helper/jbhelper.m"
    echo "==> 安装到 $JB_ROOT/usr/bin/jbhelper"
    install -m 0755 "$ROOT/helper/jbhelper" "$JB_ROOT/usr/bin/jbhelper"
    install -m 0644 "$ROOT/helper/com.dsh.jbhelper.plist" \
        "$JB_ROOT/Library/LaunchDaemons/com.dsh.jbhelper.plist"
    echo "==> 重启 launchd 服务"
    launchctl bootout system "$JB_ROOT/Library/LaunchDaemons/com.dsh.jbhelper.plist" 2>/dev/null || true
    launchctl bootstrap system "$JB_ROOT/Library/LaunchDaemons/com.dsh.jbhelper.plist" \
        || die "bootstrap 失败，看 $JB_ROOT/var/log/jbhelper.err.log"
    sleep 1
    cmd_health
}

cmd_health() {
    if [ -f "$JB_ROOT/etc/jbhelper.token" ]; then
        TOKEN=$(cat "$JB_ROOT/etc/jbhelper.token")
        printf '健康检查: '
        curl -s -H "X-JB-Token: $TOKEN" http://127.0.0.1:8787/health 2>/dev/null || echo "（curl 不可用，跳过）"
        echo
        echo "令牌: $TOKEN"
        echo "把上面这行贴进 DSH-Go/jb/config.json 的 token 字段。"
    else
        echo "还没生成令牌，先跑一次 helper 再看。"
    fi
}

cmd_tweak() {
    PROJECT=${1:-$ROOT/tweak-template}
    [ -d "$PROJECT" ] || die "工程目录不存在: $PROJECT"
    [ -d "$THEOS" ] || die "找不到 Theos: $THEOS（export THEOS=... 指定）"
    need make
    echo "==> 编译 tweak: $PROJECT"
    make -C "$PROJECT" package THEOS="$THEOS"
    echo "==> 产物"
    ls -l "$PROJECT/.theos/_/debs/" 2>/dev/null || echo "（没找到 deb，看上面的报错）"
}

cmd_install() {
    DEB=${1:-}
    [ -n "$DEB" ] || die "用法: ./build.sh install <deb 路径>"
    [ -f "$DEB" ] || die "文件不存在: $DEB"
    need dpkg
    dpkg -i "$DEB"
    echo "==> 已安装。重启目标 App 让 ElleKit 重新注入：killall -9 <进程名>"
}

cmd_check() {
    echo "==> 1/3 JS 语法与 CLI"
    node "$ROOT/proxy/jb.mjs" >/dev/null 2>&1 || echo "   （exit=$? 属正常：缺 config 或没有子命令）"
    node "$ROOT/proxy/jb.mjs" inspect 2>&1 | head -1
    echo "==> 2/3 plist 结构"
    awk '/<dict>/{d++} /<\/dict>/{d--} /<array>/{a++} /<\/array>/{a--} END{printf "   dict=%d array=%d %s\n", d, a, (d==0&&a==0)?"OK":"BAD"}' \
        "$ROOT/helper/com.dsh.jbhelper.plist"
    echo "==> 3/3 ObjC 文件存在性与规模"
    wc -l "$ROOT/helper/jbhelper.m" "$ROOT/proxy/jb.mjs" "$ROOT/tweak-template/Tweak.x"
}

case ${1:-} in
    helper)  cmd_helper ;;
    tweak)   shift; cmd_tweak "$@" ;;
    install) shift; cmd_install "$@" ;;
    check)   cmd_check ;;
    token)   cmd_health ;;
    *)       sed -n '5,14p' "$0"; exit 1 ;;
esac
