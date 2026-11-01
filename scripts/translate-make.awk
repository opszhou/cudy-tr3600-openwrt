# 把 OpenWrt make 静默模式的进度行翻译成事件行，其余行（警告/错误）原样透传，纯噪音吞掉。
# 用法: stdbuf -oL make ... 2>&1 | awk -f scripts/translate-make.awk
# 识别的两种真实格式：
#   make[3] -C feeds/packages/net/nginx compile              ← 每包构建的主格式（无冒号）
#   make[3] -C feeds/packages/net/nginx { clean compile }    ← 展开的目标列表
#   make[3]: package/feeds/packages/nginx/compile            ← 冒号形式（Entering/Leaving 等）
# 输出保留来源，便于定位包出自哪个 feed：
#   ▶ luci/luci-app-firewall：编译     ▶ kernel/mt76：编译     ▶ nikki：编译

function tr(a) {
    if (a == "compile")   return "编译"
    if (a == "install")   return "安装"
    if (a == "prepare")   return "准备"
    if (a == "configure") return "配置"
    if (a == "clean")     return "清理"
    if (a == "update")    return "更新"
    if (a == "refresh")   return "刷新"
    return ""
}

# "feeds/luci/applications/luci-app-firewall" -> "luci/luci-app-firewall"
# "feeds/nikki/nikki"                        -> "nikki"
# "package/kernel/mt76"                      -> "kernel/mt76"
# "tools/upx"                                -> "tools/upx"
function shortname(path,   n, seg, first, last) {
    n = split(path, seg, "/")
    if (n == 0) return path
    last = seg[n]
    if (seg[1] == "feeds" && n >= 2) first = seg[2]
    else if (seg[1] == "package" && n >= 2) first = seg[2]
    else first = seg[1]
    return (first == last) ? last : first "/" last
}

# 把 "compile" 或 "{ clean compile }" 这类目标串转成中文动作串
function actions(tgt,   n, acts, j, t, out, known) {
    gsub(/[{}]/, " ", tgt)
    n = split(tgt, acts, " ")
    out = ""; known = 0
    for (j = 1; j <= n; j++) {
        t = tr(acts[j])
        if (t != "") { known = 1; out = out (out == "" ? "" : "+") t }
    }
    return (known ? out : "")
}

{
    line = $0

    # 格式一：make[N] -C <路径> <目标...>
    if (match(line, /^make\[[0-9]+\] -C /)) {
        rest = substr(line, RSTART + RLENGTH)
        sp = index(rest, " ")
        if (sp > 0) {
            path = substr(rest, 1, sp - 1)
            tgt  = substr(rest, sp + 1)
            out  = actions(tgt)
            if (out != "") { printf "▶ %s：%s\n", shortname(path), out; fflush() }
        }
        next
    }

    # 格式二：make[N]: <路径>/<目标>（冒号形式）
    if (match(line, /^make\[[0-9]+\]: /)) {
        tgt = substr(line, RSTART + RLENGTH)
        pos = 0
        for (i = length(tgt); i > 0; i--)
            if (substr(tgt, i, 1) == "/") { pos = i; break }
        if (pos > 0) {
            out = actions(substr(tgt, pos + 1))
            if (out != "") { printf "▶ %s：%s\n", shortname(substr(tgt, 1, pos - 1)), out; fflush() }
        }
        next
    }

    # 每包耗时统计行（time: package/x/compile#0.1#0.2#0.3）纯噪音，吞掉
    if (line ~ /^time: /) next

    print
    fflush()
}
