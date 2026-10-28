<#
.SYNOPSIS
    真机运行统一入口：自动把环境变量里的高德 Key 以 --dart-define 注入。

.DESCRIPTION
    客户端高德 Key 是 Dart 编译期常量（lib/features/map/amap_init_guard.dart 的
    String.fromEnvironment），只能由构建命令的 --dart-define 注入。直接敲
    `flutter run` 不会编译报错，只会在真机上静默退化成「示意底图」，极易被
    误判成功能缺陷（2026-10-28 已实际发生一次）。

    本脚本从环境变量 AMAP_ANDROID_KEY 取值后转交 flutter run，未设置则直接
    报错退出，避免把漏注入的包装到真机。

    为什么用 $args 而不是 param：`-d <设备ID>` 这类原样透传的参数若声明成
    param，会被 PowerShell 当成脚本自身的参数名而绑定失败。

.PARAMETER RemainingArgs
    原样透传给 `flutter run` 的其余参数，如 `-d emulator-5554`、`--debug`。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tool/dev-run.ps1
    在当前连接的设备上以 debug 模式启动，并注入高德 Key。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tool/dev-run.ps1 -d emulator-5554
    指定设备启动。

.NOTES
    Key 的登记与取值见 deploy/docs/部署操作手册.md §11.1-4、§11.7。
#>
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:AMAP_ANDROID_KEY)) {
    throw 'AMAP_ANDROID_KEY 未设置：这样启动的包地图会退化成示意底图。请先 setx AMAP_ANDROID_KEY <key> 并重开终端（见部署操作手册 §11.1-4）。'
}

$flutterArgs = @('run', "--dart-define=AMAP_ANDROID_KEY=$($env:AMAP_ANDROID_KEY)") + $args
# 回显命令时把 Key 打成占位符：终端日志里也不留明文。
$maskedArgs = ($flutterArgs | ForEach-Object {
    $_ -replace [regex]::Escape($env:AMAP_ANDROID_KEY), '<AMAP_ANDROID_KEY>'
}) -join ' '
Write-Host "[dev-run] flutter $maskedArgs"

& flutter @flutterArgs
exit $LASTEXITCODE
