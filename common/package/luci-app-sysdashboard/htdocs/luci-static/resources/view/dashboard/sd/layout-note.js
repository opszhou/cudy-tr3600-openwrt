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

/* 只留一句：布局页会列出全部部件，长说明会占满整屏 */
var NOTE = 'Widgets without data are hidden automatically (offline / interface disabled / wireless off / no client) and come back when the condition clears.';

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

		var note = E('div', { 'class': 'cbi-section-descr sd-layout-note' }, [ _(NOTE) ]);
		pane.insertBefore(note, pane.firstChild);
	}
});
