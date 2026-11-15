'use strict';
'require baseclass';

/*
 * 统一的标签页显隐。
 *
 * 为什么标签不能像卡片那样「返回 null」：官方 collectSections 对 tabs 会
 * Object.assign({}, item, {content: node})，即使 content 为 null 也会建出一个空面板，
 * 标签按钮照样存在。所以这里用 body 状态类 + CSS 把「标签 + 菜单项」一起隐藏，
 * 并在选中项被隐藏时自动切到第一个可见标签，避免内容区空白。
 *
 * 卡片/图表不走这里：它们返回 node=null 会被官方 layout 映射后的 filter 丢掉。
 */

var CSS_READY = false;

return baseclass.extend({
	/* vis: { tabId: true|false } —— 必须每次传全量，CSS 规则只在首轮生成 */
	apply: function(vis) {
		if (typeof document === 'undefined' || !document.body)
			return;

		var ids = Object.keys(vis);

		if (!CSS_READY) {
			var head = document.head || document.querySelector('head');
			if (head) {
				head.appendChild(E('style', { 'type': 'text/css' },
					ids.map(function(id) {
						return 'body.sd-hide-tab-' + id + ' [data-tab="' + id + '"] { display: none !important; }';
					}).join('\n')));
			}
			CSS_READY = true;
		}

		ids.forEach(function(id) {
			document.body.classList.toggle('sd-hide-tab-' + id, !vis[id]);
		});

		if (typeof requestAnimationFrame !== 'function')
			return;

		requestAnimationFrame(function() {
			var group = document.querySelector('.cbi-map-tabbed');
			if (!group)
				return;

			var panes = Array.prototype.filter.call(group.children, function(el) {
				return el.dataset && el.dataset.tab;
			});
			if (!panes.length)
				return;

			/* ⛔ 不要用 data-tab-active 判断当前标签：LuCI 在用户点击切换时不会更新它，
			   拿它做判断会在切走之后把用户弹回第一个标签（实测「标签不能切换」）。
			   只看结果：还有任何面板是可见的就什么都不做。 */
			var shown = panes.filter(function(el) { return getComputedStyle(el).display !== 'none'; });
			if (shown.length)
				return;

			/* 所有面板都被隐藏（当前标签的数据没了）→ 切到第一个「应显示」的标签 */
			var next = panes.filter(function(el) { return vis[el.dataset.tab] !== false; })[0];
			if (!next)
				return;

			var menu = group.querySelector('.cbi-tabmenu');
			var link = menu && menu.querySelector('li[data-tab="' + next.dataset.tab + '"] > a');
			if (link)
				link.click();
		});
	}
});
