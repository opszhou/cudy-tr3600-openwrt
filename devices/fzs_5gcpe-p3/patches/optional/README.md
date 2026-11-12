# 诊断补丁（默认禁用）

`0002-diag-probe-ports.patch.disabled` 会把 MT7531 的 p0/p4/p5 与 MT7981 的 `gmac1` 一并暴露
（`probe0` / `probe4` / `probe5` / `eth1`），用来定位"板内连线的 RK3566 到底挂在哪一路"。

**默认不启用**：正式固件只需要 `lan1`(p1)/`lan2`(p2)/`wan`(p3)，多出来的端口对用户没有意义，
还会在 LuCI 里多出四个未配置接口。

需要诊断时：

```sh
git mv devices/fzs_5gcpe-p3/patches/optional/0002-diag-probe-ports.patch.disabled \
       devices/fzs_5gcpe-p3/patches/openwrt-25.12/0002-diag-probe-ports.patch
```

刷入后判读：

```sh
for n in probe0 probe4 probe5 eth1; do
  [ -e /sys/class/net/$n ] || continue
  ip link set "$n" up 2>/dev/null; sleep 1
  echo "$n carrier=$(cat /sys/class/net/$n/carrier) rx=$(cat /sys/class/net/$n/statistics/rx_packets)"
done
```

`probe5` 没有内部 PHY，carrier 可能不准，**以 rx/tx 计数是否增长为准**。
