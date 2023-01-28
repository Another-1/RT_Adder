$tlo_path = 'C:\OpenServer\domains\webtlo.local'
$max_seeds = -1
Clear-Host
Write-Host 'Не обнаружено настроек' -ForegroundColor Red
Write-Host 'Вот и создадим их.' -ForegroundColor Green
Write-Host 'Для получения информации о коиентах и хранимых разделах мне нужен путь к каталогу Web-TLO'
Write-Host 'Если путь верный, можно просто нажать Enter. Если нет - укажите верный'
while ( $true ) {
    If ( ( $prompt = Read-Host -Prompt "Путь к папке Web-TLO [$tlo_path]" ) -ne '' ) {
        $tlo_path = $prompt -replace ( '\s+$', '') -replace '\\$','' 
    }
    $ini_path = $tlo_path  + '\data\config.ini'
    If ( Test-Path $ini_path ) {
        break
    }
    Write-Host 'Не нахожу такого файла, проверьте ввод' -ForegroundColor Red
}
if ( ( $prompt = Read-host -Prompt "Максимальное кол-во сидов для скачивания раздачи [$max_seeds]" ) -ne '' ) {
    $max_seeds = [int]$prompt
}

Write-Output ( '$tlo_path = ' + "'$tlo_path'" + "`r`n" + '$max_seeds = ' + $max_seeds ) | Out-File "$PSScriptRoot\_settings.ps1"

# . "$PSScriptRoot\_settings.ps1"
# $ini_data = Get-IniContent $ini_path
# if ( $ini_data.proxy.type -eq 'socks5h' ) {
#     Write-Host 'ВНИМАНИЕ! Powershell не поддерживает прокси типа SOCKS5H! Если у вас есть прямой доступ до трекера без прокси, можно его отключить. Другого решения (пока) нет.' -ForegroundColor Red
#     if ( ( $prompt = Read-Host -Prompt 'Отключить использование прокси? (Y/N) [Y]' ).ToLower() -eq 'n' ) {
#         Write-Host 'Тогда ничего не получится, выходим' -ForegroundColor Red
#         Remove-Item -Path "$PSScriptRoot\_settings.ps1"
#     }
#     else {
#         Write-Output ( '$ini_path = ' + "'$ini_path'" + "`r`n" + '$max_seeds = ' + "'$max_seeds'" + "`r`n" + '$forceNoProxy = $true') | Out-File "$PSScriptRoot\_settings.ps1"
#     }
# }
