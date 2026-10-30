/// 起终点选择页的**地图态**（KTD7 / R8）：可拖图的地图 + 固定准星 + 回填面板。
///
/// **为什么单独成文件**：地图态有自己的状态（准星坐标、逆地理结果、在途序号、
/// AMap 控制器）和独立的合规/降级分支；与列表态的搜索、防抖、交换无关。放在
/// 同一个 State 里会让两种形态的字段互相污染，也让「改成后端代理或换地图组件」
/// 时必须改动列表态的代码。
///
/// **口径不变**：地图不是独立页面，而是页内一层；返回列表不提交落针（R14）；
/// 未同意隐私协议时不做逆地理、并提示先同意（KTD5）；逆地理失败仍可回填坐标
/// （R13）。
library;

import 'dart:async';

import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../../design_tokens.dart';
import '../location/amap_degrade.dart';
import '../location/reverse_geocode.dart';

/// 地图态缩放级别：与发现侧选点页一致，能看清楼栋又不至于失去参照物。
const double kRoutePairMapZoom = 17;

/// 地图选点形态。
///
/// 参数：
/// - [initialTarget] 进入时的准星位置（起点 → 终点 → 会话最优点 → 城市中心）；
/// - [consented] 是否已同意隐私协议（未同意不发逆地理请求，KTD5）；
/// - [mapUsable] 是否可渲染真实地图（合规闸门 + SDK 初始化均已通过）；
/// - [targetLabel] 回填目标行的中文名（「起点」/「终点」）；
/// - [onPicked] 确认落针时回调：地点名（可空串）、经度、纬度；
/// - [onDegraded] 逆地理降级回调（页面据此上报 `amap_degraded`，每次进页最多一次）。
class RoutePairMapMode extends StatefulWidget {
  /// 构造地图选点形态。
  const RoutePairMapMode({
    super.key,
    required this.initialTarget,
    required this.consented,
    required this.mapUsable,
    required this.targetLabel,
    required this.onDegraded,
    required this.onPicked,
  });

  /// 进入时的准星位置。
  final LatLng initialTarget;

  /// 是否已同意隐私协议。
  final bool consented;

  /// 是否可渲染真实地图。
  final bool mapUsable;

  /// 回填目标行的中文名（「起点」/「终点」）。
  final String targetLabel;

  /// 逆地理降级回调。
  final void Function(AmapDegradeReason reason) onDegraded;

  /// 确认落针回调：地点名、经度、纬度。
  final void Function(String label, double lng, double lat) onPicked;

  @override
  State<RoutePairMapMode> createState() => _RoutePairMapModeState();
}

class _RoutePairMapModeState extends State<RoutePairMapMode> {
  late LatLng _target;
  String _address = '';
  bool _resolving = false;
  AMapController? _controller;
  int _addressSeq = 0;

  @override
  void initState() {
    super.initState();
    _target = widget.initialTarget;
    // 首帧后取一次地址，让面板在用户拖动前就有可读描述。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshAddress());
    });
  }

  /// 对当前准星位置做一次逆地理（只接受最后一次请求的结果）。
  ///
  /// 返回：Future，逆地理完成（成功或失败）后结束；失败时地址留空，坐标仍可回填。
  Future<void> _refreshAddress() async {
    final seq = ++_addressSeq;
    setState(() => _resolving = true);
    final label = widget.consented
        ? await reverseGeocodeLabel(
            lat: _target.latitude,
            lng: _target.longitude,
            onDegraded: widget.onDegraded,
          )
        : '';
    if (!mounted || seq != _addressSeq) return;
    setState(() {
      _address = label;
      _resolving = false;
    });
  }

  /// 移动准星到给定坐标并刷新地址。
  ///
  /// 参数：[target] 新的准星坐标。返回：void。
  void _moveTarget(LatLng target) {
    setState(() => _target = target);
    unawaited(_refreshAddress());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (widget.mapUsable)
                AMapWidget(
                  initialCameraPosition: CameraPosition(
                    target: widget.initialTarget,
                    zoom: kRoutePairMapZoom,
                  ),
                  onMapCreated: (controller) => _controller = controller,
                  onCameraMoveEnd: (camera) => _moveTarget(camera.target),
                  onTap: (target) {
                    _moveTarget(target);
                    _controller?.moveCamera(CameraUpdate.newLatLng(target));
                  },
                  compassEnabled: false,
                  scaleEnabled: true,
                )
              else
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Text(
                      widget.consented
                          ? '高德地图 Key 未配置，地图选点不可用'
                          : '请先同意隐私协议后再使用地图选点',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: AppTypeScale.body.size,
                        color: const Color(AppColors.textSecondary),
                      ),
                    ),
                  ),
                ),
              if (widget.mapUsable)
                IgnorePointer(
                  child: Align(
                    alignment: Alignment.center,
                    child: Transform.translate(
                      offset: const Offset(0, -18),
                      child: Icon(
                        Icons.place,
                        size: 40,
                        color: const Color(AppColors.primary),
                        shadows: const [
                          Shadow(color: Colors.black26, blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        _buildPanel(),
      ],
    );
  }

  /// 底部面板：地址核对 + 回填确认。
  ///
  /// 返回：面板控件；地图不可用时按钮不渲染，只提示返回列表。
  Widget _buildPanel() {
    final label = widget.targetLabel;
    return Container(
      width: double.infinity,
      color: const Color(AppColors.surface),
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.mapUsable
                ? '拖动地图，把准星对准$label'
                : '地图不可用，返回列表继续搜索',
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          if (widget.mapUsable) ...[
            const SizedBox(height: AppSpacing.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.location_on_outlined,
                  size: 18,
                  color: Color(AppColors.primary),
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    _resolving
                        ? '正在获取位置信息…'
                        : (_address.isEmpty ? '暂时无法获取位置名称' : _address),
                    style: TextStyle(
                      fontSize: AppTypeScale.body.size,
                      fontWeight: FontWeight.w600,
                      color: _address.isEmpty && !_resolving
                          ? const Color(AppColors.textSecondary)
                          : const Color(AppColors.textPrimary),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                onPressed: () => widget.onPicked(
                  _address,
                  _target.longitude,
                  _target.latitude,
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(AppColors.primary),
                  foregroundColor: const Color(AppColors.surface),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                ),
                child: Text(
                  '设为$label',
                  style: TextStyle(
                    fontSize: AppTypeScale.body.size,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
