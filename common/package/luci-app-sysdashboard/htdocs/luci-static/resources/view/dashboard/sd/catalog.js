'use strict';
'require baseclass';

/*
 * 部件清单 —— 全项目唯一的部件声明处。
 *
 * 字段：
 *   id      官方部件 id（同 id 覆盖，后注册者胜出；必须与官方保持一致）
 *   slot    cards / charts / tabs
 *   title   显示名（布局页与标签页都用它）
 *   order   排序（沿用官方 order，接管后顺序不变）
 *   hidden  官方默认布局里不显示（用户可在布局页手动加入）
 *   need    依赖的能力键（见 sd/caps.js）；null = 始终显示
 *   own     true = 内容由我们实现；false = 复用官方 include 的内容
 *   hint    自动隐藏说明（布局页显示在条目名后面）
 *
 * 新增部件只改这一张表；显隐、注册、布局说明全部由 registry / visibility 统一处理。
 */
var HINT = {
	offline: 'hidden when offline',
	noClient: 'hidden when there is no client',
	noWifi: 'hidden when wireless is disabled',
	noWifiClient: 'hidden when there is no wireless client',
	noModem: 'hidden when no modem is detected',
	always: 'always shown'
};

return baseclass.extend({
	hint: HINT,

	widgets: [
		/* ---- 状态卡片 ---- */
		{ id: 'internet',    slot: 'cards',  title: _('Internet'),          order: 10, need: 'wan',         own: true,  hint: HINT.offline },
		{ id: 'cell-signal', slot: 'cards',  title: _('Signal strength'),    order: 12, need: 'signal',      own: true,  hint: HINT.noModem },
		{ id: 'cellular',    slot: 'cards',  title: _('Network status'),     order: 13, need: 'modem',       own: true,  hint: HINT.noModem },
		{ id: 'traffic-usage', slot: 'cards', title: _('Data usage'),        order: 14, need: 'wan',         own: true,  hint: HINT.offline },
		{ id: 'uptime',      slot: 'cards',  title: _('Uptime'),            order: 15, need: null,          own: false, hint: HINT.always },
		{ id: 'cpu',         slot: 'cards',  title: _('CPU usage'),         order: 20, need: null,          own: false, hint: HINT.always },
		{ id: 'memory',      slot: 'cards',  title: _('Memory'),            order: 30, need: null,          own: false, hint: HINT.always },
		{ id: 'dhcp',        slot: 'cards',  title: _('DHCP Devices'),      order: 50, need: 'clients',     own: true,  hidden: true, hint: HINT.noClient },
		{ id: 'wifi',        slot: 'cards',  title: _('Wireless clients'),  order: 60, need: 'wifi',        own: false, hidden: true, hint: HINT.noWifi },
		{ id: 'load',        slot: 'cards',  title: _('Load average'),      order: 80, need: null,          own: false, hidden: true, hint: HINT.always },

		/* ---- 实时图表 ---- */
		{ id: 'wan',         slot: 'charts', title: _('WAN traffic'),       order: 10, need: 'wan',         own: true,  hint: HINT.offline },
		{ id: 'system',      slot: 'charts', title: _('System load'),       order: 20, need: null,          own: false, hint: HINT.always },
		{ id: 'distribution',slot: 'charts', title: _('Wireless client distribution'), order: 30, need: 'wifiActive', own: false, hidden: true, hint: HINT.noWifiClient },
		{ id: 'signal',      slot: 'charts', title: _('Signal Strength'),   order: 40, need: 'wifiActive', own: false, hidden: true, hint: HINT.noWifiClient },
		{ id: 'traffic',     slot: 'charts', title: _('Wireless client data usage'), order: 50, need: 'wifiActive', own: false, hidden: true, hint: HINT.noWifiClient },

		/* ---- 详情标签页 ---- */
		{ id: 'internet',    slot: 'tabs',   title: _('Internet'),          order: 10, need: 'wan',         own: true,  hint: HINT.offline },
		{ id: 'system',      slot: 'tabs',   title: _('System'),            order: 20, need: null,          own: false, hint: HINT.always },
		{ id: 'resources',   slot: 'tabs',   title: _('Resources'),         order: 30, need: null,          own: false, hint: HINT.always },
		{ id: 'dhcp',        slot: 'tabs',   title: _('DHCP Devices'),      order: 40, need: 'clients',     own: true,  hint: HINT.noClient },
		{ id: 'wifi',        slot: 'tabs',   title: _('Wireless'),          order: 50, need: 'wifi',        own: false, hidden: true, hint: HINT.noWifi }
	],

	/* 官方声明里写成数组，这里生成 LuCI 的 widgets 声明（标题带自动隐藏说明） */
	declare: function() {
		return this.widgets.map(function(w) {
			var d = {
				id: w.id,
				slot: w.slot,
				title: '%s · %s'.format(w.title, _(w.hint)),
				order: w.order
			};
			if (w.hidden)
				d.hidden = true;
			return d;
		});
	}
});
