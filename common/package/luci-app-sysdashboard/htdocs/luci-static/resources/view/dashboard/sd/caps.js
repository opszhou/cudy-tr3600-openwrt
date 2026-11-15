'use strict';
'require baseclass';

/*
 * 能力模型 —— 全项目唯一的「这个部件有没有数据」判定入口。
 *
 * 数据来自 rpcd 快照的 caps 字段（判定在数据层做，前端只读结论）：
 *   wan           默认路由所在设备存在且 operstate 不是 down
 *   wifi          有射频且存在 AP 接口（无线被禁用时 iw dev 里没有 Interface）
 *   wifiClients   无线关联客户端 > 0
 *   clients       租约 + ARP 合并后的在线设备 > 0
 *   modem         qmodem 的 ubus 对象存在
 *   signal        cell_info 给出了有效 RSRP
 *
 * 约定：字段缺失一律视为不可用 —— 宁可少显示一张卡，也不显示一张空卡。
 */
return baseclass.extend({
	from: function(snap) {
		var raw = (snap && snap.caps) || {};

		function ok(key) {
			return !!(raw[key] && raw[key].ok === true);
		}

		function count(key) {
			var c = raw[key] && raw[key].count;
			return (typeof c === 'number' && c > 0) ? c : 0;
		}

		var caps = {
			wan: ok('wan'),
			wifi: ok('wifi'),
			wifiClients: ok('wifi_clients'),
			clients: ok('clients'),
			modem: ok('modem'),
			signal: ok('signal'),
			count: {
				clients: count('clients'),
				wifiClients: count('wifi_clients')
			}
		};

		/* 复合能力：无线图表看的是「有客户端在连」，单看 wifi 会留一张空图 */
		caps.wifiActive = caps.wifi && caps.wifiClients;

		return caps;
	}
});
