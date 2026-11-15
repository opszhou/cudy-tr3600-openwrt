'use strict';
'require baseclass';

/*
 * 面板级样式补丁（只补布局留白，不重画任何组件）。
 *
 * 官方面板的标签面板本身没有内边距，表格标签会直接贴到标签栏边缘；
 * 这里给所有标签面板补一圈留白，让「互联网 / 系统 / 资源 / 无线」观感一致。
 * 样式随包走，不依赖主题（Argon / 原生都能用）。
 */

var STYLE_ID = 'sd-dashboard-style';

var CSS = [
	/* 面板内边距：标签栏下方、左右、底部都留够呼吸感（第一版 8/14/12 仍嫌挤） */
	'.cbi-map-tabbed > [data-tab] { padding: 16px 22px 20px; box-sizing: border-box; }',
	/* 面板内的分节标题（信号强度 / 网络状态 / 流量）上下都留白 */
	'.cbi-map-tabbed > [data-tab] > h3 { margin: 20px 0 10px; }',
	'.cbi-map-tabbed > [data-tab] > h3:first-child { margin-top: 0; }',
	/* 表格行加一点纵向间距，长表格不再糊成一片 */
	'.cbi-map-tabbed > [data-tab] > .table .tr > .td { padding-top: 9px; padding-bottom: 9px; }',
	/* 我们自己的详情容器不要再叠一层留白 */
	'.cbi-map-tabbed > [data-tab] > .sd-detail { padding: 0; }',
	/* 表格最后一行与面板底部留一点呼吸 */
	'.cbi-map-tabbed > [data-tab] > .table:last-child { margin-bottom: 0; }'
].join('\n');

return baseclass.extend({
	ensure: function() {
		if (typeof document === 'undefined')
			return;
		if (typeof document.getElementById === 'function' && document.getElementById(STYLE_ID))
			return;

		var head = document.head || document.querySelector('head');
		if (!head)
			return;

		var node = E('style', { 'type': 'text/css', 'id': STYLE_ID }, [ CSS ]);
		head.appendChild(node);
	}
});
