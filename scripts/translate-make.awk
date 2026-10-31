# 把 OpenWrt make 静默模式的进度行（make[N]: <路径>/<动作>）翻译成事件行，
# 其余行（警告/错误等）原样透传；纯噪音行（tools/compile、package/index、world 等）吞掉。
# 用法: make ... 2>&1 | awk -f scripts/translate-make.awk
# 示例: make[3]: package/feeds/packages/nginx/{clean,compile} -> "▶ nginx：清理+编译"
{
    line = $0
    if (match(line, /^make\[[0-9]+\]: /)) {
        tgt = substr(line, RSTART + RLENGTH)
        # 最后一个 "/" 之后是动作，倒数第二个字段是包名
        pos = 0
        for (i = length(tgt); i > 0; i--)
            if (substr(tgt, i, 1) == "/") { pos = i; break }
        if (pos == 0) next
        act = substr(tgt, pos + 1)
        path = substr(tgt, 1, pos - 1)
        ppos = 0
        for (i = length(path); i > 0; i--)
            if (substr(path, i, 1) == "/") { ppos = i; break }
        pkg = (ppos > 0) ? substr(path, ppos + 1) : path
        gsub(/[{}]/, "", act)
        out = ""
        n = split(act, acts, ",")
        known = 0
        for (j = 1; j <= n; j++) {
            a = acts[j]
            t = ""
            if      (a == "compile")    { t = "编译"; known = 1 }
            else if (a == "install")    { t = "安装"; known = 1 }
            else if (a == "prepare")    { t = "准备"; known = 1 }
            else if (a == "configure")  { t = "配置"; known = 1 }
            else if (a == "clean")      { t = "清理"; known = 1 }
            else if (a == "update")     { t = "更新"; known = 1 }
            else if (a == "refresh")    { t = "刷新"; known = 1 }
            out = out t
            if (j < n) out = out "+"
        }
        if (!known) next
        printf "▶ %s：%s\n", pkg, out
        fflush()
        next
    }
    print
    fflush()
}
