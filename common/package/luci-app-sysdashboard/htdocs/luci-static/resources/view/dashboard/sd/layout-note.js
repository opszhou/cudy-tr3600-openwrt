'use strict';
'require baseclass';

/*
 * 布局页说明注入。
 *
 * 官方「布局」页由 view.dashboard.lib.layout 渲染（form.Map + 三个 DynamicList），
 * 没有可用的扩展点加说明文字，所以这里在布局面板顶部插一段描述。
 *
 * 注意：打开布局页时官方会 L.dom.content(form, ...) 重建内容，我们插的节点会被冲掉，
 * 因此每个轮询周期都检查一次（带 .sd-layout-note 标记保证不重复）。
 * 注入失败只丢说明文字，不影响任何功能。
 */

/* 追加到官方那句「列表从上到下…空列表显示默认」之后，不另起一块 */
var NOTE = 'Widgets without data are hidden automatically (offline, disabled interface, wireless off, no client) and reappear once the condition clears. Newly added widgets must be dragged into a list here and saved.';

return baseclass.extend({
	ensure: function() {
		if (typeof document === 'undefined')
			return;

		/* 只认标签组下的面板：直接查 [data-tab="layout"] 会先命中菜单里的 <li>，
		   把说明文字插进标签栏（用户实测截图就是这么错的） */
		var group = document.querySelector('.cbi-map-tabbed');
		var pane = group && group.querySelector(':scope > [data-tab="layout"]');
		if (!pane || pane.closest('.cbi-tabmenu') || pane.querySelector('.sd-layout-note'))
			return;

		var note = E('span', { 'class': 'sd-layout-note' }, [ ' ', _(NOTE) ]);

		/* 优先挂到官方那段说明后面，读起来是一段话；找不到描述时才自己起一行 */
		var descr = pane.querySelector('.cbi-section-descr');
		if (descr) {
			descr.appendChild(note);
		}
		else {
			pane.insertBefore(E('div', { 'class': 'cbi-section-descr' }, [ note ]), pane.firstChild);
		}
	}
});
