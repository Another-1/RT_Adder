$ini_path = 'C:\OpenServer\domains\webtlo.local\data\config.ini'

Clear-Host
Write-Host 'Не обнаружено настроек' -ForegroundColor Red
Write-Host 'Вот и создадим их.' -ForegroundColor Green
Write-Host 'Для получения информации о хранимых разделах мне нужен путь к файлу настроек Web-TLO'
Write-Host 'Если путь верный, можно просто нажать Enter. Если нет - укажите верный'
while ( $true ) {
    If ( ( $prompt = Read-Host -Prompt "Путь к файлу [$ini_path]" ) -ne '' ) {
        $ini_path = $prompt
    }
    If ( Test-Path $ini_path ) {
        break
    }
    Write-Host 'Не нахожу такого файла, проверьте ввод' -ForegroundColor Red
}

Write-Output ( '$ini_path = ' + "'$ini_path'" ) | Out-File "$PSScriptRoot\_settings.ps1"