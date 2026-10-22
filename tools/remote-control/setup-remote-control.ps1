# Claude Code 원격 제어(Remote Control) 원클릭 설정
# PC에서 실행하면 Claude Code 설치 -> 로그인 -> 원격 제어 시작까지 진행합니다.
$ErrorActionPreference = 'Stop'

Write-Host '=== Claude Code 원격 제어 설정 ===' -ForegroundColor Cyan

# 1. Claude Code 설치 확인
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host '[1/4] Claude Code 설치 중...' -ForegroundColor Yellow
    Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                "$env:USERPROFILE\.local\bin"
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Host '설치는 끝났지만 claude 명령을 찾지 못했습니다. 창을 닫고 이 파일을 다시 실행하세요.' -ForegroundColor Red
        Read-Host '엔터를 누르면 종료합니다'
        exit 1
    }
} else {
    Write-Host '[1/4] Claude Code 이미 설치됨' -ForegroundColor Green
}

# 2. 작업 폴더 선택
$default = (Get-Location).Path
$folder = Read-Host "[2/4] 휴대폰으로 작업할 폴더 경로 (그냥 엔터 = $default)"
if ([string]::IsNullOrWhiteSpace($folder)) { $folder = $default }
if (-not (Test-Path $folder)) {
    Write-Host "폴더가 없습니다: $folder" -ForegroundColor Red
    Read-Host '엔터를 누르면 종료합니다'
    exit 1
}
Set-Location $folder

# 3. 절전 모드 끄기 (선택)
$sleep = Read-Host '[3/4] 연결이 끊기지 않게 전원 연결 시 절전 모드를 끌까요? (Y/n)'
if ($sleep -ne 'n' -and $sleep -ne 'N') {
    powercfg /change standby-timeout-ac 0
    Write-Host '전원 연결 시 절전 모드를 껐습니다.' -ForegroundColor Green
}

# 4. 원격 제어 시작
Write-Host ''
Write-Host '[4/4] 원격 제어를 시작합니다.' -ForegroundColor Yellow
Write-Host ' - 로그인 창이 뜨면 휴대폰 앱과 같은 Claude 계정으로 로그인하세요.'
Write-Host ' - 이 창은 닫지 마세요. 닫으면 휴대폰 연결이 끊깁니다.'
Write-Host ' - 휴대폰 Claude 앱 > Code 탭에서 이 PC 세션을 선택하면 됩니다.'
Write-Host ''
claude remote-control
