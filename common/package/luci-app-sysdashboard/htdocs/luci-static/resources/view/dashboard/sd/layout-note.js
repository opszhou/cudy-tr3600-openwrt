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

var NOTE = 'Widgets whose data is unavailable are hidden automatically — for example when the uplink is offline, the interface is disabled, wireless is off, or there is no client. They reappear within a few seconds once the condition is restored.';

return baseclass.extend({
	ensure: function() {
		if (typeof document === 'undefined')
			return;

		var pane = document.querySelector('[data-tab="layout"]');
		if (!pane || pane.querySelector('.sd-layout-note'))
			return;

		var note = E('div', { 'class': 'cbi-section-descr sd-layout-note' }, [ _(NOTE) ]);
		pane.insertBefore(note, pane.firstChild);
	}
});
