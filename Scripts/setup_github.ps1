# NDICamera: автонастройка GitHub + бесплатная сборка IPA (PowerShell)
# Запуск:  powershell -NoProfile -ExecutionPolicy Bypass -File setup_github.ps1

$ErrorActionPreference = 'Continue'
cd (Split-Path -Parent $PSScriptRoot)

function Say($m) { Write-Host $m -ForegroundColor Cyan }
function Ok($m)  { Write-Host " [OK] $m" -ForegroundColor Green }
function Fail($m) { Write-Host " [X] $m" -ForegroundColor Red; Read-Host 'Нажми Enter'; exit 1 }

Say '============================================================'
Say ' NDICamera: автонастройка GitHub + сборка IPA (бесплатно)'
Say '============================================================'
Say ''

# 1. Поиск gh
$gh = $null
foreach ($cand in @('gh', "$env:ProgramFiles\GitHub CLI\gh.exe", "$env:LOCALAPPDATA\Programs\GitHub CLI\gh.exe")) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) { $gh = $cmd.Source; break }
}
if (-not $gh) { Fail 'gh CLI не найден. Установи: winget install GitHub.cli (затем перезапусти это окно)' }
Ok "gh: $gh"

# 1б. Поиск git (PowerShell не всегда видит git из git-bash)
$git = $null
foreach ($cand in @('git', "$env:ProgramFiles\Git\cmd\git.exe", "$env:ProgramFiles\Git\bin\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) { $git = $cmd.Source; break }
}
if (-not $git) { Fail 'git не найден. Установи: https://git-scm.com/download/win (затем перезапусти это окно)' }
Ok "git: $git"

# 2. Вход в GitHub
Say ''
Say '[1/5] Проверка входа в GitHub...'
& $gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Say 'Нужен вход. Откроется браузер с кодом — подтверди вход.'
    & $gh auth login --hostname github.com --web --git-protocol https
    if ($LASTEXITCODE -ne 0) { Fail 'Вход в GitHub не выполнен' }
}
Ok 'GitHub: вход есть'

# 3. Ветка main
& $git branch -M main 2>$null

# 4. Репозиторий + push
Say ''
Say '[2/5] Создание ПУБЛИЧНОГО репозитория NDICamera (бесплатные macOS-раннеры)...'
& $gh repo view NDICamera *> $null
if ($LASTEXITCODE -ne 0) {
    & $gh repo create NDICamera --public --source . --remote origin --push
    if ($LASTEXITCODE -ne 0) { Fail 'Не удалось создать репозиторий' }
} else {
    & $git remote add origin https://github.com/$((& $gh api user --jq .login))/NDICamera.git 2>$null
    & $git push -u origin main
}
Ok 'Репозиторий создан, код запушен'

# 5. Секреты
Say ''
Say '[3/5] Секреты для подписи (бесплатный Apple ID).'
Say '  - Apple ID: твой email от Apple'
Say '  - Пароль приложения: создай на https://appleid.apple.com -> "Пароли для приложений"'
Say '  - Team ID: https://appleid.apple.com -> Account -> Membership'
$appleId = Read-Host 'Apple ID (email)'
$applePass = Read-Host 'Пароль приложения' -AsSecureString
$teamId = Read-Host 'Team ID'
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($applePass))
& $gh secret set APPLE_ID --body $appleId
if ($LASTEXITCODE -ne 0) { Fail 'Не удалось задать APPLE_ID' }
& $gh secret set APPLE_APP_SPECIFIC_PASSWORD --body $plain
& $gh secret set TEAM_ID --body $teamId
Ok 'Секреты заданы'

# 6. Запуск сборки
Say ''
Say '[4/5] Запуск сборки (macOS runner, бесплатно)...'
& $gh workflow run build.yml
if ($LASTEXITCODE -ne 0) { Fail 'Не удалось запустить workflow' }
Ok 'Workflow запущен'

Say ''
Say '[5/5] Статус:'
& $gh run list --limit 3

Say ''
Say '============================================================'
Say ' ДАЛЬШЕ:'
Say '  1) Дождись завершения (5-15 минут в первый раз).'
Say '  2) Скачай артефакт NDICamera-signed.ipa со страницы Actions.'
Say '  3) Отправь его на iPhone (AirDrop/почта/файлы).'
Say '  4) На iPhone: Настройки -> Основные -> Управление VPN и'
Say '      устройствами -> Доверять разработчику.'
Say '  5) Открой .ipa - приложение установится.'
Say '  6) ВАЖНО: бесплатная подпись живёт 7 ДНЕЙ. Раз в неделю'
Say '      заходи в Actions, жми "Run workflow" и переустанавливай IPA.'
Say '============================================================'
Read-Host 'Готово. Нажми Enter для закрытия'
