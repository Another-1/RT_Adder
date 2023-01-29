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

if ( ( $prompt = Read-host -Prompt "Токен бота Telegram, если нужна отправка событий в Telegram. Если не нужно, оставить пустым" ) -ne '' ) {
    $tg_token  = $prompt
    if ( ( $prompt = Read-host -Prompt "Номер чата для отправки сообщений Telegram" ) -ne '' ) {
        $tg_chat  = $prompt
    }
}

Write-Output ( '$tlo_path = ' + "'$tlo_path'" + "`r`n" + '$max_seeds = ' + $max_seeds  + "`r`n" + '$tg_token = '  + "'" + $tg_token + "'`r`n" + '$tg_chat = ' + "'" + $tg_chat + "'") | Out-File "$PSScriptRoot\_settings.ps1"
