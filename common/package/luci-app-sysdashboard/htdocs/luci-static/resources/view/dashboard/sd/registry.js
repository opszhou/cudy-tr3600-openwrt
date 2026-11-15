'use strict';
'require baseclass';
'require rpc';
'require view.dashboard.lib.charts as charts';
'require view.dashboard.sd.caps as capsModel';
'require view.dashboard.sd.catalog as catalog';
'require view.dashboard.sd.providers as providers';
'require view.dashboard.sd.visibility as visibility';
'require view.dashboard.sd.layout-note as layoutNote';
'require view.dashboard.include.10_router as incRouter';
'require view.dashboard.include.12_resources as incResources';
'require view.dashboard.include.15_traffic as incTraffic';
'require view.dashboard.include.20_lan as incLan';
'require view.dashboard.include.30_wifi as incWifi';

/*
 * 部件注册中心 —— 官方面板的唯一入口。
 *
 * 分工：
 *   注册与显隐  → 我们的 catalog / caps / visibility（统一，不看 netifd）
 *   网络侧内容  → sd/providers.js（我们自己实现）
 *   系统侧内容  → 官方 include 的 render 结果（内容本身没有问题，不重写）
 *
 * 官方 include 在这里被降级为「纯内容提供者」：
 *   widgets = []      不再声明部件 —— 否则同一 id 会被声明两次，默认布局里
 *                     该卡片会被渲染两遍（官方 defaults 不对 id 去重）
 *   available = false dashboard 不再加载/渲染它们 —— 省掉每轮重复取数，
 *                     改由我们在 load()/render() 里按需调用
 */

var callSnap = rpc.declare({ object: 'sysdashboard', method: 'get' });

var PROVIDERS = [ incRouter, incResources, incTraffic, incLan, incWifi ];

PROVIDERS.forEach(function(inc) {
	if (!inc)
		return;
	inc.widgets = [];
	inc.available = function() { return false; };
});

return baseclass.extend({
	load: function() {
		var tasks = PROVIDERS.map(function(inc) {
			return new Promise(function(resolve) {
				try {
					resolve((inc && typeof inc.load === 'function') ? inc.load() : null);
				}
				catch (e) {
					resolve(null);
				}
			}).catch(function() { return null; });
		});

		return Promise.all([ L.resolveDefault(callSnap(), null) ].concat(tasks))
			.then(function(res) {
				return { snap: res[0], official: res.slice(1) };
			});
	},

	render: function(data) {
		if (!data || !data.snap || !data.snap.ts)
			return null;

		var snap = data.snap;
		var caps = capsModel.from(snap);
		var official = this.collect(data.official);
		var self = this;

		try {
			providers.track(snap);
		}
		catch (e) { /* 速率历史失败不影响本次渲染 */ }

		var out = { cards: [], charts: [], tabs: [] };
		var vis = {};

		/* 标签的显隐要先算全量，visibility 需要一次拿到所有 tab id */
		catalog.widgets.forEach(function(w) {
			if (w.slot === 'tabs')
				vis[w.id] = (w.need == null) ? true : caps[w.need] === true;
		});

		catalog.widgets.forEach(function(w) {
			var avail = (w.need == null) ? true : caps[w.need] === true;

			if (w.slot === 'tabs') {
				out.tabs.push(self.buildTab(w, snap, caps, official, avail));
				return;
			}

			var node = null;
			if (avail) {
				try {
					node = self.buildNode(w, snap, caps, official);
				}
				catch (e) {
					node = null;
				}
			}

			/* 关键：不可用时也要 push，但 node 为 null。
			   官方按 layout 映射后 filter(item != null) 会丢掉它，
			   同时我们已经覆盖了同 id 的官方部件，避免它被回填显示。 */
			out[w.slot].push({ id: w.id, node: node });
		});

		visibility.apply(vis);

		try {
			layoutNote.ensure();
		}
		catch (e) { /* 说明注入失败不影响页面 */ }

		return out;
	},

	buildNode: function(w, snap, caps, official) {
		if (w.own)
			return (w.slot === 'cards') ? providers.card(w.id, snap, caps)
				: providers.chart(w.id, snap, caps);

		var item = official[w.slot] && official[w.slot][w.id];
		if (!item)
			return null;

		var v = item.node;
		return (typeof v === 'function') ? v() : v;
	},

	buildTab: function(w, snap, caps, official, avail) {
		var item = { id: w.id, title: w.title }, content = null, count = null;

		if (w.own) {
			var mine = providers.tab(w.id, snap, caps);
			if (mine) {
				content = mine.content;
				count = mine.count;
			}
		}
		else {
			var off = official.tabs && official.tabs[w.id];
			if (off) {
				var v = off.content;
				content = (typeof v === 'function') ? v() : v;
				if (off.title)
					item.title = off.title;
				if (off.count != null)
					count = off.count;
			}
		}

		/* 不可用时仍要注册（覆盖官方同 id），内容给空，由 CSS 连按钮一起隐藏 */
		if (!avail || content == null)
			content = charts.empty('');

		var tab = { id: item.id, title: item.title, content: content };
		if (count != null)
			tab.count = count;

		return tab;
	},

	/* 把官方 include 的 render 结果摊平成 slot -> id -> item */
	collect: function(datas) {
		var out = { cards: {}, charts: {}, tabs: {} };

		(datas || []).forEach(function(d, i) {
			var inc = PROVIDERS[i];
			if (d == null || !inc || typeof inc.render !== 'function')
				return;

			var r;
			try {
				r = inc.render(d);
			}
			catch (e) {
				return;
			}
			if (!r)
				return;

			[ 'cards', 'charts', 'tabs' ].forEach(function(slot) {
				(r[slot] || []).forEach(function(item) {
					if (item && item.id)
						out[slot][item.id] = item;
				});
			});
		});

		return out;
	},

	/* 交给官方面板的 include 对象 */
	build: function() {
		return {
			title: _('System dashboard'),
			params: [],
			widgets: catalog.declare(),
			load: this.load.bind(this),
			render: this.render.bind(this)
		};
	}
});
