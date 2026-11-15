'use strict';
'require baseclass';
'require view.dashboard.sd.registry as registry';

/*
 * 官方面板的入口部件。
 *
 * 这里刻意保持极薄：部件声明在 sd/catalog.js，显隐判定在 sd/caps.js + sd/visibility.js，
 * 内容实现在 sd/providers.js（网络侧）与官方 include（系统侧），组装在 sd/registry.js。
 * 新增/调整部件只需要改 catalog，不再逐个改渲染代码。
 */
return registry.build();
