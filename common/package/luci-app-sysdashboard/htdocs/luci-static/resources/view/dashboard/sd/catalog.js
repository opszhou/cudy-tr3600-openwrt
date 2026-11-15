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
 *
 * 新增部件只改这一张表；显隐、注册、布局说明全部由 registry / visibility 统一处理。
 * ⛔ 不要往 title 里拼"自动隐藏"之类后缀：布局页会列全部条目，后缀会把
 *    20 个条目全变成中英混排；隐藏规则统一由布局页顶部那一句说明承担。
 */
return baseclass.extend({
	widgets: [
		/* ---- 状态卡片 ---- */
		{ id: 'internet',    slot: 'cards',  title: _('Internet'),          order: 10, need: 'wan',         own: true },
		{ id: 'cell-signal', slot: 'cards',  title: _('Signal strength'),    order: 12, need: 'signal',      own: true },
		{ id: 'cellular',    slot: 'cards',  title: _('Network status'),     order: 13, need: 'modem',       own: true },
		{ id: 'traffic-usage', slot: 'cards', title: _('Data usage'),        order: 14, need: 'wan',         own: true },
		{ id: 'uptime',      slot: 'cards',  title: _('Uptime'),            order: 15, need: null,          own: false },
		{ id: 'cpu',         slot: 'cards',  title: _('CPU usage'),         order: 20, need: null,          own: false },
		{ id: 'memory',      slot: 'cards',  title: _('Memory'),            order: 30, need: null,          own: false },
		{ id: 'dhcp',        slot: 'cards',  title: _('DHCP Devices'),      order: 50, need: 'clients',     own: true },
		{ id: 'wifi',        slot: 'cards',  title: _('Wireless clients'),  order: 60, need: 'wifi',        own: false, hidden: true },
		{ id: 'load',        slot: 'cards',  title: _('Load average'),      order: 80, need: null,          own: false, hidden: true },

		/* ---- 实时图表 ---- */
		{ id: 'wan',         slot: 'charts', title: _('WAN traffic'),       order: 10, need: 'wan',         own: true },
		{ id: 'signal-trend',slot: 'charts', title: _('Signal trend'),       order: 15, need: 'signal',      own: true },
		{ id: 'clients-trend',slot:'charts', title: _('Online device trend'),order: 18, need: 'clients',     own: true },
		{ id: 'system',      slot: 'charts', title: _('System load'),       order: 20, need: null,          own: false },
		{ id: 'distribution',slot: 'charts', title: _('Wireless client distribution'), order: 30, need: 'wifiActive', own: false, hidden: true },
		{ id: 'signal',      slot: 'charts', title: _('Signal Strength'),   order: 40, need: 'wifiActive', own: false, hidden: true },
		{ id: 'traffic',     slot: 'charts', title: _('Wireless client data usage'), order: 50, need: 'wifiActive', own: false, hidden: true },

		/* ---- 详情标签页 ---- */
		{ id: 'internet',    slot: 'tabs',   title: _('Internet'),          order: 10, need: 'wan',         own: true },
		{ id: 'system',      slot: 'tabs',   title: _('System'),            order: 20, need: null,          own: false },
		{ id: 'resources',   slot: 'tabs',   title: _('Resources'),         order: 30, need: null,          own: false },
		{ id: 'dhcp',        slot: 'tabs',   title: _('DHCP Devices'),      order: 40, need: 'clients',     own: true },
		{ id: 'wifi',        slot: 'tabs',   title: _('Wireless'),          order: 50, need: 'wifi',        own: false, hidden: true }
	],

	/* 官方声明里写成数组，这里生成 LuCI 的 widgets 声明（标题保持干净） */
	declare: function() {
		return this.widgets.map(function(w) {
			var d = {
				id: w.id,
				slot: w.slot,
				title: w.title,
				order: w.order
			};
			if (w.hidden)
				d.hidden = true;
			return d;
		});
	}
});
