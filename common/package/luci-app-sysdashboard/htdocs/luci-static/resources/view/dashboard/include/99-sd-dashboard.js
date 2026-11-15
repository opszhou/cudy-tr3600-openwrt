'use strict';
'require baseclass';
'require view.dashboard.sd.registry as registry';

/*
 * 官方面板的入口部件（极薄包装）。
 *
 * 文件名用 99-sd- 前缀：
 *   99  —— 保证在官方 include（10_/12_/15_/20_/30_）之后加载，同 id 覆盖才有效
 *   sd- —— 命名空间隔离，避免将来上游新增同名 include 撞车
 *
 * 注意两个 LuCI 语义，踩过就别再踩：
 *   1) 模块必须返回**构造函数**（baseclass.extend 的产物）——返回普通对象会报
 *      "factory yields invalid constructor"，整个面板白屏。
 *   2) 'require x as y' 拿到的是**实例**（L.require 会 new 它），所以不能直接
 *      `return registry;`，要在这里重新 extend 一个类把调用转发过去。
 *
 * 部件声明在 sd/catalog.js，显隐判定在 sd/caps.js + sd/visibility.js，
 * 内容实现在 sd/providers.js（网络侧）与官方 include（系统侧），组装在 sd/registry.js。
 */
return baseclass.extend({
	title: registry.title,
	params: registry.params,
	widgets: registry.widgets,
	load: function() { return registry.load(); },
	render: function(data) { return registry.render(data); }
});
