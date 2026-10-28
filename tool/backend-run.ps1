# 本机直跑后端的统一入口：按 .env 注入环境变量，再起 Spring Boot。
#
# 为什么需要这层：`.env` 里的 JDBC URL 含 `&`（`?sslMode=...&serverTimezone=...`），
# 为了 `set -a; source .env` 在 Git Bash / WSL 下不被 shell 当成后台运算符，
# **值必须带引号**；而 PowerShell 逐行注入时不会解析引号，会把 `'jdbc:...'`
# 连引号一起塞进环境变量，Spring 启动即报
# `'url' must start with "jdbc"`（2026-10-28 实际踩到，误判为代码缺陷排查了两轮）。
#
# 本脚本把「读 .env → 剥引号 → 校验必填 → 起服务」收敛成唯一实现处：
# 不再要求每个人手敲那行 pipeline，也不会再出现某个终端忘了剥引号。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tool/backend-run.ps1
#   powershell -ExecutionPolicy Bypass -File tool/backend-run.ps1 -DskipTests
#   powershell -ExecutionPolicy Bypass -File tool/backend-run.ps1 -EnvOnly   # 只验证注入
#
# 注意：本机 MySQL 跑在 WSL 的 `mysql8` 容器里。WSL 空闲会自动关闭，
# 关闭后容器随之停止、3306 拒绝连接（表现为 Connection refused，与代码无关）。
# 遇到该现象先执行一次任意 `wsl -e docker ps` 把 WSL 唤醒再跑本脚本。
param(
    [switch]$EnvOnly
)

$ErrorActionPreference = 'Stop'

# .env 位置：仓库根（与 src/ 同级），不随当前目录变化。
$envPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.env'
if (-not (Test-Path $envPath)) {
    throw "找不到 $envPath：请先 cp .env.example .env 并填入真实值。"
}

# 逐行解析 .env，剥掉成对的首尾引号后写入进程环境变量。
#
# 参数：无（读 $envPath）。
# 返回：无（副作用：设置 $env:*）。
function Import-DotEnv {
    param([string]$Path)

    foreach ($line in Get-Content -Path $Path) {
        $text = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text.StartsWith('#')) { continue }

        $eq = $text.IndexOf('=')
        if ($eq -le 0) { continue }

        $key = $text.Substring(0, $eq).Trim()
        $value = $text.Substring($eq + 1).Trim()

        # 只剥**成对**的首尾单引号 / 双引号：值内部的引号（JSON 里的 "）原样保留。
        if ($value.Length -ge 2) {
            $first = $value[0]
            $last = $value[$value.Length - 1]
            if (($first -eq "'" -and $last -eq "'") -or ($first -eq '"' -and $last -eq '"')) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        Set-Item -Path ("env:" + $key) -Value $value
    }
}

# 启动前点名缺失变量：application.yml 里是 `${VAR:?}` 硬占位，
# 缺一个就会在 Spring 绑定阶段抛一大段栈，看不出是「没加载 .env」。
#
# 参数：无（读环境变量）。
# 返回：无（缺失即抛错）。
function Assert-RequiredEnv {
    $required = @(
        'SPRING_DATASOURCE_URL',
        'SPRING_DATASOURCE_USERNAME',
        'SPRING_DATASOURCE_PASSWORD',
        'TRACK_DATASOURCE_URL',
        'SPRING_DATA_REDIS_PASSWORD',
        'AEAD_MASTER_KEYS_JSON',
        'HMAC_PEPPERS_JSON',
        'JWT_SECRET'
    )
    $missing = @($required | Where-Object { [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })
    if ($missing.Count -gt 0) {
        throw ("环境变量缺失：" + ($missing -join '、') + "（检查 .env 是否漏填）")
    }

    # 引号没剥干净时 URL 不以 jdbc 开头，这里直接点名，别等 Spring 报栈。
    foreach ($key in @('SPRING_DATASOURCE_URL', 'TRACK_DATASOURCE_URL')) {
        $url = [Environment]::GetEnvironmentVariable($key)
        if (-not $url.StartsWith('jdbc:')) {
            throw "$key 不以 jdbc: 开头（当前以 '$($url.Substring(0, [Math]::Min(8, $url.Length)))' 开头）：.env 里的引号未被剥掉。"
        }
    }
}

Import-DotEnv -Path $envPath
Assert-RequiredEnv

if ($EnvOnly) {
    Write-Host '[backend-run] .env 已注入，必填项校验通过（-EnvOnly：不启动服务）'
    exit 0
}

Write-Host '[backend-run] mvn -o spring-boot:run'
& mvn -o spring-boot:run @args
exit $LASTEXITCODE
