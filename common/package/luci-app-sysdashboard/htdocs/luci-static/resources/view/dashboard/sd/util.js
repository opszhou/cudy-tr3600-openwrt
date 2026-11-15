'use strict';
'require baseclass';

/*
 * 前端小工具：格式化与轻量 SVG。
 * 只放纯函数，不持有任何状态，便于沙箱单测。
 */
return baseclass.extend({
	fmtBytes: function(n) {
		n = Math.max(0, n || 0);
		var u = [ 'B', 'KB', 'MB', 'GB', 'TB' ], i = 0;
		while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
		return (i === 0 ? n.toFixed(0) : n.toFixed(1)) + ' ' + u[i];
	},

	fmtRate: function(n) {
		return this.fmtBytes(n) + '/s';
	},

	/* 两列键值表，沿用官方面板的 .table/.tr/.td 类，视觉与官方一致 */
	kvTable: function(rows) {
		var body = E('tbody', {});
		rows.forEach(function(r) {
			body.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '40%' }, [ r[0] ]),
				E('td', { 'class': 'td left' }, [ r[1] ])
			]));
		});
		return E('table', { 'class': 'table' }, [ body ]);
	},

	svgSeries: function(values, color, w, h, maxPoints) {
		var ns = 'http://www.w3.org/2000/svg';
		var max = 1, i, pts = [];
		for (i = 0; i < values.length; i++)
			max = Math.max(max, values[i]);
		for (i = 0; i < values.length; i++) {
			var x = 3 + (w - 6) * i / Math.max(1, (maxPoints || values.length) - 1);
			var y = h - 3 - (h - 6) * values[i] / max;
			pts.push((i ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1));
		}
		var svg = document.createElementNS(ns, 'svg');
		svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
		svg.setAttribute('width', '100%');
		svg.setAttribute('height', h);
		svg.setAttribute('preserveAspectRatio', 'none');
		var path = document.createElementNS(ns, 'path');
		path.setAttribute('d', pts.join(' ') || 'M0 0');
		path.setAttribute('fill', 'none');
		path.setAttribute('stroke', color);
		path.setAttribute('stroke-width', '2');
		svg.appendChild(path);
		return svg;
	}
});
