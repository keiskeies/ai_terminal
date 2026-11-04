import 'package:flutter/material.dart';

/// 全局路由观察者：页面从设置页等子路由返回时触发 `didPopNext`，
/// 用于重新读取可能在设置页修改过的持久化配置（如端点/模型目录）。
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
