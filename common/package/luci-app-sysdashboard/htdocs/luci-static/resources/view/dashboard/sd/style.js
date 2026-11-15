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
	/* 面板内边距：上 8px 让第一行不贴标签栏，左右 14px 让表格不贴边 */
	'.cbi-map-tabbed > [data-tab] { padding: 8px 14px 12px; box-sizing: border-box; }',
	/* 面板内首个标题不要顶出额外间距 */
	'.cbi-map-tabbed > [data-tab] > h3:first-child { margin-top: 2px; }',
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
